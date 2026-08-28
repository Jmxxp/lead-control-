begin;

set search_path = public, extensions;

-- Um cliente pode ser acompanhado por varias agencias. O campo legado
-- stores.technician_user_id continua representando a agencia principal para
-- compatibilidade com relatorios/documentos antigos, mas autorizacao passa a
-- depender exclusivamente desta tabela de acessos.
create table if not exists app_private.store_agency_accesses (
  store_id uuid not null,
  admin_user_id uuid not null,
  agency_user_id uuid not null references public.app_users(id) on delete cascade,
  is_active boolean not null default true,
  created_by uuid references public.app_users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (store_id, agency_user_id),
  constraint store_agency_accesses_store_admin_fk
    foreign key (store_id, admin_user_id)
    references public.stores(id, admin_user_id)
    on delete cascade
);

alter table app_private.store_agency_accesses enable row level security;
revoke all on table app_private.store_agency_accesses from public, anon, authenticated;

create index if not exists store_agency_accesses_agency_active_idx
  on app_private.store_agency_accesses (agency_user_id, store_id)
  where is_active = true;

create index if not exists store_agency_accesses_admin_store_active_idx
  on app_private.store_agency_accesses (admin_user_id, store_id)
  where is_active = true;

insert into app_private.store_agency_accesses (
  store_id,
  admin_user_id,
  agency_user_id,
  is_active
)
select
  st.id,
  st.admin_user_id,
  st.technician_user_id,
  true
from public.stores st
join public.app_users agency
  on agency.id = st.technician_user_id
 and agency.admin_user_id = st.admin_user_id
 and agency.role::text = 'technician'
where st.technician_user_id is not null
on conflict (store_id, agency_user_id) do update
set
  admin_user_id = excluded.admin_user_id,
  is_active = true,
  updated_at = now();

create or replace function app_private.validate_store_agency_access()
returns trigger
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_agency record;
  v_store record;
  v_in_use integer;
begin
  select
    u.admin_user_id,
    u.store_limit,
    u.prospection_store_limit,
    u.good_morning_seller_store_limit
  into v_agency
  from public.app_users u
  where u.id = new.agency_user_id
    and u.role::text = 'technician'
    and u.is_active = true
  for update;

  if not found or v_agency.admin_user_id is distinct from new.admin_user_id then
    raise exception 'Agencia nao encontrada, inativa ou fora desta conta.';
  end if;

  select st.is_active, st.prospection_enabled, st.good_morning_seller_enabled
  into v_store
  from public.stores st
  where st.id = new.store_id
    and st.admin_user_id = new.admin_user_id;

  if not found then
    raise exception 'Cliente nao encontrado nesta conta.';
  end if;

  if new.is_active is distinct from true
     or v_store.is_active is distinct from true
     or (
       tg_op = 'UPDATE'
       and old.is_active is true
       and old.agency_user_id is not distinct from new.agency_user_id
       and old.store_id is not distinct from new.store_id
     ) then
    new.updated_at := now();
    return new;
  end if;

  select count(*)::integer
  into v_in_use
  from app_private.store_agency_accesses access
  join public.stores st
    on st.id = access.store_id
   and st.admin_user_id = access.admin_user_id
  where access.agency_user_id = new.agency_user_id
    and access.is_active = true
    and st.is_active = true
    and access.store_id <> new.store_id;

  if v_in_use >= v_agency.store_limit then
    raise exception 'Limite de clientes da agencia atingido (% de %).', v_in_use, v_agency.store_limit;
  end if;

  if v_store.prospection_enabled is true then
    select count(*)::integer
    into v_in_use
    from app_private.store_agency_accesses access
    join public.stores st
      on st.id = access.store_id
     and st.admin_user_id = access.admin_user_id
    where access.agency_user_id = new.agency_user_id
      and access.is_active = true
      and st.is_active = true
      and st.prospection_enabled = true
      and access.store_id <> new.store_id;

    if v_in_use >= v_agency.prospection_store_limit then
      raise exception 'A agencia nao possui licenca de Prospeccoes disponivel (% de %).', v_in_use, v_agency.prospection_store_limit;
    end if;
  end if;

  if v_store.good_morning_seller_enabled is true then
    select count(*)::integer
    into v_in_use
    from app_private.store_agency_accesses access
    join public.stores st
      on st.id = access.store_id
     and st.admin_user_id = access.admin_user_id
    where access.agency_user_id = new.agency_user_id
      and access.is_active = true
      and st.is_active = true
      and st.good_morning_seller_enabled = true
      and access.store_id <> new.store_id;

    if v_in_use >= v_agency.good_morning_seller_store_limit then
      raise exception 'A agencia nao possui licenca de Bom Dia Vendedor disponivel (% de %).', v_in_use, v_agency.good_morning_seller_store_limit;
    end if;
  end if;

  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists store_agency_accesses_validate on app_private.store_agency_accesses;
create trigger store_agency_accesses_validate
before insert or update on app_private.store_agency_accesses
for each row execute function app_private.validate_store_agency_access();

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
    from app_private.store_agency_accesses access
    join public.stores st
      on st.id = access.store_id
     and st.admin_user_id = access.admin_user_id
    where access.admin_user_id = p_admin_user_id
      and access.agency_user_id = p_technician_user_id
      and access.store_id = p_store_id
      and access.is_active = true
      and st.is_active = true
  );
$$;

create or replace function app_private.prospection_store_allowed(
  p_admin_user_id uuid,
  p_user_id uuid,
  p_user_role public.app_user_role,
  p_user_store_id uuid,
  p_store_id uuid,
  p_management_only boolean default false
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
      and st.is_active = true
      and st.prospection_enabled = true
      and (
        p_user_role::text = 'admin'
        or (
          p_user_role::text = 'technician'
          and app_private.technician_can_access_store(
            p_admin_user_id,
            p_user_id,
            p_store_id
          )
        )
        or (
          coalesce(p_management_only, false) = false
          and p_user_role::text = 'store'
          and st.id = p_user_store_id
        )
      )
  );
$$;

create or replace function app_private.good_morning_seller_store_allowed(
  p_admin_user_id uuid,
  p_user_id uuid,
  p_user_role public.app_user_role,
  p_user_store_id uuid,
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
      and st.is_active = true
      and st.prospection_enabled = true
      and st.good_morning_seller_enabled = true
      and (
        p_user_role::text = 'admin'
        or (
          p_user_role::text = 'technician'
          and app_private.technician_can_access_store(
            p_admin_user_id,
            p_user_id,
            p_store_id
          )
        )
        or (p_user_role::text = 'store' and st.id = p_user_store_id)
      )
  );
