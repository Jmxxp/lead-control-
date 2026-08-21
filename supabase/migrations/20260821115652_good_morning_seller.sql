-- Bom Dia Vendedor | metas comerciais, distribuicao por vendedor e fila da vez.
-- Modulo adicional licenciado por cliente e isolado pela sessao da plataforma.

begin;

set local search_path = public, app_private, extensions;

alter table public.app_users
  add column if not exists good_morning_seller_store_limit integer not null default 0;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'app_users_good_morning_seller_limit_check'
      and conrelid = 'public.app_users'::regclass
  ) then
    alter table public.app_users
      add constraint app_users_good_morning_seller_limit_check
      check (good_morning_seller_store_limit between 0 and 9999);
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conname = 'app_users_good_morning_seller_within_store_limit_check'
      and conrelid = 'public.app_users'::regclass
  ) then
    alter table public.app_users
      add constraint app_users_good_morning_seller_within_store_limit_check
      check (
        role::text <> 'technician'
        or good_morning_seller_store_limit <= store_limit
      );
  end if;
end;
$$;

alter table public.stores
  add column if not exists good_morning_seller_enabled boolean not null default false;

create index if not exists stores_technician_good_morning_enabled_idx
  on public.stores (technician_user_id, good_morning_seller_enabled)
  where is_active = true;

create unique index if not exists prospection_professionals_identity_store_uidx
  on public.prospection_professionals (id, store_id, admin_user_id);

create table if not exists public.good_morning_seller_settings (
  store_id uuid primary key,
  admin_user_id uuid not null,
  goal_month date not null,
  monthly_goal numeric(14, 2) not null default 0,
  allocation_mode text not null default 'equal',
  current_professional_id uuid,
  updated_by uuid references public.app_users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint good_morning_seller_settings_store_admin_fk
    foreign key (store_id, admin_user_id)
    references public.stores(id, admin_user_id)
    on delete cascade,
  constraint good_morning_seller_settings_store_admin_unique
    unique (store_id, admin_user_id),
  constraint good_morning_seller_settings_current_professional_fk
    foreign key (current_professional_id, store_id, admin_user_id)
    references public.prospection_professionals(id, store_id, admin_user_id)
    on delete set null (current_professional_id),
  constraint good_morning_seller_settings_goal_month_check
    check (extract(day from goal_month) = 1),
  constraint good_morning_seller_settings_monthly_goal_check
    check (monthly_goal between 0 and 999999999999.99),
  constraint good_morning_seller_settings_allocation_mode_check
    check (allocation_mode in ('equal', 'custom'))
);

create table if not exists public.good_morning_seller_allocations (
  store_id uuid not null,
  admin_user_id uuid not null,
  professional_id uuid not null,
  goal_amount numeric(14, 2) not null,
  queue_position integer not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (store_id, professional_id),
  constraint good_morning_seller_allocations_settings_fk
    foreign key (store_id, admin_user_id)
    references public.good_morning_seller_settings(store_id, admin_user_id)
    on delete cascade,
  constraint good_morning_seller_allocations_professional_fk
    foreign key (professional_id, store_id, admin_user_id)
    references public.prospection_professionals(id, store_id, admin_user_id)
    on delete cascade,
  constraint good_morning_seller_allocations_goal_check
    check (goal_amount between 0 and 999999999999.99),
  constraint good_morning_seller_allocations_position_check
    check (queue_position between 1 and 9999),
  constraint good_morning_seller_allocations_store_position_unique
    unique (store_id, queue_position)
);

create index if not exists good_morning_seller_settings_admin_idx
  on public.good_morning_seller_settings (admin_user_id, store_id);

create index if not exists good_morning_seller_allocations_professional_idx
  on public.good_morning_seller_allocations (professional_id, store_id);

alter table public.good_morning_seller_settings enable row level security;
alter table public.good_morning_seller_allocations enable row level security;

revoke all on table public.good_morning_seller_settings from public, anon, authenticated;
revoke all on table public.good_morning_seller_allocations from public, anon, authenticated;
grant select, insert, update, delete on table public.good_morning_seller_settings to service_role;
grant select, insert, update, delete on table public.good_morning_seller_allocations to service_role;

drop trigger if exists good_morning_seller_settings_updated_at on public.good_morning_seller_settings;
create trigger good_morning_seller_settings_updated_at
before update on public.good_morning_seller_settings
for each row execute function app_private.set_updated_at();

