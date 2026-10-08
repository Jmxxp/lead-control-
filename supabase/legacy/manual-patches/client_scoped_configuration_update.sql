-- Configuracoes individuais por loja e imagens de perfil.
-- Rode depois de b2b_client_hierarchy_update.sql.

begin;

set search_path = public, extensions;

alter table public.app_users
  add column if not exists avatar_url text;

alter table public.stores
  add column if not exists avatar_url text;

alter table public.lead_options
  add column if not exists store_id uuid;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'lead_options_store_fk'
      and conrelid = 'public.lead_options'::regclass
  ) then
    alter table public.lead_options
      add constraint lead_options_store_fk
      foreign key (store_id) references public.stores(id) on delete cascade;
  end if;
end;
$$;

alter table public.lead_options
  drop constraint if exists lead_options_unique_value;

create unique index if not exists lead_options_store_group_value_idx
  on public.lead_options (store_id, group_key, value)
  where store_id is not null;

create index if not exists lead_options_store_group_sort_idx
  on public.lead_options (store_id, group_key, sort_order)
  where store_id is not null and is_active = true;

-- Copia configuracoes antigas para lojas existentes. Lojas novas permanecem vazias.
insert into public.lead_options (
  admin_user_id,
  store_id,
  group_key,
  value,
  sort_order,
  fixed,
  is_active
)
select
  old_option.admin_user_id,
  st.id,
  old_option.group_key,
  old_option.value,
  old_option.sort_order,
  (old_option.group_key in ('scheduled', 'visited', 'bought')),
  old_option.is_active
from public.lead_options old_option
join public.stores st on st.admin_user_id = old_option.admin_user_id
where old_option.store_id is null
  and not exists (
    select 1
    from public.lead_options scoped
    where scoped.store_id = st.id
      and scoped.group_key = old_option.group_key
      and scoped.value = old_option.value
  );

-- Plataformas, campanhas e demais configuracoes sao totalmente editaveis
-- dentro de cada loja, inclusive valores que eram fixos no modelo antigo.
update public.lead_options
set fixed = false
where store_id is not null
  and group_key not in ('scheduled', 'visited', 'bought')
  and fixed = true;

-- O modelo novo nao possui opcoes globais do admin. Mantemos a assinatura
-- porque a criacao de admin existente chama esta rotina, mas novos cadastros
-- nao recebem campanhas, plataformas ou conclusoes predefinidas.
create or replace function app_private.seed_default_options(p_admin_user_id uuid)
returns void
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
begin
  return;
end;
$$;

alter table public.lead_custom_categories
  add column if not exists store_id uuid;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'lead_custom_categories_store_fk'
      and conrelid = 'public.lead_custom_categories'::regclass
  ) then
    alter table public.lead_custom_categories
      add constraint lead_custom_categories_store_fk
      foreign key (store_id) references public.stores(id) on delete cascade;
  end if;
end;
$$;

drop index if exists public.lead_custom_categories_unique_name_idx;

create unique index if not exists lead_custom_categories_store_unique_name_idx
  on public.lead_custom_categories (store_id, lower(name))
  where store_id is not null and is_active = true;

create index if not exists lead_custom_categories_store_sort_idx
  on public.lead_custom_categories (store_id, sort_order, created_at)
  where store_id is not null and is_active = true;

-- Clona categorias/opcoes antigas por loja e preserva os valores dos leads.
do $$
declare
  v_scope record;
  v_new_category_id uuid;
