-- O saldo geral pertence a meta da equipe. Quando um vendedor ultrapassa sua
-- parte, o excedente precisa reduzir o que falta para a loja e ser refletido
-- nas metas individuais restantes, sempre fechando exatamente em centavos.

begin;

set local lock_timeout = '10s';
set local statement_timeout = '5min';

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
  v_team_goal_cents bigint := 0;
  v_team_actual_before_today_cents bigint := 0;
  v_team_day_goal_cents bigint := 0;
  v_professionals jsonb := '[]'::jsonb;
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

  v_team_goal_cents := round(
    coalesce(
      nullif(v_workspace #>> '{goals,month,target}', '')::numeric,
      nullif(v_workspace->>'monthly_goal', '')::numeric,
      0
    ) * 100
  )::bigint;
  v_team_actual_before_today_cents := greatest(
    round((
      coalesce(nullif(v_workspace #>> '{goals,month,actual}', '')::numeric, 0)
      - coalesce(nullif(v_workspace #>> '{goals,today,actual}', '')::numeric, 0)
    ) * 100)::bigint,
    0
  );
  v_team_day_goal_cents := case
    when v_today_is_working_day then
      app_private.good_morning_seller_remaining_daily_goal_cents(
        v_team_goal_cents,
        v_team_actual_before_today_cents,
        v_remaining_workdays
      )
    else 0::bigint
  end;

  with source as (
    select
      entries.ordinality,
      entries.professional,
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
      )::bigint as goal_month_cents,
      greatest(
        round((
          coalesce(nullif(entries.professional->>'actual_month', '')::numeric, 0)
          - coalesce(nullif(entries.professional->>'actual_today', '')::numeric, 0)
        ) * 100)::bigint,
        0
      ) as actual_before_today_cents
    from jsonb_array_elements(
      case
        when jsonb_typeof(v_workspace->'professionals') = 'array'
          then v_workspace->'professionals'
        else '[]'::jsonb
      end
    ) with ordinality as entries(professional, ordinality)
  ), balances as (
    select
      source.*,
      case
        when source.enabled then greatest(
          source.goal_month_cents - source.actual_before_today_cents,
          0
        )
        else 0::bigint
      end as individual_gap_cents
    from source
  ), available_weights as (
    select
      balances.*,
      coalesce(sum(balances.individual_gap_cents) over (), 0)::bigint as total_gap_cents,
      coalesce(sum(balances.goal_month_cents) filter (where balances.enabled) over (), 0)::bigint as total_goal_cents,
      count(*) filter (where balances.enabled) over ()::integer as enabled_count
    from balances
  ), weighted as (
    select
      available_weights.*,
      case
        when available_weights.total_gap_cents > 0
          then available_weights.individual_gap_cents::numeric
        when available_weights.total_goal_cents > 0 and available_weights.enabled
          then available_weights.goal_month_cents::numeric
        when available_weights.enabled_count > 0 and available_weights.enabled
          then 1::numeric
        else 0::numeric
      end as allocation_weight
    from available_weights
  ), weighted_totals as (
    select
      weighted.*,
      coalesce(sum(weighted.allocation_weight) over (), 0)::numeric as total_weight
    from weighted
  ), quotas as (
    select
      weighted_totals.*,
      case
        when weighted_totals.total_weight > 0 then floor(
          v_team_day_goal_cents::numeric
          * weighted_totals.allocation_weight
          / weighted_totals.total_weight
        )::bigint
        else 0::bigint
      end as base_goal_cents,
      case
        when weighted_totals.total_weight > 0 then
          (
            v_team_day_goal_cents::numeric
            * weighted_totals.allocation_weight
            / weighted_totals.total_weight
          ) - floor(
            v_team_day_goal_cents::numeric
            * weighted_totals.allocation_weight
            / weighted_totals.total_weight
          )
        else 0::numeric
      end as fractional_remainder
    from weighted_totals
  ), ranked as (
    select
      quotas.*,
      row_number() over (
        order by
          case when quotas.allocation_weight > 0 then quotas.fractional_remainder else -1::numeric end desc,
          quotas.ordinality
      )::bigint as remainder_rank,
      coalesce(sum(quotas.base_goal_cents) over (), 0)::bigint as distributed_base_cents
    from quotas
  ), finalized as (
    select
      ranked.ordinality,
      ranked.professional,
      ranked.base_goal_cents + case
        when ranked.allocation_weight > 0
         and ranked.remainder_rank <= v_team_day_goal_cents - ranked.distributed_base_cents
          then 1::bigint
        else 0::bigint
      end as goal_today_cents
    from ranked
  )
  select coalesce(
    jsonb_agg(
      finalized.professional || jsonb_build_object(
        'goal_today', finalized.goal_today_cents::numeric / 100
      )
      order by finalized.ordinality
    ),
    '[]'::jsonb
  )
  into v_professionals
  from finalized;

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
    'target', v_team_day_goal_cents::numeric / 100
  );
  v_goals := v_goals || jsonb_build_object('today', v_today_goal);

  return v_workspace || jsonb_build_object(
    'professionals', v_professionals,
    'goals', v_goals,
    'today_is_working_day', v_today_is_working_day,
    'remaining_workdays_in_month', v_remaining_workdays,
    'daily_goal_strategy', 'remaining_team_balance'
  );
end;
$$;

do $qa$
declare
  v_workspace jsonb;
begin
  -- 19/09/2026 e sabado e restam dez dias de segunda a sabado no mes.
  -- A vendeu 100,00 acima da sua parte; o excedente reduz o saldo da equipe.
  v_workspace := app_private.rebalance_good_morning_daily_goals(
    jsonb_build_object(
      'today', '2026-09-19',
      'goals', jsonb_build_object(
        'today', jsonb_build_object('target', 0, 'actual', 0),
        'month', jsonb_build_object('target', 1000, 'actual', 600)
      ),
      'professionals', jsonb_build_array(
        jsonb_build_object(
          'id', 'seller-a',
          'good_morning_seller_enabled', true,
          'goal_month', 500,
          'actual_month', 600,
          'actual_today', 0
        ),
        jsonb_build_object(
          'id', 'seller-b',
          'good_morning_seller_enabled', true,
          'goal_month', 500,
          'actual_month', 0,
          'actual_today', 0
        )
      )
    )
  );

  if (v_workspace->>'remaining_workdays_in_month')::integer <> 10
     or (v_workspace #>> '{goals,today,target}')::numeric <> 40
     or (v_workspace #>> '{professionals,0,goal_today}')::numeric <> 0
     or (v_workspace #>> '{professionals,1,goal_today}')::numeric <> 40 then
    raise exception 'QA meta da equipe: o excedente individual nao reduziu o saldo geral corretamente.';
  end if;

  -- Vendas de alguem pausado ja fazem parte do realizado geral legado. O alvo
  -- e as metas individuais precisam fechar contra o mesmo numero exibido.
  v_workspace := app_private.rebalance_good_morning_daily_goals(
    jsonb_build_object(
      'today', '2026-09-19',
      'goals', jsonb_build_object(
        'today', jsonb_build_object('target', 0, 'actual', 0),
        'month', jsonb_build_object('target', 1000, 'actual', 100)
      ),
      'professionals', jsonb_build_array(
        jsonb_build_object('id', 'a', 'good_morning_seller_enabled', true, 'goal_month', 500, 'actual_month', 0, 'actual_today', 0),
        jsonb_build_object('id', 'b', 'good_morning_seller_enabled', true, 'goal_month', 500, 'actual_month', 0, 'actual_today', 0),
        jsonb_build_object('id', 'paused', 'good_morning_seller_enabled', false, 'goal_month', 0, 'actual_month', 100, 'actual_today', 0)
      )
    )
  );

  if (v_workspace #>> '{goals,today,target}')::numeric <> 90
     or (v_workspace #>> '{professionals,0,goal_today}')::numeric <> 45
     or (v_workspace #>> '{professionals,1,goal_today}')::numeric <> 45
     or (v_workspace #>> '{professionals,2,goal_today}')::numeric <> 0 then
    raise exception 'QA meta da equipe: metas individuais nao fecharam contra o realizado geral.';
  end if;

  -- O maior resto distribui os centavos sem alterar o total do card geral.
  v_workspace := app_private.rebalance_good_morning_daily_goals(
    jsonb_build_object(
      'today', '2026-09-30',
      'goals', jsonb_build_object(
        'today', jsonb_build_object('target', 0, 'actual', 0),
        'month', jsonb_build_object('target', 1, 'actual', 0)
      ),
      'professionals', jsonb_build_array(
        jsonb_build_object('id', 'a', 'good_morning_seller_enabled', true, 'goal_month', 0.34, 'actual_month', 0, 'actual_today', 0),
        jsonb_build_object('id', 'b', 'good_morning_seller_enabled', true, 'goal_month', 0.33, 'actual_month', 0, 'actual_today', 0),
        jsonb_build_object('id', 'c', 'good_morning_seller_enabled', true, 'goal_month', 0.33, 'actual_month', 0, 'actual_today', 0)
      )
    )
  );

  if (v_workspace #>> '{goals,today,target}')::numeric <> 1
     or (
       (v_workspace #>> '{professionals,0,goal_today}')::numeric
       + (v_workspace #>> '{professionals,1,goal_today}')::numeric
       + (v_workspace #>> '{professionals,2,goal_today}')::numeric
     ) <> 1 then
    raise exception 'QA meta da equipe: distribuicao individual perdeu centavos.';
  end if;

  -- As vendas feitas hoje alteram apenas o realizado. Elas entram no saldo
  -- amanha, evitando que o alvo fique diminuindo durante o expediente.
  v_workspace := app_private.rebalance_good_morning_daily_goals(
    jsonb_build_object(
      'today', '2026-09-01',
      'goals', jsonb_build_object(
        'today', jsonb_build_object('target', 0, 'actual', 1500),
        'month', jsonb_build_object('target', 26000, 'actual', 1500)
      ),
      'professionals', jsonb_build_array(
        jsonb_build_object('id', 'a', 'good_morning_seller_enabled', true, 'goal_month', 26000, 'actual_month', 1500, 'actual_today', 1500)
      )
    )
  );

  if (v_workspace #>> '{goals,today,target}')::numeric <> 1000
     or (v_workspace #>> '{professionals,0,goal_today}')::numeric <> 1000 then
    raise exception 'QA meta da equipe: vendas do proprio dia alteraram o alvo antes da virada.';
  end if;

  -- Se o objetivo coletivo ja foi atingido, todos os alvos do dia zeram,
  -- inclusive para quem individualmente ainda estava abaixo da sua parte.
  v_workspace := app_private.rebalance_good_morning_daily_goals(
    jsonb_build_object(
      'today', '2026-09-19',
      'goals', jsonb_build_object(
        'today', jsonb_build_object('target', 0, 'actual', 0),
        'month', jsonb_build_object('target', 1000, 'actual', 1100)
      ),
      'professionals', jsonb_build_array(
        jsonb_build_object('id', 'a', 'good_morning_seller_enabled', true, 'goal_month', 500, 'actual_month', 1100, 'actual_today', 0),
        jsonb_build_object('id', 'b', 'good_morning_seller_enabled', true, 'goal_month', 500, 'actual_month', 0, 'actual_today', 0)
      )
    )
  );

  if (v_workspace #>> '{goals,today,target}')::numeric <> 0
     or (v_workspace #>> '{professionals,0,goal_today}')::numeric <> 0
     or (v_workspace #>> '{professionals,1,goal_today}')::numeric <> 0 then
    raise exception 'QA meta da equipe: meta coletiva atingida deveria zerar todos os alvos.';
  end if;

  v_workspace := app_private.rebalance_good_morning_daily_goals(
    jsonb_build_object(
      'today', '2026-11-01',
      'goals', jsonb_build_object(
        'today', jsonb_build_object('target', 100, 'actual', 0),
        'month', jsonb_build_object('target', 1000, 'actual', 0)
      ),
      'professionals', jsonb_build_array(
        jsonb_build_object('id', 'a', 'good_morning_seller_enabled', true, 'goal_month', 1000, 'actual_month', 0, 'actual_today', 0)
      )
    )
  );

  if (v_workspace #>> '{goals,today,target}')::numeric <> 0
     or (v_workspace #>> '{professionals,0,goal_today}')::numeric <> 0 then
    raise exception 'QA meta da equipe: domingo deve manter os alvos zerados.';
  end if;
end;
$qa$;

comment on function app_private.rebalance_good_morning_daily_goals(jsonb) is
  'Calcula o saldo diario geral da equipe e distribui seus centavos entre participantes conforme os saldos individuais.';

notify pgrst, 'reload schema';

commit;
