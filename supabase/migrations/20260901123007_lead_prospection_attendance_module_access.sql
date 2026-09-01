begin;

set local lock_timeout = '10s';
set local statement_timeout = '120s';
set local search_path = public, extensions;

-- Lead, Prospeccao e Atendimento sao acessos independentes. Clientes
-- existentes preservam o comportamento anterior; novos clientes nascem com
-- cada modulo desligado ate a agencia libera-lo explicitamente.
alter table public.stores
  add column if not exists lead_enabled boolean;

update public.stores
set lead_enabled = true
where lead_enabled is null;

alter table public.stores
  alter column lead_enabled set default false,
  alter column lead_enabled set not null;

alter table public.stores
  add column if not exists attendance_enabled boolean;

update public.stores
set attendance_enabled = coalesce(prospection_enabled, false)
where attendance_enabled is null;

alter table public.stores
  alter column attendance_enabled set default false,
  alter column attendance_enabled set not null;

update public.stores
set good_morning_seller_enabled = false
where attendance_enabled = false
  and good_morning_seller_enabled = true;

do $constraint$
begin
  if not exists (
    select 1
    from pg_catalog.pg_constraint constraint_row
    where constraint_row.conname = 'stores_good_morning_requires_attendance_check'
      and constraint_row.conrelid = 'public.stores'::regclass
  ) then
    alter table public.stores
      add constraint stores_good_morning_requires_attendance_check
      check (not good_morning_seller_enabled or attendance_enabled);
  end if;
end;
$constraint$;

comment on column public.stores.lead_enabled is
  'Libera o modulo Lead para este cliente. Novos clientes exigem ativacao explicita.';
comment on column public.stores.prospection_enabled is
  'Libera exclusivamente o modulo Prospeccao para este cliente.';
comment on column public.stores.attendance_enabled is
  'Libera exclusivamente o modulo Atendimento para este cliente.';
comment on column public.app_users.prospection_store_limit is
  'Cota premium compartilhada: numero de clientes distintos com Prospeccao ou Atendimento ativo.';

