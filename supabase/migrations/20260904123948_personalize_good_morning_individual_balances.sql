-- Separa definitivamente as metas individuais da rotacao da vez.
--
-- Os alvos gerais da equipe continuam sendo calculados pela estrategia
-- hierarquica existente. Cada vendedor, porem, recebe agora alvos e saldos
-- derivados exclusivamente da propria meta e do proprio realizado. Todos os
-- calculos monetarios sao feitos em bigint (centavos).

begin;

set local lock_timeout = '10s';
set local statement_timeout = '5min';

-- Preserva a implementacao que calcula os cards gerais da equipe e o corte da
-- primeira configuracao. O nome publico interno passa a ser um wrapper que
-- acrescenta a matematica individual sem alterar nenhum total geral.
alter function app_private.rebalance_good_morning_with_configuration_cutoff(jsonb)
  rename to rebalance_good_morning_with_configuration_cutoff_team_v1;

create or replace function app_private.personalize_good_morning_individual_balances(
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
  v_configured boolean := false;
  v_snapshot_active boolean := false;
  v_today_is_working_day boolean := false;
  v_workdays_in_week integer := 0;
  v_workdays_from_week_start integer := 0;
  v_remaining_workdays_in_week integer := 0;
  v_professionals jsonb := '[]'::jsonb;
begin
  if pg_catalog.jsonb_typeof(v_workspace) is distinct from 'object' then
    return v_workspace;
  end if;

  v_configured := coalesce(
    nullif(v_workspace->>'configured', '')::boolean,
    false
  );
  v_snapshot_active := coalesce(
    nullif(v_workspace->>'initial_configuration_cutoff_applied', '')::boolean,
    false
  );
  v_today_is_working_day := coalesce(
    nullif(v_workspace->>'today_is_working_day', '')::boolean,
    false
  );
  v_workdays_in_week := greatest(
    coalesce(nullif(v_workspace->>'workdays_in_week', '')::integer, 0),
    0
  );
  v_workdays_from_week_start := greatest(
    coalesce(
      nullif(v_workspace->>'workdays_in_month_from_week_start', '')::integer,
      0
    ),
    0
  );
  v_remaining_workdays_in_week := greatest(
    coalesce(
      nullif(v_workspace->>'remaining_workdays_in_week', '')::integer,
      0
    ),
    0
  );

  with source as (
    select
      entries.ordinality,
      entries.professional,
      coalesce(
        nullif(
          entries.professional->>'good_morning_seller_enabled',
          ''
        )::boolean,
        true
      ) as enabled,
      case
        when v_configured and coalesce(
          nullif(
            entries.professional->>'good_morning_seller_enabled',
            ''
          )::boolean,
          true
        ) then greatest(
          pg_catalog.round(
            coalesce(
              nullif(entries.professional->>'goal_amount', '')::numeric,
              nullif(entries.professional->>'goal_month', '')::numeric,
              0
            ) * 100
          )::bigint,
          0
        )
        else 0::bigint
      end as month_target_cents,
      greatest(
        pg_catalog.round(
          coalesce(
            nullif(entries.professional->>'actual_month', '')::numeric,
            0
          ) * 100
        )::bigint,
        0
      ) as live_month_actual_cents,
      greatest(
        pg_catalog.round(
          coalesce(
            nullif(entries.professional->>'actual_week', '')::numeric,
            0
          ) * 100
        )::bigint,
        0
      ) as live_week_actual_cents,
      greatest(
        pg_catalog.round(
          coalesce(
            nullif(entries.professional->>'actual_today', '')::numeric,
            0
          ) * 100
        )::bigint,
        0
      ) as live_today_actual_cents,
      greatest(
        pg_catalog.round(
          coalesce(
            nullif(
              entries.professional->>'actual_month_at_configuration',
              ''
            )::numeric,
            0
          ) * 100
        )::bigint,
        0
      ) as snapshot_month_actual_cents,
      greatest(
        pg_catalog.round(
          coalesce(
            nullif(
              entries.professional->>'actual_week_at_configuration',
              ''
            )::numeric,
            0
          ) * 100
        )::bigint,
        0
      ) as snapshot_week_actual_cents,
      greatest(
        pg_catalog.round(
          coalesce(
            nullif(
              entries.professional->>'actual_today_before_configuration',
              ''
            )::numeric,
            0
          ) * 100
        )::bigint,
        0
      ) as snapshot_today_actual_cents
    from pg_catalog.jsonb_array_elements(
      case
        when pg_catalog.jsonb_typeof(v_workspace->'professionals') = 'array'
          then v_workspace->'professionals'
        else '[]'::jsonb
      end
    ) with ordinality as entries(professional, ordinality)
  ), baselines as (
    select
      source.*,
      case
        when v_snapshot_active then greatest(
          source.snapshot_month_actual_cents
            - source.snapshot_week_actual_cents,
          0
        )
        else greatest(
          source.live_month_actual_cents - source.live_week_actual_cents,
          0
        )
      end as month_actual_before_week_cents,
      case
        -- No dia da primeira configuracao, tudo que ja havia sido vendido na
        -- semana (inclusive mais cedo hoje) forma o baseline do novo alvo.
        when v_snapshot_active then source.snapshot_week_actual_cents
        else greatest(
          source.live_week_actual_cents - source.live_today_actual_cents,
          0
        )
      end as week_actual_before_today_cents,
      case
        -- Apenas vendas posteriores ao cutoff consomem a nova meta de hoje.
        when v_snapshot_active then greatest(
          source.live_today_actual_cents
            - source.snapshot_today_actual_cents,
          0
        )
        else source.live_today_actual_cents
      end as today_actual_against_target_cents
    from source
  ), weekly as (
    select
      baselines.*,
      case
        when v_configured
         and baselines.enabled
         and v_workdays_from_week_start > 0 then
          pg_catalog.round(
            greatest(
              baselines.month_target_cents
                - baselines.month_actual_before_week_cents,
              0
            )::numeric
            * v_workdays_in_week::numeric
            / v_workdays_from_week_start::numeric
          )::bigint
        else 0::bigint
      end as week_target_cents
    from baselines
  ), daily as (
    select
      weekly.*,
      case
        when v_configured
         and weekly.enabled
         and v_today_is_working_day
         and v_remaining_workdays_in_week > 0 then
          pg_catalog.round(
            greatest(
              weekly.week_target_cents
                - weekly.week_actual_before_today_cents,
              0
            )::numeric
            / v_remaining_workdays_in_week::numeric
          )::bigint
        else 0::bigint
      end as today_target_cents
    from weekly
  ), finalized as (
    select
      daily.*,
      case
        when v_configured and daily.enabled then greatest(
          daily.month_target_cents - daily.live_month_actual_cents,
          0
        )
        else 0::bigint
      end as remaining_month_cents,
      case
        when v_configured and daily.enabled then greatest(
          daily.week_target_cents - daily.live_week_actual_cents,
          0
        )
        else 0::bigint
      end as remaining_week_cents,
      case
        when v_configured and daily.enabled then greatest(
          daily.today_target_cents - daily.today_actual_against_target_cents,
          0
        )
        else 0::bigint
      end as remaining_today_cents
    from daily
  )
  select coalesce(
    pg_catalog.jsonb_agg(
      finalized.professional || pg_catalog.jsonb_build_object(
        -- Chaves legadas continuam sendo alvos, nunca saldos.
        'goal_month', finalized.month_target_cents::numeric / 100,
        'goal_week', finalized.week_target_cents::numeric / 100,
        'goal_today', finalized.today_target_cents::numeric / 100,
        -- Contrato explicito para evitar que a UI confunda alvo com restante.
        'goal_month_target', finalized.month_target_cents::numeric / 100,
        'goal_week_target', finalized.week_target_cents::numeric / 100,
        'goal_today_target', finalized.today_target_cents::numeric / 100,
        'remaining_month', finalized.remaining_month_cents::numeric / 100,
        'remaining_week', finalized.remaining_week_cents::numeric / 100,
        'remaining_today', finalized.remaining_today_cents::numeric / 100,
        'goal_month_target_cents', finalized.month_target_cents,
        'goal_week_target_cents', finalized.week_target_cents,
        'goal_today_target_cents', finalized.today_target_cents,
        'remaining_month_cents', finalized.remaining_month_cents,
        'remaining_week_cents', finalized.remaining_week_cents,
        'remaining_today_cents', finalized.remaining_today_cents,
        'actual_today_against_target',
          finalized.today_actual_against_target_cents::numeric / 100,
        'actual_today_against_target_cents',
          finalized.today_actual_against_target_cents
      )
      order by finalized.ordinality
    ),
    '[]'::jsonb
  )
  into v_professionals
  from finalized;

  return v_workspace || pg_catalog.jsonb_build_object(
    'professionals', v_professionals,
    'individual_goal_strategy', 'own_remaining_balance_v2',
    'individual_goal_amounts_in_cents', true,
    'rotation_affects_individual_goals', false
  );
end;
$$;

create or replace function app_private.rebalance_good_morning_with_configuration_cutoff(
  p_workspace jsonb
)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select app_private.personalize_good_morning_individual_balances(
    app_private.rebalance_good_morning_with_configuration_cutoff_team_v1(
      p_workspace
    )
  );
$$;

-- Recria explicitamente todas as fachadas para que os corpos SQL sejam
-- associados ao wrapper novo, inclusive em servidores que ja tenham planos
-- das funcoes anteriores em cache.
create or replace function public.lc_get_good_morning_seller_workspace(
  p_session_token text,
  p_store_id uuid
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app_private.rebalance_good_morning_with_configuration_cutoff(
    app_private.refresh_good_morning_historical_actuals(
      p_session_token,
      p_store_id,
      app_private.attach_good_morning_seller_closed_days(
        p_session_token,
        p_store_id,
        app_private.rpc_get_good_morning_seller_workspace(
          p_session_token,
          p_store_id
        )
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
  select app_private.rebalance_good_morning_with_configuration_cutoff(
    app_private.refresh_good_morning_historical_actuals(
      p_session_token,
      p_store_id,
      app_private.attach_good_morning_seller_closed_days(
        p_session_token,
        p_store_id,
        app_private.mark_good_morning_goal_configured(
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
  select app_private.rebalance_good_morning_with_configuration_cutoff(
    app_private.refresh_good_morning_historical_actuals(
      p_session_token,
      p_store_id,
      app_private.attach_good_morning_seller_closed_days(
        p_session_token,
        p_store_id,
        app_private.mark_good_morning_goal_configured(
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
  select app_private.rebalance_good_morning_with_configuration_cutoff(
    app_private.refresh_good_morning_historical_actuals(
      p_session_token,
      p_store_id,
      app_private.attach_good_morning_seller_closed_days(
        p_session_token,
        p_store_id,
        app_private.rpc_advance_good_morning_seller_turn_store_only(
          p_session_token,
          p_store_id
        )
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
  select app_private.rebalance_good_morning_with_configuration_cutoff(
    app_private.refresh_good_morning_historical_actuals(
      p_session_token,
      p_store_id,
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
    )
  ) || pg_catalog.jsonb_build_object(
    'participation_update_available', true,
    'can_manage_settings', true
  );
$$;

revoke all on function app_private.rebalance_good_morning_with_configuration_cutoff_team_v1(jsonb)
  from public, anon, authenticated;
revoke all on function app_private.personalize_good_morning_individual_balances(jsonb)
  from public, anon, authenticated;
revoke all on function app_private.rebalance_good_morning_with_configuration_cutoff(jsonb)
  from public, anon, authenticated;

grant execute on function app_private.rebalance_good_morning_with_configuration_cutoff_team_v1(jsonb)
  to anon, authenticated;
grant execute on function app_private.personalize_good_morning_individual_balances(jsonb)
  to anon, authenticated;
grant execute on function app_private.rebalance_good_morning_with_configuration_cutoff(jsonb)
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
  v_rotated_workspace jsonb;
  v_projection jsonb;
  v_rotated_projection jsonb;
  v_snapshot jsonb;
  v_exact_case jsonb;
  v_saturday jsonb;
  v_closed_saturday jsonb;
  v_sunday jsonb;
  v_last_cent jsonb;
begin
  if pg_catalog.to_regprocedure(
       'app_private.rebalance_good_morning_with_configuration_cutoff_team_v1(jsonb)'
     ) is null
     or pg_catalog.to_regprocedure(
       'app_private.personalize_good_morning_individual_balances(jsonb)'
     ) is null then
    raise exception 'QA metas individuais: contrato interno incompleto.';
  end if;

  v_workspace := app_private.rebalance_good_morning_with_configuration_cutoff(
    pg_catalog.jsonb_build_object(
      'configured', true,
      'today', '2026-09-02',
      'week_start', '2026-09-01',
      'week_end', '2026-09-06',
      'current_professional_id', 'seller-k',
      'closed_days', '[]'::jsonb,
      'goals', pg_catalog.jsonb_build_object(
        'month', pg_catalog.jsonb_build_object(
          'target', 130800,
          'actual', 18454
        ),
        'week', pg_catalog.jsonb_build_object('actual', 18454),
        'today', pg_catalog.jsonb_build_object('actual', 3000)
      ),
      'professionals', pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object(
          'id', 'seller-k',
          'queue_position', 1,
          'good_morning_seller_enabled', true,
          'goal_amount', 65400,
          'goal_month', 65400,
          'actual_month', 4139,
          'actual_week', 4139,
          'actual_today', 1000
        ),
        pg_catalog.jsonb_build_object(
          'id', 'seller-a',
          'queue_position', 2,
          'good_morning_seller_enabled', true,
          'goal_amount', 65400,
          'goal_month', 65400,
          'actual_month', 14315,
          'actual_week', 14315,
          'actual_today', 2000
        )
      )
    )
  );

  -- Cada pessoa parte do proprio saldo. A que vendeu mais fica com menos a
  -- cumprir, mesmo tendo exatamente a mesma meta configurada.
  if (v_workspace #>> '{professionals,0,remaining_month_cents}')::bigint
       <> 6126100
     or (v_workspace #>> '{professionals,1,remaining_month_cents}')::bigint
       <> 5108500
     or (v_workspace #>> '{professionals,0,goal_week_target_cents}')::bigint
       <> 1257692
     or (v_workspace #>> '{professionals,1,goal_week_target_cents}')::bigint
       <> 1257692
     or (v_workspace #>> '{professionals,0,remaining_week_cents}')::bigint
       <> 843792
     or (v_workspace #>> '{professionals,1,remaining_week_cents}')::bigint
       <> 0
     or (v_workspace #>> '{professionals,0,goal_today_target_cents}')::bigint
       <> 235948
     or (v_workspace #>> '{professionals,1,goal_today_target_cents}')::bigint
       <> 6548
     or (v_workspace #>> '{professionals,0,remaining_today_cents}')::bigint
       <> 135948
     or (v_workspace #>> '{professionals,1,remaining_today_cents}')::bigint
       <> 0 then
    raise exception 'QA metas individuais: saldos personalizados incorretos: %',
      v_workspace->'professionals';
  end if;

  -- Os cards gerais permanecem exatamente sob a estrategia coletiva anterior.
  if (v_workspace #>> '{goals,month,target}')::numeric <> 130800
     or (v_workspace #>> '{goals,week,target}')::numeric <> 25153.85
     or (v_workspace #>> '{goals,today,target}')::numeric <> 2424.96 then
    raise exception 'QA metas individuais: algum alvo geral foi alterado: %',
      v_workspace->'goals';
  end if;

  -- Caso observado em producao: metas iguais de 65.400,00, mas realizados
  -- semanais de 14.315,00 e 4.139,00. Com dois dias abertos restantes, os
  -- saldos precisam ser 0 / 8.941,00 e os alvos de hoje 0 / 4.470,50.
  v_exact_case := app_private.personalize_good_morning_individual_balances(
    pg_catalog.jsonb_build_object(
      'configured', true,
      'today_is_working_day', true,
      'workdays_in_week', 5,
      'workdays_in_month_from_week_start', 25,
      'remaining_workdays_in_week', 2,
      'professionals', pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object(
          'id', 'seller-more',
          'good_morning_seller_enabled', true,
          'goal_amount', 65400,
          'actual_month', 14315,
          'actual_week', 14315,
          'actual_today', 0
        ),
        pg_catalog.jsonb_build_object(
          'id', 'seller-less',
          'good_morning_seller_enabled', true,
          'goal_amount', 65400,
          'actual_month', 4139,
          'actual_week', 4139,
          'actual_today', 0
        )
      )
    )
  );

  if (v_exact_case #>> '{professionals,0,goal_week_target_cents}')::bigint
       <> 1308000
     or (v_exact_case #>> '{professionals,1,goal_week_target_cents}')::bigint
       <> 1308000
     or (v_exact_case #>> '{professionals,0,remaining_week_cents}')::bigint
       <> 0
     or (v_exact_case #>> '{professionals,1,remaining_week_cents}')::bigint
       <> 894100
     or (v_exact_case #>> '{professionals,0,remaining_today_cents}')::bigint
       <> 0
     or (v_exact_case #>> '{professionals,1,remaining_today_cents}')::bigint
       <> 447050 then
    raise exception 'QA metas individuais: caso real divergiu: %',
      v_exact_case->'professionals';
  end if;

  select pg_catalog.jsonb_object_agg(
    entries.value->>'id',
    pg_catalog.jsonb_build_object(
      'month_target', entries.value->'goal_month_target_cents',
      'week_target', entries.value->'goal_week_target_cents',
      'today_target', entries.value->'goal_today_target_cents',
      'month_remaining', entries.value->'remaining_month_cents',
      'week_remaining', entries.value->'remaining_week_cents',
      'today_remaining', entries.value->'remaining_today_cents'
    )
  )
  into v_projection
  from pg_catalog.jsonb_array_elements(v_workspace->'professionals') entries(value);

  -- Troca simultaneamente o vendedor atual e a ordem do array/fila. A
  -- projecao por UUID precisa permanecer byte a byte igual.
  v_rotated_workspace := app_private.rebalance_good_morning_with_configuration_cutoff(
    pg_catalog.jsonb_build_object(
      'configured', true,
      'today', '2026-09-02',
      'week_start', '2026-09-01',
      'week_end', '2026-09-06',
      'current_professional_id', 'seller-a',
      'closed_days', '[]'::jsonb,
      'goals', pg_catalog.jsonb_build_object(
        'month', pg_catalog.jsonb_build_object(
          'target', 130800,
          'actual', 18454
        ),
        'week', pg_catalog.jsonb_build_object('actual', 18454),
        'today', pg_catalog.jsonb_build_object('actual', 3000)
      ),
      'professionals', pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object(
          'id', 'seller-a',
          'queue_position', 1,
          'good_morning_seller_enabled', true,
          'goal_amount', 65400,
          'goal_month', 65400,
          'actual_month', 14315,
          'actual_week', 14315,
          'actual_today', 2000
        ),
        pg_catalog.jsonb_build_object(
          'id', 'seller-k',
          'queue_position', 2,
          'good_morning_seller_enabled', true,
          'goal_amount', 65400,
          'goal_month', 65400,
          'actual_month', 4139,
          'actual_week', 4139,
          'actual_today', 1000
        )
      )
    )
  );

  select pg_catalog.jsonb_object_agg(
    entries.value->>'id',
    pg_catalog.jsonb_build_object(
      'month_target', entries.value->'goal_month_target_cents',
      'week_target', entries.value->'goal_week_target_cents',
      'today_target', entries.value->'goal_today_target_cents',
      'month_remaining', entries.value->'remaining_month_cents',
      'week_remaining', entries.value->'remaining_week_cents',
      'today_remaining', entries.value->'remaining_today_cents'
    )
  )
  into v_rotated_projection
  from pg_catalog.jsonb_array_elements(
    v_rotated_workspace->'professionals'
  ) entries(value);

  if v_rotated_projection is distinct from v_projection
     or coalesce(
       (v_rotated_workspace->>'rotation_affects_individual_goals')::boolean,
       true
     ) then
    raise exception 'QA metas individuais: a rotacao alterou metas/saldos: % <> %',
      v_projection,
      v_rotated_projection;
  end if;

  -- Configuracao no meio do dia: vendas anteriores ao cutoff entram no
  -- baseline; apenas o delta posterior consome o novo alvo diario.
  v_snapshot := app_private.rebalance_good_morning_with_configuration_cutoff(
    pg_catalog.jsonb_build_object(
      'configured', true,
      'configuration_actual_snapshot_active', true,
      'today', '2026-09-16',
      'week_start', '2026-09-14',
      'week_end', '2026-09-20',
      'closed_days', '[]'::jsonb,
      'actual_month_at_configuration', 4500,
      'actual_week_at_configuration', 1500,
      'actual_today_before_configuration', 700,
      'goals', pg_catalog.jsonb_build_object(
        'month', pg_catalog.jsonb_build_object('target', 13000, 'actual', 5000),
        'week', pg_catalog.jsonb_build_object('actual', 2000),
        'today', pg_catalog.jsonb_build_object('actual', 1200)
      ),
      'professionals', pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object(
          'id', 'seller-snapshot',
          'good_morning_seller_enabled', true,
          'goal_amount', 13000,
          'goal_month', 13000,
          'actual_month', 5000,
          'actual_week', 2000,
          'actual_today', 1200,
          'actual_month_at_configuration', 4500,
          'actual_week_at_configuration', 1500,
          'actual_today_before_configuration', 700
        )
      )
    )
  );

  if (v_snapshot #>> '{professionals,0,goal_week_target_cents}')::bigint
       <> 400000
     or (v_snapshot #>> '{professionals,0,goal_today_target_cents}')::bigint
       <> 62500
     or (v_snapshot #>> '{professionals,0,actual_today_against_target_cents}')::bigint
       <> 50000
     or (v_snapshot #>> '{professionals,0,remaining_today_cents}')::bigint
       <> 12500 then
    raise exception 'QA metas individuais: cutoff do meio do dia duplicou vendas: %',
      v_snapshot->'professionals';
  end if;

  -- Sabado e dia aberto; domingo e um sabado marcado como fechamento nao sao.
  v_saturday := app_private.rebalance_good_morning_with_configuration_cutoff(
    pg_catalog.jsonb_build_object(
      'configured', true,
      'today', '2026-09-05',
      'week_start', '2026-09-01',
      'week_end', '2026-09-06',
      'closed_days', '[]'::jsonb,
      'goals', pg_catalog.jsonb_build_object(
        'month', pg_catalog.jsonb_build_object('target', 26000, 'actual', 4000),
        'week', pg_catalog.jsonb_build_object('actual', 4000),
        'today', pg_catalog.jsonb_build_object('actual', 0)
      ),
      'professionals', pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object(
          'id', 'seller-calendar',
          'good_morning_seller_enabled', true,
          'goal_amount', 26000,
          'actual_month', 4000,
          'actual_week', 4000,
          'actual_today', 0
        ),
        pg_catalog.jsonb_build_object(
          'id', 'seller-disabled',
          'good_morning_seller_enabled', false,
          'goal_amount', 26000,
          'actual_month', 1000,
          'actual_week', 1000,
          'actual_today', 0
        )
      )
    )
  );

  v_closed_saturday := app_private.rebalance_good_morning_with_configuration_cutoff(
    pg_catalog.jsonb_set(
      v_saturday,
      '{closed_days}',
      '[{"date":"2026-09-05","reason":"Fechado"}]'::jsonb,
      true
    )
  );

  v_sunday := app_private.rebalance_good_morning_with_configuration_cutoff(
    pg_catalog.jsonb_set(
      pg_catalog.jsonb_set(
        v_saturday,
        '{today}',
        '"2026-09-06"'::jsonb,
        true
      ),
      '{closed_days}',
      '[]'::jsonb,
      true
    )
  );

  if coalesce((v_saturday->>'today_is_working_day')::boolean, false) is false
     or (v_saturday #>> '{professionals,0,goal_today_target_cents}')::bigint
       <> 100000
     or (v_saturday #>> '{professionals,1,goal_month_target_cents}')::bigint
       <> 0
     or (v_saturday #>> '{professionals,1,remaining_month_cents}')::bigint
       <> 0
     or coalesce(
       (v_closed_saturday->>'today_is_working_day')::boolean,
       true
     )
     or (v_closed_saturday #>> '{professionals,0,goal_today_target_cents}')::bigint
       <> 0
     or coalesce((v_sunday->>'today_is_working_day')::boolean, true)
     or (v_sunday #>> '{professionals,0,goal_today_target_cents}')::bigint
       <> 0 then
    raise exception 'QA metas individuais: sabado/domingo/fechamento incorreto.';
  end if;

  -- No ultimo dia aberto, um centavo de saldo permanece exatamente um centavo.
  v_last_cent := app_private.rebalance_good_morning_with_configuration_cutoff(
    pg_catalog.jsonb_build_object(
      'configured', true,
      'today', '2026-09-30',
      'week_start', '2026-09-28',
      'week_end', '2026-09-30',
      'closed_days', '[]'::jsonb,
      'goals', pg_catalog.jsonb_build_object(
        'month', pg_catalog.jsonb_build_object('target', 0.01, 'actual', 0),
        'week', pg_catalog.jsonb_build_object('actual', 0),
        'today', pg_catalog.jsonb_build_object('actual', 0)
      ),
      'professionals', pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object(
          'id', 'seller-cent',
          'good_morning_seller_enabled', true,
          'goal_amount', 0.01,
          'actual_month', 0,
          'actual_week', 0,
          'actual_today', 0
        )
      )
    )
  );

  if (v_last_cent #>> '{professionals,0,goal_week_target_cents}')::bigint <> 1
     or (v_last_cent #>> '{professionals,0,goal_today_target_cents}')::bigint <> 1
     or (v_last_cent #>> '{professionals,0,remaining_month_cents}')::bigint <> 1
     or (v_last_cent #>> '{professionals,0,remaining_week_cents}')::bigint <> 1
     or (v_last_cent #>> '{professionals,0,remaining_today_cents}')::bigint <> 1 then
    raise exception 'QA metas individuais: um centavo foi perdido: %',
      v_last_cent->'professionals';
  end if;

  if not pg_catalog.has_function_privilege(
       'anon',
       'app_private.rebalance_good_morning_with_configuration_cutoff(jsonb)',
       'EXECUTE'
     )
     or not pg_catalog.has_function_privilege(
       'anon',
       'app_private.personalize_good_morning_individual_balances(jsonb)',
       'EXECUTE'
     ) then
    raise exception 'QA metas individuais: ACL inesperada.';
  end if;
end;
$qa$;

comment on function app_private.rebalance_good_morning_with_configuration_cutoff_team_v1(jsonb) is
  'Implementacao preservada dos cards gerais e do cutoff de configuracao do Bom Dia Vendedor.';
comment on function app_private.personalize_good_morning_individual_balances(jsonb) is
  'Calcula, em centavos, alvos e saldos individuais apenas pela meta/realizado do proprio profissional; ignora integralmente a rotacao.';
comment on function app_private.rebalance_good_morning_with_configuration_cutoff(jsonb) is
  'Preserva metas gerais, aplica cutoff e acrescenta alvos/saldos individuais independentes da rotacao.';

notify pgrst, 'reload schema';

commit;