drop trigger if exists good_morning_seller_allocations_updated_at on public.good_morning_seller_allocations;
create trigger good_morning_seller_allocations_updated_at
before update on public.good_morning_seller_allocations
for each row execute function app_private.set_updated_at();

create or replace function app_private.enforce_good_morning_seller_store_quota()
returns trigger
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_limit integer;
  v_in_use integer;
begin
  if new.prospection_enabled is distinct from true
     and tg_op = 'UPDATE'
     and old.prospection_enabled is true
     and new.prospection_enabled is false then
    new.good_morning_seller_enabled := false;
  end if;

  if tg_op = 'UPDATE'
     and old.technician_user_id is not distinct from new.technician_user_id
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
    raise exception 'Bom Dia Vendedor exige Prospecções e Atendimentos ativos.';
  end if;

  if new.technician_user_id is null then
    raise exception 'Defina a agência responsável antes de liberar Bom Dia Vendedor.';
  end if;

  select u.good_morning_seller_store_limit
  into v_limit
  from public.app_users u
  where u.id = new.technician_user_id
    and u.admin_user_id = new.admin_user_id
    and u.role::text = 'technician'
    and u.is_active = true
  for update;

  if not found then
    raise exception 'Agência responsável não encontrada ou inativa.';
  end if;

  select count(*)::integer
  into v_in_use
  from public.stores st
  where st.technician_user_id = new.technician_user_id
    and st.admin_user_id = new.admin_user_id
    and st.is_active = true
    and st.good_morning_seller_enabled = true
    and st.id <> new.id;

  if v_in_use >= v_limit then
    raise exception 'Limite de clientes com Bom Dia Vendedor atingido (% de %).', v_in_use, v_limit;
  end if;

  return new;
end;
$$;

drop trigger if exists stores_enforce_good_morning_seller_quota on public.stores;
create trigger stores_enforce_good_morning_seller_quota
before insert or update of technician_user_id, admin_user_id, is_active, prospection_enabled, good_morning_seller_enabled
on public.stores
for each row execute function app_private.enforce_good_morning_seller_store_quota();

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
        or (p_user_role::text = 'technician' and st.technician_user_id = p_user_id)
        or (p_user_role::text = 'store' and st.id = p_user_store_id)
      )
  );
$$;

