-- Rode este arquivo no SQL Editor do Supabase para habilitar
-- categorias adicionais personalizadas nos leads, filtros e metricas.

set search_path = public, extensions;

alter table public.leads
  add column if not exists inspected boolean not null default false;

create index if not exists leads_admin_inspected_created_idx
  on public.leads (admin_user_id, inspected, created_at desc);

create table if not exists public.lead_custom_categories (
  id uuid primary key default gen_random_uuid(),
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
  name text not null check (length(btrim(name)) > 0),
  sort_order integer not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.lead_custom_options (
  id uuid primary key default gen_random_uuid(),
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
  category_id uuid not null references public.lead_custom_categories(id) on delete cascade,
  value text not null check (length(btrim(value)) > 0),
  sort_order integer not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.lead_custom_values (
  lead_id uuid not null references public.leads(id) on delete cascade,
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
  category_id uuid not null references public.lead_custom_categories(id) on delete cascade,
  value text not null check (length(btrim(value)) > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (lead_id, category_id)
);

create unique index if not exists lead_custom_categories_unique_name_idx
  on public.lead_custom_categories (admin_user_id, lower(name))
  where is_active;

create unique index if not exists lead_custom_options_unique_value_idx
  on public.lead_custom_options (category_id, lower(value))
  where is_active;

create index if not exists lead_custom_categories_admin_sort_idx
  on public.lead_custom_categories (admin_user_id, sort_order, created_at);

create index if not exists lead_custom_options_category_sort_idx
  on public.lead_custom_options (category_id, sort_order, created_at);

create index if not exists lead_custom_values_admin_category_idx
  on public.lead_custom_values (admin_user_id, category_id, value);

drop trigger if exists lead_custom_categories_set_updated_at on public.lead_custom_categories;
create trigger lead_custom_categories_set_updated_at
before update on public.lead_custom_categories
for each row execute function app_private.set_updated_at();

drop trigger if exists lead_custom_options_set_updated_at on public.lead_custom_options;
create trigger lead_custom_options_set_updated_at
before update on public.lead_custom_options
for each row execute function app_private.set_updated_at();

drop trigger if exists lead_custom_values_set_updated_at on public.lead_custom_values;
create trigger lead_custom_values_set_updated_at
before update on public.lead_custom_values
for each row execute function app_private.set_updated_at();

alter table public.lead_custom_categories enable row level security;
alter table public.lead_custom_options enable row level security;
alter table public.lead_custom_values enable row level security;

create or replace function app_private.next_custom_category_name(p_admin_user_id uuid)
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
    select 1
    from public.lead_custom_categories
    where admin_user_id = p_admin_user_id
      and lower(name) = lower(v_name)
      and is_active = true
  ) loop
    v_name := v_base || ' ' || v_counter;
    v_counter := v_counter + 1;
  end loop;

  return v_name;
end;
$$;

create or replace function app_private.next_custom_option_label(
  p_admin_user_id uuid,
  p_category_id uuid
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
    select 1
    from public.lead_custom_options
    where admin_user_id = p_admin_user_id
      and category_id = p_category_id
      and lower(value) = lower(v_label)
      and is_active = true
  ) loop
    v_label := v_base || ' ' || v_counter;
    v_counter := v_counter + 1;
  end loop;

  return v_label;
end;
$$;

create or replace function app_private.rpc_list_custom_categories(p_session_token text)
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
  v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);

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
        )
        order by o.sort_order, o.created_at
      ) filter (where o.id is not null),
      '[]'::jsonb
    ) as options
  from public.lead_custom_categories c
  left join public.lead_custom_options o
    on o.category_id = c.id
   and o.admin_user_id = c.admin_user_id
   and o.is_active = true
  where c.admin_user_id = v_session.admin_user_id
    and c.is_active = true
  group by c.id
  order by c.sort_order, c.created_at;
end;
$$;

create or replace function app_private.rpc_add_custom_category(
  p_session_token text,
  p_name text default null
)
returns uuid
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_name text;
  v_category_id uuid;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text not in ('admin', 'technician', 'store') then
    raise exception 'Apenas admin, tecnico ou loja pode alterar categorias.';
  end if;

  v_name := coalesce(
    nullif(btrim(coalesce(p_name, '')), ''),
    app_private.next_custom_category_name(v_session.admin_user_id)
  );

  insert into public.lead_custom_categories (admin_user_id, name, sort_order)
  values (
    v_session.admin_user_id,
    v_name,
    coalesce((
      select max(sort_order) + 10
      from public.lead_custom_categories
      where admin_user_id = v_session.admin_user_id
    ), 10)
  )
  returning id into v_category_id;

  return v_category_id;
