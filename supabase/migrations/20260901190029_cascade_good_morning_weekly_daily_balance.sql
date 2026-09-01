-- A meta semanal abre com uma fatia proporcional do saldo mensal e vendas da
-- propria semana nao a deslocam. Correcoes retroativas anteriores a semana
-- atualizam a base para manter o saldo mensal verdadeiro. A meta diaria usa o
-- saldo da semana ate ontem, levando falta ou excesso aos dias seguintes.

begin;

set local lock_timeout = '10s';
set local statement_timeout = '5min';

create or replace function app_private.good_morning_seller_apportion_cents(
  p_total_cents bigint,
  p_weights bigint[]
)
returns bigint[]
language sql
immutable
security invoker
set search_path = ''
as $$
  with source as (
    select
      weights.ordinality::integer as item_index,
      greatest(coalesce(weights.weight_value, 0), 0)::numeric as allocation_weight,
      greatest(coalesce(p_total_cents, 0), 0)::numeric as total_cents
    from unnest(coalesce(p_weights, array[]::bigint[]))
      with ordinality as weights(weight_value, ordinality)
  ), prepared as (
    select
      source.*,
      coalesce(sum(source.allocation_weight) over (), 0)::numeric as total_weight
    from source
  ), quotas as (
    select
      prepared.*,
      case
        when prepared.total_weight > 0 then floor(
          prepared.total_cents * prepared.allocation_weight / prepared.total_weight
        )::bigint
        else 0::bigint
      end as base_cents,
      case
        when prepared.total_weight > 0 then
          (
            prepared.total_cents * prepared.allocation_weight / prepared.total_weight
          ) - floor(
            prepared.total_cents * prepared.allocation_weight / prepared.total_weight
          )
        else 0::numeric
      end as fractional_remainder
    from prepared
  ), ranked as (
    select
      quotas.*,
      row_number() over (
        order by
          case when quotas.allocation_weight > 0 then quotas.fractional_remainder else -1::numeric end desc,
          quotas.item_index
      )::bigint as remainder_rank,
      coalesce(sum(quotas.base_cents) over (), 0)::bigint as distributed_base_cents
    from quotas
  )
  select coalesce(
    array_agg(
      ranked.base_cents + case
        when ranked.allocation_weight > 0
         and ranked.remainder_rank <= ranked.total_cents::bigint - ranked.distributed_base_cents
          then 1::bigint
        else 0::bigint
      end
      order by ranked.item_index
    ),
    array[]::bigint[]
  )
  from ranked;
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
  v_configured boolean := false;
  v_today_is_working_day boolean := false;
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
  if jsonb_typeof(v_workspace) is distinct from 'object'
     or nullif(v_workspace->>'today', '') is null then
    return v_workspace;
  end if;

  v_today := (v_workspace->>'today')::date;
  v_configured := coalesce(nullif(v_workspace->>'configured', '')::boolean, true);
  v_month_start := date_trunc('month', v_today)::date;
  v_month_end := (v_month_start + interval '1 month - 1 day')::date;
  v_week_start := coalesce(
    nullif(v_workspace->>'week_start', '')::date,
    greatest(v_month_start, v_today - (extract(isodow from v_today)::integer - 1))
  );
  v_week_end := coalesce(
    nullif(v_workspace->>'week_end', '')::date,
    least(v_month_end, v_week_start + 6)
  );
  v_week_start := greatest(v_month_start, v_week_start);
  v_week_end := least(v_month_end, v_week_end);
  v_today_is_working_day := extract(isodow from v_today)::integer between 1 and 6;

  select
    count(*) filter (
      where calendar.day_value between v_week_start and v_week_end
    )::integer,
    count(*) filter (
      where calendar.day_value between v_week_start and v_month_end
    )::integer,
    count(*) filter (
      where calendar.day_value between v_today and v_week_end
    )::integer,
    count(*) filter (
      where calendar.day_value between v_today and v_month_end
    )::integer
  into
    v_workdays_in_week,
    v_workdays_from_week_start,
    v_remaining_workdays_in_week,
    v_remaining_workdays_in_month
  from (
    select generated.day_value::date
    from generate_series(v_month_start, v_month_end, interval '1 day') as generated(day_value)
    where extract(isodow from generated.day_value)::integer between 1 and 6
  ) as calendar;

  v_team_month_goal_cents := round(
    coalesce(
      nullif(v_workspace #>> '{goals,month,target}', '')::numeric,
      nullif(v_workspace->>'monthly_goal', '')::numeric,
      0
    ) * 100
  )::bigint;
  v_team_month_actual_cents := greatest(
    round(coalesce(nullif(v_workspace #>> '{goals,month,actual}', '')::numeric, 0) * 100)::bigint,
    0
  );
  v_team_week_actual_cents := greatest(
    round(coalesce(nullif(v_workspace #>> '{goals,week,actual}', '')::numeric, 0) * 100)::bigint,
    0
  );
  v_team_today_actual_cents := greatest(
    round(coalesce(nullif(v_workspace #>> '{goals,today,actual}', '')::numeric, 0) * 100)::bigint,
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

  select
    coalesce(array_agg(source.enabled order by source.ordinality), array[]::boolean[]),
    coalesce(array_agg(source.month_goal_cents order by source.ordinality), array[]::bigint[]),
    coalesce(array_agg(source.month_actual_before_week_cents order by source.ordinality), array[]::bigint[]),
    coalesce(array_agg(source.week_actual_before_today_cents order by source.ordinality), array[]::bigint[])
  into
    v_enabled,
    v_month_goal_cents,
    v_month_actual_before_week_cents,
    v_week_actual_before_today_cents
  from (
    select
      entries.ordinality,
      coalesce(
        nullif(entries.professional->>'good_morning_seller_enabled', '')::boolean,
        true
      ) as enabled,
      round(
        coalesce(
          nullif(entries.professional->>'goal_month', '')::numeric,
          nullif(entries.professional->>'goal_amount', '')::numeric,
          0
        ) * 100
      )::bigint as month_goal_cents,
      greatest(
        round((
          coalesce(nullif(entries.professional->>'actual_month', '')::numeric, 0)
          - coalesce(nullif(entries.professional->>'actual_week', '')::numeric, 0)
        ) * 100)::bigint,
        0
      ) as month_actual_before_week_cents,
      greatest(
        round((
          coalesce(nullif(entries.professional->>'actual_week', '')::numeric, 0)
          - coalesce(nullif(entries.professional->>'actual_today', '')::numeric, 0)
        ) * 100)::bigint,
        0
      ) as week_actual_before_today_cents
    from jsonb_array_elements(
      case
        when jsonb_typeof(v_workspace->'professionals') = 'array'
          then v_workspace->'professionals'
        else '[]'::jsonb
      end
    ) with ordinality as entries(professional, ordinality)
  ) as source;

  select
    coalesce(array_agg(
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
    coalesce(sum(
      case
        when v_enabled[indexes.item_index] then greatest(
          v_month_goal_cents[indexes.item_index]
          - v_month_actual_before_week_cents[indexes.item_index],
          0
        )
        else 0::bigint
      end
    ), 0)::bigint,
    coalesce(sum(
      case when v_enabled[indexes.item_index] then v_month_goal_cents[indexes.item_index] else 0 end
    ), 0)::bigint,
    count(*) filter (where v_enabled[indexes.item_index])::integer
  into
    v_month_gap_cents,
    v_total_month_gap_cents,
    v_total_enabled_month_goal_cents,
    v_enabled_count
  from generate_subscripts(v_enabled, 1) as indexes(item_index);

  if v_configured and v_enabled_count > 0 and v_workdays_from_week_start > 0 then
    v_team_week_goal_cents := round(
      greatest(v_team_month_goal_cents - v_team_actual_before_week_cents, 0)::numeric
      * v_workdays_in_week::numeric
      / v_workdays_from_week_start::numeric
    )::bigint;
  else
    v_team_week_goal_cents := 0;
  end if;

  select coalesce(array_agg(
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
  from generate_subscripts(v_enabled, 1) as indexes(item_index);

  v_week_goal_cents := app_private.good_morning_seller_apportion_cents(
    v_team_week_goal_cents,
    v_week_weights
  );

  select
    coalesce(array_agg(
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
    coalesce(sum(
      case
        when v_enabled[indexes.item_index] then greatest(
          coalesce(v_week_goal_cents[indexes.item_index], 0)
          - v_week_actual_before_today_cents[indexes.item_index],
          0
        )
        else 0::bigint
      end
    ), 0)::bigint,
    coalesce(sum(
      case when v_enabled[indexes.item_index] then coalesce(v_week_goal_cents[indexes.item_index], 0) else 0 end
    ), 0)::bigint
  into
    v_week_gap_cents,
    v_total_week_gap_cents,
    v_total_enabled_week_goal_cents
  from generate_subscripts(v_enabled, 1) as indexes(item_index);

  if v_today_is_working_day and v_enabled_count > 0 and v_remaining_workdays_in_week > 0 then
    v_team_day_goal_cents := app_private.good_morning_seller_remaining_daily_goal_cents(
      v_team_week_goal_cents,
      v_team_week_actual_before_today_cents,
      v_remaining_workdays_in_week
    );
  else
    v_team_day_goal_cents := 0;
  end if;

  select coalesce(array_agg(
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
  from generate_subscripts(v_enabled, 1) as indexes(item_index);

  v_day_goal_cents := app_private.good_morning_seller_apportion_cents(
    v_team_day_goal_cents,
    v_day_weights
  );

  select coalesce(
    jsonb_agg(
      entries.professional || jsonb_build_object(
        'goal_week', coalesce(v_week_goal_cents[entries.ordinality::integer], 0)::numeric / 100,
        'goal_today', coalesce(v_day_goal_cents[entries.ordinality::integer], 0)::numeric / 100
      )
      order by entries.ordinality
    ),
    '[]'::jsonb
  )
  into v_professionals
  from jsonb_array_elements(
    case
      when jsonb_typeof(v_workspace->'professionals') = 'array'
        then v_workspace->'professionals'
      else '[]'::jsonb
    end
  ) with ordinality as entries(professional, ordinality);

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
  v_week_goal := case
    when jsonb_typeof(v_goals->'week') = 'object'
      then v_goals->'week'
    else '{}'::jsonb
  end;
  v_today_goal := v_today_goal || jsonb_build_object(
    'target', v_team_day_goal_cents::numeric / 100
  );
  v_week_goal := v_week_goal || jsonb_build_object(
    'target', v_team_week_goal_cents::numeric / 100
  );
  v_goals := v_goals || jsonb_build_object(
    'today', v_today_goal,
    'week', v_week_goal
  );

  return v_workspace || jsonb_build_object(
    'professionals', v_professionals,
    'goals', v_goals,
    'today_is_working_day', v_today_is_working_day,
    'workdays_in_week', v_workdays_in_week,
    'workdays_in_current_week', v_workdays_in_week,
    'remaining_workdays_in_week', v_remaining_workdays_in_week,
    'remaining_workdays_in_month', v_remaining_workdays_in_month,
    'workdays_in_month_from_week_start', v_workdays_from_week_start,
    'goal_strategy', 'hierarchical_weekly_daily_team_balance_v1',
    'weekly_goal_strategy', 'remaining_month_balance',
    'daily_goal_strategy', 'remaining_team_balance'
  );
end;
$$;

revoke all on function app_private.good_morning_seller_apportion_cents(bigint, bigint[])
  from public, anon, authenticated;
grant execute on function app_private.good_morning_seller_apportion_cents(bigint, bigint[])
  to anon, authenticated;

do $qa$
declare
  v_workspace jsonb;
begin
  if app_private.good_morning_seller_apportion_cents(100, array[100, 100, 100]::bigint[])
     <> array[34, 33, 33]::bigint[] then
    raise exception 'QA cascata de metas: maior resto nao fechou os centavos.';
  end if;

  -- Setembro/2026 comeca na terca: cinco dias nesta semana e 26 no mes.
  v_workspace := app_private.rebalance_good_morning_daily_goals(
    jsonb_build_object(
      'today', '2026-09-01',
      'week_start', '2026-09-01',
      'week_end', '2026-09-06',
      'goals', jsonb_build_object(
        'today', jsonb_build_object('actual', 0),
        'week', jsonb_build_object('actual', 0),
        'month', jsonb_build_object('target', 26000, 'actual', 0)
      ),
      'professionals', jsonb_build_array(
        jsonb_build_object(
          'id', 'seller-a',
          'good_morning_seller_enabled', true,
          'goal_month', 26000,
          'actual_month', 0,
          'actual_week', 0,
          'actual_today', 0
        )
      )
    )
  );

  if (v_workspace #>> '{goals,week,target}')::numeric <> 5000
     or (v_workspace #>> '{goals,today,target}')::numeric <> 1000
     or (v_workspace->>'remaining_workdays_in_week')::integer <> 5
     or (v_workspace->>'remaining_workdays_in_month')::integer <> 26 then
    raise exception 'QA cascata de metas: abertura da primeira semana ficou incorreta.';
  end if;

  -- Se a terca ficou 500,00 abaixo, quarta absorve a diferenca nos quatro
  -- dias restantes: (5.000 - 500) / 4 = 1.125.
  v_workspace := app_private.rebalance_good_morning_daily_goals(
    jsonb_build_object(
      'today', '2026-09-02',
      'week_start', '2026-09-01',
      'week_end', '2026-09-06',
      'goals', jsonb_build_object(
        'today', jsonb_build_object('actual', 0),
        'week', jsonb_build_object('actual', 500),
        'month', jsonb_build_object('target', 26000, 'actual', 500)
      ),
      'professionals', jsonb_build_array(
        jsonb_build_object(
          'id', 'seller-a',
          'good_morning_seller_enabled', true,
          'goal_month', 26000,
          'actual_month', 500,
          'actual_week', 500,
          'actual_today', 0
        )
      )
    )
  );

  if (v_workspace #>> '{goals,week,target}')::numeric <> 5000
     or (v_workspace #>> '{goals,today,target}')::numeric <> 1125 then
    raise exception 'QA cascata de metas: deficit diario nao aumentou o dia seguinte pela semana.';
  end if;

  -- Se a terca superou em 500,00, quarta cai para 875,00.
  v_workspace := app_private.rebalance_good_morning_daily_goals(
    jsonb_build_object(
      'today', '2026-09-02',
      'week_start', '2026-09-01',
      'week_end', '2026-09-06',
      'goals', jsonb_build_object(
        'today', jsonb_build_object('actual', 0),
        'week', jsonb_build_object('actual', 1500),
        'month', jsonb_build_object('target', 26000, 'actual', 1500)
      ),
      'professionals', jsonb_build_array(
        jsonb_build_object(
          'id', 'seller-a',
          'good_morning_seller_enabled', true,
          'goal_month', 26000,
          'actual_month', 1500,
          'actual_week', 1500,
          'actual_today', 0
        )
      )
    )
  );

  if (v_workspace #>> '{goals,week,target}')::numeric <> 5000
     or (v_workspace #>> '{goals,today,target}')::numeric <> 875 then
    raise exception 'QA cascata de metas: excesso diario nao reduziu o dia seguinte pela semana.';
  end if;

  -- Vendas de hoje mudam o realizado, mas so entram no alvo na manha seguinte.
  v_workspace := app_private.rebalance_good_morning_daily_goals(
    jsonb_build_object(
      'today', '2026-09-01',
      'week_start', '2026-09-01',
      'week_end', '2026-09-06',
      'goals', jsonb_build_object(
        'today', jsonb_build_object('actual', 1500),
        'week', jsonb_build_object('actual', 1500),
        'month', jsonb_build_object('target', 26000, 'actual', 1500)
      ),
      'professionals', jsonb_build_array(
        jsonb_build_object(
          'id', 'seller-a',
          'good_morning_seller_enabled', true,
          'goal_month', 26000,
          'actual_month', 1500,
          'actual_week', 1500,
          'actual_today', 1500
        )
      )
    )
  );

  if (v_workspace #>> '{goals,week,target}')::numeric <> 5000
     or (v_workspace #>> '{goals,today,target}')::numeric <> 1000 then
    raise exception 'QA cascata de metas: venda de hoje alterou o alvo durante o expediente.';
  end if;

  -- A semana seguinte redistribui pelo mes o resultado da semana anterior.
  -- Restam 21 dias; 21.500,00 de saldo; a semana possui seis dias.
  v_workspace := app_private.rebalance_good_morning_daily_goals(
    jsonb_build_object(
      'today', '2026-09-07',
      'week_start', '2026-09-07',
      'week_end', '2026-09-13',
      'goals', jsonb_build_object(
        'today', jsonb_build_object('actual', 0),
        'week', jsonb_build_object('actual', 0),
        'month', jsonb_build_object('target', 26000, 'actual', 4500)
      ),
      'professionals', jsonb_build_array(
        jsonb_build_object(
          'id', 'seller-a',
          'good_morning_seller_enabled', true,
          'goal_month', 26000,
          'actual_month', 4500,
          'actual_week', 0,
          'actual_today', 0
        )
      )
    )
  );

  if (v_workspace #>> '{goals,week,target}')::numeric <> 6142.86
     or (v_workspace #>> '{goals,today,target}')::numeric <> 1023.81 then
    raise exception 'QA cascata de metas: resultado semanal anterior nao repercutiu no saldo mensal.';
  end if;

  -- Ultima semana absorve todo o saldo restante; domingo continua zerado.
  v_workspace := app_private.rebalance_good_morning_daily_goals(
    jsonb_build_object(
      'today', '2026-09-28',
      'week_start', '2026-09-28',
      'week_end', '2026-09-30',
      'goals', jsonb_build_object(
        'today', jsonb_build_object('actual', 0),
        'week', jsonb_build_object('actual', 0),
        'month', jsonb_build_object('target', 26000, 'actual', 23000)
      ),
      'professionals', jsonb_build_array(
        jsonb_build_object(
          'id', 'seller-a',
          'good_morning_seller_enabled', true,
          'goal_month', 26000,
          'actual_month', 23000,
          'actual_week', 0,
          'actual_today', 0
        )
      )
    )
  );

  if (v_workspace #>> '{goals,week,target}')::numeric <> 3000
     or (v_workspace #>> '{goals,today,target}')::numeric <> 1000 then
    raise exception 'QA cascata de metas: ultima semana nao absorveu o saldo do mes.';
  end if;

  -- Sabado absorve o saldo semanal integralmente; domingo mantem a meta da
  -- semana para analise, mas nao cria uma nova meta diaria.
  v_workspace := app_private.rebalance_good_morning_daily_goals(
    jsonb_build_object(
      'today', '2026-09-05',
      'week_start', '2026-09-01',
      'week_end', '2026-09-06',
      'goals', jsonb_build_object(
        'today', jsonb_build_object('actual', 0),
        'week', jsonb_build_object('actual', 4000),
        'month', jsonb_build_object('target', 26000, 'actual', 4000)
      ),
      'professionals', jsonb_build_array(
        jsonb_build_object('id', 'a', 'good_morning_seller_enabled', true, 'goal_month', 26000, 'actual_month', 4000, 'actual_week', 4000, 'actual_today', 0)
      )
    )
  );

  if (v_workspace #>> '{goals,week,target}')::numeric <> 5000
     or (v_workspace #>> '{goals,today,target}')::numeric <> 1000
     or (v_workspace->>'remaining_workdays_in_week')::integer <> 1 then
    raise exception 'QA cascata de metas: sabado nao absorveu o saldo semanal.';
  end if;

  v_workspace := app_private.rebalance_good_morning_daily_goals(
    jsonb_build_object(
      'today', '2026-09-06',
      'week_start', '2026-09-01',
      'week_end', '2026-09-06',
      'goals', jsonb_build_object(
        'today', jsonb_build_object('actual', 0),
        'week', jsonb_build_object('actual', 4500),
        'month', jsonb_build_object('target', 26000, 'actual', 4500)
      ),
      'professionals', jsonb_build_array(
        jsonb_build_object('id', 'a', 'good_morning_seller_enabled', true, 'goal_month', 26000, 'actual_month', 4500, 'actual_week', 4500, 'actual_today', 0)
      )
    )
  );

  if (v_workspace #>> '{goals,week,target}')::numeric <> 5000
     or (v_workspace #>> '{goals,today,target}')::numeric <> 0 then
    raise exception 'QA cascata de metas: domingo normal deveria zerar apenas o alvo diario.';
  end if;

  -- A distribuicao individual fecha exatamente com os cards gerais e quem
  -- estiver pausado permanece com metas zeradas.
  v_workspace := app_private.rebalance_good_morning_daily_goals(
    jsonb_build_object(
      'today', '2026-09-30',
      'week_start', '2026-09-28',
      'week_end', '2026-09-30',
      'goals', jsonb_build_object(
        'today', jsonb_build_object('actual', 0),
        'week', jsonb_build_object('actual', 0),
        'month', jsonb_build_object('target', 1, 'actual', 0)
      ),
      'professionals', jsonb_build_array(
        jsonb_build_object('id', 'a', 'good_morning_seller_enabled', true, 'goal_month', 0.34, 'actual_month', 0, 'actual_week', 0, 'actual_today', 0),
        jsonb_build_object('id', 'b', 'good_morning_seller_enabled', true, 'goal_month', 0.33, 'actual_month', 0, 'actual_week', 0, 'actual_today', 0),
        jsonb_build_object('id', 'c', 'good_morning_seller_enabled', true, 'goal_month', 0.33, 'actual_month', 0, 'actual_week', 0, 'actual_today', 0),
        jsonb_build_object('id', 'paused', 'good_morning_seller_enabled', false, 'goal_month', 0, 'actual_month', 0, 'actual_week', 0, 'actual_today', 0)
      )
    )
  );

  if (v_workspace #>> '{goals,week,target}')::numeric <> 1
     or (v_workspace #>> '{goals,today,target}')::numeric <> 1
     or (
       (v_workspace #>> '{professionals,0,goal_week}')::numeric
       + (v_workspace #>> '{professionals,1,goal_week}')::numeric
       + (v_workspace #>> '{professionals,2,goal_week}')::numeric
     ) <> 1
     or (
       (v_workspace #>> '{professionals,0,goal_today}')::numeric
       + (v_workspace #>> '{professionals,1,goal_today}')::numeric
       + (v_workspace #>> '{professionals,2,goal_today}')::numeric
     ) <> 1
     or (v_workspace #>> '{professionals,3,goal_week}')::numeric <> 0
     or (v_workspace #>> '{professionals,3,goal_today}')::numeric <> 0 then
    raise exception 'QA cascata de metas: distribuicao individual divergiu do total geral.';
  end if;

  v_workspace := app_private.rebalance_good_morning_daily_goals(
    jsonb_build_object(
      'configured', false,
      'today', '2026-09-01',
      'week_start', '2026-09-01',
      'week_end', '2026-09-06',
      'goals', jsonb_build_object(
        'today', jsonb_build_object('actual', 0),
        'week', jsonb_build_object('actual', 0),
        'month', jsonb_build_object('target', 26000, 'actual', 0)
      ),
      'professionals', jsonb_build_array(
        jsonb_build_object('id', 'a', 'good_morning_seller_enabled', true, 'goal_month', 26000, 'actual_month', 0, 'actual_week', 0, 'actual_today', 0)
      )
    )
  );

  if (v_workspace #>> '{goals,week,target}')::numeric <> 0
     or (v_workspace #>> '{goals,today,target}')::numeric <> 0 then
    raise exception 'QA cascata de metas: configuracao pendente deveria zerar os alvos.';
  end if;

  v_workspace := app_private.rebalance_good_morning_daily_goals(
    jsonb_build_object(
      'today', '2026-11-01',
      'week_start', '2026-11-01',
      'week_end', '2026-11-01',
      'goals', jsonb_build_object(
        'today', jsonb_build_object('actual', 0),
        'week', jsonb_build_object('actual', 0),
        'month', jsonb_build_object('target', 1000, 'actual', 0)
      ),
      'professionals', jsonb_build_array(
        jsonb_build_object(
          'id', 'seller-a',
          'good_morning_seller_enabled', true,
          'goal_month', 1000,
          'actual_month', 0,
          'actual_week', 0,
          'actual_today', 0
        )
      )
    )
  );

  if (v_workspace #>> '{goals,week,target}')::numeric <> 0
     or (v_workspace #>> '{goals,today,target}')::numeric <> 0 then
    raise exception 'QA cascata de metas: domingo deve manter os alvos zerados.';
  end if;

  if not pg_catalog.has_function_privilege(
    'anon',
    'app_private.good_morning_seller_apportion_cents(bigint, bigint[])',
    'EXECUTE'
  ) or not pg_catalog.has_function_privilege(
    'anon',
    'app_private.rebalance_good_morning_daily_goals(jsonb)',
    'EXECUTE'
  ) then
    raise exception 'QA cascata de metas: RPC nao possui os privilegios necessarios para anon.';
  end if;
end;
$qa$;

comment on function app_private.good_morning_seller_apportion_cents(bigint, bigint[]) is
  'Distribui um total inteiro em centavos por pesos usando maior resto e ordem deterministica.';
comment on function app_private.rebalance_good_morning_daily_goals(jsonb) is
  'Abre a meta semanal pelo saldo mensal e recalcula a meta diaria pelo saldo semanal ate ontem.';

notify pgrst, 'reload schema';

commit;