create or replace function app_private.rpc_get_good_morning_seller_workspace(
  p_session_token text,
  p_store_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_settings public.good_morning_seller_settings%rowtype;
  v_today date := timezone('America/Sao_Paulo', now())::date;
  v_month_start date;
  v_month_end date;
  v_week_start date;
  v_week_end date;
  v_days_in_month integer;
  v_days_in_week integer;
  v_configured boolean := false;
  v_monthly_goal numeric(14, 2) := 0;
  v_day_goal numeric(14, 2) := 0;
  v_week_goal numeric(14, 2) := 0;
  v_month_actual numeric(14, 2) := 0;
  v_week_actual numeric(14, 2) := 0;
  v_day_actual numeric(14, 2) := 0;
  v_professionals jsonb := '[]'::jsonb;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if not app_private.good_morning_seller_store_allowed(
    v_session.admin_user_id,
    v_session.user_id,
    v_session.user_role,
    v_session.user_store_id,
    p_store_id
  ) then
    raise exception 'Bom Dia Vendedor não está licenciado para este cliente.';
  end if;

  v_month_start := date_trunc('month', v_today)::date;
  v_month_end := (v_month_start + interval '1 month - 1 day')::date;
  v_week_start := greatest(
    v_month_start,
    v_today - (extract(isodow from v_today)::integer - 1)
  );
  v_week_end := least(v_month_end, v_week_start + 6);
  v_days_in_month := extract(day from v_month_end)::integer;
  v_days_in_week := (v_week_end - v_week_start) + 1;

  select *
  into v_settings
  from public.good_morning_seller_settings settings
  where settings.store_id = p_store_id;

  v_configured := found and v_settings.goal_month = v_month_start;
  if found then
    v_monthly_goal := v_settings.monthly_goal;
  end if;

  if v_configured and v_days_in_month > 0 then
    v_day_goal := round(v_monthly_goal / v_days_in_month, 2);
    v_week_goal := round((v_monthly_goal / v_days_in_month) * v_days_in_week, 2);
  end if;

  select
    coalesce(sum(a.purchase_value) filter (
      where timezone('America/Sao_Paulo', a.attended_at)::date between v_month_start and v_month_end
    ), 0),
    coalesce(sum(a.purchase_value) filter (
      where timezone('America/Sao_Paulo', a.attended_at)::date between v_week_start and v_week_end
    ), 0),
    coalesce(sum(a.purchase_value) filter (
      where timezone('America/Sao_Paulo', a.attended_at)::date = v_today
    ), 0)
  into v_month_actual, v_week_actual, v_day_actual
  from public.attendances a
  where a.store_id = p_store_id
    and a.admin_user_id = v_session.admin_user_id
    and a.tag = 'purchase'
    and a.purchase_value > 0
    and a.attended_at >= (v_month_start::timestamp at time zone 'America/Sao_Paulo')
    and a.attended_at < ((v_month_end + 1)::timestamp at time zone 'America/Sao_Paulo');

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', team.id,
      'name', team.name,
      'is_active', team.is_active,
      'goal_amount', case when v_configured then coalesce(allocation.goal_amount, 0) else 0 end,
      'queue_position', coalesce(allocation.queue_position, team.default_position),
      'is_current', v_configured and team.id = v_settings.current_professional_id,
      'actual_month', team.actual_month,
      'actual_week', team.actual_week,
      'actual_today', team.actual_today
    ) order by coalesce(allocation.queue_position, team.default_position), team.name
  ), '[]'::jsonb)
  into v_professionals
  from (
    select
      pp.id,
      pp.name,
      pp.is_active,
      row_number() over (order by pp.is_active desc, pp.created_at, pp.name)::integer as default_position,
      coalesce(sum(a.purchase_value) filter (
        where a.tag = 'purchase'
          and a.purchase_value > 0
          and timezone('America/Sao_Paulo', a.attended_at)::date between v_month_start and v_month_end
      ), 0) as actual_month,
      coalesce(sum(a.purchase_value) filter (
        where a.tag = 'purchase'
          and a.purchase_value > 0
          and timezone('America/Sao_Paulo', a.attended_at)::date between v_week_start and v_week_end
      ), 0) as actual_week,
      coalesce(sum(a.purchase_value) filter (
        where a.tag = 'purchase'
          and a.purchase_value > 0
          and timezone('America/Sao_Paulo', a.attended_at)::date = v_today
      ), 0) as actual_today
    from public.prospection_professionals pp
    left join public.attendances a
      on a.professional_id = pp.id
      and a.store_id = pp.store_id
      and a.admin_user_id = pp.admin_user_id
      and a.attended_at >= (v_month_start::timestamp at time zone 'America/Sao_Paulo')
      and a.attended_at < ((v_month_end + 1)::timestamp at time zone 'America/Sao_Paulo')
    where pp.store_id = p_store_id
      and pp.admin_user_id = v_session.admin_user_id
      and pp.is_active = true
    group by pp.id, pp.name, pp.is_active, pp.created_at
  ) team
  left join public.good_morning_seller_allocations allocation
    on allocation.store_id = p_store_id
    and allocation.professional_id = team.id;

  return jsonb_build_object(
    'licensed', true,
    'configured', v_configured,
    'goal_month', v_month_start,
    'saved_goal_month', case when v_settings.store_id is not null then v_settings.goal_month else null end,
    'allocation_mode', coalesce(v_settings.allocation_mode, 'equal'),
    'monthly_goal', case when v_configured then v_monthly_goal else 0 end,
    'last_monthly_goal', v_monthly_goal,
    'today', v_today,
    'week_start', v_week_start,
    'week_end', v_week_end,
    'goals', jsonb_build_object(
      'today', jsonb_build_object('target', v_day_goal, 'actual', v_day_actual),
      'week', jsonb_build_object('target', v_week_goal, 'actual', v_week_actual),
      'month', jsonb_build_object('target', case when v_configured then v_monthly_goal else 0 end, 'actual', v_month_actual)
    ),
    'current_professional_id', case when v_configured then v_settings.current_professional_id else null end,
    'professionals', v_professionals
  );
end;
$$;

