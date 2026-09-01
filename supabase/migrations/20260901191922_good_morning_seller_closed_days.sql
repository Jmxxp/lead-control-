-- Bom Dia Vendedor | feriados e dias sem expediente por loja.
--
-- A RPC historica de configuracao permanece inalterada e preserva o calendario
-- ja salvo. A RPC v2 salva meta, rotacao e calendario na mesma transacao.

begin;

set local lock_timeout = '10s';
set local statement_timeout = '5min';

create table public.good_morning_seller_closed_days (
  store_id uuid not null,
  admin_user_id uuid not null,
  closed_on date not null,
  reason text not null default 'Sem expediente',
  created_by uuid references public.app_users(id) on delete set null,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  primary key (store_id, closed_on),
  constraint good_morning_seller_closed_days_store_admin_fk
    foreign key (store_id, admin_user_id)
    references public.stores(id, admin_user_id)
    on delete cascade,
  constraint good_morning_seller_closed_days_reason_check
    check (
      reason = pg_catalog.btrim(reason)
      and pg_catalog.char_length(reason) between 1 and 160
    ),
  constraint good_morning_seller_closed_days_working_weekday_check
    check (extract(isodow from closed_on)::integer between 1 and 6)
);

create index good_morning_seller_closed_days_admin_store_date_idx
  on public.good_morning_seller_closed_days (admin_user_id, store_id, closed_on);

alter table public.good_morning_seller_closed_days enable row level security;

revoke all on table public.good_morning_seller_closed_days
  from public, anon, authenticated;
grant select, insert, update, delete on table public.good_morning_seller_closed_days
  to service_role;

create trigger good_morning_seller_closed_days_updated_at
before update on public.good_morning_seller_closed_days
for each row execute function app_private.set_updated_at();

create or replace function app_private.normalize_good_morning_seller_closed_days(
  p_closed_days jsonb,
  p_month_start date
)
returns jsonb
language plpgsql
immutable
security invoker
set search_path = ''
as $$
declare
  v_item jsonb;
  v_raw_date text;
  v_closed_on date;
  v_reason text;
  v_seen_dates date[] := array[]::date[];
  v_normalized jsonb := '[]'::jsonb;
begin
  if p_month_start is null
     or extract(day from p_month_start)::integer <> 1 then
    raise exception using
      errcode = '22023',
      message = 'O mês do calendário é inválido.';
  end if;

  if pg_catalog.jsonb_typeof(p_closed_days) is distinct from 'array'
     or pg_catalog.jsonb_array_length(p_closed_days) > 31 then
    raise exception using
      errcode = '22023',
      message = 'A lista de dias sem expediente é inválida.';
  end if;

  for v_item in
    select entries.value
    from pg_catalog.jsonb_array_elements(p_closed_days) as entries(value)
  loop
    if pg_catalog.jsonb_typeof(v_item) is distinct from 'object'
       or not (v_item ? 'date')
       or pg_catalog.jsonb_typeof(v_item->'date') is distinct from 'string'
       or (
         v_item ? 'reason'
         and pg_catalog.jsonb_typeof(v_item->'reason') not in ('string', 'null')
       ) then
      raise exception using
        errcode = '22023',
        message = 'Cada dia sem expediente deve conter data e motivo válidos.';
    end if;

    v_raw_date := pg_catalog.btrim(v_item->>'date');
    if v_raw_date !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
      raise exception using
        errcode = '22023',
        message = 'Use datas no formato AAAA-MM-DD.';
    end if;

    begin
      v_closed_on := v_raw_date::date;
    exception
      when others then
        raise exception using
          errcode = '22023',
          message = 'Existe uma data inválida nos dias sem expediente.';
    end;

    if v_closed_on < p_month_start
       or v_closed_on >= (p_month_start + interval '1 month')::date then
      raise exception using
        errcode = '22023',
        message = 'Os dias sem expediente devem pertencer ao mês atual.';
    end if;

    if extract(isodow from v_closed_on)::integer = 7 then
      raise exception using
        errcode = '22023',
        message = 'Domingo já não entra nas metas e não precisa ser marcado.';
    end if;

    if v_closed_on = any(v_seen_dates) then
      raise exception using
        errcode = '22023',
        message = 'Não repita datas no calendário sem expediente.';
    end if;

    v_reason := pg_catalog.btrim(coalesce(v_item->>'reason', ''));
    if v_reason = '' then
      v_reason := 'Sem expediente';
    end if;
    if pg_catalog.char_length(v_reason) > 160 then
      raise exception using
        errcode = '22023',
        message = 'O motivo deve ter no máximo 160 caracteres.';
    end if;

    v_seen_dates := pg_catalog.array_append(v_seen_dates, v_closed_on);
    v_normalized := v_normalized || pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object(
        'date', pg_catalog.to_char(v_closed_on, 'YYYY-MM-DD'),
        'reason', v_reason
      )
    );
  end loop;

  select coalesce(
    pg_catalog.jsonb_agg(entries.value order by (entries.value->>'date')::date),
    '[]'::jsonb
  )
  into v_normalized
  from pg_catalog.jsonb_array_elements(v_normalized) as entries(value);

  return v_normalized;
end;
$$;

create or replace function app_private.attach_good_morning_seller_closed_days(
  p_session_token text,
  p_store_id uuid,
  p_workspace jsonb
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_session record;
  v_workspace jsonb := coalesce(p_workspace, '{}'::jsonb);
  v_today date;
  v_month_start date;
  v_closed_days jsonb := '[]'::jsonb;
begin
  select *
  into v_session
  from app_private.session_user(p_session_token);

  if not app_private.good_morning_seller_store_allowed(
    v_session.admin_user_id,
    v_session.user_id,
    v_session.user_role,
    v_session.user_store_id,
    p_store_id
  ) then
    raise exception 'Bom Dia Vendedor não está licenciado para este cliente.';
  end if;

  v_today := coalesce(
    nullif(v_workspace->>'today', '')::date,
    pg_catalog.timezone('America/Sao_Paulo', pg_catalog.now())::date
  );
  v_month_start := pg_catalog.date_trunc('month', v_today)::date;

  select coalesce(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'date', pg_catalog.to_char(days.closed_on, 'YYYY-MM-DD'),
        'reason', days.reason
      )
      order by days.closed_on
    ),
    '[]'::jsonb
  )
  into v_closed_days
  from public.good_morning_seller_closed_days days
  where days.store_id = p_store_id
    and days.admin_user_id = v_session.admin_user_id
    and days.closed_on >= v_month_start
    and days.closed_on < (v_month_start + interval '1 month')::date;

  return v_workspace || pg_catalog.jsonb_build_object(
    'closed_days_configuration_available', true,
    'closed_days', v_closed_days
  );
