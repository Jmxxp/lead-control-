-- PASSO 2/2
-- Rode este arquivo depois do technician_role_step1.sql concluir com sucesso.
-- Ele cria o papel tecnico, libera metricas/opcoes para tecnico e mantem lojas restritas ao admin.

set search_path = public, extensions;

alter table public.leads
  add column if not exists inspected boolean not null default false;

create index if not exists leads_admin_inspected_created_idx
  on public.leads (admin_user_id, inspected, created_at desc);

create or replace function app_private.session_user(p_session_token text)
returns table (
  user_id uuid,
  admin_user_id uuid,
  user_role public.app_user_role,
  user_store_id uuid
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_token_hash text;
begin
  if coalesce(p_session_token, '') = '' then
    raise exception 'Sessao obrigatoria.' using errcode = '28000';
  end if;

  v_token_hash := encode(digest(p_session_token, 'sha256'), 'hex');

  return query
  select
    u.id,
    coalesce(u.admin_user_id, u.id),
    u.role,
    u.store_id
  from public.app_sessions s
  join public.app_users u on u.id = s.user_id
  left join public.stores st on st.id = u.store_id
  where s.token_hash = v_token_hash
    and s.revoked_at is null
    and s.expires_at > now()
    and u.is_active = true
    and (
      u.role in ('admin', 'technician')
      or (st.id is not null and st.is_active = true)
    )
  limit 1;

  if not found then
    raise exception 'Sessao invalida ou expirada.' using errcode = '28000';
  end if;

  update public.app_sessions
  set last_seen_at = now()
  where token_hash = v_token_hash;
end;
$$;

create or replace function app_private.rpc_login(p_nick text, p_password text)
returns table (
  session_token text,
  expires_at timestamptz,
  user_id uuid,
  admin_id uuid,
  nick text,
  full_name text,
  role public.app_user_role,
  store_id uuid,
  store_name text
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_user public.app_users;
begin
  select u.*
  into v_user
  from public.app_users u
  left join public.stores st on st.id = u.store_id
  where u.nick_key = app_private.normalize_nick(p_nick)
    and u.is_active = true
    and (
      u.role in ('admin', 'technician')
      or (st.id is not null and st.is_active = true)
    );

  if not found or v_user.password_hash <> crypt(coalesce(p_password, ''), v_user.password_hash) then
    raise exception 'Nick ou senha invalidos.' using errcode = '28000';
  end if;

  return query select * from app_private.create_session_result(v_user.id);
end;
$$;

drop function if exists public.lc_create_technician(text, text, text, text);
drop function if exists app_private.rpc_create_technician(text, text, text, text);

create or replace function app_private.rpc_create_technician(
  p_session_token text,
  p_full_name text,
  p_nick text,
  p_password text
)
returns table (
  id uuid,
  nick text,
  full_name text,
  is_active boolean,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_user_id uuid;
  v_nick_key text;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role <> 'admin' then
    raise exception 'Apenas admin pode criar tecnico.';
  end if;

  v_nick_key := app_private.normalize_nick(p_nick);

  if v_nick_key = '' then
    raise exception 'Digite um nick valido para o tecnico.';
  end if;

  if length(coalesce(p_password, '')) < 6 then
    raise exception 'A senha do tecnico precisa ter pelo menos 6 caracteres.';
  end if;

  if exists (select 1 from public.app_users where nick_key = v_nick_key) then
    raise exception 'Esse nick ja existe.';
  end if;

  insert into public.app_users as new_user (nick, password_hash, full_name, role, admin_user_id, store_id)
  values (
    v_nick_key,
    crypt(p_password, gen_salt('bf')),
    coalesce(nullif(btrim(p_full_name), ''), v_nick_key),
    'technician',
    v_session.admin_user_id,
    null
  )
  returning new_user.id into v_user_id;

  return query
  select u.id, u.nick_key, u.full_name, u.is_active, u.created_at
  from public.app_users u
  where u.id = v_user_id;
end;
$$;

create or replace function public.lc_create_technician(
  p_session_token text,
  p_full_name text,
  p_nick text,
  p_password text
)
returns table (
  id uuid,
  nick text,
  full_name text,
  is_active boolean,
  created_at timestamptz
)
language sql
security invoker
as $$
  select * from app_private.rpc_create_technician(p_session_token, p_full_name, p_nick, p_password);
$$;

drop function if exists public.lc_list_technicians(text);
drop function if exists app_private.rpc_list_technicians(text);

create or replace function app_private.rpc_list_technicians(p_session_token text)
returns table (
  id uuid,
  nick text,
  full_name text,
  is_active boolean,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role <> 'admin' then
    raise exception 'Apenas admin pode listar tecnicos.';
  end if;

  return query
  select u.id, u.nick_key, u.full_name, u.is_active, u.created_at
  from public.app_users u
  where u.admin_user_id = v_session.admin_user_id
    and u.role = 'technician'
  order by u.created_at desc;
end;
$$;

create or replace function public.lc_list_technicians(p_session_token text)
returns table (
  id uuid,
  nick text,
  full_name text,
  is_active boolean,
  created_at timestamptz
)
language sql
security invoker
as $$
  select * from app_private.rpc_list_technicians(p_session_token);
$$;

create or replace function app_private.rpc_list_stores(p_session_token text)
returns table (
  id uuid,
  name text,
  nick text,
  created_at timestamptz,
  leads_count bigint,
  sales_count bigint
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
    st.id,
    st.name,
    st.nick_key,
    st.created_at,
    count(l.id) as leads_count,
    count(l.id) filter (where l.bought = 'Sim') as sales_count
  from public.stores st
  left join public.leads l on l.store_id = st.id and l.admin_user_id = st.admin_user_id
  where st.is_active = true
    and st.admin_user_id = v_session.admin_user_id
    and (
      v_session.user_role in ('admin', 'technician')
      or st.id = v_session.user_store_id
    )
  group by st.id
  order by st.created_at desc;
end;
$$;

create or replace function app_private.rpc_add_option(
  p_session_token text,
  p_group_key public.lead_option_group,
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
  v_sort_order integer;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text not in ('admin', 'technician', 'store') then
    raise exception 'Apenas admin, tecnico ou loja pode alterar opcoes.';
  end if;

  if p_group_key in ('scheduled', 'visited', 'bought') then
    raise exception 'Este grupo de opcoes e fixo.';
  end if;

  v_value := coalesce(nullif(btrim(coalesce(p_value, '')), ''), app_private.next_option_label(v_session.admin_user_id, p_group_key));
  v_sort_order := coalesce((
    select max(sort_order) + 10
    from public.lead_options
    where admin_user_id = v_session.admin_user_id
      and group_key = p_group_key
      and is_active = true
  ), 10);

  if exists (
    select 1
    from public.lead_options
    where admin_user_id = v_session.admin_user_id
      and group_key = p_group_key
      and value = v_value
      and is_active = true
  ) then
    raise exception 'Essa opcao ja existe.';
  end if;

  update public.lead_options
  set
    is_active = true,
    sort_order = v_sort_order
  where admin_user_id = v_session.admin_user_id
    and group_key = p_group_key
    and value = v_value
    and is_active = false;

  if found then
    return true;
  end if;

  insert into public.lead_options (admin_user_id, group_key, value, sort_order)
  values (
    v_session.admin_user_id,
    p_group_key,
    v_value,
    v_sort_order
  );

  return true;
end;
$$;

create or replace function app_private.rpc_update_option(
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
  v_option record;
  v_value text;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text not in ('admin', 'technician', 'store') then
    raise exception 'Apenas admin, tecnico ou loja pode alterar opcoes.';
  end if;

  v_value := btrim(coalesce(p_value, ''));

  if length(v_value) = 0 then
    raise exception 'Opcao nao encontrada, vazia ou fixa.';
  end if;

  select id, group_key, sort_order
  into v_option
  from public.lead_options
  where id = p_option_id
    and admin_user_id = v_session.admin_user_id
    and fixed = false
    and is_active = true;

  if not found then
    raise exception 'Opcao nao encontrada, vazia ou fixa.';
  end if;

  if exists (
    select 1
    from public.lead_options
    where admin_user_id = v_session.admin_user_id
      and group_key = v_option.group_key
      and value = v_value
      and is_active = true
      and id <> p_option_id
  ) then
    raise exception 'Essa opcao ja existe.';
  end if;

  update public.lead_options
  set
    is_active = true,
    sort_order = v_option.sort_order
  where admin_user_id = v_session.admin_user_id
    and group_key = v_option.group_key
    and value = v_value
    and is_active = false;

  if found then
    update public.lead_options
    set is_active = false
    where id = p_option_id;

    return true;
  end if;

  update public.lead_options
  set value = v_value
  where id = p_option_id;

  return true;
end;
$$;

create or replace function app_private.rpc_delete_option(
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
    raise exception 'Apenas admin, tecnico ou loja pode alterar opcoes.';
  end if;

  update public.lead_options
  set is_active = false
  where id = p_option_id
    and admin_user_id = v_session.admin_user_id
    and fixed = false
    and is_active = true;

  if not found then
    raise exception 'Opcao nao encontrada ou fixa.';
  end if;

  return true;
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
      v_session.user_role in ('admin', 'technician')
      or l.store_id = v_session.user_store_id
    )
  order by l.created_at desc;
end;
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

create or replace function app_private.rpc_set_lead_inspected(
  p_session_token text,
  p_lead_id uuid,
  p_inspected boolean
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

  update public.leads
  set
    inspected = coalesce(p_inspected, false),
    updated_by = v_session.user_id
  where id = p_lead_id
    and admin_user_id = v_session.admin_user_id
    and (
      v_session.user_role in ('admin', 'technician')
      or store_id = v_session.user_store_id
    );

  if not found then
    raise exception 'Lead nao encontrado ou sem permissao.';
  end if;

  return true;
end;
$$;

create or replace function public.lc_set_lead_inspected(
  p_session_token text,
  p_lead_id uuid,
  p_inspected boolean
)
returns boolean
language sql
security invoker
as $$
  select app_private.rpc_set_lead_inspected(p_session_token, p_lead_id, p_inspected);
$$;

drop function if exists public.lc_update_admin_credentials(text, text, text, text);
drop function if exists app_private.rpc_update_admin_credentials(text, text, text, text);

create or replace function app_private.rpc_update_admin_credentials(
  p_session_token text,
  p_nick text,
  p_current_password text,
  p_new_password text default null
)
returns table (
  nick text
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_user public.app_users;
  v_nick_key text;
  v_new_password text;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role <> 'admin' then
    raise exception 'Apenas admin pode alterar essa conta.';
  end if;

  select *
  into v_user
  from public.app_users
  where id = v_session.user_id
    and role = 'admin'
    and is_active = true;

  if not found then
    raise exception 'Admin nao encontrado.';
  end if;

  if v_user.password_hash <> crypt(coalesce(p_current_password, ''), v_user.password_hash) then
    raise exception 'Senha atual incorreta.' using errcode = '28000';
  end if;

  v_nick_key := app_private.normalize_nick(p_nick);
  if v_nick_key = '' then
    raise exception 'Digite um nick valido.';
  end if;

  if exists (
    select 1
    from public.app_users
    where nick_key = v_nick_key
      and id <> v_user.id
  ) then
    raise exception 'Esse nick ja existe.';
  end if;

  v_new_password := nullif(coalesce(p_new_password, ''), '');
  if v_new_password is not null and length(v_new_password) < 6 then
    raise exception 'A nova senha precisa ter pelo menos 6 caracteres.';
  end if;

  update public.app_users
  set
    nick = v_nick_key,
    password_hash = case
      when v_new_password is null then password_hash
      else crypt(v_new_password, gen_salt('bf'))
    end
  where id = v_user.id;

  return query
  select u.nick_key
  from public.app_users u
  where u.id = v_user.id;
end;
$$;

create or replace function public.lc_update_admin_credentials(
  p_session_token text,
  p_nick text,
  p_current_password text,
  p_new_password text default null
)
returns table (
  nick text
)
language sql
security invoker
as $$
  select * from app_private.rpc_update_admin_credentials(
    p_session_token,
    p_nick,
    p_current_password,
    p_new_password
  );
$$;

grant execute on function app_private.rpc_login(text, text) to anon, authenticated;
grant execute on function app_private.session_user(text) to anon, authenticated;
grant execute on function app_private.rpc_create_technician(text, text, text, text) to anon, authenticated;
grant execute on function public.lc_create_technician(text, text, text, text) to anon, authenticated;
grant execute on function app_private.rpc_list_technicians(text) to anon, authenticated;
grant execute on function public.lc_list_technicians(text) to anon, authenticated;
grant execute on function app_private.rpc_list_stores(text) to anon, authenticated;
grant execute on function public.lc_list_stores(text) to anon, authenticated;
grant execute on function app_private.rpc_add_option(text, public.lead_option_group, text) to anon, authenticated;
grant execute on function public.lc_add_option(text, public.lead_option_group, text) to anon, authenticated;
grant execute on function app_private.rpc_update_option(text, uuid, text) to anon, authenticated;
grant execute on function public.lc_update_option(text, uuid, text) to anon, authenticated;
grant execute on function app_private.rpc_delete_option(text, uuid) to anon, authenticated;
grant execute on function public.lc_delete_option(text, uuid) to anon, authenticated;
grant execute on function app_private.rpc_add_custom_category(text, text) to anon, authenticated;
grant execute on function public.lc_add_custom_category(text, text) to anon, authenticated;
grant execute on function app_private.rpc_update_custom_category(text, uuid, text) to anon, authenticated;
grant execute on function public.lc_update_custom_category(text, uuid, text) to anon, authenticated;
grant execute on function app_private.rpc_delete_custom_category(text, uuid) to anon, authenticated;
grant execute on function public.lc_delete_custom_category(text, uuid) to anon, authenticated;
grant execute on function app_private.rpc_add_custom_option(text, uuid, text) to anon, authenticated;
grant execute on function public.lc_add_custom_option(text, uuid, text) to anon, authenticated;
grant execute on function app_private.rpc_update_custom_option(text, uuid, text) to anon, authenticated;
grant execute on function public.lc_update_custom_option(text, uuid, text) to anon, authenticated;
grant execute on function app_private.rpc_delete_custom_option(text, uuid) to anon, authenticated;
grant execute on function public.lc_delete_custom_option(text, uuid) to anon, authenticated;
grant execute on function app_private.rpc_list_leads(text) to anon, authenticated;
grant execute on function public.lc_list_leads(text) to anon, authenticated;
grant execute on function app_private.rpc_set_lead_inspected(text, uuid, boolean) to anon, authenticated;
grant execute on function public.lc_set_lead_inspected(text, uuid, boolean) to anon, authenticated;
grant execute on function app_private.rpc_update_admin_credentials(text, text, text, text) to anon, authenticated;
grant execute on function public.lc_update_admin_credentials(text, text, text, text) to anon, authenticated;