create or replace function app_private.rpc_save_good_morning_seller_settings(
  p_session_token text,
  p_store_id uuid,
  p_monthly_goal numeric,
  p_allocation_mode text,
  p_allocations jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_month_start date := date_trunc('month', timezone('America/Sao_Paulo', now()))::date;
  v_goal numeric(14, 2) := round(coalesce(p_monthly_goal, -1), 2);
  v_mode text := lower(btrim(coalesce(p_allocation_mode, '')));
  v_professional_count integer;
  v_allocation_count integer;
  v_sum numeric(14, 2);
  v_goal_cents bigint;
  v_base_cents bigint;
  v_remainder_cents integer;
  v_current_professional_id uuid;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if not app_private.good_morning_seller_store_allowed(
    v_session.admin_user_id,
    v_session.user_id,
    v_session.user_role,
    v_session.user_store_id,
    p_store_id
  ) then
    raise exception 'Bom Dia Vendedor não está licenciado para este cliente.';
  end if;

  if v_goal < 0 or v_goal > 999999999999.99 then
    raise exception 'Informe uma meta mensal válida.';
  end if;

  if v_mode not in ('equal', 'custom') then
    raise exception 'Escolha divisão igual ou personalizada.';
  end if;

  if jsonb_typeof(p_allocations) is distinct from 'array'
     or jsonb_array_length(p_allocations) > 500 then
    raise exception 'A lista de vendedores é inválida.';
  end if;

  select count(*)::integer
  into v_professional_count
  from public.prospection_professionals pp
  where pp.store_id = p_store_id
    and pp.admin_user_id = v_session.admin_user_id
    and pp.is_active = true;

  if v_professional_count = 0 then
    raise exception 'Cadastre ao menos um vendedor ativo em Prospecções.';
  end if;

  select count(*)::integer
  into v_allocation_count
  from jsonb_array_elements(p_allocations) item
  where jsonb_typeof(item.value) = 'object'
    and (item.value->>'professional_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
    and (item.value->>'queue_position') ~ '^[0-9]+$'
    and (item.value->>'goal_amount') ~ '^[0-9]+([.][0-9]{1,2})?$';

  if v_allocation_count <> v_professional_count
     or v_allocation_count <> jsonb_array_length(p_allocations) then
    raise exception 'Inclua todos os vendedores ativos com valores válidos.';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_allocations) item
    left join public.prospection_professionals pp
      on pp.id = (item.value->>'professional_id')::uuid
      and pp.store_id = p_store_id
      and pp.admin_user_id = v_session.admin_user_id
      and pp.is_active = true
    where pp.id is null
  ) then
    raise exception 'A lista possui vendedor inválido ou de outro cliente.';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_allocations) item
    group by item.value->>'professional_id'
    having count(*) > 1
  ) or exists (
    select 1
    from jsonb_array_elements(p_allocations) item
    group by (item.value->>'queue_position')::integer
    having count(*) > 1
  ) then
    raise exception 'Não repita vendedores ou posições na fila.';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_allocations) item
    where (item.value->>'queue_position')::integer not between 1 and v_professional_count
  ) then
    raise exception 'A ordem da fila deve ser contínua.';
  end if;

  if v_mode = 'custom' then
    select round(coalesce(sum((item.value->>'goal_amount')::numeric), 0), 2)
    into v_sum
    from jsonb_array_elements(p_allocations) item;
    if v_sum <> v_goal then
      raise exception 'A soma das metas por vendedor deve ser igual à meta mensal (%).', v_goal;
    end if;
  end if;

  select settings.current_professional_id
  into v_current_professional_id
  from public.good_morning_seller_settings settings
  where settings.store_id = p_store_id
  for update;

  insert into public.good_morning_seller_settings (
    store_id,
    admin_user_id,
    goal_month,
    monthly_goal,
    allocation_mode,
    current_professional_id,
    updated_by
  ) values (
    p_store_id,
    v_session.admin_user_id,
    v_month_start,
    v_goal,
    v_mode,
    null,
    v_session.user_id
  )
  on conflict (store_id) do update
  set goal_month = excluded.goal_month,
      monthly_goal = excluded.monthly_goal,
      allocation_mode = excluded.allocation_mode,
      current_professional_id = null,
      updated_by = excluded.updated_by;

  delete from public.good_morning_seller_allocations allocation
  where allocation.store_id = p_store_id;

  if v_mode = 'equal' then
    v_goal_cents := round(v_goal * 100)::bigint;
    v_base_cents := v_goal_cents / v_professional_count;
    v_remainder_cents := (v_goal_cents % v_professional_count)::integer;

    insert into public.good_morning_seller_allocations (
      store_id,
      admin_user_id,
      professional_id,
      goal_amount,
      queue_position
    )
    select
      p_store_id,
      v_session.admin_user_id,
      (item.value->>'professional_id')::uuid,
      (
        v_base_cents
        + case when (item.value->>'queue_position')::integer <= v_remainder_cents then 1 else 0 end
      )::numeric / 100,
      (item.value->>'queue_position')::integer
    from jsonb_array_elements(p_allocations) item;
  else
    insert into public.good_morning_seller_allocations (
      store_id,
      admin_user_id,
      professional_id,
      goal_amount,
      queue_position
    )
    select
      p_store_id,
      v_session.admin_user_id,
      (item.value->>'professional_id')::uuid,
      round((item.value->>'goal_amount')::numeric, 2),
      (item.value->>'queue_position')::integer
    from jsonb_array_elements(p_allocations) item;
  end if;

  if v_current_professional_id is null or not exists (
    select 1
    from public.good_morning_seller_allocations allocation
    where allocation.store_id = p_store_id
      and allocation.professional_id = v_current_professional_id
  ) then
    select allocation.professional_id
    into v_current_professional_id
    from public.good_morning_seller_allocations allocation
    where allocation.store_id = p_store_id
    order by allocation.queue_position
    limit 1;
  end if;

  update public.good_morning_seller_settings
  set current_professional_id = v_current_professional_id
  where store_id = p_store_id;

  return app_private.rpc_get_good_morning_seller_workspace(p_session_token, p_store_id);