begin
  for v_scope in
    select
      old_category.id as old_category_id,
      old_category.admin_user_id,
      old_category.name,
      old_category.sort_order,
      old_category.is_active,
      st.id as store_id
    from public.lead_custom_categories old_category
    join public.stores st on st.admin_user_id = old_category.admin_user_id
    where old_category.store_id is null
  loop
    select scoped.id
    into v_new_category_id
    from public.lead_custom_categories scoped
    where scoped.store_id = v_scope.store_id
      and lower(scoped.name) = lower(v_scope.name)
    limit 1;

    if v_new_category_id is null then
      insert into public.lead_custom_categories (
        admin_user_id,
        store_id,
        name,
        sort_order,
        is_active
      )
      values (
        v_scope.admin_user_id,
        v_scope.store_id,
        v_scope.name,
        v_scope.sort_order,
        v_scope.is_active
      )
      returning id into v_new_category_id;
    end if;

    insert into public.lead_custom_options (
      admin_user_id,
      category_id,
      value,
      sort_order,
      is_active
    )
    select
      old_option.admin_user_id,
      v_new_category_id,
      old_option.value,
      old_option.sort_order,
      old_option.is_active
    from public.lead_custom_options old_option
    where old_option.category_id = v_scope.old_category_id
      and not exists (
        select 1
        from public.lead_custom_options scoped_option
        where scoped_option.category_id = v_new_category_id
          and lower(scoped_option.value) = lower(old_option.value)
      );

    update public.lead_custom_values custom_value
    set category_id = v_new_category_id
    where custom_value.category_id = v_scope.old_category_id
      and exists (
        select 1
        from public.leads l
        where l.id = custom_value.lead_id
          and l.store_id = v_scope.store_id
      );
  end loop;
end;
$$;