end;
$$;

create or replace function app_private.rpc_update_custom_category(
  p_session_token text,
  p_category_id uuid,
  p_name text
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text not in ('admin', 'technician', 'store') then
    raise exception 'Apenas admin, tecnico ou loja pode alterar categorias.';
  end if;

  update public.lead_custom_categories
  set name = btrim(p_name)
  where id = p_category_id
    and admin_user_id = v_session.admin_user_id
    and is_active = true
    and length(btrim(coalesce(p_name, ''))) > 0;

  if not found then
    raise exception 'Categoria nao encontrada ou vazia.';
  end if;

  return true;
end;
$$;

create or replace function app_private.rpc_delete_custom_category(
  p_session_token text,
  p_category_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text not in ('admin', 'technician', 'store') then
    raise exception 'Apenas admin, tecnico ou loja pode alterar categorias.';
  end if;

  update public.lead_custom_categories
  set is_active = false
  where id = p_category_id
    and admin_user_id = v_session.admin_user_id
    and is_active = true;

  if not found then
    raise exception 'Categoria nao encontrada.';
  end if;

  update public.lead_custom_options
  set is_active = false
  where category_id = p_category_id
    and admin_user_id = v_session.admin_user_id
    and is_active = true;

  return true;
end;
$$;

create or replace function app_private.rpc_add_custom_option(
  p_session_token text,
  p_category_id uuid,
  p_value text default null
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_value text;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text not in ('admin', 'technician', 'store') then
    raise exception 'Apenas admin, tecnico ou loja pode alterar categorias.';
  end if;

  if not exists (
    select 1
    from public.lead_custom_categories
    where id = p_category_id
      and admin_user_id = v_session.admin_user_id
      and is_active = true
  ) then
    raise exception 'Categoria nao encontrada.';
  end if;

  v_value := coalesce(
    nullif(btrim(coalesce(p_value, '')), ''),
    app_private.next_custom_option_label(v_session.admin_user_id, p_category_id)
  );

  insert into public.lead_custom_options (admin_user_id, category_id, value, sort_order)
  values (
    v_session.admin_user_id,
    p_category_id,
    v_value,
    coalesce((
      select max(sort_order) + 10
      from public.lead_custom_options
      where admin_user_id = v_session.admin_user_id
        and category_id = p_category_id
    ), 10)
  );

  return true;
end;
$$;

create or replace function app_private.rpc_update_custom_option(
  p_session_token text,
  p_option_id uuid,
  p_value text
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text not in ('admin', 'technician', 'store') then
    raise exception 'Apenas admin, tecnico ou loja pode alterar categorias.';
  end if;

  update public.lead_custom_options
  set value = btrim(p_value)
  where id = p_option_id
    and admin_user_id = v_session.admin_user_id
    and is_active = true
    and length(btrim(coalesce(p_value, ''))) > 0;

  if not found then
    raise exception 'Opcao nao encontrada ou vazia.';
  end if;

  return true;
end;
$$;

create or replace function app_private.rpc_delete_custom_option(
  p_session_token text,
  p_option_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text not in ('admin', 'technician', 'store') then
    raise exception 'Apenas admin, tecnico ou loja pode alterar categorias.';
  end if;

  update public.lead_custom_options
  set is_active = false
  where id = p_option_id
    and admin_user_id = v_session.admin_user_id
    and is_active = true;

  if not found then
    raise exception 'Opcao nao encontrada.';
  end if;

  return true;
end;
$$;

drop function if exists public.lc_list_leads(text);
drop function if exists app_private.rpc_list_leads(text);

create or replace function app_private.rpc_list_leads(p_session_token text)
returns table (
  id uuid,
  store_id uuid,
  store_name text,
  name text,
  phone text,
  channel text,
  campaign text,
  conversation_start text,
  conclusion text,
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
    l.id,
    l.store_id,
    st.name as store_name,
    l.name,
    l.phone,
    l.channel,
    l.campaign,
    l.conversation_start,
    l.conclusion,
    l.visited,
    l.bought,
    l.purchase_amount,
    l.service_order,
    l.notes,
    l.inspected,
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'category_id', c.id,
          'category_name', c.name,
          'value', v.value
        )
        order by c.sort_order, c.created_at
      )
      from public.lead_custom_values v
      join public.lead_custom_categories c
        on c.id = v.category_id
       and c.admin_user_id = v.admin_user_id
       and c.is_active = true
      where v.lead_id = l.id
        and v.admin_user_id = l.admin_user_id
    ), '[]'::jsonb) as custom_values,
    l.created_at,
    l.updated_at
  from public.leads l
  join public.stores st on st.id = l.store_id
  where l.admin_user_id = v_session.admin_user_id
    and (
      v_session.user_role = 'admin'
      or l.store_id = v_session.user_store_id
    )
  order by l.created_at desc;
end;
$$;

drop function if exists public.lc_upsert_lead(text, uuid, text, text, text, text, text, text, text, text, uuid);
drop function if exists app_private.rpc_upsert_lead(text, uuid, text, text, text, text, text, text, text, text, uuid);
drop function if exists public.lc_upsert_lead(text, uuid, text, text, text, text, text, text, text, text, numeric, text, uuid);
drop function if exists app_private.rpc_upsert_lead(text, uuid, text, text, text, text, text, text, text, text, numeric, text, uuid);
drop function if exists public.lc_upsert_lead(text, uuid, text, text, text, text, text, text, text, text, numeric, text, text, uuid);
drop function if exists app_private.rpc_upsert_lead(text, uuid, text, text, text, text, text, text, text, text, numeric, text, text, uuid);
drop function if exists public.lc_upsert_lead(text, uuid, text, text, text, text, text, text, text, text, numeric, text, text, jsonb, uuid);
drop function if exists app_private.rpc_upsert_lead(text, uuid, text, text, text, text, text, text, text, text, numeric, text, text, jsonb, uuid);

create or replace function app_private.rpc_upsert_lead(
  p_session_token text,
  p_lead_id uuid,
  p_name text,
  p_phone text,
  p_channel text default null,
  p_campaign text default null,
  p_conversation_start text default null,
  p_conclusion text default null,
  p_visited text default null,
  p_bought text default null,
  p_purchase_amount numeric default null,
  p_service_order text default null,
  p_notes text default null,
  p_custom_values jsonb default '[]'::jsonb,
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
  v_lead_id uuid;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if length(btrim(coalesce(p_name, ''))) = 0 or length(btrim(coalesce(p_phone, ''))) = 0 then
    raise exception 'Preencha nome e telefone.';
  end if;

  if jsonb_typeof(coalesce(p_custom_values, '[]'::jsonb)) <> 'array' then
    raise exception 'Categorias adicionais invalidas.';
  end if;

  if nullif(btrim(coalesce(p_visited, '')), '') = 'Sim'
     and nullif(btrim(coalesce(p_bought, '')), '') is null then
    raise exception 'Informe se o lead comprou ou nao.';
  end if;

  if nullif(btrim(coalesce(p_bought, '')), '') = 'Sim'
     and (p_purchase_amount is null or p_purchase_amount <= 0 or nullif(btrim(coalesce(p_service_order, '')), '') is null) then
    raise exception 'Informe o valor da compra e a OS.';
  end if;

  if v_session.user_role = 'store' then
    v_store_id := v_session.user_store_id;
  else
    v_store_id := p_store_id;
  end if;

  if p_lead_id is not null and v_store_id is null then
    select store_id
    into v_store_id
    from public.leads
    where id = p_lead_id
      and admin_user_id = v_session.admin_user_id;
  end if;

  if v_store_id is null then
    raise exception 'Loja obrigatoria para cadastrar lead.';
  end if;

  if not exists (
    select 1
    from public.stores
    where id = v_store_id
      and admin_user_id = v_session.admin_user_id
      and is_active = true
  ) then
    raise exception 'Loja nao encontrada ou sem permissao.';
  end if;

  if p_lead_id is null then
    insert into public.leads (
      admin_user_id,
      store_id,
      name,
      phone,
      channel,
      campaign,
      conversation_start,
      conclusion,
      visited,
      bought,
      purchase_amount,
      service_order,
      notes,
      created_by,
      updated_by
    )
    values (
      v_session.admin_user_id,
      v_store_id,
      btrim(p_name),
      btrim(p_phone),
      nullif(btrim(coalesce(p_channel, '')), ''),
      nullif(btrim(coalesce(p_campaign, '')), ''),
      nullif(btrim(coalesce(p_conversation_start, '')), ''),
      nullif(btrim(coalesce(p_conclusion, '')), ''),
      nullif(btrim(coalesce(p_visited, '')), ''),
      nullif(btrim(coalesce(p_bought, '')), ''),
      case when nullif(btrim(coalesce(p_bought, '')), '') = 'Sim' then p_purchase_amount else null end,
      case when nullif(btrim(coalesce(p_bought, '')), '') = 'Sim' then nullif(btrim(coalesce(p_service_order, '')), '') else null end,
      nullif(btrim(coalesce(p_notes, '')), ''),
      v_session.user_id,
      v_session.user_id
    )
    returning id into v_lead_id;
  else
    update public.leads
    set
      store_id = v_store_id,
      name = btrim(p_name),
      phone = btrim(p_phone),
      channel = nullif(btrim(coalesce(p_channel, '')), ''),
      campaign = nullif(btrim(coalesce(p_campaign, '')), ''),
      conversation_start = nullif(btrim(coalesce(p_conversation_start, '')), ''),
      conclusion = nullif(btrim(coalesce(p_conclusion, '')), ''),
      visited = nullif(btrim(coalesce(p_visited, '')), ''),
      bought = nullif(btrim(coalesce(p_bought, '')), ''),
      purchase_amount = case when nullif(btrim(coalesce(p_bought, '')), '') = 'Sim' then p_purchase_amount else null end,
      service_order = case when nullif(btrim(coalesce(p_bought, '')), '') = 'Sim' then nullif(btrim(coalesce(p_service_order, '')), '') else null end,
      notes = nullif(btrim(coalesce(p_notes, '')), ''),
      updated_by = v_session.user_id
    where id = p_lead_id
      and admin_user_id = v_session.admin_user_id
      and (
        v_session.user_role = 'admin'
        or store_id = v_session.user_store_id
      )
    returning id into v_lead_id;

    if not found then
      raise exception 'Lead nao encontrado ou sem permissao.';
    end if;
  end if;

  delete from public.lead_custom_values
  where lead_id = v_lead_id
    and admin_user_id = v_session.admin_user_id;

  insert into public.lead_custom_values (admin_user_id, lead_id, category_id, value)
  select
    v_session.admin_user_id,
    v_lead_id,
    c.id,
    o.value
  from jsonb_array_elements(coalesce(p_custom_values, '[]'::jsonb)) as item(value)
  join public.lead_custom_categories c
    on c.id = nullif(item.value->>'category_id', '')::uuid
   and c.admin_user_id = v_session.admin_user_id
   and c.is_active = true
  join public.lead_custom_options o
    on o.category_id = c.id
   and o.admin_user_id = v_session.admin_user_id
   and o.is_active = true
   and lower(o.value) = lower(nullif(btrim(coalesce(item.value->>'value', '')), ''))
  where nullif(btrim(coalesce(item.value->>'value', '')), '') is not null
  on conflict (lead_id, category_id) do update
  set
    value = excluded.value,
    updated_at = now();

  return v_lead_id;
end;
$$;

create or replace function public.lc_list_custom_categories(p_session_token text)
returns table (
  id uuid,
  name text,
  sort_order integer,
  options jsonb
)
language sql
security invoker
as $$
  select * from app_private.rpc_list_custom_categories(p_session_token);
$$;

create or replace function public.lc_add_custom_category(
  p_session_token text,
  p_name text default null
)
returns uuid
language sql
security invoker
as $$
  select app_private.rpc_add_custom_category(p_session_token, p_name);
$$;

create or replace function public.lc_update_custom_category(
  p_session_token text,
  p_category_id uuid,
  p_name text
)
returns boolean
language sql
security invoker
as $$
  select app_private.rpc_update_custom_category(p_session_token, p_category_id, p_name);
$$;

create or replace function public.lc_delete_custom_category(
  p_session_token text,
  p_category_id uuid
)
returns boolean
language sql
security invoker
as $$
  select app_private.rpc_delete_custom_category(p_session_token, p_category_id);
$$;

create or replace function public.lc_add_custom_option(
  p_session_token text,
  p_category_id uuid,
  p_value text default null
)
returns boolean
language sql
security invoker
as $$
  select app_private.rpc_add_custom_option(p_session_token, p_category_id, p_value);
$$;

create or replace function public.lc_update_custom_option(
  p_session_token text,
  p_option_id uuid,
  p_value text
)
returns boolean
language sql
security invoker
as $$
  select app_private.rpc_update_custom_option(p_session_token, p_option_id, p_value);
$$;

create or replace function public.lc_delete_custom_option(
  p_session_token text,
  p_option_id uuid
)
returns boolean
language sql
security invoker
as $$
  select app_private.rpc_delete_custom_option(p_session_token, p_option_id);
$$;

create or replace function public.lc_list_leads(p_session_token text)
returns table (
  id uuid,
  store_id uuid,
  store_name text,
  name text,
  phone text,
  channel text,
  campaign text,
  conversation_start text,
  conclusion text,
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
language sql
security invoker
as $$
  select * from app_private.rpc_list_leads(p_session_token);
$$;

create or replace function public.lc_upsert_lead(
  p_session_token text,
  p_lead_id uuid,
  p_name text,
  p_phone text,
  p_channel text default null,
  p_campaign text default null,
  p_conversation_start text default null,
  p_conclusion text default null,
  p_visited text default null,
  p_bought text default null,
  p_purchase_amount numeric default null,
  p_service_order text default null,
  p_notes text default null,
  p_custom_values jsonb default '[]'::jsonb,
  p_store_id uuid default null
)
returns uuid
language sql
security invoker
as $$
  select app_private.rpc_upsert_lead(
    p_session_token,
    p_lead_id,
    p_name,
    p_phone,
    p_channel,
    p_campaign,
    p_conversation_start,
    p_conclusion,
    p_visited,
    p_bought,
    p_purchase_amount,
    p_service_order,
    p_notes,
    p_custom_values,
    p_store_id
  );
$$;

revoke all on table public.lead_custom_categories from anon, authenticated;
revoke all on table public.lead_custom_options from anon, authenticated;
revoke all on table public.lead_custom_values from anon, authenticated;

grant select, insert, update, delete on table public.lead_custom_categories to service_role;
grant select, insert, update, delete on table public.lead_custom_options to service_role;
grant select, insert, update, delete on table public.lead_custom_values to service_role;

grant usage on schema app_private to anon, authenticated;

grant execute on function app_private.rpc_list_custom_categories(text) to anon, authenticated;
grant execute on function app_private.rpc_add_custom_category(text, text) to anon, authenticated;
grant execute on function app_private.rpc_update_custom_category(text, uuid, text) to anon, authenticated;
grant execute on function app_private.rpc_delete_custom_category(text, uuid) to anon, authenticated;
grant execute on function app_private.rpc_add_custom_option(text, uuid, text) to anon, authenticated;
grant execute on function app_private.rpc_update_custom_option(text, uuid, text) to anon, authenticated;
grant execute on function app_private.rpc_delete_custom_option(text, uuid) to anon, authenticated;
grant execute on function app_private.rpc_list_leads(text) to anon, authenticated;
grant execute on function app_private.rpc_upsert_lead(text, uuid, text, text, text, text, text, text, text, text, numeric, text, text, jsonb, uuid) to anon, authenticated;

grant execute on function public.lc_list_custom_categories(text) to anon, authenticated;
grant execute on function public.lc_add_custom_category(text, text) to anon, authenticated;
grant execute on function public.lc_update_custom_category(text, uuid, text) to anon, authenticated;
grant execute on function public.lc_delete_custom_category(text, uuid) to anon, authenticated;
grant execute on function public.lc_add_custom_option(text, uuid, text) to anon, authenticated;
grant execute on function public.lc_update_custom_option(text, uuid, text) to anon, authenticated;
grant execute on function public.lc_delete_custom_option(text, uuid) to anon, authenticated;
grant execute on function public.lc_list_leads(text) to anon, authenticated;
grant execute on function public.lc_upsert_lead(text, uuid, text, text, text, text, text, text, text, text, numeric, text, text, jsonb, uuid) to anon, authenticated;