end;
$$;

create or replace function app_private.rpc_advance_good_morning_seller_turn(
  p_session_token text,
  p_store_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_current uuid;
  v_current_position integer := 0;
  v_next uuid;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if not app_private.good_morning_seller_store_allowed(
    v_session.admin_user_id,
    v_session.user_id,
    v_session.user_role,
    v_session.user_store_id,
    p_store_id
  ) then
    raise exception 'Bom Dia Vendedor não está licenciado para este cliente.';
  end if;

  select settings.current_professional_id
  into v_current
  from public.good_morning_seller_settings settings
  where settings.store_id = p_store_id
    and settings.goal_month = date_trunc('month', timezone('America/Sao_Paulo', now()))::date
  for update;

  if not found then
    raise exception 'Configure a meta deste mês antes de usar a fila.';
  end if;

  select coalesce(allocation.queue_position, 0)
  into v_current_position
  from public.good_morning_seller_allocations allocation
  where allocation.store_id = p_store_id
    and allocation.professional_id = v_current;

  select allocation.professional_id
  into v_next
  from public.good_morning_seller_allocations allocation
  where allocation.store_id = p_store_id
    and allocation.queue_position > v_current_position
  order by allocation.queue_position
  limit 1;

  if v_next is null then
    select allocation.professional_id
    into v_next
    from public.good_morning_seller_allocations allocation
    where allocation.store_id = p_store_id
    order by allocation.queue_position
    limit 1;
  end if;

  if v_next is null then
    raise exception 'A fila não possui vendedores.';
  end if;

  update public.good_morning_seller_settings
  set current_professional_id = v_next,
      updated_by = v_session.user_id
  where store_id = p_store_id;

  return app_private.rpc_get_good_morning_seller_workspace(p_session_token, p_store_id);
end;
$$;

create or replace function app_private.rpc_set_technician_good_morning_seller_limit(
  p_session_token text,
  p_technician_id uuid,
  p_limit integer
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_store_limit integer;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text <> 'admin' then
    raise exception 'Apenas o Admin pode alterar o limite do Bom Dia Vendedor.';
  end if;

  if coalesce(p_limit, -1) not between 0 and 9999 then
    raise exception 'Informe um limite do Bom Dia Vendedor entre 0 e 9999.';
  end if;

  select u.store_limit
  into v_store_limit
  from public.app_users u
  where u.id = p_technician_id
    and u.admin_user_id = v_session.admin_user_id
    and u.role::text = 'technician'
    and u.is_active = true
  for update;

  if not found then
    raise exception 'Agência não encontrada.';
  end if;

  if p_limit > v_store_limit then
    raise exception 'O limite do Bom Dia Vendedor não pode superar o total de % clientes.', v_store_limit;
  end if;

  update public.app_users
  set good_morning_seller_store_limit = p_limit
  where id = p_technician_id;

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
    raise exception 'Somente o Admin ou a Agência podem alterar este acesso.';
  end if;

  if not exists (
    select 1
    from public.stores st
    where st.id = p_store_id
      and st.admin_user_id = v_session.admin_user_id
      and st.is_active = true
      and (
        v_session.user_role::text = 'admin'
        or st.technician_user_id = v_session.user_id
      )
  ) then
    raise exception 'Cliente não encontrado ou sem permissão.';
  end if;

  update public.stores
  set good_morning_seller_enabled = coalesce(p_enabled, false)
  where id = p_store_id;

  return true;
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
          select u.prospection_store_limit from public.app_users u where u.id = v_session.user_id
        ), 0)
        else 0
      end,
      'prospection_store_count', case
        when v_session.user_role::text = 'technician' then (
          select count(*) from public.stores st
          where st.admin_user_id = v_session.admin_user_id
            and st.technician_user_id = v_session.user_id
            and st.is_active = true
            and st.prospection_enabled = true
        )
        else 0
      end,
      'good_morning_seller_store_limit', case
        when v_session.user_role::text = 'technician' then coalesce((
          select u.good_morning_seller_store_limit from public.app_users u where u.id = v_session.user_id
        ), 0)
        else 0
      end,
      'good_morning_seller_store_count', case
        when v_session.user_role::text = 'technician' then (
          select count(*) from public.stores st
          where st.admin_user_id = v_session.admin_user_id
            and st.technician_user_id = v_session.user_id
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
          or (v_session.user_role::text = 'technician' and st.technician_user_id = v_session.user_id)
          or (v_session.user_role::text = 'store' and st.id = v_session.user_store_id)
        )
    ), '[]'::jsonb),
    'technicians', coalesce((
      select jsonb_agg(jsonb_build_object(
        'technician_id', u.id,
        'prospection_store_limit', u.prospection_store_limit,
        'prospection_store_count', (
          select count(*) from public.stores st
          where st.admin_user_id = v_session.admin_user_id
            and st.technician_user_id = u.id
            and st.is_active = true
            and st.prospection_enabled = true
        ),
        'good_morning_seller_store_limit', u.good_morning_seller_store_limit,
        'good_morning_seller_store_count', (
          select count(*) from public.stores st
          where st.admin_user_id = v_session.admin_user_id
            and st.technician_user_id = u.id
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
  v_store record;
  v_result jsonb;
  v_target_technician_id uuid;
begin
  select * into v_session from app_private.session_user(p_session_token);

  select st.technician_user_id, st.good_morning_seller_enabled
  into v_store
  from public.stores st
  where st.id = p_store_id
    and st.admin_user_id = v_session.admin_user_id
    and st.is_active = true
    and (
      v_session.user_role::text = 'admin'
      or st.technician_user_id = v_session.user_id
    )
  for update;

  if not found then
    raise exception 'Cliente não encontrado ou sem permissão.';
  end if;

  v_target_technician_id := case
    when v_session.user_role::text = 'technician' then v_session.user_id
    else coalesce(p_technician_id, v_store.technician_user_id)
  end;

  if v_store.good_morning_seller_enabled is true
     and (
       coalesce(p_good_morning_seller_enabled, false) is false
       or v_store.technician_user_id is distinct from v_target_technician_id
     ) then
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

create or replace function app_private.rpc_create_technician_with_all_feature_plan(
  p_session_token text,
  p_full_name text,
  p_nick text,
  p_password text,
  p_store_limit integer,
  p_prospection_limit integer,
  p_good_morning_seller_limit integer
)
returns jsonb
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_result jsonb;
  v_technician_id uuid;
begin
  if coalesce(p_good_morning_seller_limit, -1) not between 0 and p_store_limit then
    raise exception 'A franquia do Bom Dia Vendedor deve ficar entre zero e o limite total de clientes.';
  end if;

  select app_private.rpc_create_technician_with_feature_plan(
    p_session_token,
    p_full_name,
    p_nick,
    p_password,
    p_store_limit,
    p_prospection_limit
  ) into v_result;

  v_technician_id := nullif(v_result->>'id', '')::uuid;
  if v_technician_id is null then
    raise exception 'Não foi possível identificar a Agência criada.';
  end if;

  perform app_private.rpc_set_technician_good_morning_seller_limit(
    p_session_token,
    v_technician_id,
    p_good_morning_seller_limit
  );

  return v_result || jsonb_build_object(
    'good_morning_seller_store_limit', p_good_morning_seller_limit
  );
end;
$$;

create or replace function app_private.rpc_update_technician_with_all_feature_plan(
  p_session_token text,
  p_technician_id uuid,
  p_full_name text,
  p_nick text,
  p_password text default null,
  p_store_limit integer default 5,
  p_prospection_limit integer default 0,
  p_good_morning_seller_limit integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_current_store_limit integer;
  v_result jsonb;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text <> 'admin' then
    raise exception 'Apenas o Admin pode alterar o plano da Agência.';
  end if;

  if coalesce(p_good_morning_seller_limit, -1) not between 0 and p_store_limit then
    raise exception 'A franquia do Bom Dia Vendedor deve ficar entre zero e o limite total de clientes.';
  end if;

  select agency.store_limit
  into v_current_store_limit
  from public.app_users agency
  where agency.id = p_technician_id
    and agency.admin_user_id = v_session.admin_user_id
    and agency.role::text = 'technician'
    and agency.is_active = true
  for update;

  if not found then
    raise exception 'Agência não encontrada.';
  end if;

  if p_store_limit < v_current_store_limit then
    perform app_private.rpc_set_technician_good_morning_seller_limit(
      p_session_token,
      p_technician_id,
      p_good_morning_seller_limit
    );
  end if;

  select app_private.rpc_update_technician_with_feature_plan(
    p_session_token,
    p_technician_id,
    p_full_name,
    p_nick,
    p_password,
    p_store_limit,
    p_prospection_limit
  ) into v_result;

  if p_store_limit >= v_current_store_limit then
    perform app_private.rpc_set_technician_good_morning_seller_limit(
      p_session_token,
      p_technician_id,
      p_good_morning_seller_limit
    );
  end if;

  return v_result || jsonb_build_object(
    'good_morning_seller_store_limit', p_good_morning_seller_limit
  );
end;
$$;

create or replace function public.lc_get_good_morning_seller_workspace(
  p_session_token text,
  p_store_id uuid
)
returns jsonb
language sql
security invoker
set search_path = app_private, public, extensions
as $$
  select app_private.rpc_get_good_morning_seller_workspace(p_session_token, p_store_id);
$$;

create or replace function public.lc_save_good_morning_seller_settings(
  p_session_token text,
  p_store_id uuid,
  p_monthly_goal numeric,
  p_allocation_mode text,
  p_allocations jsonb
)
returns jsonb
language sql
security invoker
set search_path = app_private, public, extensions
as $$
  select app_private.rpc_save_good_morning_seller_settings(
    p_session_token,
    p_store_id,
    p_monthly_goal,
    p_allocation_mode,
    p_allocations
  );
$$;

create or replace function public.lc_advance_good_morning_seller_turn(
  p_session_token text,
  p_store_id uuid
)
returns jsonb
language sql
security invoker
set search_path = app_private, public, extensions
as $$
  select app_private.rpc_advance_good_morning_seller_turn(p_session_token, p_store_id);
$$;

create or replace function public.lc_set_technician_good_morning_seller_limit(
  p_session_token text,
  p_technician_id uuid,
  p_limit integer
)
returns boolean
language sql
security invoker
set search_path = app_private, public, extensions
as $$
  select app_private.rpc_set_technician_good_morning_seller_limit(
    p_session_token,
    p_technician_id,
    p_limit
  );
$$;

create or replace function public.lc_set_store_good_morning_seller_access(
  p_session_token text,
  p_store_id uuid,
  p_enabled boolean
)
returns boolean
language sql
security invoker
set search_path = app_private, public, extensions
as $$
  select app_private.rpc_set_store_good_morning_seller_access(
    p_session_token,
    p_store_id,
    p_enabled
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

create or replace function public.lc_create_technician_with_all_feature_plan(
  p_session_token text,
  p_full_name text,
  p_nick text,
  p_password text,
  p_store_limit integer,
  p_prospection_limit integer,
  p_good_morning_seller_limit integer
)
returns jsonb
language sql
security invoker
set search_path = app_private, public, extensions
as $$
  select app_private.rpc_create_technician_with_all_feature_plan(
    p_session_token,
    p_full_name,
    p_nick,
    p_password,
    p_store_limit,
    p_prospection_limit,
    p_good_morning_seller_limit
  );
$$;

create or replace function public.lc_update_technician_with_all_feature_plan(
  p_session_token text,
  p_technician_id uuid,
  p_full_name text,
  p_nick text,
  p_password text default null,
  p_store_limit integer default 5,
  p_prospection_limit integer default 0,
  p_good_morning_seller_limit integer default 0
)
returns jsonb
language sql
security invoker
set search_path = app_private, public, extensions
as $$
  select app_private.rpc_update_technician_with_all_feature_plan(
    p_session_token,
    p_technician_id,
    p_full_name,
    p_nick,
    p_password,
    p_store_limit,
    p_prospection_limit,
    p_good_morning_seller_limit
  );
$$;

revoke all on function app_private.enforce_good_morning_seller_store_quota() from public, anon, authenticated;
revoke all on function app_private.good_morning_seller_store_allowed(uuid, uuid, public.app_user_role, uuid, uuid) from public, anon, authenticated;
revoke all on function app_private.rpc_get_good_morning_seller_workspace(text, uuid) from public, anon, authenticated;
revoke all on function app_private.rpc_save_good_morning_seller_settings(text, uuid, numeric, text, jsonb) from public, anon, authenticated;
revoke all on function app_private.rpc_advance_good_morning_seller_turn(text, uuid) from public, anon, authenticated;
revoke all on function app_private.rpc_set_technician_good_morning_seller_limit(text, uuid, integer) from public, anon, authenticated;
revoke all on function app_private.rpc_set_store_good_morning_seller_access(text, uuid, boolean) from public, anon, authenticated;
revoke all on function app_private.rpc_update_store_with_all_feature_access(text, uuid, text, text, text, uuid, boolean, boolean) from public, anon, authenticated;
revoke all on function app_private.rpc_create_technician_with_all_feature_plan(text, text, text, text, integer, integer, integer) from public, anon, authenticated;
revoke all on function app_private.rpc_update_technician_with_all_feature_plan(text, uuid, text, text, text, integer, integer, integer) from public, anon, authenticated;

grant execute on function app_private.rpc_get_good_morning_seller_workspace(text, uuid) to anon, authenticated;
grant execute on function app_private.rpc_save_good_morning_seller_settings(text, uuid, numeric, text, jsonb) to anon, authenticated;
grant execute on function app_private.rpc_advance_good_morning_seller_turn(text, uuid) to anon, authenticated;
grant execute on function app_private.rpc_set_technician_good_morning_seller_limit(text, uuid, integer) to anon, authenticated;
grant execute on function app_private.rpc_set_store_good_morning_seller_access(text, uuid, boolean) to anon, authenticated;
grant execute on function app_private.rpc_update_store_with_all_feature_access(text, uuid, text, text, text, uuid, boolean, boolean) to anon, authenticated;
grant execute on function app_private.rpc_create_technician_with_all_feature_plan(text, text, text, text, integer, integer, integer) to anon, authenticated;
grant execute on function app_private.rpc_update_technician_with_all_feature_plan(text, uuid, text, text, text, integer, integer, integer) to anon, authenticated;

revoke all on function public.lc_get_good_morning_seller_workspace(text, uuid) from public;
revoke all on function public.lc_save_good_morning_seller_settings(text, uuid, numeric, text, jsonb) from public;
revoke all on function public.lc_advance_good_morning_seller_turn(text, uuid) from public;
revoke all on function public.lc_set_technician_good_morning_seller_limit(text, uuid, integer) from public;
revoke all on function public.lc_set_store_good_morning_seller_access(text, uuid, boolean) from public;
revoke all on function public.lc_update_store_with_all_feature_access(text, uuid, text, text, text, uuid, boolean, boolean) from public;
revoke all on function public.lc_create_technician_with_all_feature_plan(text, text, text, text, integer, integer, integer) from public;
revoke all on function public.lc_update_technician_with_all_feature_plan(text, uuid, text, text, text, integer, integer, integer) from public;

grant execute on function public.lc_get_good_morning_seller_workspace(text, uuid) to anon, authenticated;
grant execute on function public.lc_save_good_morning_seller_settings(text, uuid, numeric, text, jsonb) to anon, authenticated;
grant execute on function public.lc_advance_good_morning_seller_turn(text, uuid) to anon, authenticated;
grant execute on function public.lc_set_technician_good_morning_seller_limit(text, uuid, integer) to anon, authenticated;
grant execute on function public.lc_set_store_good_morning_seller_access(text, uuid, boolean) to anon, authenticated;
grant execute on function public.lc_update_store_with_all_feature_access(text, uuid, text, text, text, uuid, boolean, boolean) to anon, authenticated;
grant execute on function public.lc_create_technician_with_all_feature_plan(text, text, text, text, integer, integer, integer) to anon, authenticated;
grant execute on function public.lc_update_technician_with_all_feature_plan(text, uuid, text, text, text, integer, integer, integer) to anon, authenticated;

comment on table public.good_morning_seller_settings is
  'Configuracao mensal e vendedor atual do modulo licenciado Bom Dia Vendedor.';
comment on table public.good_morning_seller_allocations is
  'Meta individual e ordem da fila para cada vendedor do Bom Dia Vendedor.';

notify pgrst, 'reload schema';

commit;
