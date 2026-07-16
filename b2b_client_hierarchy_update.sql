-- Hierarquia B2B: admin -> empresa de trafego (technician) -> lojas.
-- Rode este arquivo no SQL Editor do Supabase depois das migracoes existentes.

begin;

set search_path = public, extensions;

alter table public.app_users
  add column if not exists store_limit integer not null default 5;

update public.app_users
set store_limit = 0
where role::text <> 'technician'
  and store_limit <> 0;

alter table public.app_users
  alter column store_limit set default 0;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'app_users_store_limit_check'
      and conrelid = 'public.app_users'::regclass
  ) then
    alter table public.app_users
      add constraint app_users_store_limit_check
      check (store_limit between 0 and 9999);
  end if;
end;
$$;

alter table public.stores
  add column if not exists technician_user_id uuid;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'stores_technician_user_fk'
      and conrelid = 'public.stores'::regclass
  ) then
    alter table public.stores
      add constraint stores_technician_user_fk
      foreign key (technician_user_id)
      references public.app_users(id)
      on delete set null;
  end if;
end;
$$;

-- Preserva instalacoes antigas: quando um admin tem uma unica empresa,
-- associa automaticamente a ela as lojas que ainda nao tinham responsavel.
with single_technician as (
  select admin_user_id, min(id::text)::uuid as technician_user_id
  from public.app_users
  where role::text = 'technician'
    and is_active = true
  group by admin_user_id
  having count(*) = 1
)
update public.stores st
set technician_user_id = single_technician.technician_user_id
from single_technician
where st.admin_user_id = single_technician.admin_user_id
  and st.technician_user_id is null;

create index if not exists stores_technician_active_created_idx
  on public.stores (technician_user_id, is_active, created_at desc);

