-- A meta diaria do Bom Dia Vendedor passa a acompanhar o saldo real de cada
-- participante. O alvo do dia usa somente compras anteriores a hoje, portanto
-- permanece estavel durante o expediente e e recalculado na manha seguinte.

begin;

set local lock_timeout = '10s';
set local statement_timeout = '5min';

create or replace function app_private.good_morning_seller_remaining_daily_goal_cents(
  p_goal_cents bigint,
  p_actual_before_today_cents bigint,
  p_remaining_workdays integer
)
returns bigint
language sql
immutable
security invoker
set search_path = ''
as $$
  select case
    when coalesce(p_remaining_workdays, 0) <= 0 then 0::bigint
    when coalesce(p_goal_cents, 0) <= coalesce(p_actual_before_today_cents, 0) then 0::bigint
    else round(
      (
        greatest(
          coalesce(p_goal_cents, 0) - coalesce(p_actual_before_today_cents, 0),
          0
        )
      )::numeric / p_remaining_workdays::numeric
    )::bigint
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
  v_month_end date;
  v_today_is_working_day boolean := false;
  v_remaining_workdays integer := 0;
  v_professionals jsonb := '[]'::jsonb;
  v_day_goal_cents bigint := 0;
  v_goals jsonb := '{}'::jsonb;
  v_today_goal jsonb := '{}'::jsonb;