$$;

create or replace function app_private.rpc_list_store_agency_accesses(p_session_token text)
returns table (
  store_id uuid,
  agency_id uuid,
  agency_name text,
  agency_nick text,
  is_primary boolean
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
    access.store_id,
    access.agency_user_id,
    agency.full_name,
    agency.nick_key,
    st.technician_user_id = access.agency_user_id
  from app_private.store_agency_accesses access
  join public.stores st
    on st.id = access.store_id
   and st.admin_user_id = access.admin_user_id
  join public.app_users agency on agency.id = access.agency_user_id
  where access.admin_user_id = v_session.admin_user_id
    and access.is_active = true
    and st.is_active = true
    and agency.is_active = true
    and (
      v_session.user_role::text = 'admin'
      or (v_session.user_role::text = 'technician' and access.agency_user_id = v_session.user_id)
      or (v_session.user_role::text = 'store' and access.store_id = v_session.user_store_id)
    )
  order by access.store_id, agency.full_name, agency.nick_key;
end;
$$;

create or replace function public.lc_list_store_agency_accesses(p_session_token text)
returns table (
  store_id uuid,
  agency_id uuid,
  agency_name text,
  agency_nick text,
  is_primary boolean
)
language sql
security invoker
set search_path = public, app_private, extensions
as $$
  select * from app_private.rpc_list_store_agency_accesses(p_session_token);
$$;

create or replace function app_private.rpc_set_store_agency_accesses(
  p_session_token text,
  p_store_id uuid,
  p_agency_ids uuid[]
)
returns jsonb
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_requested_ids uuid[];
  v_agency_id uuid;
  v_primary_id uuid;
  v_store record;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text <> 'admin' then
    raise exception 'Apenas o Admin pode alterar quem acessa um cliente.';
  end if;

  select st.id, st.technician_user_id
  into v_store
  from public.stores st
  where st.id = p_store_id
    and st.admin_user_id = v_session.admin_user_id
    and st.is_active = true
  for update;

  if not found then
    raise exception 'Cliente nao encontrado.';
  end if;

  select coalesce(array_agg(distinct requested_id order by requested_id), '{}'::uuid[])
  into v_requested_ids
  from unnest(coalesce(p_agency_ids, '{}'::uuid[])) requested_id;

  if (
    select count(*)
    from public.app_users agency
    where agency.id = any(v_requested_ids)
      and agency.admin_user_id = v_session.admin_user_id
      and agency.role::text = 'technician'
      and agency.is_active = true
  ) <> cardinality(v_requested_ids) then
    raise exception 'Uma ou mais agencias selecionadas sao invalidas ou estao inativas.';
  end if;

  update app_private.store_agency_accesses access
  set is_active = false, updated_at = now()
  where access.store_id = p_store_id
    and access.admin_user_id = v_session.admin_user_id
    and access.is_active = true
    and not (access.agency_user_id = any(v_requested_ids));

  foreach v_agency_id in array v_requested_ids loop
    insert into app_private.store_agency_accesses (
      store_id,
      admin_user_id,
      agency_user_id,
      is_active,
      created_by
    ) values (
      p_store_id,
      v_session.admin_user_id,
      v_agency_id,
      true,
      v_session.user_id
    )
    on conflict (store_id, agency_user_id) do update
    set
      admin_user_id = excluded.admin_user_id,
      is_active = true,
      updated_at = now();
  end loop;

  v_primary_id := case
    when v_store.technician_user_id = any(v_requested_ids) then v_store.technician_user_id
    else null
  end;

  if v_primary_id is null then
    select access.agency_user_id
    into v_primary_id
    from app_private.store_agency_accesses access
    join public.app_users agency on agency.id = access.agency_user_id
    where access.store_id = p_store_id
      and access.is_active = true
    order by agency.full_name, agency.nick_key, agency.id
    limit 1;
  end if;

  update public.stores st
  set technician_user_id = v_primary_id
  where st.id = p_store_id
    and st.admin_user_id = v_session.admin_user_id;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'agency_id', access.agency_user_id,
      'agency_name', agency.full_name,
      'agency_nick', agency.nick_key,
      'is_primary', access.agency_user_id = v_primary_id
    ) order by agency.full_name, agency.nick_key)
    from app_private.store_agency_accesses access
    join public.app_users agency on agency.id = access.agency_user_id
    where access.store_id = p_store_id
      and access.is_active = true
  ), '[]'::jsonb);
end;
$$;

create or replace function public.lc_set_store_agency_accesses(
  p_session_token text,
  p_store_id uuid,
  p_agency_ids uuid[]
)
returns jsonb
language sql
security invoker
set search_path = public, app_private, extensions
as $$
  select app_private.rpc_set_store_agency_accesses(
    p_session_token,
    p_store_id,
    p_agency_ids
  );
$$;