create or replace function app_private.technician_can_access_store(
  p_admin_user_id uuid,
  p_technician_user_id uuid,
  p_store_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = app_private, public, extensions
as $$
  select exists (
    select 1
    from public.stores st
    where st.id = p_store_id
      and st.admin_user_id = p_admin_user_id
      and st.technician_user_id = p_technician_user_id
      and st.is_active = true
  );
$$;

-- Criacao de empresas com limite definido pelo admin.
drop function if exists public.lc_create_technician(text, text, text, text);
drop function if exists app_private.rpc_create_technician(text, text, text, text);

create or replace function app_private.rpc_create_technician(
  p_session_token text,
  p_full_name text,
  p_nick text,
  p_password text,
  p_store_limit integer default 5
)
returns table (
  id uuid,
  nick text,
  full_name text,
  is_active boolean,
  created_at timestamptz,
  store_limit integer,
  store_count bigint
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

  if v_session.user_role::text <> 'admin' then
    raise exception 'Apenas o admin pode criar uma empresa.';
  end if;

  if length(btrim(coalesce(p_full_name, ''))) = 0 then
    raise exception 'Digite o nome da empresa.';
  end if;

  v_nick_key := app_private.normalize_nick(p_nick);
  if v_nick_key = '' then
    raise exception 'Digite um login valido para a empresa.';
  end if;

  if length(coalesce(p_password, '')) < 6 then
    raise exception 'A senha da empresa precisa ter pelo menos 6 caracteres.';
  end if;

  if coalesce(p_store_limit, -1) not between 0 and 9999 then
    raise exception 'Informe um limite de clientes entre 0 e 9999.';
  end if;

  if exists (select 1 from public.app_users au where au.nick_key = v_nick_key) then
    raise exception 'Esse login ja existe.';
  end if;

  insert into public.app_users as new_user (
    nick,
    password_hash,
    full_name,
    role,
    admin_user_id,
    store_id,
    store_limit
  )
  values (
    v_nick_key,
    crypt(p_password, gen_salt('bf')),
    btrim(p_full_name),
    'technician',
    v_session.admin_user_id,
    null,
    p_store_limit
  )
  returning new_user.id into v_user_id;

  return query
  select
    u.id,
    u.nick_key,
    u.full_name,
    u.is_active,
    u.created_at,
    u.store_limit,
    0::bigint
  from public.app_users u
  where u.id = v_user_id;
end;
$$;

create or replace function public.lc_create_technician(
  p_session_token text,
  p_full_name text,
  p_nick text,
  p_password text,
  p_store_limit integer default 5
)
returns table (
  id uuid,
  nick text,
  full_name text,
  is_active boolean,
  created_at timestamptz,
  store_limit integer,
  store_count bigint
)
language sql
security invoker
as $$
  select *
  from app_private.rpc_create_technician(
    p_session_token,
    p_full_name,
    p_nick,
    p_password,
    p_store_limit
  );
$$;

-- Listagem das empresas com consumo atual da franquia.
drop function if exists public.lc_list_technicians(text);
drop function if exists app_private.rpc_list_technicians(text);

create or replace function app_private.rpc_list_technicians(p_session_token text)
returns table (
  id uuid,
  nick text,
  full_name text,
  is_active boolean,
  created_at timestamptz,
  store_limit integer,
  store_count bigint
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text <> 'admin' then
    raise exception 'Apenas o admin pode listar empresas.';
  end if;

  return query
  select
    u.id,
    u.nick_key,
    u.full_name,
    u.is_active,
    u.created_at,
    u.store_limit,
    count(st.id) filter (where st.is_active = true) as store_count
  from public.app_users u
  left join public.stores st on st.technician_user_id = u.id
  where u.admin_user_id = v_session.admin_user_id
    and u.role::text = 'technician'
  group by u.id
  order by u.created_at desc;
end;
$$;

create or replace function public.lc_list_technicians(p_session_token text)
returns table (
  id uuid,
  nick text,
  full_name text,
  is_active boolean,
  created_at timestamptz,
  store_limit integer,
  store_count bigint
)
language sql
security invoker
as $$
  select * from app_private.rpc_list_technicians(p_session_token);
$$;

-- Alteracao de credenciais e limite da empresa.
drop function if exists public.lc_update_technician_account(text, uuid, text, text, text);
drop function if exists app_private.rpc_update_technician_account(text, uuid, text, text, text);

create or replace function app_private.rpc_update_technician_account(
  p_session_token text,
  p_technician_id uuid,
  p_full_name text,
  p_nick text,
  p_password text default null,
  p_store_limit integer default 5
)
returns table (
  id uuid,
  nick text,
  full_name text,
  is_active boolean,
  created_at timestamptz,
  store_limit integer,
  store_count bigint
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_nick_key text;
  v_password text;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text <> 'admin' then
    raise exception 'Apenas o admin pode editar uma empresa.';
  end if;

  if length(btrim(coalesce(p_full_name, ''))) = 0 then
    raise exception 'Digite o nome da empresa.';
  end if;

  if coalesce(p_store_limit, -1) not between 0 and 9999 then
    raise exception 'Informe um limite de clientes entre 0 e 9999.';
  end if;

  v_nick_key := app_private.normalize_nick(p_nick);
  if v_nick_key = '' then
    raise exception 'Digite um login valido para a empresa.';
  end if;

  v_password := nullif(coalesce(p_password, ''), '');
  if v_password is not null and length(v_password) < 6 then
    raise exception 'A nova senha precisa ter pelo menos 6 caracteres.';
  end if;

  if not exists (
    select 1
    from public.app_users au
    where au.id = p_technician_id
      and au.admin_user_id = v_session.admin_user_id
      and au.role::text = 'technician'
      and au.is_active = true
  ) then
    raise exception 'Empresa nao encontrada.';
  end if;

  if exists (
    select 1
    from public.app_users au
    where au.nick_key = v_nick_key
      and au.id <> p_technician_id
  ) then
    raise exception 'Esse login ja existe.';
  end if;

  update public.app_users au
  set
    nick = v_nick_key,
    full_name = btrim(p_full_name),
    store_limit = p_store_limit,
    password_hash = case
      when v_password is null then au.password_hash
      else crypt(v_password, gen_salt('bf'))
    end
  where au.id = p_technician_id
    and au.admin_user_id = v_session.admin_user_id
    and au.role::text = 'technician';

  return query
  select
    au.id,
    au.nick_key,
    au.full_name,
    au.is_active,
    au.created_at,
    au.store_limit,
    count(st.id) filter (where st.is_active = true) as store_count
  from public.app_users au
  left join public.stores st on st.technician_user_id = au.id
  where au.id = p_technician_id
  group by au.id;
end;
$$;

create or replace function public.lc_update_technician_account(
  p_session_token text,
  p_technician_id uuid,
  p_full_name text,
  p_nick text,
  p_password text default null,
  p_store_limit integer default 5
)
returns table (
  id uuid,
  nick text,
  full_name text,
  is_active boolean,
  created_at timestamptz,
  store_limit integer,
  store_count bigint
)
language sql
security invoker
as $$
  select *
  from app_private.rpc_update_technician_account(
    p_session_token,
    p_technician_id,
    p_full_name,
    p_nick,
    p_password,
    p_store_limit
  );
$$;

-- Criacao de loja pela propria empresa, com bloqueio concorrente do limite.
drop function if exists public.lc_create_store(text, text, text, text);
drop function if exists app_private.rpc_create_store(text, text, text, text);

create or replace function app_private.rpc_create_store(
  p_session_token text,
  p_name text,
  p_nick text,
  p_password text,
  p_technician_id uuid default null
)
returns table (
  store_id uuid,
  store_name text,
  store_nick text,
  user_id uuid,
  user_nick text,
  technician_id uuid
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_store_id uuid;
  v_user_id uuid;
  v_nick_key text;
  v_technician_id uuid;
  v_store_limit integer;
  v_store_count bigint;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text = 'technician' then
    v_technician_id := v_session.user_id;
    if p_technician_id is not null and p_technician_id <> v_session.user_id then
      raise exception 'Empresa sem permissao para criar esta loja.';
    end if;
  elsif v_session.user_role::text = 'admin' then
    v_technician_id := p_technician_id;
  else
    raise exception 'Apenas o admin ou a empresa podem criar lojas.';
  end if;

  if v_technician_id is null then
    raise exception 'Selecione a empresa responsavel pela loja.';
  end if;

  -- O lock impede que cadastros simultaneos ultrapassem a franquia.
  select au.store_limit
  into v_store_limit
  from public.app_users au
  where au.id = v_technician_id
    and au.admin_user_id = v_session.admin_user_id
    and au.role::text = 'technician'
    and au.is_active = true
  for update;

  if not found then
    raise exception 'Empresa nao encontrada ou inativa.';
  end if;

  select count(*)
  into v_store_count
  from public.stores st
  where st.technician_user_id = v_technician_id
    and st.is_active = true;

  if v_store_count >= v_store_limit then
    raise exception 'Limite de clientes atingido (% de %).', v_store_count, v_store_limit;
  end if;

  if length(btrim(coalesce(p_name, ''))) = 0 then
    raise exception 'Digite o nome da loja.';
  end if;

  if length(coalesce(p_password, '')) < 6 then
    raise exception 'A senha da loja precisa ter pelo menos 6 caracteres.';
  end if;

  v_nick_key := app_private.normalize_nick(p_nick);
  if v_nick_key = '' then
    raise exception 'Digite um login valido para a loja.';
  end if;

  if exists (select 1 from public.app_users au where au.nick_key = v_nick_key) then
    raise exception 'Esse login ja existe.';
  end if;

  insert into public.stores (admin_user_id, technician_user_id, name, nick)
  values (v_session.admin_user_id, v_technician_id, btrim(p_name), v_nick_key)
  returning id into v_store_id;

  insert into public.app_users (nick, password_hash, full_name, role, admin_user_id, store_id, store_limit)
  values (
    v_nick_key,
    crypt(p_password, gen_salt('bf')),
    btrim(p_name),
    'store',
    v_session.admin_user_id,
    v_store_id,
    0
  )
  returning id into v_user_id;

  return query
  select st.id, st.name, st.nick_key, u.id, u.nick_key, st.technician_user_id
  from public.stores st
  join public.app_users u on u.store_id = st.id and u.role::text = 'store'
  where st.id = v_store_id;
end;
$$;

create or replace function public.lc_create_store(
  p_session_token text,
  p_name text,
  p_nick text,
  p_password text,
  p_technician_id uuid default null
)
returns table (
  store_id uuid,
  store_name text,
  store_nick text,
  user_id uuid,
  user_nick text,
  technician_id uuid
)
language sql
security invoker
as $$
  select *
  from app_private.rpc_create_store(
    p_session_token,
    p_name,
    p_nick,
    p_password,
    p_technician_id
  );
$$;

-- Cada papel ve apenas as lojas do seu escopo.
drop function if exists public.lc_list_stores(text);
drop function if exists app_private.rpc_list_stores(text);

create or replace function app_private.rpc_list_stores(p_session_token text)
returns table (
  id uuid,
  name text,
  nick text,
  created_at timestamptz,
  leads_count bigint,
  sales_count bigint,
  technician_id uuid,
  technician_name text
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
    count(l.id) filter (where l.bought = 'Sim') as sales_count,
    st.technician_user_id,
    tech.full_name
  from public.stores st
  left join public.app_users tech on tech.id = st.technician_user_id
  left join public.leads l on l.store_id = st.id and l.admin_user_id = st.admin_user_id
  where st.is_active = true
    and st.admin_user_id = v_session.admin_user_id
    and (
      v_session.user_role::text = 'admin'
      or (v_session.user_role::text = 'technician' and st.technician_user_id = v_session.user_id)
      or (v_session.user_role::text = 'store' and st.id = v_session.user_store_id)
    )
  group by st.id, tech.full_name
  order by st.created_at desc;
end;
$$;

create or replace function public.lc_list_stores(p_session_token text)
returns table (
  id uuid,
  name text,
  nick text,
  created_at timestamptz,
  leads_count bigint,
  sales_count bigint,
  technician_id uuid,
  technician_name text
)
language sql
security invoker
as $$
  select * from app_private.rpc_list_stores(p_session_token);
$$;

-- A empresa pode trocar nome/login/senha apenas das lojas da propria carteira.
drop function if exists public.lc_update_store_account(text, uuid, text, text, text);
drop function if exists public.lc_update_store_account(text, uuid, text, text, text, uuid);
drop function if exists app_private.rpc_update_store_account(text, uuid, text, text, text);
drop function if exists app_private.rpc_update_store_account(text, uuid, text, text, text, uuid);

create or replace function app_private.rpc_update_store_account(
  p_session_token text,
  p_store_id uuid,
  p_name text,
  p_nick text,
  p_password text default null,
  p_technician_id uuid default null
)
returns table (
  id uuid,
  name text,
  nick text
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_nick_key text;
  v_password text;
  v_technician_id uuid;
  v_current_technician_id uuid;
  v_store_limit integer;
  v_store_count bigint;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text not in ('admin', 'technician') then
    raise exception 'Sem permissao para editar esta loja.';
  end if;

  if v_session.user_role::text = 'technician' then
    v_technician_id := v_session.user_id;
    if p_technician_id is not null and p_technician_id <> v_session.user_id then
      raise exception 'Empresa sem permissao para transferir esta loja.';
    end if;
  else
    v_technician_id := p_technician_id;
  end if;

  if v_technician_id is null then
    raise exception 'Selecione a empresa responsavel pela loja.';
  end if;

  if length(btrim(coalesce(p_name, ''))) = 0 then
    raise exception 'Digite o nome da loja.';
  end if;

  v_nick_key := app_private.normalize_nick(p_nick);
  if v_nick_key = '' then
    raise exception 'Digite um login valido para a loja.';
  end if;

  v_password := nullif(coalesce(p_password, ''), '');
  if v_password is not null and length(v_password) < 6 then
    raise exception 'A nova senha precisa ter pelo menos 6 caracteres.';
  end if;

  select st.technician_user_id
  into v_current_technician_id
    from public.stores st
    where st.id = p_store_id
      and st.admin_user_id = v_session.admin_user_id
      and st.is_active = true
      and (
        v_session.user_role::text = 'admin'
        or st.technician_user_id = v_session.user_id
      );

  if not found then
    raise exception 'Loja nao encontrada ou sem permissao.';
  end if;

  select au.store_limit
  into v_store_limit
  from public.app_users au
  where au.id = v_technician_id
    and au.admin_user_id = v_session.admin_user_id
    and au.role::text = 'technician'
    and au.is_active = true
  for update;

  if not found then
    raise exception 'Empresa nao encontrada ou inativa.';
  end if;

  if v_current_technician_id is distinct from v_technician_id then
    select count(*)
    into v_store_count
    from public.stores st
    where st.technician_user_id = v_technician_id
      and st.is_active = true;

    if v_store_count >= v_store_limit then
      raise exception 'Limite de clientes da empresa de destino atingido (% de %).', v_store_count, v_store_limit;
    end if;
  end if;

  if exists (
    select 1
    from public.app_users au
    where au.nick_key = v_nick_key
      and not (au.role::text = 'store' and au.store_id = p_store_id)
  ) or exists (
    select 1
    from public.stores st
    where st.nick_key = v_nick_key
      and st.id <> p_store_id
  ) then
    raise exception 'Esse login ja existe.';
  end if;

  update public.stores st
  set
    name = btrim(p_name),
    nick = v_nick_key,
    technician_user_id = v_technician_id
  where st.id = p_store_id
    and st.admin_user_id = v_session.admin_user_id;

  update public.app_users au
  set
    nick = v_nick_key,
    full_name = btrim(p_name),
    password_hash = case
      when v_password is null then au.password_hash
      else crypt(v_password, gen_salt('bf'))
    end
  where au.role::text = 'store'
    and au.store_id = p_store_id
    and au.admin_user_id = v_session.admin_user_id
    and au.is_active = true;

  if not found then
    raise exception 'Usuario da loja nao encontrado.';
  end if;

  return query
  select st.id, st.name, st.nick_key
  from public.stores st
  where st.id = p_store_id;
end;
$$;

create or replace function public.lc_update_store_account(
  p_session_token text,
  p_store_id uuid,
  p_name text,
  p_nick text,
  p_password text default null,
  p_technician_id uuid default null
)
returns table (
  id uuid,
  name text,
  nick text
)
language sql
security invoker
as $$
  select *
  from app_private.rpc_update_store_account(
    p_session_token,
    p_store_id,
    p_name,
    p_nick,
    p_password,
    p_technician_id
  );
$$;

-- Indicador da franquia para o painel da empresa.
create or replace function app_private.rpc_account_usage(p_session_token text)
returns table (
  technician_id uuid,
  store_limit integer,
  store_count bigint
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text <> 'technician' then
    raise exception 'Indicador disponivel apenas para empresas.';
  end if;

  return query
  select
    u.id,
    u.store_limit,
    count(st.id) filter (where st.is_active = true) as store_count
  from public.app_users u
  left join public.stores st on st.technician_user_id = u.id
  where u.id = v_session.user_id
  group by u.id;
end;
$$;

create or replace function public.lc_account_usage(p_session_token text)
returns table (
  technician_id uuid,
  store_limit integer,
  store_count bigint
)
language sql
security invoker
as $$
  select * from app_private.rpc_account_usage(p_session_token);
$$;

-- Leitura dos leads isolada por empresa em uma funcao nova. O nome separado
-- torna a migracao compativel com as duas versoes antigas de contact_date.
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
    l.id,
    l.store_id,
    st.name,
    l.name,
    l.phone,
    l.contact_date,
    l.channel,
    l.campaign,
    l.conversation_start,
    l.conclusion,
    l.scheduled,
    l.scheduled_visit_date,
    l.scheduled_visit_time,
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

drop function if exists public.lc_list_leads(text);

create or replace function public.lc_list_leads(p_session_token text)
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
language sql
security invoker
as $$
  select * from app_private.rpc_list_leads_b2b(p_session_token);
$$;

-- A API publica valida a carteira antes de encaminhar qualquer gravacao.
-- Isso impede que uma empresa use manualmente o RPC para gravar em outra loja.
create or replace function public.lc_upsert_lead(
  p_session_token text,
  p_lead_id uuid,
  p_name text,
  p_phone text,
  p_channel text default null,
  p_campaign text default null,
  p_conversation_start text default null,
  p_conclusion text default null,
  p_scheduled text default null,
  p_scheduled_visit_date date default null,
  p_scheduled_visit_time time default null,
  p_visited text default null,
  p_bought text default null,
  p_purchase_amount numeric default null,
  p_service_order text default null,
  p_notes text default null,
  p_custom_values jsonb default '[]'::jsonb,
  p_store_id uuid default null,
  p_contact_date date default null
)
returns uuid
language plpgsql
security invoker
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_store_id uuid;
  v_lead_id uuid;
begin
  select * into v_session from app_private.session_user(p_session_token);
  v_store_id := p_store_id;

  if v_store_id is null and p_lead_id is not null then
    select l.store_id
    into v_store_id
    from public.leads l
    where l.id = p_lead_id
      and l.admin_user_id = v_session.admin_user_id;
  end if;

  if v_session.user_role::text = 'technician'
     and not app_private.technician_can_access_store(
       v_session.admin_user_id,
       v_session.user_id,
       v_store_id
     ) then
    raise exception 'Loja nao encontrada ou sem permissao.';
  end if;

  v_lead_id := app_private.rpc_upsert_lead(
    p_session_token,
    p_lead_id,
    p_name,
    p_phone,
    p_channel,
    p_campaign,
    p_conversation_start,
    p_conclusion,
    p_scheduled,
    p_scheduled_visit_date,
    p_scheduled_visit_time,
    p_visited,
    p_bought,
    p_purchase_amount,
    p_service_order,
    p_notes,
    p_custom_values,
    p_store_id
  );

  perform app_private.rpc_set_lead_contact_date(
    p_session_token,
    v_lead_id,
    p_contact_date
  );

  return v_lead_id;
end;
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

  update public.leads l
  set
    inspected = coalesce(p_inspected, false),
    updated_by = v_session.user_id
  where l.id = p_lead_id
    and l.admin_user_id = v_session.admin_user_id
    and (
      v_session.user_role::text = 'admin'
      or (v_session.user_role::text = 'store' and l.store_id = v_session.user_store_id)
      or (
        v_session.user_role::text = 'technician'
        and app_private.technician_can_access_store(
          v_session.admin_user_id,
          v_session.user_id,
          l.store_id
        )
      )
    );

  if not found then
    raise exception 'Lead nao encontrado ou sem permissao.';
  end if;

  return true;
end;
$$;

create or replace function app_private.rpc_set_lead_contact_date(
  p_session_token text,
  p_lead_id uuid,
  p_contact_date date default null
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

  update public.leads l
  set
    contact_date = coalesce(p_contact_date, l.contact_date, (timezone('America/Sao_Paulo', now()))::date),
    updated_by = v_session.user_id
  where l.id = p_lead_id
    and l.admin_user_id = v_session.admin_user_id
    and (
      v_session.user_role::text = 'admin'
      or (v_session.user_role::text = 'store' and l.store_id = v_session.user_store_id)
      or (
        v_session.user_role::text = 'technician'
        and app_private.technician_can_access_store(
          v_session.admin_user_id,
          v_session.user_id,
          l.store_id
        )
      )
    );

  if not found then
    raise exception 'Lead nao encontrado ou sem permissao.';
  end if;

  return true;
end;
$$;

create or replace function app_private.rpc_delete_lead(
  p_session_token text,
  p_lead_id uuid
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

  delete from public.leads l
  where l.id = p_lead_id
    and l.admin_user_id = v_session.admin_user_id
    and (
      v_session.user_role::text = 'admin'
      or (v_session.user_role::text = 'store' and l.store_id = v_session.user_store_id)
      or (
        v_session.user_role::text = 'technician'
        and app_private.technician_can_access_store(
          v_session.admin_user_id,
          v_session.user_id,
          l.store_id
        )
      )
    );

  if not found then
    raise exception 'Lead nao encontrado ou sem permissao.';
  end if;

  return true;
end;
$$;

-- Mantem os grants das funcoes substituidas e registra as novas assinaturas.
grant execute on function app_private.technician_can_access_store(uuid, uuid, uuid) to anon, authenticated;
grant execute on function app_private.rpc_create_technician(text, text, text, text, integer) to anon, authenticated;
grant execute on function public.lc_create_technician(text, text, text, text, integer) to anon, authenticated;
grant execute on function app_private.rpc_list_technicians(text) to anon, authenticated;
grant execute on function public.lc_list_technicians(text) to anon, authenticated;
grant execute on function app_private.rpc_update_technician_account(text, uuid, text, text, text, integer) to anon, authenticated;
grant execute on function public.lc_update_technician_account(text, uuid, text, text, text, integer) to anon, authenticated;
grant execute on function app_private.rpc_create_store(text, text, text, text, uuid) to anon, authenticated;
grant execute on function public.lc_create_store(text, text, text, text, uuid) to anon, authenticated;
grant execute on function app_private.rpc_list_stores(text) to anon, authenticated;
grant execute on function public.lc_list_stores(text) to anon, authenticated;
grant execute on function app_private.rpc_update_store_account(text, uuid, text, text, text, uuid) to anon, authenticated;
grant execute on function public.lc_update_store_account(text, uuid, text, text, text, uuid) to anon, authenticated;
grant execute on function app_private.rpc_account_usage(text) to anon, authenticated;
grant execute on function public.lc_account_usage(text) to anon, authenticated;
grant execute on function app_private.rpc_list_leads_b2b(text) to anon, authenticated;
grant execute on function public.lc_list_leads(text) to anon, authenticated;
grant execute on function app_private.rpc_set_lead_inspected(text, uuid, boolean) to anon, authenticated;
grant execute on function app_private.rpc_set_lead_contact_date(text, uuid, date) to anon, authenticated;
grant execute on function app_private.rpc_delete_lead(text, uuid) to anon, authenticated;
grant execute on function public.lc_upsert_lead(text, uuid, text, text, text, text, text, text, text, date, time, text, text, numeric, text, text, jsonb, uuid, date) to anon, authenticated;

commit;

notify pgrst, 'reload schema';