begin
  if jsonb_typeof(v_workspace) is distinct from 'object'
     or nullif(v_workspace->>'today', '') is null then
    return v_workspace;
  end if;

  v_today := (v_workspace->>'today')::date;
  v_month_end := (date_trunc('month', v_today)::date + interval '1 month - 1 day')::date;
  v_today_is_working_day := extract(isodow from v_today)::integer between 1 and 6;

  select count(*)::integer
  into v_remaining_workdays
  from generate_series(v_today, v_month_end, interval '1 day') as calendar(day_value)
  where extract(isodow from calendar.day_value)::integer between 1 and 6;

  with rebalanced as (
    select
      entries.ordinality,
      entries.professional,
      case
        when v_today_is_working_day then
          app_private.good_morning_seller_remaining_daily_goal_cents(
            round(
              coalesce(
                nullif(entries.professional->>'goal_month', '')::numeric,
                nullif(entries.professional->>'goal_amount', '')::numeric,
                0
              ) * 100
            )::bigint,
            greatest(
              round((
                coalesce(nullif(entries.professional->>'actual_month', '')::numeric, 0)
                - coalesce(nullif(entries.professional->>'actual_today', '')::numeric, 0)
              ) * 100)::bigint,
              0
            ),
            v_remaining_workdays
          )
        else 0::bigint
      end as goal_today_cents
    from jsonb_array_elements(
      case
        when jsonb_typeof(v_workspace->'professionals') = 'array'
          then v_workspace->'professionals'
        else '[]'::jsonb
      end
    ) with ordinality as entries(professional, ordinality)
  )
  select
    coalesce(
      jsonb_agg(
        rebalanced.professional || jsonb_build_object(
          'goal_today', rebalanced.goal_today_cents::numeric / 100
        )
        order by rebalanced.ordinality
      ),
      '[]'::jsonb
    ),
    coalesce(sum(rebalanced.goal_today_cents), 0)::bigint
  into v_professionals, v_day_goal_cents
  from rebalanced;

  v_goals := case
    when jsonb_typeof(v_workspace->'goals') = 'object'
      then v_workspace->'goals'
    else '{}'::jsonb
  end;
  v_today_goal := case
    when jsonb_typeof(v_goals->'today') = 'object'
      then v_goals->'today'
    else '{}'::jsonb
  end;
  v_today_goal := v_today_goal || jsonb_build_object(
    'target', v_day_goal_cents::numeric / 100
  );
  v_goals := v_goals || jsonb_build_object('today', v_today_goal);

  return v_workspace || jsonb_build_object(
    'professionals', v_professionals,
    'goals', v_goals,
    'today_is_working_day', v_today_is_working_day,
    'remaining_workdays_in_month', v_remaining_workdays,
    'daily_goal_strategy', 'remaining_balance'
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
set search_path = ''
as $$
  select app_private.rebalance_good_morning_daily_goals(
    app_private.rpc_get_good_morning_seller_workspace(
      p_session_token,
      p_store_id
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
    app_private.rpc_save_good_morning_seller_settings_store_only(
      p_session_token,
      p_store_id,
      p_monthly_goal,
      p_allocation_mode,
      p_allocations
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
    app_private.rpc_advance_good_morning_seller_turn_store_only(
      p_session_token,
      p_store_id
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
    app_private.rpc_set_good_morning_seller_participation(
      p_session_token,
      p_store_id,
      p_professional_id,
      p_enabled
    )
  ) || pg_catalog.jsonb_build_object(
    'participation_update_available', true,
    'can_manage_settings', true
  );
$$;

revoke all on function app_private.good_morning_seller_remaining_daily_goal_cents(bigint, bigint, integer)
  from public, anon, authenticated;
revoke all on function app_private.rebalance_good_morning_daily_goals(jsonb)
  from public, anon, authenticated;
grant execute on function app_private.good_morning_seller_remaining_daily_goal_cents(bigint, bigint, integer)
  to anon, authenticated;
grant execute on function app_private.rebalance_good_morning_daily_goals(jsonb)
  to anon, authenticated;

revoke all on function public.lc_get_good_morning_seller_workspace(text, uuid)
  from public;
grant execute on function public.lc_get_good_morning_seller_workspace(text, uuid)
  to anon, authenticated;

revoke all on function public.lc_save_good_morning_seller_settings(text, uuid, numeric, text, jsonb)
  from public;
grant execute on function public.lc_save_good_morning_seller_settings(text, uuid, numeric, text, jsonb)
  to anon, authenticated;

revoke all on function public.lc_advance_good_morning_seller_turn(text, uuid)
  from public;
grant execute on function public.lc_advance_good_morning_seller_turn(text, uuid)
  to anon, authenticated;

revoke all on function public.lc_set_good_morning_seller_participation(text, uuid, uuid, boolean)
  from public;
grant execute on function public.lc_set_good_morning_seller_participation(text, uuid, uuid, boolean)
  to anon, authenticated;

do $qa$
declare
  v_workspace jsonb;
begin
  if app_private.good_morning_seller_remaining_daily_goal_cents(2600000, 150000, 25) <> 98000 then
    raise exception 'QA meta diaria: excesso anterior deveria reduzir o alvo para 980,00.';
  end if;
  if app_private.good_morning_seller_remaining_daily_goal_cents(2600000, 50000, 25) <> 102000 then
    raise exception 'QA meta diaria: deficit anterior deveria elevar o alvo para 1020,00.';
  end if;
  if app_private.good_morning_seller_remaining_daily_goal_cents(10000, 0, 3) <> 3333
     or app_private.good_morning_seller_remaining_daily_goal_cents(10000, 3333, 2) <> 3334 then
    raise exception 'QA meta diaria: o arredondamento em centavos nao foi compensado no dia seguinte.';
  end if;
  if app_private.good_morning_seller_remaining_daily_goal_cents(2600000, 2532145, 1) <> 67855
     or app_private.good_morning_seller_remaining_daily_goal_cents(2600000, 2650000, 1) <> 0 then
    raise exception 'QA meta diaria: o ultimo dia nao absorveu o saldo exato.';
  end if;

  v_workspace := app_private.rebalance_good_morning_daily_goals(
    jsonb_build_object(
      'today', '2026-09-02',
      'today_is_working_day', true,
      'goals', jsonb_build_object(
        'today', jsonb_build_object('target', 0, 'actual', 0),
        'week', jsonb_build_object('target', 0, 'actual', 0),
        'month', jsonb_build_object('target', 26000, 'actual', 1500)
      ),
      'professionals', jsonb_build_array(
        jsonb_build_object(
          'id', 'seller-1',
          'goal_month', 26000,
          'goal_amount', 26000,
          'actual_month', 1500,
          'actual_today', 0
        ),
        jsonb_build_object(
          'id', 'paused',
          'goal_month', 0,
          'goal_amount', 0,
          'actual_month', 900,
          'actual_today', 0
        )
      )
    )
  );

  if (v_workspace->>'remaining_workdays_in_month')::integer <> 25
     or (v_workspace #>> '{professionals,0,goal_today}')::numeric <> 980
     or (v_workspace #>> '{professionals,1,goal_today}')::numeric <> 0
     or (v_workspace #>> '{goals,today,target}')::numeric <> 980 then
    raise exception 'QA meta diaria: workspace nao recalculou metas individual e geral pelo saldo.';
  end if;

  v_workspace := app_private.rebalance_good_morning_daily_goals(
    jsonb_build_object(
      'today', '2026-09-06',
      'goals', jsonb_build_object('today', jsonb_build_object('target', 1000, 'actual', 0)),
      'professionals', jsonb_build_array(
        jsonb_build_object(
          'goal_month', 26000,
          'actual_month', 6000,
          'actual_today', 0
        )
      )
    )
  );

  if (v_workspace #>> '{goals,today,target}')::numeric <> 0
     or (v_workspace #>> '{professionals,0,goal_today}')::numeric <> 0 then
    raise exception 'QA meta diaria: domingo deve permanecer com alvo zero.';
  end if;
end;
$qa$;

comment on function app_private.good_morning_seller_remaining_daily_goal_cents(bigint, bigint, integer) is
  'Divide em centavos o saldo da meta individual pelos dias de segunda a sabado restantes.';
comment on function app_private.rebalance_good_morning_daily_goals(jsonb) is
  'Recalcula a meta diaria individual e geral usando compras anteriores ao dia atual; o alvo nao muda durante o expediente.';
comment on function public.lc_get_good_morning_seller_workspace(text, uuid) is
  'Retorna o Bom Dia Vendedor com meta diaria recalculada pelo saldo mensal e dias de segunda a sabado restantes.';

notify pgrst, 'reload schema';

commit;