end;
$$;

create or replace function app_private.rpc_save_good_morning_seller_settings_with_closed_days(
  p_session_token text,
  p_store_id uuid,
  p_monthly_goal numeric,
  p_allocation_mode text,
  p_allocations jsonb,
  p_closed_days jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_session record;
  v_workspace jsonb;
  v_month_start date := pg_catalog.date_trunc(
    'month',
    pg_catalog.timezone('America/Sao_Paulo', pg_catalog.now())
  )::date;
  v_closed_days jsonb;
begin
  if not app_private.good_morning_seller_settings_manage_allowed(
    p_session_token,
    p_store_id
  ) then
    raise exception 'Somente o Admin ou a própria loja podem configurar o calendário do Bom Dia Vendedor.';
  end if;

  select *
  into v_session
  from app_private.session_user(p_session_token);

  v_closed_days := app_private.normalize_good_morning_seller_closed_days(
    p_closed_days,
    v_month_start
  );

  -- A funcao consolidada mantem os locks cliente -> equipe -> configuracao.
  -- Os locks duram ate o fim desta chamada, portanto calendario e rotacao
  -- confirmam ou revertem juntos.
  v_workspace := app_private.rpc_save_good_morning_seller_settings_store_only(
    p_session_token,
    p_store_id,
    p_monthly_goal,
    p_allocation_mode,
    p_allocations
  );

  delete from public.good_morning_seller_closed_days days
  where days.store_id = p_store_id
    and days.admin_user_id = v_session.admin_user_id
    and days.closed_on >= v_month_start
    and days.closed_on < (v_month_start + interval '1 month')::date;

  insert into public.good_morning_seller_closed_days (
    store_id,
    admin_user_id,
    closed_on,
    reason,
    created_by
  )
  select
    p_store_id,
    v_session.admin_user_id,
    (entries.value->>'date')::date,
    entries.value->>'reason',
    v_session.user_id
  from pg_catalog.jsonb_array_elements(v_closed_days) as entries(value);

  return v_workspace;
end;
$$;

create or replace function app_private.rebalance_good_morning_daily_goals(
  p_workspace jsonb
)
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_workspace jsonb := coalesce(p_workspace, '{}'::jsonb);
  v_today date;
  v_month_start date;
  v_month_end date;
  v_week_start date;
  v_week_end date;
  v_closed_days date[] := array[]::date[];
  v_configured boolean := false;
  v_today_is_closed boolean := false;
  v_today_is_working_day boolean := false;
  v_workdays_in_month integer := 0;
  v_workdays_in_week integer := 0;
  v_workdays_from_week_start integer := 0;
  v_remaining_workdays_in_week integer := 0;
  v_remaining_workdays_in_month integer := 0;
  v_team_month_goal_cents bigint := 0;
  v_team_month_actual_cents bigint := 0;
  v_team_week_actual_cents bigint := 0;
  v_team_today_actual_cents bigint := 0;
  v_team_actual_before_week_cents bigint := 0;
  v_team_week_actual_before_today_cents bigint := 0;
  v_team_week_goal_cents bigint := 0;
  v_team_day_goal_cents bigint := 0;
  v_unallocated_month_balance_cents bigint := 0;
  v_enabled boolean[] := array[]::boolean[];
  v_month_goal_cents bigint[] := array[]::bigint[];
  v_month_actual_before_week_cents bigint[] := array[]::bigint[];
  v_week_actual_before_today_cents bigint[] := array[]::bigint[];
  v_month_gap_cents bigint[] := array[]::bigint[];
  v_week_weights bigint[] := array[]::bigint[];
  v_week_goal_cents bigint[] := array[]::bigint[];
  v_week_gap_cents bigint[] := array[]::bigint[];
  v_day_weights bigint[] := array[]::bigint[];
  v_day_goal_cents bigint[] := array[]::bigint[];
  v_total_month_gap_cents bigint := 0;
  v_total_enabled_month_goal_cents bigint := 0;
  v_total_week_gap_cents bigint := 0;
  v_total_enabled_week_goal_cents bigint := 0;
  v_enabled_count integer := 0;
  v_professionals jsonb := '[]'::jsonb;
  v_goals jsonb := '{}'::jsonb;
  v_today_goal jsonb := '{}'::jsonb;
  v_week_goal jsonb := '{}'::jsonb;
begin
  if pg_catalog.jsonb_typeof(v_workspace) is distinct from 'object'
     or nullif(v_workspace->>'today', '') is null then
    return v_workspace;
  end if;

  v_today := (v_workspace->>'today')::date;
  v_configured := coalesce(
    nullif(v_workspace->>'configured', '')::boolean,
    true
  );
  v_month_start := pg_catalog.date_trunc('month', v_today)::date;
  v_month_end := (v_month_start + interval '1 month - 1 day')::date;
  v_week_start := coalesce(
    nullif(v_workspace->>'week_start', '')::date,
    greatest(
      v_month_start,
      v_today - (extract(isodow from v_today)::integer - 1)
    )
  );
  v_week_end := coalesce(
    nullif(v_workspace->>'week_end', '')::date,
    least(v_month_end, v_week_start + 6)
  );
  v_week_start := greatest(v_month_start, v_week_start);
  v_week_end := least(v_month_end, v_week_end);

  select coalesce(
    pg_catalog.array_agg((entries.value->>'date')::date order by entries.ordinality),
    array[]::date[]
  )
  into v_closed_days
  from pg_catalog.jsonb_array_elements(
    case
      when pg_catalog.jsonb_typeof(v_workspace->'closed_days') = 'array'
        then v_workspace->'closed_days'
      else '[]'::jsonb
    end
  ) with ordinality as entries(value, ordinality)
  where pg_catalog.jsonb_typeof(entries.value) = 'object'
    and (entries.value->>'date') ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$';

  v_today_is_closed := v_today = any(v_closed_days);
  v_today_is_working_day :=
    extract(isodow from v_today)::integer between 1 and 6
    and not v_today_is_closed;

  select
    pg_catalog.count(*)::integer,
    pg_catalog.count(*) filter (
      where calendar.day_value between v_week_start and v_week_end
    )::integer,
    pg_catalog.count(*) filter (
      where calendar.day_value between v_week_start and v_month_end
    )::integer,
    pg_catalog.count(*) filter (
      where calendar.day_value between v_today and v_week_end
    )::integer,
    pg_catalog.count(*) filter (
      where calendar.day_value between v_today and v_month_end
    )::integer
  into
    v_workdays_in_month,
    v_workdays_in_week,
    v_workdays_from_week_start,
    v_remaining_workdays_in_week,
    v_remaining_workdays_in_month
  from (
    select generated.day_value::date
    from pg_catalog.generate_series(
      v_month_start,
      v_month_end,
      interval '1 day'
    ) as generated(day_value)
    where extract(isodow from generated.day_value)::integer between 1 and 6
      and not (generated.day_value::date = any(v_closed_days))
  ) as calendar;

  v_team_month_goal_cents := pg_catalog.round(
    coalesce(
      nullif(v_workspace #>> '{goals,month,target}', '')::numeric,
      nullif(v_workspace->>'monthly_goal', '')::numeric,
      0
    ) * 100
  )::bigint;
  v_team_month_actual_cents := greatest(
    pg_catalog.round(
      coalesce(
        nullif(v_workspace #>> '{goals,month,actual}', '')::numeric,
        0
      ) * 100
    )::bigint,
    0
  );
  v_team_week_actual_cents := greatest(
    pg_catalog.round(
      coalesce(
        nullif(v_workspace #>> '{goals,week,actual}', '')::numeric,
        0
      ) * 100
    )::bigint,
    0
  );
  v_team_today_actual_cents := greatest(
    pg_catalog.round(
      coalesce(
        nullif(v_workspace #>> '{goals,today,actual}', '')::numeric,
        0
      ) * 100
    )::bigint,
    0
  );
  v_team_actual_before_week_cents := greatest(
    v_team_month_actual_cents - v_team_week_actual_cents,
    0
  );
  v_team_week_actual_before_today_cents := greatest(
    v_team_week_actual_cents - v_team_today_actual_cents,
    0
  );
  if v_configured and v_remaining_workdays_in_month = 0 then
    v_unallocated_month_balance_cents := greatest(
      v_team_month_goal_cents - v_team_month_actual_cents,
      0
    );
  end if;

  select
    coalesce(
      pg_catalog.array_agg(source.enabled order by source.ordinality),
      array[]::boolean[]
    ),
    coalesce(
      pg_catalog.array_agg(source.month_goal_cents order by source.ordinality),
      array[]::bigint[]
    ),
    coalesce(
      pg_catalog.array_agg(source.month_actual_before_week_cents order by source.ordinality),
      array[]::bigint[]
    ),
    coalesce(
      pg_catalog.array_agg(source.week_actual_before_today_cents order by source.ordinality),
      array[]::bigint[]
    )
  into
    v_enabled,
    v_month_goal_cents,
    v_month_actual_before_week_cents,
    v_week_actual_before_today_cents
  from (
    select
      entries.ordinality,
      coalesce(
        nullif(
          entries.professional->>'good_morning_seller_enabled',
          ''
        )::boolean,
        true
      ) as enabled,
      pg_catalog.round(
        coalesce(
          nullif(entries.professional->>'goal_month', '')::numeric,
          nullif(entries.professional->>'goal_amount', '')::numeric,
          0
        ) * 100
      )::bigint as month_goal_cents,
      greatest(
        pg_catalog.round((
          coalesce(
            nullif(entries.professional->>'actual_month', '')::numeric,
            0
          )
          - coalesce(
            nullif(entries.professional->>'actual_week', '')::numeric,
            0
          )
        ) * 100)::bigint,
        0
      ) as month_actual_before_week_cents,
      greatest(
        pg_catalog.round((
          coalesce(
            nullif(entries.professional->>'actual_week', '')::numeric,
            0
          )
          - coalesce(
            nullif(entries.professional->>'actual_today', '')::numeric,
            0
          )
        ) * 100)::bigint,
        0
      ) as week_actual_before_today_cents
    from pg_catalog.jsonb_array_elements(
      case
        when pg_catalog.jsonb_typeof(v_workspace->'professionals') = 'array'
          then v_workspace->'professionals'
        else '[]'::jsonb
      end
    ) with ordinality as entries(professional, ordinality)
  ) as source;

  select
    coalesce(pg_catalog.array_agg(
      case
        when v_enabled[indexes.item_index] then greatest(
          v_month_goal_cents[indexes.item_index]
          - v_month_actual_before_week_cents[indexes.item_index],
          0
        )
        else 0::bigint
      end
      order by indexes.item_index
    ), array[]::bigint[]),
    coalesce(pg_catalog.sum(
      case
        when v_enabled[indexes.item_index] then greatest(
          v_month_goal_cents[indexes.item_index]
          - v_month_actual_before_week_cents[indexes.item_index],
          0
        )
        else 0::bigint
      end
    ), 0)::bigint,
    coalesce(pg_catalog.sum(
      case
        when v_enabled[indexes.item_index]
          then v_month_goal_cents[indexes.item_index]
        else 0
      end
    ), 0)::bigint,
    pg_catalog.count(*) filter (where v_enabled[indexes.item_index])::integer
  into
    v_month_gap_cents,
    v_total_month_gap_cents,
    v_total_enabled_month_goal_cents,
    v_enabled_count
  from pg_catalog.generate_subscripts(v_enabled, 1) as indexes(item_index);

  if v_configured and v_enabled_count > 0 and v_workdays_from_week_start > 0 then
    v_team_week_goal_cents := pg_catalog.round(
      greatest(
        v_team_month_goal_cents - v_team_actual_before_week_cents,
        0
      )::numeric
      * v_workdays_in_week::numeric
      / v_workdays_from_week_start::numeric
    )::bigint;
  else
    v_team_week_goal_cents := 0;
  end if;

  select coalesce(pg_catalog.array_agg(
    case
      when v_total_month_gap_cents > 0 then v_month_gap_cents[indexes.item_index]
      when v_total_enabled_month_goal_cents > 0 and v_enabled[indexes.item_index]
        then v_month_goal_cents[indexes.item_index]
      when v_enabled[indexes.item_index] then 1::bigint
      else 0::bigint
    end
    order by indexes.item_index
  ), array[]::bigint[])
  into v_week_weights
  from pg_catalog.generate_subscripts(v_enabled, 1) as indexes(item_index);

  v_week_goal_cents := app_private.good_morning_seller_apportion_cents(
    v_team_week_goal_cents,
    v_week_weights
  );

  select
    coalesce(pg_catalog.array_agg(
      case
        when v_enabled[indexes.item_index] then greatest(
          coalesce(v_week_goal_cents[indexes.item_index], 0)
          - v_week_actual_before_today_cents[indexes.item_index],
          0
        )
        else 0::bigint
      end
      order by indexes.item_index
    ), array[]::bigint[]),
    coalesce(pg_catalog.sum(
      case
        when v_enabled[indexes.item_index] then greatest(
          coalesce(v_week_goal_cents[indexes.item_index], 0)
          - v_week_actual_before_today_cents[indexes.item_index],
          0
        )
        else 0::bigint
      end
    ), 0)::bigint,
    coalesce(pg_catalog.sum(
      case
        when v_enabled[indexes.item_index]
          then coalesce(v_week_goal_cents[indexes.item_index], 0)
        else 0
      end
    ), 0)::bigint
  into
    v_week_gap_cents,
    v_total_week_gap_cents,
    v_total_enabled_week_goal_cents
  from pg_catalog.generate_subscripts(v_enabled, 1) as indexes(item_index);

  if v_today_is_working_day
     and v_enabled_count > 0
     and v_remaining_workdays_in_week > 0 then
    v_team_day_goal_cents := app_private.good_morning_seller_remaining_daily_goal_cents(
      v_team_week_goal_cents,
      v_team_week_actual_before_today_cents,
      v_remaining_workdays_in_week
    );
  else
    v_team_day_goal_cents := 0;
  end if;

  select coalesce(pg_catalog.array_agg(
    case
      when v_total_week_gap_cents > 0 then v_week_gap_cents[indexes.item_index]
      when v_total_enabled_week_goal_cents > 0 and v_enabled[indexes.item_index]
        then coalesce(v_week_goal_cents[indexes.item_index], 0)
      when v_total_enabled_month_goal_cents > 0 and v_enabled[indexes.item_index]
        then v_month_goal_cents[indexes.item_index]
      when v_enabled[indexes.item_index] then 1::bigint
      else 0::bigint
    end
    order by indexes.item_index
  ), array[]::bigint[])
  into v_day_weights
  from pg_catalog.generate_subscripts(v_enabled, 1) as indexes(item_index);

  v_day_goal_cents := app_private.good_morning_seller_apportion_cents(
    v_team_day_goal_cents,
    v_day_weights
  );

  select coalesce(
    pg_catalog.jsonb_agg(
      entries.professional || pg_catalog.jsonb_build_object(
        'goal_week',
          coalesce(
            v_week_goal_cents[entries.ordinality::integer],
            0
          )::numeric / 100,
        'goal_today',
          coalesce(
            v_day_goal_cents[entries.ordinality::integer],
            0
          )::numeric / 100
      )
      order by entries.ordinality
    ),
    '[]'::jsonb
  )
  into v_professionals
  from pg_catalog.jsonb_array_elements(
    case
      when pg_catalog.jsonb_typeof(v_workspace->'professionals') = 'array'
        then v_workspace->'professionals'
      else '[]'::jsonb
    end
  ) with ordinality as entries(professional, ordinality);

  v_goals := case
    when pg_catalog.jsonb_typeof(v_workspace->'goals') = 'object'
      then v_workspace->'goals'
    else '{}'::jsonb
  end;
  v_today_goal := case
    when pg_catalog.jsonb_typeof(v_goals->'today') = 'object'
      then v_goals->'today'
    else '{}'::jsonb
  end;
  v_week_goal := case
    when pg_catalog.jsonb_typeof(v_goals->'week') = 'object'
      then v_goals->'week'
    else '{}'::jsonb
  end;
  v_today_goal := v_today_goal || pg_catalog.jsonb_build_object(
    'target', v_team_day_goal_cents::numeric / 100
  );
  v_week_goal := v_week_goal || pg_catalog.jsonb_build_object(
    'target', v_team_week_goal_cents::numeric / 100
  );
  v_goals := v_goals || pg_catalog.jsonb_build_object(
    'today', v_today_goal,
    'week', v_week_goal
  );

  return v_workspace || pg_catalog.jsonb_build_object(
    'professionals', v_professionals,
    'goals', v_goals,
    'today_is_closed', v_today_is_closed,
    'today_is_working_day', v_today_is_working_day,
    'workdays_in_month', v_workdays_in_month,
    'workdays_in_week', v_workdays_in_week,
    'workdays_in_current_week', v_workdays_in_week,
    'remaining_workdays_in_week', v_remaining_workdays_in_week,
    'remaining_workdays_in_month', v_remaining_workdays_in_month,
    'workdays_in_month_from_week_start', v_workdays_from_week_start,
    -- Mantido para frontends anteriores confiarem nos alvos calculados pelo SQL.
    'goal_strategy', 'hierarchical_weekly_daily_team_balance_v1',
    'weekly_goal_strategy', 'remaining_month_balance',
    'daily_goal_strategy', 'remaining_team_balance',
    'working_calendar_strategy', 'monday_saturday_store_closed_days_v1',
    'has_unallocated_month_balance', v_unallocated_month_balance_cents > 0,
    'unallocated_month_balance', v_unallocated_month_balance_cents::numeric / 100
  );
end;
$$;

-- Leitura e escritas historicas passam a anexar o calendario antes de
-- recalcular as metas, sem mudar nenhuma assinatura ja publicada.
create or replace function public.lc_get_good_morning_seller_workspace(
  p_session_token text,
  p_store_id uuid
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app_private.rebalance_good_morning_daily_goals(
    app_private.attach_good_morning_seller_closed_days(
      p_session_token,
      p_store_id,
      app_private.rpc_get_good_morning_seller_workspace(
        p_session_token,
        p_store_id
      )
    )
  ) || pg_catalog.jsonb_build_object(
    'participation_update_available', true,
    'can_manage_settings', app_private.good_morning_seller_settings_manage_allowed(
      p_session_token,
      p_store_id
    )
  );
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
set search_path = ''
as $$
  select app_private.rebalance_good_morning_daily_goals(
    app_private.attach_good_morning_seller_closed_days(
      p_session_token,
      p_store_id,
      app_private.rpc_save_good_morning_seller_settings_store_only(
        p_session_token,
        p_store_id,
        p_monthly_goal,
        p_allocation_mode,
        p_allocations
      )
    )
  ) || pg_catalog.jsonb_build_object(
    'participation_update_available', true,
    'can_manage_settings', true
  );
$$;

create or replace function public.lc_save_good_morning_seller_settings_v2(
  p_session_token text,
  p_store_id uuid,
  p_monthly_goal numeric,
  p_allocation_mode text,
  p_allocations jsonb,
  p_closed_days jsonb default '[]'::jsonb
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app_private.rebalance_good_morning_daily_goals(
    app_private.attach_good_morning_seller_closed_days(
      p_session_token,
      p_store_id,
      app_private.rpc_save_good_morning_seller_settings_with_closed_days(
        p_session_token,
        p_store_id,
        p_monthly_goal,
        p_allocation_mode,
        p_allocations,
        p_closed_days
      )
    )
  ) || pg_catalog.jsonb_build_object(
    'participation_update_available', true,
    'can_manage_settings', true
  );
$$;

create or replace function public.lc_advance_good_morning_seller_turn(
  p_session_token text,
  p_store_id uuid
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app_private.rebalance_good_morning_daily_goals(
    app_private.attach_good_morning_seller_closed_days(
      p_session_token,
      p_store_id,
      app_private.rpc_advance_good_morning_seller_turn_store_only(
        p_session_token,
        p_store_id
      )
    )
  ) || pg_catalog.jsonb_build_object(
    'participation_update_available', true,
    'can_manage_settings', true
  );
$$;

create or replace function public.lc_set_good_morning_seller_participation(
  p_session_token text,
  p_store_id uuid,
  p_professional_id uuid,
  p_enabled boolean
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app_private.rebalance_good_morning_daily_goals(
    app_private.attach_good_morning_seller_closed_days(
      p_session_token,
      p_store_id,
      app_private.rpc_set_good_morning_seller_participation(
        p_session_token,
        p_store_id,
        p_professional_id,
        p_enabled
      )
    )
  ) || pg_catalog.jsonb_build_object(
    'participation_update_available', true,
    'can_manage_settings', true
  );
$$;

revoke all on function app_private.normalize_good_morning_seller_closed_days(jsonb, date)
  from public, anon, authenticated;

revoke all on function app_private.attach_good_morning_seller_closed_days(text, uuid, jsonb)
  from public, anon, authenticated;
grant execute on function app_private.attach_good_morning_seller_closed_days(text, uuid, jsonb)
  to anon, authenticated;

revoke all on function app_private.rpc_save_good_morning_seller_settings_with_closed_days(
  text, uuid, numeric, text, jsonb, jsonb
) from public, anon, authenticated;
grant execute on function app_private.rpc_save_good_morning_seller_settings_with_closed_days(
  text, uuid, numeric, text, jsonb, jsonb
) to anon, authenticated;

revoke all on function app_private.rebalance_good_morning_daily_goals(jsonb)
  from public, anon, authenticated;
grant execute on function app_private.rebalance_good_morning_daily_goals(jsonb)
  to anon, authenticated;

revoke all on function public.lc_get_good_morning_seller_workspace(text, uuid)
  from public;
grant execute on function public.lc_get_good_morning_seller_workspace(text, uuid)
  to anon, authenticated;

revoke all on function public.lc_save_good_morning_seller_settings(
  text, uuid, numeric, text, jsonb
) from public;
grant execute on function public.lc_save_good_morning_seller_settings(
  text, uuid, numeric, text, jsonb
) to anon, authenticated;

revoke all on function public.lc_save_good_morning_seller_settings_v2(
  text, uuid, numeric, text, jsonb, jsonb
) from public;
grant execute on function public.lc_save_good_morning_seller_settings_v2(
  text, uuid, numeric, text, jsonb, jsonb
) to anon, authenticated;

revoke all on function public.lc_advance_good_morning_seller_turn(text, uuid)
  from public;
grant execute on function public.lc_advance_good_morning_seller_turn(text, uuid)
  to anon, authenticated;

revoke all on function public.lc_set_good_morning_seller_participation(
  text, uuid, uuid, boolean
) from public;
grant execute on function public.lc_set_good_morning_seller_participation(
  text, uuid, uuid, boolean
) to anon, authenticated;

do $qa$
declare
  v_workspace jsonb;
  v_normalized jsonb;
  v_rejected boolean := false;
  v_sum_week numeric;
  v_sum_today numeric;
begin
  v_normalized := app_private.normalize_good_morning_seller_closed_days(
    pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object('date', '2026-09-05', 'reason', ''),
      pg_catalog.jsonb_build_object('date', '2026-09-02', 'reason', ' Feriado municipal ')
    ),
    '2026-09-01'::date
  );

  if v_normalized <> '[
    {"date":"2026-09-02","reason":"Feriado municipal"},
    {"date":"2026-09-05","reason":"Sem expediente"}
  ]'::jsonb then
    raise exception 'QA calendario: normalizacao, motivo padrao ou ordenacao incorreta.';
  end if;

  begin
    perform app_private.normalize_good_morning_seller_closed_days(
      '[{"date":"2026-09-06","reason":"Domingo"}]'::jsonb,
      '2026-09-01'::date
    );
  exception
    when invalid_parameter_value then
      v_rejected := true;
  end;
  if not v_rejected then
    raise exception 'QA calendario: domingo deveria ser rejeitado.';
  end if;

  v_rejected := false;
  begin
    perform app_private.normalize_good_morning_seller_closed_days(
      '[
        {"date":"2026-09-02","reason":"A"},
        {"date":"2026-09-02","reason":"B"}
      ]'::jsonb,
      '2026-09-01'::date
    );
  exception
    when invalid_parameter_value then
      v_rejected := true;
  end;
  if not v_rejected then
    raise exception 'QA calendario: datas repetidas deveriam ser rejeitadas.';
  end if;

  -- Setembro/2026 possui 26 segundas-sabados. Fechando 02, 05 e 29,
  -- restam 23 dias; na primeira semana ficam apenas 01, 03 e 04.
  v_workspace := app_private.rebalance_good_morning_daily_goals(
    pg_catalog.jsonb_build_object(
      'today', '2026-09-01',
      'week_start', '2026-09-01',
      'week_end', '2026-09-06',
      'closed_days', '[
        {"date":"2026-09-02","reason":"Feriado"},
        {"date":"2026-09-05","reason":"Sem expediente"},
        {"date":"2026-09-29","reason":"Inventário"}
      ]'::jsonb,
      'goals', pg_catalog.jsonb_build_object(
        'today', pg_catalog.jsonb_build_object('actual', 0),
        'week', pg_catalog.jsonb_build_object('actual', 0),
        'month', pg_catalog.jsonb_build_object('target', 23000, 'actual', 0)
      ),
      'professionals', pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object(
          'id', 'seller-a',
          'good_morning_seller_enabled', true,
          'goal_month', 23000,
          'actual_month', 0,
          'actual_week', 0,
          'actual_today', 0
        )
      )
    )
  );

  if (v_workspace->>'workdays_in_month')::integer <> 23
     or (v_workspace->>'workdays_in_week')::integer <> 3
     or (v_workspace->>'remaining_workdays_in_month')::integer <> 23
     or (v_workspace #>> '{goals,week,target}')::numeric <> 3000
     or (v_workspace #>> '{goals,today,target}')::numeric <> 1000
     or not (v_workspace->>'today_is_working_day')::boolean then
    raise exception 'QA calendario: 23 dias, primeira semana ou alvo inicial incorretos.';
  end if;

  -- Um dia fechado nunca recebe alvo diario.
  v_workspace := app_private.rebalance_good_morning_daily_goals(
    pg_catalog.jsonb_build_object(
      'today', '2026-09-02',
      'week_start', '2026-09-01',
      'week_end', '2026-09-06',
      'closed_days', '[
        {"date":"2026-09-02","reason":"Feriado"},
        {"date":"2026-09-05","reason":"Sem expediente"},
        {"date":"2026-09-29","reason":"Inventário"}
      ]'::jsonb,
      'goals', pg_catalog.jsonb_build_object(
        'today', pg_catalog.jsonb_build_object('actual', 300),
        'week', pg_catalog.jsonb_build_object('actual', 1800),
        'month', pg_catalog.jsonb_build_object('target', 23000, 'actual', 1800)
      ),
      'professionals', pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object(
          'id', 'seller-a',
          'good_morning_seller_enabled', true,
          'goal_month', 23000,
          'actual_month', 1800,
          'actual_week', 1800,
          'actual_today', 300
        )
      )
    )
  );

  if not (v_workspace->>'today_is_closed')::boolean
     or (v_workspace->>'today_is_working_day')::boolean
     or (v_workspace #>> '{goals,today,target}')::numeric <> 0
     or (v_workspace #>> '{professionals,0,goal_today}')::numeric <> 0 then
    raise exception 'QA calendario: dia fechado deveria zerar alvo geral e individual.';
  end if;

  -- A venda de 300 feita no dia fechado continua no realizado semanal. No
  -- proximo aberto: (3.000 - 1.800) / 2 = 600.
  v_workspace := app_private.rebalance_good_morning_daily_goals(
    pg_catalog.jsonb_build_object(
      'today', '2026-09-03',
      'week_start', '2026-09-01',
      'week_end', '2026-09-06',
      'closed_days', '[
        {"date":"2026-09-02","reason":"Feriado"},
        {"date":"2026-09-05","reason":"Sem expediente"},
        {"date":"2026-09-29","reason":"Inventário"}
      ]'::jsonb,
      'goals', pg_catalog.jsonb_build_object(
        'today', pg_catalog.jsonb_build_object('actual', 0),
        'week', pg_catalog.jsonb_build_object('actual', 1800),
        'month', pg_catalog.jsonb_build_object('target', 23000, 'actual', 1800)
      ),
      'professionals', pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object(
          'id', 'seller-a',
          'good_morning_seller_enabled', true,
          'goal_month', 23000,
          'actual_month', 1800,
          'actual_week', 1800,
          'actual_today', 0
        )
      )
    )
  );

  if (v_workspace #>> '{goals,week,target}')::numeric <> 3000
     or (v_workspace #>> '{goals,today,target}')::numeric <> 600
     or (v_workspace->>'remaining_workdays_in_week')::integer <> 2 then
    raise exception 'QA calendario: venda em dia fechado ou saldo diario foram descartados.';
  end if;

  -- Na segunda semana restam 20 dias abertos a partir da segunda-feira.
  -- (23.000 - 2.400) * 6 / 20 = 6.180.
  v_workspace := app_private.rebalance_good_morning_daily_goals(
    pg_catalog.jsonb_build_object(
      'today', '2026-09-07',
      'week_start', '2026-09-07',
      'week_end', '2026-09-13',
      'closed_days', '[
        {"date":"2026-09-02","reason":"Feriado"},
        {"date":"2026-09-05","reason":"Sem expediente"},
        {"date":"2026-09-29","reason":"Inventário"}
      ]'::jsonb,
      'goals', pg_catalog.jsonb_build_object(
        'today', pg_catalog.jsonb_build_object('actual', 0),
        'week', pg_catalog.jsonb_build_object('actual', 0),
        'month', pg_catalog.jsonb_build_object('target', 23000, 'actual', 2400)
      ),
      'professionals', pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object(
          'id', 'seller-a',
          'good_morning_seller_enabled', true,
          'goal_month', 23000,
          'actual_month', 2400,
          'actual_week', 0,
          'actual_today', 0
        )
      )
    )
  );

  if (v_workspace #>> '{goals,week,target}')::numeric <> 6180
     or (v_workspace->>'workdays_in_month_from_week_start')::integer <> 20 then
    raise exception 'QA calendario: saldo da semana seguinte ficou incorreto.';
  end if;

  -- Dia 30 e o ultimo aberto porque 29 esta fechado; todo o saldo semanal
  -- restante deve cair nele.
  v_workspace := app_private.rebalance_good_morning_daily_goals(
    pg_catalog.jsonb_build_object(
      'today', '2026-09-30',
      'week_start', '2026-09-28',
      'week_end', '2026-09-30',
      'closed_days', '[{"date":"2026-09-29","reason":"Inventário"}]'::jsonb,
      'goals', pg_catalog.jsonb_build_object(
        'today', pg_catalog.jsonb_build_object('actual', 0),
        'week', pg_catalog.jsonb_build_object('actual', 500),
        'month', pg_catalog.jsonb_build_object('target', 1000, 'actual', 500)
      ),
      'professionals', pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object(
          'id', 'seller-a',
          'good_morning_seller_enabled', true,
          'goal_month', 1000,
          'actual_month', 500,
          'actual_week', 500,
          'actual_today', 0
        )
      )
    )
  );

  if (v_workspace #>> '{goals,week,target}')::numeric <> 1000
     or (v_workspace #>> '{goals,today,target}')::numeric <> 500
     or (v_workspace->>'remaining_workdays_in_week')::integer <> 1 then
    raise exception 'QA calendario: ultimo dia aberto nao absorveu o saldo restante.';
  end if;

  -- O maior resto continua fechando os centavos exatamente e participante
  -- pausado permanece zerado, mesmo com calendario personalizado.
  v_workspace := app_private.rebalance_good_morning_daily_goals(
    pg_catalog.jsonb_build_object(
      'today', '2026-09-30',
      'week_start', '2026-09-28',
      'week_end', '2026-09-30',
      'closed_days', '[{"date":"2026-09-29","reason":"Inventário"}]'::jsonb,
      'goals', pg_catalog.jsonb_build_object(
        'today', pg_catalog.jsonb_build_object('actual', 0),
        'week', pg_catalog.jsonb_build_object('actual', 0),
        'month', pg_catalog.jsonb_build_object('target', 1, 'actual', 0)
      ),
      'professionals', pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object('id', 'a', 'good_morning_seller_enabled', true, 'goal_month', 0.34, 'actual_month', 0, 'actual_week', 0, 'actual_today', 0),
        pg_catalog.jsonb_build_object('id', 'b', 'good_morning_seller_enabled', true, 'goal_month', 0.33, 'actual_month', 0, 'actual_week', 0, 'actual_today', 0),
        pg_catalog.jsonb_build_object('id', 'c', 'good_morning_seller_enabled', true, 'goal_month', 0.33, 'actual_month', 0, 'actual_week', 0, 'actual_today', 0),
        pg_catalog.jsonb_build_object('id', 'paused', 'good_morning_seller_enabled', false, 'goal_month', 0, 'actual_month', 0, 'actual_week', 0, 'actual_today', 0)
      )
    )
  );

  select
    coalesce(pg_catalog.sum((entries.value->>'goal_week')::numeric), 0),
    coalesce(pg_catalog.sum((entries.value->>'goal_today')::numeric), 0)
  into v_sum_week, v_sum_today
  from pg_catalog.jsonb_array_elements(v_workspace->'professionals') as entries(value)
  where coalesce(
    nullif(entries.value->>'good_morning_seller_enabled', '')::boolean,
    true
  );

  if v_sum_week <> (v_workspace #>> '{goals,week,target}')::numeric
     or v_sum_today <> (v_workspace #>> '{goals,today,target}')::numeric
     or (v_workspace #>> '{professionals,3,goal_week}')::numeric <> 0
     or (v_workspace #>> '{professionals,3,goal_today}')::numeric <> 0 then
    raise exception 'QA calendario: centavos individuais divergiram do total ou pausado recebeu meta.';
  end if;

  -- Sem o novo campo, o comportamento anterior permanece: segundas-sabados.
  v_workspace := app_private.rebalance_good_morning_daily_goals(
    pg_catalog.jsonb_build_object(
      'today', '2026-09-01',
      'week_start', '2026-09-01',
      'week_end', '2026-09-06',
      'goals', pg_catalog.jsonb_build_object(
        'today', pg_catalog.jsonb_build_object('actual', 0),
        'week', pg_catalog.jsonb_build_object('actual', 0),
        'month', pg_catalog.jsonb_build_object('target', 26000, 'actual', 0)
      ),
      'professionals', pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object('id', 'a', 'good_morning_seller_enabled', true, 'goal_month', 26000, 'actual_month', 0, 'actual_week', 0, 'actual_today', 0)
      )
    )
  );

  if (v_workspace->>'workdays_in_month')::integer <> 26
     or (v_workspace->>'workdays_in_week')::integer <> 5
     or (v_workspace #>> '{goals,week,target}')::numeric <> 5000
     or (v_workspace #>> '{goals,today,target}')::numeric <> 1000 then
    raise exception 'QA calendario: compatibilidade sem dias fechados foi quebrada.';
  end if;

  -- Mantem as garantias matematicas anteriores: excesso reduz o proximo dia.
  v_workspace := app_private.rebalance_good_morning_daily_goals(
    pg_catalog.jsonb_build_object(
      'today', '2026-09-02',
      'week_start', '2026-09-01',
      'week_end', '2026-09-06',
      'goals', pg_catalog.jsonb_build_object(
        'today', pg_catalog.jsonb_build_object('actual', 0),
        'week', pg_catalog.jsonb_build_object('actual', 1500),
        'month', pg_catalog.jsonb_build_object('target', 26000, 'actual', 1500)
      ),
      'professionals', pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object('id', 'a', 'good_morning_seller_enabled', true, 'goal_month', 26000, 'actual_month', 1500, 'actual_week', 1500, 'actual_today', 0)
      )
    )
  );
  if (v_workspace #>> '{goals,week,target}')::numeric <> 5000
     or (v_workspace #>> '{goals,today,target}')::numeric <> 875 then
    raise exception 'QA calendario: excesso anterior deixou de reduzir a meta diaria.';
  end if;

  -- Vendas de hoje entram no realizado, mas o alvo nao muda durante o dia.
  v_workspace := app_private.rebalance_good_morning_daily_goals(
    pg_catalog.jsonb_build_object(
      'today', '2026-09-01',
      'week_start', '2026-09-01',
      'week_end', '2026-09-06',
      'goals', pg_catalog.jsonb_build_object(
        'today', pg_catalog.jsonb_build_object('actual', 1500),
        'week', pg_catalog.jsonb_build_object('actual', 1500),
        'month', pg_catalog.jsonb_build_object('target', 26000, 'actual', 1500)
      ),
      'professionals', pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object('id', 'a', 'good_morning_seller_enabled', true, 'goal_month', 26000, 'actual_month', 1500, 'actual_week', 1500, 'actual_today', 1500)
      )
    )
  );
  if (v_workspace #>> '{goals,week,target}')::numeric <> 5000
     or (v_workspace #>> '{goals,today,target}')::numeric <> 1000 then
    raise exception 'QA calendario: venda de hoje alterou o alvo durante o expediente.';
  end if;

  -- Sabado segue sendo dia util quando a loja nao o marcou como fechado.
  v_workspace := app_private.rebalance_good_morning_daily_goals(
    pg_catalog.jsonb_build_object(
      'today', '2026-09-05',
      'week_start', '2026-09-01',
      'week_end', '2026-09-06',
      'goals', pg_catalog.jsonb_build_object(
        'today', pg_catalog.jsonb_build_object('actual', 0),
        'week', pg_catalog.jsonb_build_object('actual', 4000),
        'month', pg_catalog.jsonb_build_object('target', 26000, 'actual', 4000)
      ),
      'professionals', pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object('id', 'a', 'good_morning_seller_enabled', true, 'goal_month', 26000, 'actual_month', 4000, 'actual_week', 4000, 'actual_today', 0)
      )
    )
  );
  if not (v_workspace->>'today_is_working_day')::boolean
     or (v_workspace->>'today_is_closed')::boolean
     or (v_workspace #>> '{goals,today,target}')::numeric <> 1000
     or (v_workspace->>'remaining_workdays_in_week')::integer <> 1 then
    raise exception 'QA calendario: sabado aberto deveria absorver o saldo semanal.';
  end if;

  -- Domingo nao e um fechamento cadastrado, mas continua fora dos divisores.
  v_workspace := app_private.rebalance_good_morning_daily_goals(
    pg_catalog.jsonb_build_object(
      'today', '2026-09-06',
      'week_start', '2026-09-01',
      'week_end', '2026-09-06',
      'goals', pg_catalog.jsonb_build_object(
        'today', pg_catalog.jsonb_build_object('actual', 0),
        'week', pg_catalog.jsonb_build_object('actual', 4500),
        'month', pg_catalog.jsonb_build_object('target', 26000, 'actual', 4500)
      ),
      'professionals', pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object('id', 'a', 'good_morning_seller_enabled', true, 'goal_month', 26000, 'actual_month', 4500, 'actual_week', 4500, 'actual_today', 0)
      )
    )
  );
  if (v_workspace->>'today_is_working_day')::boolean
     or (v_workspace->>'today_is_closed')::boolean
     or (v_workspace #>> '{goals,today,target}')::numeric <> 0 then
    raise exception 'QA calendario: domingo deveria zerar apenas o alvo diario.';
  end if;

  -- Se a loja fechar todos os dias restantes, evita divisao por zero e deixa
  -- o saldo explicito para a interface, em vez de o perder silenciosamente.
  v_workspace := app_private.rebalance_good_morning_daily_goals(
    pg_catalog.jsonb_build_object(
      'today', '2026-09-28',
      'week_start', '2026-09-28',
      'week_end', '2026-09-30',
      'closed_days', '[
        {"date":"2026-09-28","reason":"Fechado"},
        {"date":"2026-09-29","reason":"Fechado"},
        {"date":"2026-09-30","reason":"Fechado"}
      ]'::jsonb,
      'goals', pg_catalog.jsonb_build_object(
        'today', pg_catalog.jsonb_build_object('actual', 0),
        'week', pg_catalog.jsonb_build_object('actual', 0),
        'month', pg_catalog.jsonb_build_object('target', 1000, 'actual', 0)
      ),
      'professionals', pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object('id', 'a', 'good_morning_seller_enabled', true, 'goal_month', 1000, 'actual_month', 0, 'actual_week', 0, 'actual_today', 0)
      )
    )
  );
  if (v_workspace->>'remaining_workdays_in_month')::integer <> 0
     or (v_workspace #>> '{goals,week,target}')::numeric <> 0
     or (v_workspace #>> '{goals,today,target}')::numeric <> 0
     or not (v_workspace->>'has_unallocated_month_balance')::boolean
     or (v_workspace->>'unallocated_month_balance')::numeric <> 1000 then
    raise exception 'QA calendario: saldo sem dias restantes nao ficou seguro e explicito.';
  end if;

  -- Configuracao pendente continua zerando os alvos.
  v_workspace := app_private.rebalance_good_morning_daily_goals(
    pg_catalog.jsonb_build_object(
      'configured', false,
      'today', '2026-09-01',
      'week_start', '2026-09-01',
      'week_end', '2026-09-06',
      'closed_days', '[{"date":"2026-09-02","reason":"Feriado"}]'::jsonb,
      'goals', pg_catalog.jsonb_build_object(
        'today', pg_catalog.jsonb_build_object('actual', 0),
        'week', pg_catalog.jsonb_build_object('actual', 0),
        'month', pg_catalog.jsonb_build_object('target', 1000, 'actual', 0)
      ),
      'professionals', pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object('id', 'a', 'good_morning_seller_enabled', true, 'goal_month', 1000, 'actual_month', 0, 'actual_week', 0, 'actual_today', 0)
      )
    )
  );

  if (v_workspace #>> '{goals,week,target}')::numeric <> 0
     or (v_workspace #>> '{goals,today,target}')::numeric <> 0 then
    raise exception 'QA calendario: configuracao pendente deveria zerar os alvos.';
  end if;

  -- Isolamento: nenhuma role de navegador acessa a tabela diretamente; a
  -- escrita existe apenas na RPC autenticada/gated. Sem policies permissivas,
  -- Agencia nao ganha um caminho alternativo de escrita.
  if not (
    select classes.relrowsecurity
    from pg_catalog.pg_class classes
    join pg_catalog.pg_namespace namespaces
      on namespaces.oid = classes.relnamespace
    where namespaces.nspname = 'public'
      and classes.relname = 'good_morning_seller_closed_days'
  ) then
    raise exception 'QA calendario: RLS deveria estar habilitado.';
  end if;

  if pg_catalog.has_table_privilege(
       'anon', 'public.good_morning_seller_closed_days', 'SELECT'
     )
     or pg_catalog.has_table_privilege(
       'anon', 'public.good_morning_seller_closed_days', 'INSERT'
     )
     or pg_catalog.has_table_privilege(
       'authenticated', 'public.good_morning_seller_closed_days', 'SELECT'
     )
     or pg_catalog.has_table_privilege(
       'authenticated', 'public.good_morning_seller_closed_days', 'UPDATE'
     ) then
    raise exception 'QA calendario: tabela privada possui privilegio direto de navegador.';
  end if;

  if exists (
    select 1
    from pg_catalog.pg_policies policies
    where policies.schemaname = 'public'
      and policies.tablename = 'good_morning_seller_closed_days'
  ) then
    raise exception 'QA calendario: tabela privada nao deveria expor policies ao navegador.';
  end if;

  if not pg_catalog.has_function_privilege(
       'anon',
       'public.lc_save_good_morning_seller_settings_v2(text, uuid, numeric, text, jsonb, jsonb)',
       'EXECUTE'
     )
     or not pg_catalog.has_function_privilege(
       'authenticated',
       'public.lc_save_good_morning_seller_settings_v2(text, uuid, numeric, text, jsonb, jsonb)',
       'EXECUTE'
     )
     or pg_catalog.has_function_privilege(
       'anon',
       'app_private.normalize_good_morning_seller_closed_days(jsonb, date)',
       'EXECUTE'
     ) then
    raise exception 'QA calendario: privilegios das funcoes estao incorretos.';
  end if;
end;
$qa$;

comment on table public.good_morning_seller_closed_days is
  'Feriados e dias sem expediente do Bom Dia Vendedor, isolados por loja e mes. Alterar o calendario replaneja imediatamente a semana corrente.';
comment on column public.good_morning_seller_closed_days.closed_on is
  'Data local da loja (America/Sao_Paulo) retirada apenas dos divisores de meta.';
comment on function app_private.normalize_good_morning_seller_closed_days(jsonb, date) is
  'Valida, normaliza e ordena ate 31 dias fechados de segunda a sabado no mes informado.';
comment on function app_private.attach_good_morning_seller_closed_days(text, uuid, jsonb) is
  'Anexa ao workspace os dias fechados do mes, depois de validar sessao e acesso ao cliente.';
comment on function public.lc_save_good_morning_seller_settings_v2(
  text, uuid, numeric, text, jsonb, jsonb
) is
  'Salva meta, rotacao, participacao e dias sem expediente atomicamente; Admin e propria loja podem editar, Agencia nao.';
comment on function app_private.rebalance_good_morning_daily_goals(jsonb) is
  'Calcula metas mensal, semanal e diaria em centavos usando segunda-sabado menos os dias sem expediente da loja.';

notify pgrst, 'reload schema';

commit;