create or replace function app_private.resolve_configuration_store(
  p_session_token text,
  p_store_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_store_id uuid;
begin
  select * into v_session from app_private.session_user(p_session_token);
  v_store_id := case
    when v_session.user_role::text = 'store' then v_session.user_store_id
    else p_store_id
  end;

  if v_store_id is null then
    raise exception 'Selecione uma loja.';
  end if;

  if not exists (
    select 1
    from public.stores st
    where st.id = v_store_id
      and st.admin_user_id = v_session.admin_user_id
      and st.is_active = true
      and (
        v_session.user_role::text = 'admin'
        or (v_session.user_role::text = 'technician' and st.technician_user_id = v_session.user_id)
        or (v_session.user_role::text = 'store' and st.id = v_session.user_store_id)
      )
  ) then
    raise exception 'Loja nao encontrada ou sem permissao.';
  end if;

  return v_store_id;
end;
$$;

create or replace function app_private.next_store_option_label(
  p_store_id uuid,
  p_group_key public.lead_option_group
)
returns text
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_base text := 'Nova opcao';
  v_label text := 'Nova opcao';
  v_counter integer := 2;
begin
  while exists (
    select 1 from public.lead_options
    where store_id = p_store_id
      and group_key = p_group_key
      and lower(value) = lower(v_label)
      and is_active = true
  ) loop
    v_label := v_base || ' ' || v_counter;
    v_counter := v_counter + 1;
  end loop;
  return v_label;
end;
$$;

drop function if exists public.lc_list_options(text);
drop function if exists app_private.rpc_list_options(text);

create or replace function app_private.rpc_list_options(
  p_session_token text,
  p_store_id uuid default null
)
returns table (
  id uuid,
  group_key public.lead_option_group,
  value text,
  sort_order integer,
  fixed boolean
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_store_id uuid;
begin
  v_store_id := app_private.resolve_configuration_store(p_session_token, p_store_id);
  return query
  select o.id, o.group_key, o.value, o.sort_order, o.fixed
  from public.lead_options o
  where o.store_id = v_store_id
    and o.is_active = true
  order by o.group_key, o.sort_order, o.created_at;
end;
$$;

create or replace function public.lc_list_options(
  p_session_token text,
  p_store_id uuid default null
)
returns table (
  id uuid,
  group_key public.lead_option_group,
  value text,
  sort_order integer,
  fixed boolean
)
language sql
security invoker
as $$
  select * from app_private.rpc_list_options(p_session_token, p_store_id);
$$;

drop function if exists public.lc_add_option(text, public.lead_option_group, text);
drop function if exists app_private.rpc_add_option(text, public.lead_option_group, text);

create or replace function app_private.rpc_add_option(
  p_session_token text,
  p_group_key public.lead_option_group,
  p_value text default null,
  p_store_id uuid default null
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_store_id uuid;
  v_value text;
  v_sort_order integer;
begin
  select * into v_session from app_private.session_user(p_session_token);
  v_store_id := app_private.resolve_configuration_store(p_session_token, p_store_id);

  if p_group_key in ('scheduled', 'visited', 'bought') then
    raise exception 'Este grupo de opcoes e fixo.';
  end if;

  v_value := coalesce(
    nullif(btrim(coalesce(p_value, '')), ''),
    app_private.next_store_option_label(v_store_id, p_group_key)
  );
  v_sort_order := coalesce((
    select max(o.sort_order) + 10
    from public.lead_options o
    where o.store_id = v_store_id
      and o.group_key = p_group_key
      and o.is_active = true
  ), 10);

  update public.lead_options o
  set is_active = true, sort_order = v_sort_order
  where o.store_id = v_store_id
    and o.group_key = p_group_key
    and lower(o.value) = lower(v_value)
    and o.is_active = false;

  if not found then
    insert into public.lead_options (
      admin_user_id, store_id, group_key, value, sort_order, fixed
    ) values (
      v_session.admin_user_id, v_store_id, p_group_key, v_value, v_sort_order, false
    );
  end if;

  return true;
end;
$$;

create or replace function public.lc_add_option(
  p_session_token text,
  p_group_key public.lead_option_group,
  p_value text default null,
  p_store_id uuid default null
)
returns boolean
language sql
security invoker
as $$
  select app_private.rpc_add_option(p_session_token, p_group_key, p_value, p_store_id);
$$;

drop function if exists public.lc_update_option(text, uuid, text);
drop function if exists app_private.rpc_update_option(text, uuid, text);

create or replace function app_private.rpc_update_option(
  p_session_token text,
  p_option_id uuid,
  p_value text,
  p_store_id uuid default null
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_store_id uuid;
  v_value text;
begin
  v_store_id := app_private.resolve_configuration_store(p_session_token, p_store_id);
  v_value := btrim(coalesce(p_value, ''));
  if v_value = '' then raise exception 'Digite um valor.'; end if;

  update public.lead_options o
  set value = v_value
  where o.id = p_option_id
    and o.store_id = v_store_id
    and o.fixed = false
    and o.is_active = true;

  if not found then raise exception 'Opcao nao encontrada.'; end if;
  return true;
end;
$$;

create or replace function public.lc_update_option(
  p_session_token text,
  p_option_id uuid,
  p_value text,
  p_store_id uuid default null
)
returns boolean
language sql
security invoker
as $$
  select app_private.rpc_update_option(p_session_token, p_option_id, p_value, p_store_id);
$$;

drop function if exists public.lc_delete_option(text, uuid);
drop function if exists app_private.rpc_delete_option(text, uuid);

create or replace function app_private.rpc_delete_option(
  p_session_token text,
  p_option_id uuid,
  p_store_id uuid default null
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_store_id uuid;
begin
  v_store_id := app_private.resolve_configuration_store(p_session_token, p_store_id);
  update public.lead_options o
  set is_active = false
  where o.id = p_option_id
    and o.store_id = v_store_id
    and o.fixed = false
    and o.is_active = true;
  if not found then raise exception 'Opcao nao encontrada.'; end if;
  return true;
end;
$$;

create or replace function public.lc_delete_option(
  p_session_token text,
  p_option_id uuid,
  p_store_id uuid default null
)
returns boolean
language sql
security invoker
as $$
  select app_private.rpc_delete_option(p_session_token, p_option_id, p_store_id);
$$;

create or replace function app_private.next_store_custom_category_name(p_store_id uuid)
returns text
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_base text := 'Categoria adicional';
  v_name text := 'Categoria adicional';
  v_counter integer := 2;
begin
  while exists (
    select 1 from public.lead_custom_categories c
    where c.store_id = p_store_id
      and lower(c.name) = lower(v_name)
      and c.is_active = true
  ) loop
    v_name := v_base || ' ' || v_counter;
    v_counter := v_counter + 1;
  end loop;
  return v_name;
end;
$$;

drop function if exists public.lc_list_custom_categories(text);
drop function if exists app_private.rpc_list_custom_categories(text);

create or replace function app_private.rpc_list_custom_categories(
  p_session_token text,
  p_store_id uuid default null
)
returns table (
  id uuid,
  name text,
  sort_order integer,
  options jsonb
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_store_id uuid;
begin
  v_store_id := app_private.resolve_configuration_store(p_session_token, p_store_id);
  return query
  select
    c.id,
    c.name,
    c.sort_order,
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'id', o.id,
          'category_id', o.category_id,
          'value', o.value,
          'sort_order', o.sort_order
        ) order by o.sort_order, o.created_at
      ) filter (where o.id is not null),
      '[]'::jsonb
    )
  from public.lead_custom_categories c
  left join public.lead_custom_options o
    on o.category_id = c.id and o.is_active = true
  where c.store_id = v_store_id
    and c.is_active = true
  group by c.id
  order by c.sort_order, c.created_at;
end;
$$;

create or replace function public.lc_list_custom_categories(
  p_session_token text,
  p_store_id uuid default null
)
returns table (
  id uuid,
  name text,
  sort_order integer,
  options jsonb
)
language sql
security invoker
as $$
  select * from app_private.rpc_list_custom_categories(p_session_token, p_store_id);
$$;

drop function if exists public.lc_add_custom_category(text, text);
drop function if exists app_private.rpc_add_custom_category(text, text);

create or replace function app_private.rpc_add_custom_category(
  p_session_token text,
  p_name text default null,
  p_store_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_store_id uuid;
  v_name text;
  v_category_id uuid;
begin
  select * into v_session from app_private.session_user(p_session_token);
  v_store_id := app_private.resolve_configuration_store(p_session_token, p_store_id);
  v_name := coalesce(
    nullif(btrim(coalesce(p_name, '')), ''),
    app_private.next_store_custom_category_name(v_store_id)
  );

  insert into public.lead_custom_categories (
    admin_user_id, store_id, name, sort_order
  ) values (
    v_session.admin_user_id,
    v_store_id,
    v_name,
    coalesce((select max(c.sort_order) + 10 from public.lead_custom_categories c where c.store_id = v_store_id), 10)
  ) returning id into v_category_id;
  return v_category_id;
end;
$$;

create or replace function public.lc_add_custom_category(
  p_session_token text,
  p_name text default null,
  p_store_id uuid default null
)
returns uuid
language sql
security invoker
as $$
  select app_private.rpc_add_custom_category(p_session_token, p_name, p_store_id);
$$;

drop function if exists public.lc_update_custom_category(text, uuid, text);
drop function if exists app_private.rpc_update_custom_category(text, uuid, text);

create or replace function app_private.rpc_update_custom_category(
  p_session_token text,
  p_category_id uuid,
  p_name text,
  p_store_id uuid default null
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_store_id uuid;
begin
  v_store_id := app_private.resolve_configuration_store(p_session_token, p_store_id);
  update public.lead_custom_categories c
  set name = btrim(p_name)
  where c.id = p_category_id
    and c.store_id = v_store_id
    and c.is_active = true
    and length(btrim(coalesce(p_name, ''))) > 0;
  if not found then raise exception 'Categoria nao encontrada ou vazia.'; end if;
  return true;
end;
$$;

create or replace function public.lc_update_custom_category(
  p_session_token text,
  p_category_id uuid,
  p_name text,
  p_store_id uuid default null
)
returns boolean
language sql
security invoker
as $$
  select app_private.rpc_update_custom_category(p_session_token, p_category_id, p_name, p_store_id);
$$;

drop function if exists public.lc_delete_custom_category(text, uuid);
drop function if exists app_private.rpc_delete_custom_category(text, uuid);

create or replace function app_private.rpc_delete_custom_category(
  p_session_token text,
  p_category_id uuid,
  p_store_id uuid default null
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_store_id uuid;
begin
  v_store_id := app_private.resolve_configuration_store(p_session_token, p_store_id);
  update public.lead_custom_categories c
  set is_active = false
  where c.id = p_category_id and c.store_id = v_store_id and c.is_active = true;
  if not found then raise exception 'Categoria nao encontrada.'; end if;
  update public.lead_custom_options set is_active = false where category_id = p_category_id and is_active = true;
  return true;
end;
$$;

create or replace function public.lc_delete_custom_category(
  p_session_token text,
  p_category_id uuid,
  p_store_id uuid default null
)
returns boolean
language sql
security invoker
as $$
  select app_private.rpc_delete_custom_category(p_session_token, p_category_id, p_store_id);
$$;

drop function if exists public.lc_add_custom_option(text, uuid, text);
drop function if exists app_private.rpc_add_custom_option(text, uuid, text);

create or replace function app_private.rpc_add_custom_option(
  p_session_token text,
  p_category_id uuid,
  p_value text default null,
  p_store_id uuid default null
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_store_id uuid;
  v_value text;
  v_counter integer := 2;
begin
  select * into v_session from app_private.session_user(p_session_token);
  v_store_id := app_private.resolve_configuration_store(p_session_token, p_store_id);
  if not exists (
    select 1 from public.lead_custom_categories c
    where c.id = p_category_id and c.store_id = v_store_id and c.is_active = true
  ) then raise exception 'Categoria nao encontrada.'; end if;

  v_value := nullif(btrim(coalesce(p_value, '')), '');
  if v_value is null then
    v_value := 'Nova opcao';
    while exists (
      select 1 from public.lead_custom_options o
      where o.category_id = p_category_id and lower(o.value) = lower(v_value) and o.is_active = true
    ) loop
      v_value := 'Nova opcao ' || v_counter;
      v_counter := v_counter + 1;
    end loop;
  end if;

  insert into public.lead_custom_options (
    admin_user_id, category_id, value, sort_order
  ) values (
    v_session.admin_user_id,
    p_category_id,
    v_value,
    coalesce((select max(o.sort_order) + 10 from public.lead_custom_options o where o.category_id = p_category_id), 10)
  );
  return true;
end;
$$;

create or replace function public.lc_add_custom_option(
  p_session_token text,
  p_category_id uuid,
  p_value text default null,
  p_store_id uuid default null
)
returns boolean
language sql
security invoker
as $$
  select app_private.rpc_add_custom_option(p_session_token, p_category_id, p_value, p_store_id);
$$;

drop function if exists public.lc_update_custom_option(text, uuid, text);
drop function if exists app_private.rpc_update_custom_option(text, uuid, text);

create or replace function app_private.rpc_update_custom_option(
  p_session_token text,
  p_option_id uuid,
  p_value text,
  p_store_id uuid default null
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_store_id uuid;
begin
  v_store_id := app_private.resolve_configuration_store(p_session_token, p_store_id);
  update public.lead_custom_options o
  set value = btrim(p_value)
  from public.lead_custom_categories c
  where o.id = p_option_id
    and c.id = o.category_id
    and c.store_id = v_store_id
    and o.is_active = true
    and length(btrim(coalesce(p_value, ''))) > 0;
  if not found then raise exception 'Opcao nao encontrada ou vazia.'; end if;
  return true;
end;
$$;

create or replace function public.lc_update_custom_option(
  p_session_token text,
  p_option_id uuid,
  p_value text,
  p_store_id uuid default null
)
returns boolean
language sql
security invoker
as $$
  select app_private.rpc_update_custom_option(p_session_token, p_option_id, p_value, p_store_id);
$$;

drop function if exists public.lc_delete_custom_option(text, uuid);
drop function if exists app_private.rpc_delete_custom_option(text, uuid);

create or replace function app_private.rpc_delete_custom_option(
  p_session_token text,
  p_option_id uuid,
  p_store_id uuid default null
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_store_id uuid;
begin
  v_store_id := app_private.resolve_configuration_store(p_session_token, p_store_id);
  update public.lead_custom_options o
  set is_active = false
  from public.lead_custom_categories c
  where o.id = p_option_id
    and c.id = o.category_id
    and c.store_id = v_store_id
    and o.is_active = true;
  if not found then raise exception 'Opcao nao encontrada.'; end if;
  return true;
end;
$$;

create or replace function public.lc_delete_custom_option(
  p_session_token text,
  p_option_id uuid,
  p_store_id uuid default null
)
returns boolean
language sql
security invoker
as $$
  select app_private.rpc_delete_custom_option(p_session_token, p_option_id, p_store_id);
$$;

create or replace function app_private.enforce_custom_value_store()
returns trigger
language plpgsql
set search_path = app_private, public, extensions
as $$
declare
  v_lead_store_id uuid;
  v_category_store_id uuid;
begin
  select l.store_id into v_lead_store_id from public.leads l where l.id = new.lead_id;
  select c.store_id into v_category_store_id from public.lead_custom_categories c where c.id = new.category_id;
  if v_lead_store_id is null or v_category_store_id is null or v_lead_store_id <> v_category_store_id then
    raise exception 'Categoria nao pertence a loja deste lead.';
  end if;
  return new;
end;
$$;

drop trigger if exists lead_custom_values_store_guard on public.lead_custom_values;
create trigger lead_custom_values_store_guard
before insert or update of category_id, lead_id on public.lead_custom_values
for each row execute function app_private.enforce_custom_value_store();

-- Atualiza a leitura dos leads para exibir apenas categorias da propria loja.
create or replace function app_private.rpc_list_leads_b2b(p_session_token text)
returns table (
  id uuid,
  store_id uuid,
  store_name text,
  name text,
  phone text,
  contact_date date,
  channel text,
  campaign text,
  conversation_start text,
  conclusion text,
  scheduled text,
  scheduled_visit_date date,
  scheduled_visit_time time,
  visited text,
  bought text,
  purchase_amount numeric,
  service_order text,
  notes text,
  inspected boolean,
  custom_values jsonb,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);
  return query
  select
    l.id, l.store_id, st.name, l.name, l.phone, l.contact_date,
    l.channel, l.campaign, l.conversation_start, l.conclusion,
    l.scheduled, l.scheduled_visit_date, l.scheduled_visit_time,
    l.visited, l.bought, l.purchase_amount, l.service_order, l.notes, l.inspected,
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'category_id', c.id,
          'category_name', c.name,
          'value', v.value
        ) order by c.sort_order, c.created_at
      )
      from public.lead_custom_values v
      join public.lead_custom_categories c
        on c.id = v.category_id
       and c.store_id = l.store_id
       and c.is_active = true
      where v.lead_id = l.id
        and v.admin_user_id = l.admin_user_id
    ), '[]'::jsonb),
    l.created_at,
    l.updated_at
  from public.leads l
  join public.stores st on st.id = l.store_id
  where l.admin_user_id = v_session.admin_user_id
    and (
      v_session.user_role::text = 'admin'
      or (v_session.user_role::text = 'technician' and st.technician_user_id = v_session.user_id)
      or (v_session.user_role::text = 'store' and l.store_id = v_session.user_store_id)
    )
  order by l.created_at desc;
end;
$$;

create or replace function app_private.rpc_list_profile_avatars(p_session_token text)
returns table (
  account_type text,
  account_id uuid,
  avatar_url text
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);
  return query
  select 'technician'::text, u.id, u.avatar_url
  from public.app_users u
  where u.role::text = 'technician'
    and u.is_active = true
    and u.admin_user_id = v_session.admin_user_id
    and (
      v_session.user_role::text = 'admin'
      or (v_session.user_role::text = 'technician' and u.id = v_session.user_id)
    )
  union all
  select 'store'::text, st.id, st.avatar_url
  from public.stores st
  where st.admin_user_id = v_session.admin_user_id
    and st.is_active = true
    and (
      v_session.user_role::text = 'admin'
      or (v_session.user_role::text = 'technician' and st.technician_user_id = v_session.user_id)
      or (v_session.user_role::text = 'store' and st.id = v_session.user_store_id)
    );
end;
$$;

create or replace function public.lc_list_profile_avatars(p_session_token text)
returns table (
  account_type text,
  account_id uuid,
  avatar_url text
)
language sql
security invoker
as $$
  select * from app_private.rpc_list_profile_avatars(p_session_token);
$$;

create or replace function app_private.rpc_set_profile_avatar(
  p_session_token text,
  p_account_type text,
  p_account_id uuid,
  p_avatar_url text
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_avatar_url text;
begin
  select * into v_session from app_private.session_user(p_session_token);
  v_avatar_url := nullif(coalesce(p_avatar_url, ''), '');

  if v_avatar_url is not null and (
    length(v_avatar_url) > 750000
    or v_avatar_url !~ '^data:image/(png|jpeg|webp);base64,'
  ) then
    raise exception 'Imagem de perfil invalida ou muito grande.';
  end if;

  if p_account_type = 'technician' then
    update public.app_users u
    set avatar_url = v_avatar_url
    where u.id = p_account_id
      and u.role::text = 'technician'
      and u.admin_user_id = v_session.admin_user_id
      and (
        v_session.user_role::text = 'admin'
        or (v_session.user_role::text = 'technician' and u.id = v_session.user_id)
      );
  elsif p_account_type = 'store' then
    update public.stores st
    set avatar_url = v_avatar_url
    where st.id = p_account_id
      and st.admin_user_id = v_session.admin_user_id
      and (
        v_session.user_role::text = 'admin'
        or (v_session.user_role::text = 'technician' and st.technician_user_id = v_session.user_id)
        or (v_session.user_role::text = 'store' and st.id = v_session.user_store_id)
      );
  else
    raise exception 'Tipo de perfil invalido.';
  end if;

  if not found then raise exception 'Perfil nao encontrado ou sem permissao.'; end if;
  return true;
end;
$$;

create or replace function public.lc_set_profile_avatar(
  p_session_token text,
  p_account_type text,
  p_account_id uuid,
  p_avatar_url text
)
returns boolean
language sql
security invoker
as $$
  select app_private.rpc_set_profile_avatar(p_session_token, p_account_type, p_account_id, p_avatar_url);
$$;

grant execute on function app_private.resolve_configuration_store(text, uuid) to anon, authenticated;
grant execute on function app_private.next_store_option_label(uuid, public.lead_option_group) to anon, authenticated;
grant execute on function app_private.rpc_list_options(text, uuid) to anon, authenticated;
grant execute on function public.lc_list_options(text, uuid) to anon, authenticated;
grant execute on function app_private.rpc_add_option(text, public.lead_option_group, text, uuid) to anon, authenticated;
grant execute on function public.lc_add_option(text, public.lead_option_group, text, uuid) to anon, authenticated;
grant execute on function app_private.rpc_update_option(text, uuid, text, uuid) to anon, authenticated;
grant execute on function public.lc_update_option(text, uuid, text, uuid) to anon, authenticated;
grant execute on function app_private.rpc_delete_option(text, uuid, uuid) to anon, authenticated;
grant execute on function public.lc_delete_option(text, uuid, uuid) to anon, authenticated;
grant execute on function app_private.next_store_custom_category_name(uuid) to anon, authenticated;
grant execute on function app_private.rpc_list_custom_categories(text, uuid) to anon, authenticated;
grant execute on function public.lc_list_custom_categories(text, uuid) to anon, authenticated;
grant execute on function app_private.rpc_add_custom_category(text, text, uuid) to anon, authenticated;
grant execute on function public.lc_add_custom_category(text, text, uuid) to anon, authenticated;
grant execute on function app_private.rpc_update_custom_category(text, uuid, text, uuid) to anon, authenticated;
grant execute on function public.lc_update_custom_category(text, uuid, text, uuid) to anon, authenticated;
grant execute on function app_private.rpc_delete_custom_category(text, uuid, uuid) to anon, authenticated;
grant execute on function public.lc_delete_custom_category(text, uuid, uuid) to anon, authenticated;
grant execute on function app_private.rpc_add_custom_option(text, uuid, text, uuid) to anon, authenticated;
grant execute on function public.lc_add_custom_option(text, uuid, text, uuid) to anon, authenticated;
grant execute on function app_private.rpc_update_custom_option(text, uuid, text, uuid) to anon, authenticated;
grant execute on function public.lc_update_custom_option(text, uuid, text, uuid) to anon, authenticated;
grant execute on function app_private.rpc_delete_custom_option(text, uuid, uuid) to anon, authenticated;
grant execute on function public.lc_delete_custom_option(text, uuid, uuid) to anon, authenticated;
grant execute on function app_private.rpc_list_leads_b2b(text) to anon, authenticated;
grant execute on function app_private.rpc_list_profile_avatars(text) to anon, authenticated;
grant execute on function public.lc_list_profile_avatars(text) to anon, authenticated;
grant execute on function app_private.rpc_set_profile_avatar(text, text, uuid, text) to anon, authenticated;
grant execute on function public.lc_set_profile_avatar(text, text, uuid, text) to anon, authenticated;

commit;

notify pgrst, 'reload schema';