create or replace function app_private.rpc_deactivate_store_access(
  p_session_token text,
  p_store_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_next_primary uuid;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text <> 'technician' then
    raise exception 'Apenas a Agencia pode desativar um cliente da propria carteira.';
  end if;

  update app_private.store_agency_accesses access
  set is_active = false, updated_at = now()
  where access.store_id = p_store_id
    and access.admin_user_id = v_session.admin_user_id
    and access.agency_user_id = v_session.user_id
    and access.is_active = true;

  if not found then
    raise exception 'Cliente nao encontrado ou sem permissao.';
  end if;

  if exists (
    select 1
    from public.stores st
    where st.id = p_store_id
      and st.technician_user_id = v_session.user_id
  ) then
    select access.agency_user_id
    into v_next_primary
    from app_private.store_agency_accesses access
    join public.app_users agency on agency.id = access.agency_user_id
    where access.store_id = p_store_id
      and access.is_active = true
      and agency.is_active = true
    order by agency.full_name, agency.nick_key, agency.id
    limit 1;

    update public.stores
    set technician_user_id = v_next_primary
    where id = p_store_id
      and admin_user_id = v_session.admin_user_id;
  end if;

  return true;
end;
$$;

create or replace function public.lc_deactivate_store_access(
  p_session_token text,
  p_store_id uuid
)
returns boolean
language sql
security invoker
set search_path = public, app_private, extensions
as $$
  select app_private.rpc_deactivate_store_access(p_session_token, p_store_id);
$$;

create or replace function app_private.rpc_delete_store_permanently(
  p_session_token text,
  p_store_id uuid
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

  if v_session.user_role::text <> 'admin' then
    raise exception 'Apenas o Admin pode excluir um cliente permanentemente.';
  end if;

  delete from public.stores st
  where st.id = p_store_id
    and st.admin_user_id = v_session.admin_user_id;

  if not found then
    raise exception 'Cliente nao encontrado.';
  end if;

  return true;
end;
$$;

create or replace function public.lc_delete_store_permanently(
  p_session_token text,
  p_store_id uuid
)
returns boolean
language sql
security invoker
set search_path = public, app_private, extensions
as $$
  select app_private.rpc_delete_store_permanently(p_session_token, p_store_id);
$$;

-- Mantem o RPC antigo nao destrutivo: uma agencia remove somente o proprio
-- acesso. O Admin deve usar explicitamente o RPC de exclusao permanente.
create or replace function app_private.rpc_delete_store_account(
  p_session_token text,
  p_store_id uuid
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

  if v_session.user_role::text = 'technician' then
    return app_private.rpc_deactivate_store_access(p_session_token, p_store_id);
  end if;

  raise exception 'Use a exclusao permanente exclusiva do Admin.';
end;
$$;

create or replace function app_private.enforce_prospection_store_quota()
returns trigger
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_agency record;
  v_in_use integer;
begin
  if tg_op = 'UPDATE'
     and old.admin_user_id is not distinct from new.admin_user_id
     and old.is_active is not distinct from new.is_active
     and old.prospection_enabled is not distinct from new.prospection_enabled then
    return new;
  end if;

  if new.is_active is distinct from true
     or new.prospection_enabled is distinct from true then
    return new;
  end if;

  for v_agency in
    select u.id, u.prospection_store_limit
    from app_private.store_agency_accesses access
    join public.app_users u on u.id = access.agency_user_id
    where access.store_id = new.id
      and access.admin_user_id = new.admin_user_id
      and access.is_active = true
      and u.is_active = true
    order by u.id
    for update of u
  loop
    select count(*)::integer
    into v_in_use
    from app_private.store_agency_accesses access
    join public.stores st
      on st.id = access.store_id
     and st.admin_user_id = access.admin_user_id
    where access.agency_user_id = v_agency.id
      and access.is_active = true
      and st.is_active = true
      and st.prospection_enabled = true
      and st.id <> new.id;

    if v_in_use >= v_agency.prospection_store_limit then
      raise exception 'Limite de clientes com Prospeccoes atingido para uma das agencias (% de %).', v_in_use, v_agency.prospection_store_limit;
    end if;
  end loop;

  return new;
end;
$$;

create or replace function app_private.enforce_good_morning_seller_store_quota()
returns trigger
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_agency record;
  v_in_use integer;
begin
  if new.prospection_enabled is distinct from true
     and tg_op = 'UPDATE'
     and old.prospection_enabled is true
     and new.prospection_enabled is false then
    new.good_morning_seller_enabled := false;
  end if;

  if tg_op = 'UPDATE'
     and old.admin_user_id is not distinct from new.admin_user_id
     and old.is_active is not distinct from new.is_active
     and old.prospection_enabled is not distinct from new.prospection_enabled
     and old.good_morning_seller_enabled is not distinct from new.good_morning_seller_enabled then
    return new;
  end if;

  if new.is_active is distinct from true
     or new.good_morning_seller_enabled is distinct from true then
    return new;
  end if;

  if new.prospection_enabled is distinct from true then
    raise exception 'Bom Dia Vendedor exige Prospeccoes e Atendimentos ativos.';
  end if;

  for v_agency in
    select u.id, u.good_morning_seller_store_limit
    from app_private.store_agency_accesses access
    join public.app_users u on u.id = access.agency_user_id
    where access.store_id = new.id
      and access.admin_user_id = new.admin_user_id
      and access.is_active = true
      and u.is_active = true
    order by u.id
    for update of u
  loop
    select count(*)::integer
    into v_in_use
    from app_private.store_agency_accesses access
    join public.stores st
      on st.id = access.store_id
     and st.admin_user_id = access.admin_user_id
    where access.agency_user_id = v_agency.id
      and access.is_active = true
      and st.is_active = true
      and st.good_morning_seller_enabled = true
      and st.id <> new.id;

    if v_in_use >= v_agency.good_morning_seller_store_limit then
      raise exception 'Limite de clientes com Bom Dia Vendedor atingido para uma das agencias (% de %).', v_in_use, v_agency.good_morning_seller_store_limit;
    end if;
  end loop;

  return new;
end;
$$;

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
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text = 'technician' then
    v_technician_id := v_session.user_id;
    if p_technician_id is not null and p_technician_id <> v_session.user_id then
      raise exception 'Agencia sem permissao para criar este cliente.';
    end if;
  elsif v_session.user_role::text = 'admin' then
    v_technician_id := p_technician_id;
  else
    raise exception 'Apenas o Admin ou a Agencia podem criar clientes.';
  end if;

  if v_technician_id is null then
    raise exception 'Selecione a agencia responsavel pelo cliente.';
  end if;

  if length(btrim(coalesce(p_name, ''))) = 0 then
    raise exception 'Digite o nome do cliente.';
  end if;

  if length(coalesce(p_password, '')) < 6 then
    raise exception 'A senha do cliente precisa ter pelo menos 6 caracteres.';
  end if;

  v_nick_key := app_private.normalize_nick(p_nick);
  if v_nick_key = '' then
    raise exception 'Digite um login valido para o cliente.';
  end if;

  if exists (select 1 from public.app_users au where au.nick_key = v_nick_key) then
    raise exception 'Esse login ja existe.';
  end if;

  insert into public.stores (admin_user_id, technician_user_id, name, nick)
  values (v_session.admin_user_id, v_technician_id, btrim(p_name), v_nick_key)
  returning id into v_store_id;

  insert into app_private.store_agency_accesses (
    store_id,
    admin_user_id,
    agency_user_id,
    is_active,
    created_by
  ) values (
    v_store_id,
    v_session.admin_user_id,
    v_technician_id,
    true,
    v_session.user_id
  );

  insert into public.app_users (
    nick,
    password_hash,
    full_name,
    role,
    admin_user_id,
    store_id,
    store_limit
  ) values (
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
  left join public.leads l
    on l.store_id = st.id
   and l.admin_user_id = st.admin_user_id
  where st.is_active = true
    and st.admin_user_id = v_session.admin_user_id
    and (
      v_session.user_role::text = 'admin'
      or (
        v_session.user_role::text = 'technician'
        and app_private.technician_can_access_store(
          v_session.admin_user_id,
          v_session.user_id,
          st.id
        )
      )
      or (v_session.user_role::text = 'store' and st.id = v_session.user_store_id)
    )
  group by st.id, tech.full_name
  order by st.created_at desc;
end;
$$;

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
    raise exception 'Apenas o Admin pode listar agencias.';
  end if;

  return query
  select
    u.id,
    u.nick_key,
    u.full_name,
    u.is_active,
    u.created_at,
    u.store_limit,
    count(access.store_id) filter (
      where access.is_active = true and st.is_active = true
    ) as store_count
  from public.app_users u
  left join app_private.store_agency_accesses access
    on access.agency_user_id = u.id
   and access.admin_user_id = u.admin_user_id
  left join public.stores st
    on st.id = access.store_id
   and st.admin_user_id = access.admin_user_id
  where u.admin_user_id = v_session.admin_user_id
    and u.role::text = 'technician'
  group by u.id
  order by u.created_at desc;
end;
$$;

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
    raise exception 'Indicador disponivel apenas para Agencias.';
  end if;

  return query
  select
    u.id,
    u.store_limit,
    count(access.store_id) filter (
      where access.is_active = true and st.is_active = true
    ) as store_count
  from public.app_users u
  left join app_private.store_agency_accesses access
    on access.agency_user_id = u.id
   and access.admin_user_id = u.admin_user_id
  left join public.stores st
    on st.id = access.store_id
   and st.admin_user_id = access.admin_user_id
  where u.id = v_session.user_id
  group by u.id;
end;
$$;

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
    raise exception 'Apenas o Admin pode editar uma agencia.';
  end if;

  if length(btrim(coalesce(p_full_name, ''))) = 0 then
    raise exception 'Digite o nome da agencia.';
  end if;

  if coalesce(p_store_limit, -1) not between 0 and 9999 then
    raise exception 'Informe um limite de clientes entre 0 e 9999.';
  end if;

  v_nick_key := app_private.normalize_nick(p_nick);
  if v_nick_key = '' then
    raise exception 'Digite um login valido para a agencia.';
  end if;

  v_password := nullif(coalesce(p_password, ''), '');
  if v_password is not null and length(v_password) < 6 then
    raise exception 'A nova senha precisa ter pelo menos 6 caracteres.';
  end if;

  if not exists (
    select 1
    from public.app_users agency
    where agency.id = p_technician_id
      and agency.admin_user_id = v_session.admin_user_id
      and agency.role::text = 'technician'
      and agency.is_active = true
  ) then
    raise exception 'Agencia nao encontrada.';
  end if;

  if exists (
    select 1
    from public.app_users account
    where account.nick_key = v_nick_key
      and account.id <> p_technician_id
  ) then
    raise exception 'Esse login ja existe.';
  end if;

  update public.app_users agency
  set
    nick = v_nick_key,
    full_name = btrim(p_full_name),
    store_limit = p_store_limit,
    password_hash = case
      when v_password is null then agency.password_hash
      else crypt(v_password, gen_salt('bf'))
    end
  where agency.id = p_technician_id
    and agency.admin_user_id = v_session.admin_user_id
    and agency.role::text = 'technician';

  return query
  select
    agency.id,
    agency.nick_key,
    agency.full_name,
    agency.is_active,
    agency.created_at,
    agency.store_limit,
    count(access.store_id) filter (
      where access.is_active = true and st.is_active = true
    ) as store_count
  from public.app_users agency
  left join app_private.store_agency_accesses access
    on access.agency_user_id = agency.id
   and access.admin_user_id = agency.admin_user_id
  left join public.stores st
    on st.id = access.store_id
   and st.admin_user_id = access.admin_user_id
  where agency.id = p_technician_id
  group by agency.id;
end;
$$;

create or replace function app_private.rpc_set_store_prospection_access(
  p_session_token text,
  p_store_id uuid,
  p_enabled boolean
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

  if v_session.user_role::text not in ('admin', 'technician') then
    raise exception 'Somente o Admin ou a Agencia podem alterar este acesso.';
  end if;

  if not exists (
    select 1
    from public.stores st
    where st.id = p_store_id
      and st.admin_user_id = v_session.admin_user_id
      and st.is_active = true
      and (
        v_session.user_role::text = 'admin'
        or app_private.technician_can_access_store(
          v_session.admin_user_id,
          v_session.user_id,
          st.id
        )
      )
  ) then
    raise exception 'Cliente nao encontrado ou sem permissao.';
  end if;

  update public.stores
  set prospection_enabled = coalesce(p_enabled, false)
  where id = p_store_id
    and admin_user_id = v_session.admin_user_id;

  return true;
end;
$$;

create or replace function app_private.rpc_set_store_good_morning_seller_access(
  p_session_token text,
  p_store_id uuid,
  p_enabled boolean
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

  if v_session.user_role::text not in ('admin', 'technician') then
    raise exception 'Somente o Admin ou a Agencia podem alterar este acesso.';
  end if;

  if not exists (
    select 1
    from public.stores st
    where st.id = p_store_id
      and st.admin_user_id = v_session.admin_user_id
      and st.is_active = true
      and (
        v_session.user_role::text = 'admin'
        or app_private.technician_can_access_store(
          v_session.admin_user_id,
          v_session.user_id,
          st.id
        )
      )
  ) then
    raise exception 'Cliente nao encontrado ou sem permissao.';
  end if;

  update public.stores
  set good_morning_seller_enabled = coalesce(p_enabled, false)
  where id = p_store_id
    and admin_user_id = v_session.admin_user_id;

  return true;
end;
$$;

create or replace function app_private.rpc_update_store_account(
  p_session_token text,
  p_store_id uuid,
  p_name text,
  p_nick text,
  p_password text default null,
  p_technician_id uuid default null
)
returns table (id uuid, name text, nick text)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_nick_key text;
  v_password text;
  v_current_primary uuid;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text not in ('admin', 'technician') then
    raise exception 'Sem permissao para editar este cliente.';
  end if;

  select st.technician_user_id
  into v_current_primary
  from public.stores st
  where st.id = p_store_id
    and st.admin_user_id = v_session.admin_user_id
    and st.is_active = true
    and (
      v_session.user_role::text = 'admin'
      or app_private.technician_can_access_store(
        v_session.admin_user_id,
        v_session.user_id,
        st.id
      )
    )
  for update;

  if not found then
    raise exception 'Cliente nao encontrado ou sem permissao.';
  end if;

  if length(btrim(coalesce(p_name, ''))) = 0 then
    raise exception 'Digite o nome do cliente.';
  end if;

  v_nick_key := app_private.normalize_nick(p_nick);
  if v_nick_key = '' then
    raise exception 'Digite um login valido para o cliente.';
  end if;

  v_password := nullif(coalesce(p_password, ''), '');
  if v_password is not null and length(v_password) < 6 then
    raise exception 'A nova senha precisa ter pelo menos 6 caracteres.';
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

  -- Compatibilidade com a tela antiga: se o Admin realmente escolher outra
  -- agencia principal, a operacao continua sendo uma transferencia exclusiva.
  if v_session.user_role::text = 'admin'
     and p_technician_id is not null
     and p_technician_id is distinct from v_current_primary then
    perform app_private.rpc_set_store_agency_accesses(
      p_session_token,
      p_store_id,
      array[p_technician_id]
    );
  end if;

  update public.stores st
  set name = btrim(p_name), nick = v_nick_key
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
    raise exception 'Usuario do cliente nao encontrado.';
  end if;

  return query
  select st.id, st.name, st.nick_key
  from public.stores st
  where st.id = p_store_id;
end;
$$;

create or replace function app_private.rpc_update_store_with_feature_access(
  p_session_token text,
  p_store_id uuid,
  p_name text,
  p_nick text,
  p_password text default null,
  p_technician_id uuid default null,
  p_prospection_enabled boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_was_enabled boolean;
  v_result jsonb;
begin
  select * into v_session from app_private.session_user(p_session_token);

  select st.prospection_enabled
  into v_was_enabled
  from public.stores st
  where st.id = p_store_id
    and st.admin_user_id = v_session.admin_user_id
    and st.is_active = true
    and (
      v_session.user_role::text = 'admin'
      or (
        v_session.user_role::text = 'technician'
        and app_private.technician_can_access_store(
          v_session.admin_user_id,
          v_session.user_id,
          st.id
        )
      )
    )
  for update;

  if not found then
    raise exception 'Cliente nao encontrado ou sem permissao.';
  end if;

  if v_was_enabled and coalesce(p_prospection_enabled, false) is false then
    perform app_private.rpc_set_store_prospection_access(p_session_token, p_store_id, false);
  end if;

  select to_jsonb(updated)
  into strict v_result
  from app_private.rpc_update_store_account(
    p_session_token,
    p_store_id,
    p_name,
    p_nick,
    p_password,
    p_technician_id
  ) updated;

  if not v_was_enabled and coalesce(p_prospection_enabled, false) is true then
    perform app_private.rpc_set_store_prospection_access(p_session_token, p_store_id, true);
  end if;

  return v_result || jsonb_build_object(
    'prospection_enabled', coalesce(p_prospection_enabled, false)
  );
end;
$$;

create or replace function app_private.rpc_update_store_with_all_feature_access(
  p_session_token text,
  p_store_id uuid,
  p_name text,
  p_nick text,
  p_password text default null,
  p_technician_id uuid default null,
  p_prospection_enabled boolean default false,
  p_good_morning_seller_enabled boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_was_good_morning_enabled boolean;
  v_result jsonb;
begin
  select * into v_session from app_private.session_user(p_session_token);

  select st.good_morning_seller_enabled
  into v_was_good_morning_enabled
  from public.stores st
  where st.id = p_store_id
    and st.admin_user_id = v_session.admin_user_id
    and st.is_active = true
    and (
      v_session.user_role::text = 'admin'
      or (
        v_session.user_role::text = 'technician'
        and app_private.technician_can_access_store(
          v_session.admin_user_id,
          v_session.user_id,
          st.id
        )
      )
    )
  for update;

  if not found then
    raise exception 'Cliente nao encontrado ou sem permissao.';
  end if;

  if v_was_good_morning_enabled
     and coalesce(p_good_morning_seller_enabled, false) is false then
    perform app_private.rpc_set_store_good_morning_seller_access(
      p_session_token,
      p_store_id,
      false
    );
  end if;

  select app_private.rpc_update_store_with_feature_access(
    p_session_token,
    p_store_id,
    p_name,
    p_nick,
    p_password,
    p_technician_id,
    p_prospection_enabled
  ) into v_result;

  if coalesce(p_good_morning_seller_enabled, false) then
    perform app_private.rpc_set_store_good_morning_seller_access(
      p_session_token,
      p_store_id,
      true
    );
  end if;

  return v_result || jsonb_build_object(
    'good_morning_seller_enabled', coalesce(p_good_morning_seller_enabled, false)
  );
end;
$$;

create or replace function app_private.rpc_get_prospection_entitlements(p_session_token text)
returns jsonb
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);

  return jsonb_build_object(
    'profile', jsonb_build_object(
      'role', v_session.user_role::text,
      'prospection_store_limit', case
        when v_session.user_role::text = 'technician' then coalesce((
          select u.prospection_store_limit
          from public.app_users u
          where u.id = v_session.user_id
        ), 0)
        else 0
      end,
      'prospection_store_count', case
        when v_session.user_role::text = 'technician' then (
          select count(*)
          from app_private.store_agency_accesses access
          join public.stores st
            on st.id = access.store_id
           and st.admin_user_id = access.admin_user_id
          where access.agency_user_id = v_session.user_id
            and access.is_active = true
            and st.is_active = true
            and st.prospection_enabled = true
        )
        else 0
      end,
      'good_morning_seller_store_limit', case
        when v_session.user_role::text = 'technician' then coalesce((
          select u.good_morning_seller_store_limit
          from public.app_users u
          where u.id = v_session.user_id
        ), 0)
        else 0
      end,
      'good_morning_seller_store_count', case
        when v_session.user_role::text = 'technician' then (
          select count(*)
          from app_private.store_agency_accesses access
          join public.stores st
            on st.id = access.store_id
           and st.admin_user_id = access.admin_user_id
          where access.agency_user_id = v_session.user_id
            and access.is_active = true
            and st.is_active = true
            and st.good_morning_seller_enabled = true
        )
        else 0
      end
    ),
    'stores', coalesce((
      select jsonb_agg(jsonb_build_object(
        'store_id', st.id,
        'technician_id', st.technician_user_id,
        'prospection_enabled', st.prospection_enabled,
        'good_morning_seller_enabled', st.good_morning_seller_enabled
      ) order by st.created_at)
      from public.stores st
      where st.admin_user_id = v_session.admin_user_id
        and st.is_active = true
        and (
          v_session.user_role::text = 'admin'
          or (
            v_session.user_role::text = 'technician'
            and app_private.technician_can_access_store(
              v_session.admin_user_id,
              v_session.user_id,
              st.id
            )
          )
          or (v_session.user_role::text = 'store' and st.id = v_session.user_store_id)
        )
    ), '[]'::jsonb),
    'technicians', coalesce((
      select jsonb_agg(jsonb_build_object(
        'technician_id', u.id,
        'prospection_store_limit', u.prospection_store_limit,
        'prospection_store_count', (
          select count(*)
          from app_private.store_agency_accesses access
          join public.stores st
            on st.id = access.store_id
           and st.admin_user_id = access.admin_user_id
          where access.agency_user_id = u.id
            and access.is_active = true
            and st.is_active = true
            and st.prospection_enabled = true
        ),
        'good_morning_seller_store_limit', u.good_morning_seller_store_limit,
        'good_morning_seller_store_count', (
          select count(*)
          from app_private.store_agency_accesses access
          join public.stores st
            on st.id = access.store_id
           and st.admin_user_id = access.admin_user_id
          where access.agency_user_id = u.id
            and access.is_active = true
            and st.is_active = true
            and st.good_morning_seller_enabled = true
        )
      ) order by u.full_name, u.nick)
      from public.app_users u
      where u.admin_user_id = v_session.admin_user_id
        and u.role::text = 'technician'
        and u.is_active = true
        and (v_session.user_role::text = 'admin' or u.id = v_session.user_id)
    ), '[]'::jsonb)
  );
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
    raise exception 'Selecione um cliente.';
  end if;

  if not exists (
    select 1
    from public.stores st
    where st.id = v_store_id
      and st.admin_user_id = v_session.admin_user_id
      and st.is_active = true
      and (
        v_session.user_role::text = 'admin'
        or (
          v_session.user_role::text = 'technician'
          and app_private.technician_can_access_store(
            v_session.admin_user_id,
            v_session.user_id,
            st.id
          )
        )
        or (v_session.user_role::text = 'store' and st.id = v_session.user_store_id)
      )
  ) then
    raise exception 'Cliente nao encontrado ou sem permissao.';
  end if;

  return v_store_id;
end;
$$;

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
      select jsonb_agg(jsonb_build_object(
        'category_id', c.id,
        'category_name', c.name,
        'value', v.value
      ) order by c.sort_order, c.created_at)
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
    and st.is_active = true
    and (
      v_session.user_role::text = 'admin'
      or (
        v_session.user_role::text = 'technician'
        and app_private.technician_can_access_store(
          v_session.admin_user_id,
          v_session.user_id,
          st.id
        )
      )
      or (v_session.user_role::text = 'store' and l.store_id = v_session.user_store_id)
    )
  order by l.created_at desc;
end;
$$;

create or replace function app_private.rpc_list_lead_intelligence(p_session_token text)
returns table (
  lead_id uuid,
  lifecycle_status text,
  qualified boolean,
  loss_reason text,
  owner_name text,
  email text,
  first_response_at timestamptz,
  qualified_at timestamptz,
  lost_at timestamptz,
  purchased_at timestamptz,
  returning_customer boolean
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
    li.lead_id,
    li.lifecycle_status,
    li.qualified,
    li.loss_reason,
    li.owner_name,
    li.email,
    li.first_response_at,
    li.qualified_at,
    li.lost_at,
    li.purchased_at,
    li.returning_customer
  from public.lead_intelligence li
  join public.stores st on st.id = li.store_id
  where li.admin_user_id = v_session.admin_user_id
    and st.is_active = true
    and (
      v_session.user_role::text = 'admin'
      or (
        v_session.user_role::text = 'technician'
        and app_private.technician_can_access_store(
          v_session.admin_user_id,
          v_session.user_id,
          st.id
        )
      )
      or (v_session.user_role::text = 'store' and li.store_id = v_session.user_store_id)
    );
end;
$$;

create or replace function app_private.rpc_list_profile_avatars(p_session_token text)
returns table (account_type text, account_id uuid, avatar_url text)
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
      or (
        v_session.user_role::text = 'technician'
        and app_private.technician_can_access_store(
          v_session.admin_user_id,
          v_session.user_id,
          st.id
        )
      )
      or (v_session.user_role::text = 'store' and st.id = v_session.user_store_id)
    );
end;
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
        or (
          v_session.user_role::text = 'technician'
          and app_private.technician_can_access_store(
            v_session.admin_user_id,
            v_session.user_id,
            st.id
          )
        )
        or (v_session.user_role::text = 'store' and st.id = v_session.user_store_id)
      );
  else
    raise exception 'Tipo de perfil invalido.';
  end if;

  if not found then
    raise exception 'Perfil nao encontrado ou sem permissao.';
  end if;

  return true;
end;
$$;

create or replace function app_private.rpc_save_lead_intelligence(
  p_session_token text,
  p_lead_id uuid,
  p_payload jsonb default '{}'::jsonb
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_lead record;
  v_before record;
  v_status text;
  v_qualified boolean;
  v_loss_reason text;
begin
  select * into v_session from app_private.session_user(p_session_token);

  select l.* into v_lead
  from public.leads l
  join public.stores st on st.id = l.store_id
  where l.id = p_lead_id
    and l.admin_user_id = v_session.admin_user_id
    and st.is_active = true
    and (
      v_session.user_role::text = 'admin'
      or (
        v_session.user_role::text = 'technician'
        and app_private.technician_can_access_store(
          v_session.admin_user_id,
          v_session.user_id,
          st.id
        )
      )
      or (v_session.user_role::text = 'store' and l.store_id = v_session.user_store_id)
    );

  if not found then
    raise exception 'Lead nao encontrado ou sem permissao.';
  end if;

  insert into public.lead_intelligence (lead_id, admin_user_id, store_id)
  values (v_lead.id, v_lead.admin_user_id, v_lead.store_id)
  on conflict (lead_id) do nothing;

  select * into v_before
  from public.lead_intelligence
  where lead_id = p_lead_id;

  v_status := coalesce(
    nullif(btrim(p_payload->>'lifecycle_status'), ''),
    v_before.lifecycle_status
  );

  if v_status not in ('new', 'contacted', 'qualified', 'scheduled', 'visited', 'won', 'lost') then
    raise exception 'Etapa comercial invalida.';
  end if;

  v_qualified := case
    when p_payload ? 'qualified'
      then lower(coalesce(p_payload->>'qualified', 'false')) in ('true', '1', 'sim')
    else v_before.qualified
  end;

  v_loss_reason := case
    when p_payload ? 'loss_reason'
      then nullif(btrim(p_payload->>'loss_reason'), '')
    else v_before.loss_reason
  end;

  if v_status = 'lost' and v_loss_reason is null then
    raise exception 'Informe o motivo da perda.';
  end if;

  update public.lead_intelligence
  set
    lifecycle_status = v_status,
    qualified = v_qualified,
    loss_reason = case when v_status = 'lost' then v_loss_reason else null end,
    owner_name = case
      when p_payload ? 'owner_name' then nullif(left(btrim(p_payload->>'owner_name'), 160), '')
      else owner_name
    end,
    email = case
      when p_payload ? 'email' then nullif(left(lower(btrim(p_payload->>'email')), 320), '')
      else email
    end,
    first_response_at = case
      when p_payload ? 'first_response_at' then nullif(p_payload->>'first_response_at', '')::timestamptz
      else first_response_at
    end,
    qualified_at = case when v_qualified then coalesce(qualified_at, now()) else null end,
    lost_at = case when v_status = 'lost' then coalesce(lost_at, now()) else null end,
    purchased_at = case when v_status = 'won' then coalesce(purchased_at, now()) else purchased_at end,
    returning_customer = case
      when p_payload ? 'returning_customer'
        then lower(coalesce(p_payload->>'returning_customer', 'false')) in ('true', '1', 'sim')
      else returning_customer
    end
  where lead_id = p_lead_id;

  if v_qualified and not v_before.qualified then
    insert into public.lead_events (
      admin_user_id, store_id, lead_id, event_type, actor_user_id
    ) values (
      v_lead.admin_user_id, v_lead.store_id, v_lead.id, 'qualified', v_session.user_id
    );
  end if;

  if v_status = 'lost' and v_before.lifecycle_status is distinct from 'lost' then
    insert into public.lead_events (
      admin_user_id, store_id, lead_id, event_type, actor_user_id, metadata
    ) values (
      v_lead.admin_user_id,
      v_lead.store_id,
      v_lead.id,
      'lost',
      v_session.user_id,
      jsonb_build_object('reason', v_loss_reason)
    );
  elsif v_before.lifecycle_status = 'lost' and v_status <> 'lost' then
    insert into public.lead_events (
      admin_user_id, store_id, lead_id, event_type, actor_user_id
    ) values (
      v_lead.admin_user_id, v_lead.store_id, v_lead.id, 'reopened', v_session.user_id
    );
  end if;

  return true;
end;
$$;

create or replace function app_private.rpc_export_prospections(
  p_session_token text,
  p_store_id uuid default null
)
returns table (
  id uuid,
  store_id uuid,
  store_name text,
  technician_id uuid,
  name text,
  phone text,
  cpf text,
  notes text,
  probability text,
  tags text[],
  professional_id uuid,
  professional_name text,
  returned_at timestamptz,
  purchased_at timestamptz,
  purchase_amount numeric,
  purchase_order text,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_requested_store uuid;
begin
  select * into v_session from app_private.session_user(p_session_token);
  perform app_private.purge_expired_prospections();
  v_requested_store := case
    when v_session.user_role::text = 'store' then v_session.user_store_id
    else p_store_id
  end;

  return query
  select
    pr.id,
    pr.store_id,
    st.name,
    st.technician_user_id,
    pr.name,
    pr.phone,
    pr.cpf,
    pr.notes,
    pr.probability,
    pr.tags,
    pr.professional_id,
    coalesce(pp.name, pr.professional_name_snapshot),
    pr.returned_at,
    pr.purchased_at,
    pr.purchase_amount,
    pr.purchase_order,
    pr.created_at,
    pr.updated_at
  from public.prospections pr
  join public.stores st
    on st.id = pr.store_id
   and st.admin_user_id = pr.admin_user_id
  left join public.prospection_professionals pp on pp.id = pr.professional_id
  where pr.admin_user_id = v_session.admin_user_id
    and st.is_active = true
    and pr.created_at >= now() - interval '2 years'
    and (v_requested_store is null or pr.store_id = v_requested_store)
    and (
      v_session.user_role::text = 'admin'
      or (
        v_session.user_role::text = 'technician'
        and app_private.technician_can_access_store(
          v_session.admin_user_id,
          v_session.user_id,
          st.id
        )
      )
      or (v_session.user_role::text = 'store' and st.id = v_session.user_store_id)
    )
  order by pr.created_at desc;
end;
$$;

create or replace function app_private.rpc_delete_agency_account(
  p_session_token text,
  p_agency_id uuid
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

  if v_session.user_role::text <> 'admin' then
    raise exception 'Apenas o Admin pode excluir Agencias.';
  end if;

  if not exists (
    select 1
    from public.app_users u
    where u.id = p_agency_id
      and u.admin_user_id = v_session.admin_user_id
      and u.role::text = 'technician'
  ) then
    raise exception 'Agencia nao encontrada.';
  end if;

  if exists (
    select 1
    from app_private.store_agency_accesses access
    join public.stores st
      on st.id = access.store_id
     and st.admin_user_id = access.admin_user_id
    where access.agency_user_id = p_agency_id
      and access.admin_user_id = v_session.admin_user_id
      and access.is_active = true
      and st.is_active = true
  ) then
    raise exception 'Remova o acesso desta Agencia aos clientes antes de exclui-la.';
  end if;

  delete from public.app_users
  where id = p_agency_id
    and admin_user_id = v_session.admin_user_id
    and role::text = 'technician';

  return true;
end;
$$;

create or replace function app_private.rpc_support_assistant_runtime(
  p_session_token text,
  p_store_id uuid default null
)
returns table (
  admin_user_id uuid,
  user_id uuid,
  user_role text,
  user_store_id uuid,
  provider text,
  model text,
  api_key text,
  capabilities jsonb,
  allowed_actions text[],
  usage_id uuid
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_scope_store_id uuid;
  v_has_client boolean := false;
  v_has_prospections boolean := false;
  v_has_good_morning_seller boolean := false;
  v_provider text;
  v_model text;
  v_api_key text;
  v_usage_id uuid;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text not in ('admin', 'technician', 'store') then
    raise exception 'Perfil sem acesso ao Assistente de Suporte.' using errcode = '42501';
  end if;

  if v_session.user_role::text = 'store' then
    if p_store_id is not null and p_store_id <> v_session.user_store_id then
      raise exception 'Cliente sem permissao para esta loja.' using errcode = '42501';
    end if;
    v_scope_store_id := v_session.user_store_id;
  elsif p_store_id is not null then
    if not exists (
      select 1
      from public.stores st
      where st.id = p_store_id
        and st.admin_user_id = v_session.admin_user_id
        and st.is_active = true
        and (
          v_session.user_role::text = 'admin'
          or (
            v_session.user_role::text = 'technician'
            and app_private.technician_can_access_store(
              v_session.admin_user_id,
              v_session.user_id,
              st.id
            )
          )
        )
    ) then
      raise exception 'Cliente sem permissao para esta loja.' using errcode = '42501';
    end if;
    v_scope_store_id := p_store_id;
  end if;

  select
    exists (
      select 1
      from public.stores st
      where st.admin_user_id = v_session.admin_user_id
        and st.is_active = true
        and (v_scope_store_id is null or st.id = v_scope_store_id)
        and (
          v_session.user_role::text = 'admin'
          or (
            v_session.user_role::text = 'technician'
            and app_private.technician_can_access_store(
              v_session.admin_user_id,
              v_session.user_id,
              st.id
            )
          )
          or (v_session.user_role::text = 'store' and st.id = v_session.user_store_id)
        )
    ),
    exists (
      select 1
      from public.stores st
      where st.admin_user_id = v_session.admin_user_id
        and st.is_active = true
        and st.prospection_enabled = true
        and (v_scope_store_id is null or st.id = v_scope_store_id)
        and (
          v_session.user_role::text = 'admin'
          or (
            v_session.user_role::text = 'technician'
            and app_private.technician_can_access_store(
              v_session.admin_user_id,
              v_session.user_id,
              st.id
            )
          )
          or (v_session.user_role::text = 'store' and st.id = v_session.user_store_id)
        )
    ),
    exists (
      select 1
      from public.stores st
      where st.admin_user_id = v_session.admin_user_id
        and st.is_active = true
        and st.prospection_enabled = true
        and st.good_morning_seller_enabled = true
        and (v_scope_store_id is null or st.id = v_scope_store_id)
        and (
          v_session.user_role::text = 'admin'
          or (
            v_session.user_role::text = 'technician'
            and app_private.technician_can_access_store(
              v_session.admin_user_id,
              v_session.user_id,
              st.id
            )
          )
          or (v_session.user_role::text = 'store' and st.id = v_session.user_store_id)
        )
    )
  into v_has_client, v_has_prospections, v_has_good_morning_seller;

  select settings.provider, settings.model, settings.api_key
  into v_provider, v_model, v_api_key
  from public.ai_settings settings
  where settings.admin_user_id = v_session.admin_user_id
    and settings.provider in ('gemini', 'deepseek')
    and length(btrim(settings.api_key)) > 0
  limit 1;

  if not found then
    raise exception 'A IA ainda nao foi configurada pelo administrador.' using errcode = 'P0001';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    'support_assistant:' || v_session.user_id::text,
    0
  ));

  if (
    select count(*)
    from public.ai_usage usage
    where usage.user_id = v_session.user_id
      and usage.request_kind = 'support_assistant'
      and usage.created_at > now() - interval '1 hour'
  ) >= 40 then
    raise exception 'Limite temporario do Assistente de Suporte atingido.' using errcode = 'P0001';
  end if;

  insert into public.ai_usage (
    admin_user_id,
    user_id,
    store_id,
    provider,
    model,
    request_kind,
    status
  ) values (
    v_session.admin_user_id,
    v_session.user_id,
    v_scope_store_id,
    v_provider,
    v_model,
    'support_assistant',
    'started'
  ) returning id into v_usage_id;

  return query
  select
    v_session.admin_user_id::uuid,
    v_session.user_id::uuid,
    v_session.user_role::text,
    v_session.user_store_id::uuid,
    v_provider,
    v_model,
    v_api_key,
    jsonb_build_object(
      'leads', v_has_client,
      'prospections', v_has_prospections,
      'attendances', v_has_prospections,
      'good_morning_seller', v_has_good_morning_seller,
      'client_configuration', v_has_client,
      'categories', v_has_client,
      'options', v_has_client,
      'sequence', v_has_client
    ),
    array_remove(array[
      case when v_has_client then 'open_leads' end,
      case when v_has_prospections then 'open_prospections' end,
      case when v_has_prospections then 'open_attendances' end,
      case when v_has_client then 'open_lead_configuration' end
    ]::text[], null),
    v_usage_id;
end;
$$;

revoke all on function app_private.validate_store_agency_access() from public, anon, authenticated;

revoke all on function app_private.rpc_list_store_agency_accesses(text) from public, anon, authenticated;
revoke all on function app_private.rpc_set_store_agency_accesses(text, uuid, uuid[]) from public, anon, authenticated;
revoke all on function app_private.rpc_deactivate_store_access(text, uuid) from public, anon, authenticated;
revoke all on function app_private.rpc_delete_store_permanently(text, uuid) from public, anon, authenticated;

grant execute on function app_private.rpc_list_store_agency_accesses(text) to anon, authenticated;
grant execute on function app_private.rpc_set_store_agency_accesses(text, uuid, uuid[]) to anon, authenticated;
grant execute on function app_private.rpc_deactivate_store_access(text, uuid) to anon, authenticated;
grant execute on function app_private.rpc_delete_store_permanently(text, uuid) to anon, authenticated;

revoke all on function public.lc_list_store_agency_accesses(text) from public;
revoke all on function public.lc_set_store_agency_accesses(text, uuid, uuid[]) from public;
revoke all on function public.lc_deactivate_store_access(text, uuid) from public;
revoke all on function public.lc_delete_store_permanently(text, uuid) from public;

grant execute on function public.lc_list_store_agency_accesses(text) to anon, authenticated;
grant execute on function public.lc_set_store_agency_accesses(text, uuid, uuid[]) to anon, authenticated;
grant execute on function public.lc_deactivate_store_access(text, uuid) to anon, authenticated;
grant execute on function public.lc_delete_store_permanently(text, uuid) to anon, authenticated;

commit;

notify pgrst, 'reload schema';