create or replace function app_private.lead_store_allowed(
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
      and st.lead_enabled = true
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

create or replace function app_private.attendance_store_allowed(
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
      and st.attendance_enabled = true
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
      and st.attendance_enabled = true
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

-- A antiga cota de Prospeccoes passa a contar a uniao dos dois modulos
-- premium. O mesmo cliente consome apenas uma licenca se ambos estiverem
-- ativos.
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

  select
    st.is_active,
    st.prospection_enabled,
    st.attendance_enabled,
    st.good_morning_seller_enabled
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
    raise exception 'Limite de clientes da agencia atingido (% de %).',
      v_in_use, v_agency.store_limit;
  end if;

  if v_store.prospection_enabled is true
     or v_store.attendance_enabled is true then
    select count(*)::integer
    into v_in_use
    from app_private.store_agency_accesses access
    join public.stores st
      on st.id = access.store_id
     and st.admin_user_id = access.admin_user_id
    where access.agency_user_id = new.agency_user_id
      and access.is_active = true
      and st.is_active = true
      and (st.prospection_enabled = true or st.attendance_enabled = true)
      and access.store_id <> new.store_id;

    if v_in_use >= v_agency.prospection_store_limit then
      raise exception 'A agencia nao possui licenca premium disponivel (% de %).',
        v_in_use, v_agency.prospection_store_limit;
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
      raise exception 'A agencia nao possui licenca de Bom Dia Vendedor disponivel (% de %).',
        v_in_use, v_agency.good_morning_seller_store_limit;
    end if;
  end if;

  new.updated_at := now();
  return new;
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
  v_old_premium_enabled boolean;
  v_new_premium_enabled boolean;
begin
  v_old_premium_enabled := case
    when tg_op = 'UPDATE'
      then coalesce(old.prospection_enabled, false)
        or coalesce(old.attendance_enabled, false)
    else false
  end;
  v_new_premium_enabled := coalesce(new.prospection_enabled, false)
    or coalesce(new.attendance_enabled, false);

  if tg_op = 'UPDATE'
     and old.admin_user_id is not distinct from new.admin_user_id
     and old.is_active is not distinct from new.is_active
     and v_old_premium_enabled is not distinct from v_new_premium_enabled then
    return new;
  end if;

  if new.is_active is distinct from true
     or v_new_premium_enabled is distinct from true then
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
      and (st.prospection_enabled = true or st.attendance_enabled = true)
      and st.id <> new.id;

    if v_in_use >= v_agency.prospection_store_limit then
      raise exception 'Limite de clientes premium atingido para uma das agencias (% de %).',
        v_in_use, v_agency.prospection_store_limit;
    end if;
  end loop;

  return new;
end;
$$;

drop trigger if exists stores_enforce_prospection_quota on public.stores;
create trigger stores_enforce_prospection_quota
before insert or update of admin_user_id, is_active, prospection_enabled, attendance_enabled
on public.stores
for each row execute function app_private.enforce_prospection_store_quota();

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
  if tg_op = 'UPDATE'
     and old.attendance_enabled is true
     and new.attendance_enabled is false then
    new.good_morning_seller_enabled := false;
  end if;

  if tg_op = 'UPDATE'
     and old.admin_user_id is not distinct from new.admin_user_id
     and old.is_active is not distinct from new.is_active
     and old.attendance_enabled is not distinct from new.attendance_enabled
     and old.good_morning_seller_enabled is not distinct from new.good_morning_seller_enabled then
    return new;
  end if;

  if new.is_active is distinct from true
     or new.good_morning_seller_enabled is distinct from true then
    return new;
  end if;

  if new.attendance_enabled is distinct from true then
    raise exception 'Bom Dia Vendedor exige o modulo Atendimento ativo.';
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
      raise exception 'Limite de clientes com Bom Dia Vendedor atingido para uma das agencias (% de %).',
        v_in_use, v_agency.good_morning_seller_store_limit;
    end if;
  end loop;

  return new;
end;
$$;

drop trigger if exists stores_enforce_good_morning_seller_quota on public.stores;
create trigger stores_enforce_good_morning_seller_quota
before insert or update of admin_user_id, is_active, attendance_enabled, good_morning_seller_enabled
on public.stores
for each row execute function app_private.enforce_good_morning_seller_store_quota();

create or replace function app_private.rpc_set_store_lead_access(
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

  perform 1
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

  update public.stores
  set lead_enabled = coalesce(p_enabled, false)
  where id = p_store_id
    and admin_user_id = v_session.admin_user_id;

  return true;
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

  perform 1
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

  update public.stores
  set prospection_enabled = coalesce(p_enabled, false)
  where id = p_store_id
    and admin_user_id = v_session.admin_user_id;

  return true;
end;
$$;

create or replace function app_private.rpc_set_store_attendance_access(
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

  perform 1
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

  update public.stores
  set attendance_enabled = coalesce(p_enabled, false)
  where id = p_store_id
    and admin_user_id = v_session.admin_user_id;

  return true;
end;
$$;

create or replace function app_private.rpc_get_prospection_entitlements(
  p_session_token text
)
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
            and (st.prospection_enabled = true or st.attendance_enabled = true)
        )
        else 0
      end,
      'premium_store_limit', case
        when v_session.user_role::text = 'technician' then coalesce((
          select u.prospection_store_limit
          from public.app_users u
          where u.id = v_session.user_id
        ), 0)
        else 0
      end,
      'premium_store_count', case
        when v_session.user_role::text = 'technician' then (
          select count(*)
          from app_private.store_agency_accesses access
          join public.stores st
            on st.id = access.store_id
           and st.admin_user_id = access.admin_user_id
          where access.agency_user_id = v_session.user_id
            and access.is_active = true
            and st.is_active = true
            and (st.prospection_enabled = true or st.attendance_enabled = true)
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
        'lead_enabled', st.lead_enabled,
        'prospection_enabled', st.prospection_enabled,
        'attendance_enabled', st.attendance_enabled,
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
            and (st.prospection_enabled = true or st.attendance_enabled = true)
        ),
        'premium_store_limit', u.prospection_store_limit,
        'premium_store_count', (
          select count(*)
          from app_private.store_agency_accesses access
          join public.stores st
            on st.id = access.store_id
           and st.admin_user_id = access.admin_user_id
          where access.agency_user_id = u.id
            and access.is_active = true
            and st.is_active = true
            and (st.prospection_enabled = true or st.attendance_enabled = true)
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

-- Toda configuracao operacional de Lead passa por este resolvedor. A listagem
-- administrativa de clientes permanece fora deste guard para que os modulos
-- possam ser ligados novamente.
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

  if not app_private.lead_store_allowed(
    v_session.admin_user_id,
    v_session.user_id,
    v_session.user_role,
    v_session.user_store_id,
    v_store_id
  ) then
    raise exception 'Cliente nao encontrado, sem permissao ou sem acesso ao modulo Lead.';
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
    and app_private.lead_store_allowed(
      v_session.admin_user_id,
      v_session.user_id,
      v_session.user_role,
      v_session.user_store_id,
      l.store_id
    )
  order by l.created_at desc;
end;
$$;

-- O endpoint interno legado tambem delega para a listagem protegida, evitando
-- que integracoes antigas contornem a flag do modulo.
create or replace function app_private.rpc_list_leads(p_session_token text)
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
security definer
set search_path = app_private, public, extensions
as $$
  select * from app_private.rpc_list_leads_b2b(p_session_token);
$$;

create or replace function app_private.rpc_list_lead_intelligence(
  p_session_token text
)
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
  where li.admin_user_id = v_session.admin_user_id
    and app_private.lead_store_allowed(
      v_session.admin_user_id,
      v_session.user_id,
      v_session.user_role,
      v_session.user_store_id,
      li.store_id
    );
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
  where l.id = p_lead_id
    and l.admin_user_id = v_session.admin_user_id
    and app_private.lead_store_allowed(
      v_session.admin_user_id,
      v_session.user_id,
      v_session.user_role,
      v_session.user_store_id,
      l.store_id
    );

  if not found then
    raise exception 'Lead nao encontrado, sem permissao ou sem acesso ao modulo Lead.';
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
      when p_payload ? 'first_response_at'
        then nullif(p_payload->>'first_response_at', '')::timestamptz
      else first_response_at
    end,
    qualified_at = case when v_qualified then coalesce(qualified_at, now()) else null end,
    lost_at = case when v_status = 'lost' then coalesce(lost_at, now()) else null end,
    purchased_at = case
      when v_status = 'won' then coalesce(purchased_at, now())
      else purchased_at
    end,
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

create or replace function app_private.rpc_set_lead_cpf(
  p_session_token text,
  p_lead_id uuid,
  p_cpf text default null
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_store_id uuid;
  v_cpf text := nullif(btrim(coalesce(p_cpf, '')), '');
begin
  select * into v_session from app_private.session_user(p_session_token);

  select l.store_id into v_store_id
  from public.leads l
  where l.id = p_lead_id
    and l.admin_user_id = v_session.admin_user_id;

  if v_store_id is null or not app_private.lead_store_allowed(
    v_session.admin_user_id,
    v_session.user_id,
    v_session.user_role,
    v_session.user_store_id,
    v_store_id
  ) then
    raise exception 'Lead nao encontrado, sem permissao ou sem acesso ao modulo Lead.';
  end if;

  if v_cpf is not null and not app_private.is_valid_cpf(v_cpf) then
    raise exception 'Informe um CPF valido.';
  end if;

  update public.leads
  set cpf = v_cpf,
      updated_by = v_session.user_id
  where id = p_lead_id
    and admin_user_id = v_session.admin_user_id;

  return true;
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
  set inspected = coalesce(p_inspected, false),
      updated_by = v_session.user_id
  where l.id = p_lead_id
    and l.admin_user_id = v_session.admin_user_id
    and app_private.lead_store_allowed(
      v_session.admin_user_id,
      v_session.user_id,
      v_session.user_role,
      v_session.user_store_id,
      l.store_id
    );

  if not found then
    raise exception 'Lead nao encontrado, sem permissao ou sem acesso ao modulo Lead.';
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
  set contact_date = coalesce(
        p_contact_date,
        l.contact_date,
        (timezone('America/Sao_Paulo', now()))::date
      ),
      updated_by = v_session.user_id
  where l.id = p_lead_id
    and l.admin_user_id = v_session.admin_user_id
    and app_private.lead_store_allowed(
      v_session.admin_user_id,
      v_session.user_id,
      v_session.user_role,
      v_session.user_store_id,
      l.store_id
    );

  if not found then
    raise exception 'Lead nao encontrado, sem permissao ou sem acesso ao modulo Lead.';
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
    and app_private.lead_store_allowed(
      v_session.admin_user_id,
      v_session.user_id,
      v_session.user_role,
      v_session.user_store_id,
      l.store_id
    );

  if not found then
    raise exception 'Lead nao encontrado, sem permissao ou sem acesso ao modulo Lead.';
  end if;

  return true;
end;
$$;

create or replace function app_private.rpc_upsert_lead(
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
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_store_id uuid;
  v_lead_id uuid;
  v_contact_date date;
  v_scheduled text;
  v_visited text;
  v_bought text;
begin
  select * into v_session from app_private.session_user(p_session_token);

  v_contact_date := coalesce(
    p_contact_date,
    (timezone('America/Sao_Paulo', now()))::date
  );
  v_scheduled := nullif(btrim(coalesce(p_scheduled, '')), '');
  v_visited := nullif(btrim(coalesce(p_visited, '')), '');
  v_bought := nullif(btrim(coalesce(p_bought, '')), '');

  if length(btrim(coalesce(p_name, ''))) = 0
     or length(btrim(coalesce(p_phone, ''))) = 0 then
    raise exception 'Preencha nome e telefone.';
  end if;

  if jsonb_typeof(coalesce(p_custom_values, '[]'::jsonb)) <> 'array' then
    raise exception 'Categorias adicionais invalidas.';
  end if;

  if v_scheduled is null then
    raise exception 'Informe se o lead agendou visita ou nao.';
  end if;

  if v_scheduled not in ('Sim', 'Não') then
    raise exception 'Agendamento invalido.';
  end if;

  if v_scheduled = 'Sim' and p_scheduled_visit_date is null then
    raise exception 'Informe a data da visita agendada.';
  end if;

  if v_visited = 'Sim' and v_bought is null then
    raise exception 'Informe se o lead comprou ou nao.';
  end if;

  if v_bought = 'Sim'
     and (
       p_purchase_amount is null
       or p_purchase_amount <= 0
       or nullif(btrim(coalesce(p_service_order, '')), '') is null
     ) then
    raise exception 'Informe o valor da compra e a OS.';
  end if;

  if v_session.user_role::text = 'store' then
    v_store_id := v_session.user_store_id;
  else
    v_store_id := p_store_id;
  end if;

  if p_lead_id is not null and v_store_id is null then
    select l.store_id
    into v_store_id
    from public.leads l
    where l.id = p_lead_id
      and l.admin_user_id = v_session.admin_user_id;
  end if;

  if v_store_id is null then
    raise exception 'Loja obrigatoria para cadastrar lead.';
  end if;

  if not app_private.lead_store_allowed(
    v_session.admin_user_id,
    v_session.user_id,
    v_session.user_role,
    v_session.user_store_id,
    v_store_id
  ) then
    raise exception 'Loja nao encontrada, sem permissao ou sem acesso ao modulo Lead.';
  end if;

  if p_lead_id is null then
    insert into public.leads (
      admin_user_id,
      store_id,
      name,
      phone,
      contact_date,
      channel,
      campaign,
      conversation_start,
      conclusion,
      scheduled,
      scheduled_visit_date,
      scheduled_visit_time,
      visited,
      bought,
      purchase_amount,
      service_order,
      notes,
      created_by,
      updated_by
    ) values (
      v_session.admin_user_id,
      v_store_id,
      btrim(p_name),
      btrim(p_phone),
      v_contact_date,
      nullif(btrim(coalesce(p_channel, '')), ''),
      nullif(btrim(coalesce(p_campaign, '')), ''),
      nullif(btrim(coalesce(p_conversation_start, '')), ''),
      nullif(btrim(coalesce(p_conclusion, '')), ''),
      v_scheduled,
      case when v_scheduled = 'Sim' then p_scheduled_visit_date else null end,
      case when v_scheduled = 'Sim' then p_scheduled_visit_time else null end,
      v_visited,
      v_bought,
      case when v_bought = 'Sim' then p_purchase_amount else null end,
      case
        when v_bought = 'Sim'
          then nullif(btrim(coalesce(p_service_order, '')), '')
        else null
      end,
      nullif(btrim(coalesce(p_notes, '')), ''),
      v_session.user_id,
      v_session.user_id
    )
    returning id into v_lead_id;
  else
    update public.leads l
    set
      store_id = v_store_id,
      name = btrim(p_name),
      phone = btrim(p_phone),
      contact_date = v_contact_date,
      channel = nullif(btrim(coalesce(p_channel, '')), ''),
      campaign = nullif(btrim(coalesce(p_campaign, '')), ''),
      conversation_start = nullif(btrim(coalesce(p_conversation_start, '')), ''),
      conclusion = nullif(btrim(coalesce(p_conclusion, '')), ''),
      scheduled = v_scheduled,
      scheduled_visit_date = case
        when v_scheduled = 'Sim' then p_scheduled_visit_date
        else null
      end,
      scheduled_visit_time = case
        when v_scheduled = 'Sim' then p_scheduled_visit_time
        else null
      end,
      visited = v_visited,
      bought = v_bought,
      purchase_amount = case
        when v_bought = 'Sim' then p_purchase_amount
        else null
      end,
      service_order = case
        when v_bought = 'Sim'
          then nullif(btrim(coalesce(p_service_order, '')), '')
        else null
      end,
      notes = nullif(btrim(coalesce(p_notes, '')), ''),
      updated_by = v_session.user_id
    where l.id = p_lead_id
      and l.admin_user_id = v_session.admin_user_id
      and app_private.lead_store_allowed(
        v_session.admin_user_id,
        v_session.user_id,
        v_session.user_role,
        v_session.user_store_id,
        l.store_id
      )
    returning l.id into v_lead_id;

    if not found then
      raise exception 'Lead nao encontrado, sem permissao ou sem acesso ao modulo Lead.';
    end if;
  end if;

  delete from public.lead_custom_values
  where lead_id = v_lead_id
    and admin_user_id = v_session.admin_user_id;

  insert into public.lead_custom_values (
    admin_user_id,
    lead_id,
    category_id,
    value
  )
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
   and lower(o.value) = lower(
     nullif(btrim(coalesce(item.value->>'value', '')), '')
   )
  where nullif(btrim(coalesce(item.value->>'value', '')), '') is not null
  on conflict (lead_id, category_id) do update
  set value = excluded.value,
      updated_at = now();

  return v_lead_id;
end;
$$;

-- RPCs versionados: criacao e edicao sao atomicas. Qualquer falha de cota ou
-- permissao desfaz tambem a conta/vinculo criados ou alterados na mesma chamada.
create or replace function app_private.rpc_create_store_with_module_access_v2(
  p_session_token text,
  p_name text,
  p_nick text,
  p_password text,
  p_technician_id uuid default null,
  p_lead_enabled boolean default false,
  p_prospection_enabled boolean default false,
  p_attendance_enabled boolean default false
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
  v_created record;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text not in ('admin', 'technician') then
    raise exception 'Apenas o Admin ou a Agencia podem criar clientes.';
  end if;

  select *
  into strict v_created
  from app_private.rpc_create_store(
    p_session_token,
    p_name,
    p_nick,
    p_password,
    p_technician_id
  );

  if coalesce(p_lead_enabled, false) then
    perform app_private.rpc_set_store_lead_access(
      p_session_token,
      v_created.store_id,
      true
    );
  end if;

  if coalesce(p_prospection_enabled, false) then
    perform app_private.rpc_set_store_prospection_access(
      p_session_token,
      v_created.store_id,
      true
    );
  end if;

  if coalesce(p_attendance_enabled, false) then
    perform app_private.rpc_set_store_attendance_access(
      p_session_token,
      v_created.store_id,
      true
    );
  end if;

  return query
  select
    v_created.store_id::uuid,
    v_created.store_name::text,
    v_created.store_nick::text,
    v_created.user_id::uuid,
    v_created.user_nick::text,
    v_created.technician_id::uuid;
end;
$$;

create or replace function app_private.rpc_update_store_with_module_access_v2(
  p_session_token text,
  p_store_id uuid,
  p_name text,
  p_nick text,
  p_password text default null,
  p_technician_id uuid default null,
  p_lead_enabled boolean default false,
  p_prospection_enabled boolean default false,
  p_attendance_enabled boolean default false,
  p_good_morning_seller_enabled boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_current record;
  v_actual record;
  v_result jsonb;
  v_lead_enabled boolean := coalesce(p_lead_enabled, false);
  v_prospection_enabled boolean := coalesce(p_prospection_enabled, false);
  v_attendance_enabled boolean := coalesce(p_attendance_enabled, false);
  v_good_morning_enabled boolean := coalesce(p_good_morning_seller_enabled, false);
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text not in ('admin', 'technician') then
    raise exception 'Sem permissao para editar este cliente.';
  end if;

  select
    st.lead_enabled,
    st.prospection_enabled,
    st.attendance_enabled,
    st.good_morning_seller_enabled
  into v_current
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

  if v_good_morning_enabled and not v_attendance_enabled then
    raise exception 'Bom Dia Vendedor exige o modulo Atendimento ativo.';
  end if;

  if v_current.good_morning_seller_enabled
     and not v_good_morning_enabled then
    perform app_private.rpc_set_store_good_morning_seller_access(
      p_session_token,
      p_store_id,
      false
    );
  end if;

  if v_current.lead_enabled and not v_lead_enabled then
    perform app_private.rpc_set_store_lead_access(
      p_session_token,
      p_store_id,
      false
    );
  end if;

  if v_current.prospection_enabled and not v_prospection_enabled then
    perform app_private.rpc_set_store_prospection_access(
      p_session_token,
      p_store_id,
      false
    );
  end if;

  if v_current.attendance_enabled and not v_attendance_enabled then
    perform app_private.rpc_set_store_attendance_access(
      p_session_token,
      p_store_id,
      false
    );
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

  if v_lead_enabled then
    perform app_private.rpc_set_store_lead_access(
      p_session_token,
      p_store_id,
      true
    );
  end if;

  if v_prospection_enabled then
    perform app_private.rpc_set_store_prospection_access(
      p_session_token,
      p_store_id,
      true
    );
  end if;

  if v_attendance_enabled then
    perform app_private.rpc_set_store_attendance_access(
      p_session_token,
      p_store_id,
      true
    );
  end if;

  if v_good_morning_enabled then
    perform app_private.rpc_set_store_good_morning_seller_access(
      p_session_token,
      p_store_id,
      true
    );
  end if;

  select
    st.lead_enabled,
    st.prospection_enabled,
    st.attendance_enabled,
    st.good_morning_seller_enabled
  into strict v_actual
  from public.stores st
  where st.id = p_store_id
    and st.admin_user_id = v_session.admin_user_id;

  return v_result || jsonb_build_object(
    'lead_enabled', v_actual.lead_enabled,
    'prospection_enabled', v_actual.prospection_enabled,
    'attendance_enabled', v_actual.attendance_enabled,
    'good_morning_seller_enabled', v_actual.good_morning_seller_enabled
  );
end;
$$;

-- Compatibilidade: o antigo unico switch de Prospeccao representava tambem
-- Atendimento. Ele continua controlando os dois, mas nunca liga Lead.
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
  v_lead_enabled boolean;
  v_good_morning_enabled boolean;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text not in ('admin', 'technician') then
    raise exception 'Sem permissao para editar este cliente.';
  end if;

  select st.lead_enabled, st.good_morning_seller_enabled
  into v_lead_enabled, v_good_morning_enabled
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

  return app_private.rpc_update_store_with_module_access_v2(
    p_session_token,
    p_store_id,
    p_name,
    p_nick,
    p_password,
    p_technician_id,
    v_lead_enabled,
    coalesce(p_prospection_enabled, false),
    coalesce(p_prospection_enabled, false),
    v_good_morning_enabled and coalesce(p_prospection_enabled, false)
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
  v_lead_enabled boolean;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text not in ('admin', 'technician') then
    raise exception 'Sem permissao para editar este cliente.';
  end if;

  select st.lead_enabled
  into v_lead_enabled
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

  return app_private.rpc_update_store_with_module_access_v2(
    p_session_token,
    p_store_id,
    p_name,
    p_nick,
    p_password,
    p_technician_id,
    v_lead_enabled,
    coalesce(p_prospection_enabled, false),
    coalesce(p_prospection_enabled, false),
    coalesce(p_good_morning_seller_enabled, false)
  );
end;
$$;

create or replace function public.lc_set_store_lead_access(
  p_session_token text,
  p_store_id uuid,
  p_enabled boolean
)
returns boolean
language sql
security invoker
set search_path = app_private, public, extensions
as $$
  select app_private.rpc_set_store_lead_access(
    p_session_token,
    p_store_id,
    p_enabled
  );
$$;

create or replace function public.lc_set_store_attendance_access(
  p_session_token text,
  p_store_id uuid,
  p_enabled boolean
)
returns boolean
language sql
security invoker
set search_path = app_private, public, extensions
as $$
  select app_private.rpc_set_store_attendance_access(
    p_session_token,
    p_store_id,
    p_enabled
  );
$$;

create or replace function public.lc_create_store_with_module_access_v2(
  p_session_token text,
  p_name text,
  p_nick text,
  p_password text,
  p_technician_id uuid default null,
  p_lead_enabled boolean default false,
  p_prospection_enabled boolean default false,
  p_attendance_enabled boolean default false
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
set search_path = app_private, public, extensions
as $$
  select *
  from app_private.rpc_create_store_with_module_access_v2(
    p_session_token,
    p_name,
    p_nick,
    p_password,
    p_technician_id,
    p_lead_enabled,
    p_prospection_enabled,
    p_attendance_enabled
  );
$$;

create or replace function public.lc_update_store_with_module_access_v2(
  p_session_token text,
  p_store_id uuid,
  p_name text,
  p_nick text,
  p_password text default null,
  p_technician_id uuid default null,
  p_lead_enabled boolean default false,
  p_prospection_enabled boolean default false,
  p_attendance_enabled boolean default false,
  p_good_morning_seller_enabled boolean default false
)
returns jsonb
language sql
security invoker
set search_path = app_private, public, extensions
as $$
  select app_private.rpc_update_store_with_module_access_v2(
    p_session_token,
    p_store_id,
    p_name,
    p_nick,
    p_password,
    p_technician_id,
    p_lead_enabled,
    p_prospection_enabled,
    p_attendance_enabled,
    p_good_morning_seller_enabled
  );
$$;

create or replace function public.lc_update_store_with_feature_access(
  p_session_token text,
  p_store_id uuid,
  p_name text,
  p_nick text,
  p_password text default null,
  p_technician_id uuid default null,
  p_prospection_enabled boolean default false
)
returns jsonb
language sql
security invoker
set search_path = app_private, public, extensions
as $$
  select app_private.rpc_update_store_with_feature_access(
    p_session_token,
    p_store_id,
    p_name,
    p_nick,
    p_password,
    p_technician_id,
    p_prospection_enabled
  );
$$;

create or replace function public.lc_update_store_with_all_feature_access(
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
language sql
security invoker
set search_path = app_private, public, extensions
as $$
  select app_private.rpc_update_store_with_all_feature_access(
    p_session_token,
    p_store_id,
    p_name,
    p_nick,
    p_password,
    p_technician_id,
    p_prospection_enabled,
    p_good_morning_seller_enabled
  );
$$;

-- Mantem o Assistente de Suporte coerente com as novas licencas independentes.
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
  v_has_leads boolean := false;
  v_has_prospections boolean := false;
  v_has_attendances boolean := false;
  v_has_good_morning_seller boolean := false;
  v_provider text;
  v_model text;
  v_api_key text;
  v_usage_id uuid;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text not in ('admin', 'technician', 'store') then
    raise exception 'Perfil sem acesso ao Assistente de Suporte.'
      using errcode = '42501';
  end if;

  if v_session.user_role::text = 'store' then
    if p_store_id is not null and p_store_id <> v_session.user_store_id then
      raise exception 'Cliente sem permissao para esta loja.'
        using errcode = '42501';
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
      raise exception 'Cliente sem permissao para esta loja.'
        using errcode = '42501';
    end if;
    v_scope_store_id := p_store_id;
  end if;

  select
    exists (
      select 1
      from public.stores st
      where st.admin_user_id = v_session.admin_user_id
        and (v_scope_store_id is null or st.id = v_scope_store_id)
        and app_private.lead_store_allowed(
          v_session.admin_user_id,
          v_session.user_id,
          v_session.user_role,
          v_session.user_store_id,
          st.id
        )
    ),
    exists (
      select 1
      from public.stores st
      where st.admin_user_id = v_session.admin_user_id
        and (v_scope_store_id is null or st.id = v_scope_store_id)
        and app_private.prospection_store_allowed(
          v_session.admin_user_id,
          v_session.user_id,
          v_session.user_role,
          v_session.user_store_id,
          st.id,
          false
        )
    ),
    exists (
      select 1
      from public.stores st
      where st.admin_user_id = v_session.admin_user_id
        and (v_scope_store_id is null or st.id = v_scope_store_id)
        and app_private.attendance_store_allowed(
          v_session.admin_user_id,
          v_session.user_id,
          v_session.user_role,
          v_session.user_store_id,
          st.id
        )
    ),
    exists (
      select 1
      from public.stores st
      where st.admin_user_id = v_session.admin_user_id
        and (v_scope_store_id is null or st.id = v_scope_store_id)
        and app_private.good_morning_seller_store_allowed(
          v_session.admin_user_id,
          v_session.user_id,
          v_session.user_role,
          v_session.user_store_id,
          st.id
        )
    )
  into
    v_has_leads,
    v_has_prospections,
    v_has_attendances,
    v_has_good_morning_seller;

  select settings.provider, settings.model, settings.api_key
  into v_provider, v_model, v_api_key
  from public.ai_settings settings
  where settings.admin_user_id = v_session.admin_user_id
    and settings.provider in ('gemini', 'deepseek')
    and length(btrim(settings.api_key)) > 0
  limit 1;

  if not found then
    raise exception 'A IA ainda nao foi configurada pelo administrador.'
      using errcode = 'P0001';
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
    raise exception 'Limite temporario do Assistente de Suporte atingido.'
      using errcode = 'P0001';
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
      'leads', v_has_leads,
      'prospections', v_has_prospections,
      'attendances', v_has_attendances,
      'good_morning_seller', v_has_good_morning_seller,
      'client_configuration', v_has_leads,
      'categories', v_has_leads,
      'options', v_has_leads,
      'sequence', v_has_leads
    ),
    array_remove(array[
      case when v_has_leads then 'open_leads' end,
      case when v_has_prospections then 'open_prospections' end,
      case when v_has_attendances then 'open_attendances' end,
      case when v_has_leads then 'open_lead_configuration' end
    ]::text[], null),
    v_usage_id;
end;
$$;

revoke all on function app_private.lead_store_allowed(
  uuid, uuid, public.app_user_role, uuid, uuid
) from public, anon, authenticated;
revoke all on function app_private.prospection_store_allowed(
  uuid, uuid, public.app_user_role, uuid, uuid, boolean
) from public, anon, authenticated;
revoke all on function app_private.attendance_store_allowed(
  uuid, uuid, public.app_user_role, uuid, uuid
) from public, anon, authenticated;
revoke all on function app_private.good_morning_seller_store_allowed(
  uuid, uuid, public.app_user_role, uuid, uuid
) from public, anon, authenticated;
revoke all on function app_private.validate_store_agency_access()
  from public, anon, authenticated;
revoke all on function app_private.enforce_prospection_store_quota()
  from public, anon, authenticated;
revoke all on function app_private.enforce_good_morning_seller_store_quota()
  from public, anon, authenticated;

revoke all on function app_private.rpc_list_leads(text)
  from public, anon, authenticated;
grant execute on function app_private.rpc_list_leads(text)
  to anon, authenticated;

revoke all on function app_private.rpc_set_store_lead_access(text, uuid, boolean)
  from public, anon, authenticated;
revoke all on function app_private.rpc_set_store_prospection_access(text, uuid, boolean)
  from public, anon, authenticated;
revoke all on function app_private.rpc_set_store_attendance_access(text, uuid, boolean)
  from public, anon, authenticated;
revoke all on function app_private.rpc_create_store_with_module_access_v2(
  text, text, text, text, uuid, boolean, boolean, boolean
) from public, anon, authenticated;
revoke all on function app_private.rpc_update_store_with_module_access_v2(
  text, uuid, text, text, text, uuid, boolean, boolean, boolean, boolean
) from public, anon, authenticated;
revoke all on function app_private.rpc_update_store_with_feature_access(
  text, uuid, text, text, text, uuid, boolean
) from public, anon, authenticated;
revoke all on function app_private.rpc_update_store_with_all_feature_access(
  text, uuid, text, text, text, uuid, boolean, boolean
) from public, anon, authenticated;

grant execute on function app_private.rpc_set_store_lead_access(text, uuid, boolean)
  to anon, authenticated;
grant execute on function app_private.rpc_set_store_prospection_access(text, uuid, boolean)
  to anon, authenticated;
grant execute on function app_private.rpc_set_store_attendance_access(text, uuid, boolean)
  to anon, authenticated;
grant execute on function app_private.rpc_create_store_with_module_access_v2(
  text, text, text, text, uuid, boolean, boolean, boolean
) to anon, authenticated;
grant execute on function app_private.rpc_update_store_with_module_access_v2(
  text, uuid, text, text, text, uuid, boolean, boolean, boolean, boolean
) to anon, authenticated;
grant execute on function app_private.rpc_update_store_with_feature_access(
  text, uuid, text, text, text, uuid, boolean
) to anon, authenticated;
grant execute on function app_private.rpc_update_store_with_all_feature_access(
  text, uuid, text, text, text, uuid, boolean, boolean
) to anon, authenticated;

revoke all on function public.lc_set_store_lead_access(text, uuid, boolean)
  from public;
revoke all on function public.lc_set_store_attendance_access(text, uuid, boolean)
  from public;
revoke all on function public.lc_create_store_with_module_access_v2(
  text, text, text, text, uuid, boolean, boolean, boolean
) from public;
revoke all on function public.lc_update_store_with_module_access_v2(
  text, uuid, text, text, text, uuid, boolean, boolean, boolean, boolean
) from public;
revoke all on function public.lc_update_store_with_feature_access(
  text, uuid, text, text, text, uuid, boolean
) from public;
revoke all on function public.lc_update_store_with_all_feature_access(
  text, uuid, text, text, text, uuid, boolean, boolean
) from public;

grant execute on function public.lc_set_store_lead_access(text, uuid, boolean)
  to anon, authenticated;
grant execute on function public.lc_set_store_attendance_access(text, uuid, boolean)
  to anon, authenticated;
grant execute on function public.lc_create_store_with_module_access_v2(
  text, text, text, text, uuid, boolean, boolean, boolean
) to anon, authenticated;
grant execute on function public.lc_update_store_with_module_access_v2(
  text, uuid, text, text, text, uuid, boolean, boolean, boolean, boolean
) to anon, authenticated;
grant execute on function public.lc_update_store_with_feature_access(
  text, uuid, text, text, text, uuid, boolean
) to anon, authenticated;
grant execute on function public.lc_update_store_with_all_feature_access(
  text, uuid, text, text, text, uuid, boolean, boolean
) to anon, authenticated;

comment on function public.lc_create_store_with_module_access_v2(
  text, text, text, text, uuid, boolean, boolean, boolean
) is 'Cria cliente e define Lead, Prospeccao e Atendimento de forma atomica.';
comment on function public.lc_update_store_with_module_access_v2(
  text, uuid, text, text, text, uuid, boolean, boolean, boolean, boolean
) is 'Atualiza cliente e os acessos independentes aos modulos de forma atomica.';

notify pgrst, 'reload schema';

commit;
