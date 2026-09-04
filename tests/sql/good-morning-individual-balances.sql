-- Executar depois de aplicar
-- 20260904134151_reconcile_good_morning_individual_balances.sql.
-- Usa uma sessao administrativa efemera, gira a rotacao e reverte tudo.
-- Nenhuma informacao de cliente e emitida pelo teste.

begin;

do $integration$
declare
  v_admin_user_id uuid;
  v_store_id uuid;
  v_session_token text :=
    'qa-individual-goals-' || extensions.gen_random_uuid()::text;
  v_before jsonb;
  v_after jsonb;
  v_before_projection jsonb;
  v_after_projection jsonb;
  v_before_current text;
  v_after_current text;
  v_invalid_count integer := 0;
  v_month_target_cents bigint := 0;
  v_month_actual_cents bigint := 0;
  v_week_target_cents bigint := 0;
  v_week_actual_cents bigint := 0;
  v_today_target_cents bigint := 0;
  v_today_actual_cents bigint := 0;
  v_today_snapshot_cents bigint := 0;
  v_today_effective_actual_cents bigint := 0;
  v_expected_month_remaining_cents bigint := 0;
  v_expected_week_remaining_cents bigint := 0;
  v_expected_today_remaining_cents bigint := 0;
  v_reported_month_remaining_cents bigint := 0;
  v_reported_week_remaining_cents bigint := 0;
  v_reported_today_remaining_cents bigint := 0;
  v_sum_month_remaining_cents bigint := 0;
  v_sum_week_remaining_cents bigint := 0;
  v_sum_today_remaining_cents bigint := 0;
  v_cutoff_case jsonb;
  v_exact_case jsonb;
begin
  if pg_catalog.to_regprocedure(
       'app_private.personalize_good_morning_individual_balances(jsonb)'
     ) is null
     or pg_catalog.to_regprocedure(
       'app_private.rebalance_good_morning_with_configuration_cutoff_team_v1(jsonb)'
     ) is null then
    raise exception 'Smoke individual: migration ainda nao foi aplicada.';
  end if;

  select settings.admin_user_id, settings.store_id
  into v_admin_user_id, v_store_id
  from public.good_morning_seller_settings settings
  join public.app_users admin_user
    on admin_user.id = settings.admin_user_id
   and admin_user.role::text = 'admin'
   and admin_user.is_active = true
  join public.stores store_record
    on store_record.id = settings.store_id
   and store_record.admin_user_id = settings.admin_user_id
   and store_record.is_active = true
   and store_record.attendance_enabled = true
   and store_record.good_morning_seller_enabled = true
  where settings.goal_month = pg_catalog.date_trunc(
    'month',
    pg_catalog.timezone('America/Sao_Paulo', pg_catalog.now())
  )::date
    and (
      select pg_catalog.count(*)
      from public.good_morning_seller_allocations allocation
      join public.prospection_professionals professional
        on professional.id = allocation.professional_id
       and professional.store_id = allocation.store_id
       and professional.admin_user_id = allocation.admin_user_id
       and professional.is_active = true
       and professional.archived_at is null
       and professional.good_morning_seller_enabled = true
      where allocation.store_id = settings.store_id
        and allocation.admin_user_id = settings.admin_user_id
    ) >= 2
  order by settings.store_id
  limit 1;

  if not found then
    raise exception 'Smoke individual: nenhuma loja configurada com dois participantes.';
  end if;

  insert into public.app_sessions (user_id, token_hash, expires_at)
  values (
    v_admin_user_id,
    pg_catalog.encode(
      extensions.digest(v_session_token, 'sha256'),
      'hex'
    ),
    pg_catalog.now() + interval '5 minutes'
  );

  v_before := public.lc_get_good_morning_seller_workspace(
    v_session_token,
    v_store_id
  );

  if v_before->>'individual_goal_strategy'
       is distinct from 'team_remaining_personalized_v3'
     or coalesce(
       (v_before->>'rotation_affects_individual_goals')::boolean,
       true
     ) then
    raise exception 'Smoke individual: contrato publico novo nao foi retornado.';
  end if;

  v_month_target_cents := greatest(pg_catalog.round(coalesce(
    nullif(v_before #>> '{goals,month,target}', '')::numeric,
    0
  ) * 100)::bigint, 0);
  v_month_actual_cents := greatest(pg_catalog.round(coalesce(
    nullif(v_before #>> '{goals,month,actual}', '')::numeric,
    0
  ) * 100)::bigint, 0);
  v_week_target_cents := greatest(pg_catalog.round(coalesce(
    nullif(v_before #>> '{goals,week,target}', '')::numeric,
    0
  ) * 100)::bigint, 0);
  v_week_actual_cents := greatest(pg_catalog.round(coalesce(
    nullif(v_before #>> '{goals,week,actual}', '')::numeric,
    0
  ) * 100)::bigint, 0);
  v_today_target_cents := greatest(pg_catalog.round(coalesce(
    nullif(v_before #>> '{goals,today,target}', '')::numeric,
    0
  ) * 100)::bigint, 0);
  v_today_actual_cents := greatest(pg_catalog.round(coalesce(
    nullif(v_before #>> '{goals,today,actual}', '')::numeric,
    0
  ) * 100)::bigint, 0);
  v_today_snapshot_cents := greatest(pg_catalog.round(coalesce(
    nullif(v_before->>'actual_today_before_configuration', '')::numeric,
    0
  ) * 100)::bigint, 0);
  v_today_effective_actual_cents := case
    when coalesce(
      nullif(v_before->>'configuration_actual_snapshot_active', '')::boolean,
      false
    ) then greatest(v_today_actual_cents - v_today_snapshot_cents, 0)
    else v_today_actual_cents
  end;

  v_expected_month_remaining_cents := greatest(
    v_month_target_cents - v_month_actual_cents,
    0
  );
  v_expected_week_remaining_cents := greatest(
    v_week_target_cents - v_week_actual_cents,
    0
  );
  v_expected_today_remaining_cents := greatest(
    v_today_target_cents - v_today_effective_actual_cents,
    0
  );

  v_reported_month_remaining_cents := coalesce(
    nullif(v_before #>> '{individual_remaining_totals_cents,month}', '')::bigint,
    -1
  );
  v_reported_week_remaining_cents := coalesce(
    nullif(v_before #>> '{individual_remaining_totals_cents,week}', '')::bigint,
    -1
  );
  v_reported_today_remaining_cents := coalesce(
    nullif(v_before #>> '{individual_remaining_totals_cents,today}', '')::bigint,
    -1
  );

  if v_reported_month_remaining_cents <> v_expected_month_remaining_cents
     or v_reported_week_remaining_cents <> v_expected_week_remaining_cents
     or v_reported_today_remaining_cents <> v_expected_today_remaining_cents then
    raise exception 'Smoke individual: totais publicados divergem do saldo coletivo.';
  end if;

  -- Valida fechamento, limites e presenca de todos os campos em centavos.
  select
    coalesce(pg_catalog.sum(
      (entry.value->>'remaining_month_cents')::bigint
    ) filter (
      where coalesce(
        (entry.value->>'good_morning_seller_enabled')::boolean,
        true
      )
    ), 0)::bigint,
    coalesce(pg_catalog.sum(
      (entry.value->>'remaining_week_cents')::bigint
    ) filter (
      where coalesce(
        (entry.value->>'good_morning_seller_enabled')::boolean,
        true
      )
    ), 0)::bigint,
    coalesce(pg_catalog.sum(
      (entry.value->>'remaining_today_cents')::bigint
    ) filter (
      where coalesce(
        (entry.value->>'good_morning_seller_enabled')::boolean,
        true
      )
    ), 0)::bigint,
    pg_catalog.count(*) filter (
      where entry.value->>'remaining_month_cents' is null
         or entry.value->>'remaining_week_cents' is null
         or entry.value->>'remaining_today_cents' is null
         or entry.value->>'actual_today_against_target_cents' is null
         or (entry.value->>'remaining_month_cents')::bigint < 0
         or (entry.value->>'remaining_week_cents')::bigint < 0
         or (entry.value->>'remaining_today_cents')::bigint < 0
         or (entry.value->>'actual_today_against_target_cents')::bigint < 0
         or (
           coalesce(
             (entry.value->>'good_morning_seller_enabled')::boolean,
             true
           )
           and (
             (entry.value->>'remaining_month_cents')::bigint
               > v_reported_month_remaining_cents
             or (entry.value->>'remaining_week_cents')::bigint
               > v_reported_week_remaining_cents
             or (entry.value->>'remaining_today_cents')::bigint
               > v_reported_today_remaining_cents
           )
         )
         or (
           not coalesce(
             (entry.value->>'good_morning_seller_enabled')::boolean,
             true
           )
           and (
             (entry.value->>'remaining_month_cents')::bigint <> 0
             or (entry.value->>'remaining_week_cents')::bigint <> 0
             or (entry.value->>'remaining_today_cents')::bigint <> 0
           )
         )
    )::integer
  into
    v_sum_month_remaining_cents,
    v_sum_week_remaining_cents,
    v_sum_today_remaining_cents,
    v_invalid_count
  from pg_catalog.jsonb_array_elements(v_before->'professionals') entry(value)
  ;

  if v_invalid_count <> 0
     or v_sum_month_remaining_cents <> v_reported_month_remaining_cents
     or v_sum_week_remaining_cents <> v_reported_week_remaining_cents
     or v_sum_today_remaining_cents <> v_reported_today_remaining_cents then
    raise exception 'Smoke individual: fechamento ou limite individual divergiu.';
  end if;

  -- Reproduz o incidente real sem nomes nem IDs de clientes. Ambos ainda tem
  -- deficit mensal; logo nenhum pode zerar enquanto o periodo tem saldo.
  v_exact_case := app_private.personalize_good_morning_individual_balances(
    pg_catalog.jsonb_build_object(
      'configured', true,
      'goals', pg_catalog.jsonb_build_object(
        'today', pg_catalog.jsonb_build_object('target', 3853, 'actual', 0),
        'week', pg_catalog.jsonb_build_object('target', 26160, 'actual', 18454),
        'month', pg_catalog.jsonb_build_object('target', 130800, 'actual', 18454)
      ),
      'professionals', pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object(
          'id', '00000000-0000-4000-8000-000000000001',
          'good_morning_seller_enabled', true,
          'goal_amount', 65400,
          'actual_month', 14315
        ),
        pg_catalog.jsonb_build_object(
          'id', '00000000-0000-4000-8000-000000000002',
          'good_morning_seller_enabled', true,
          'goal_amount', 65400,
          'actual_month', 4139
        )
      )
    )
  );

  if (v_exact_case #>> '{professionals,0,remaining_today_cents}')::bigint <> 175200
     or (v_exact_case #>> '{professionals,1,remaining_today_cents}')::bigint <> 210100
     or (v_exact_case #>> '{professionals,0,remaining_week_cents}')::bigint <> 350401
     or (v_exact_case #>> '{professionals,1,remaining_week_cents}')::bigint <> 420199
     or (v_exact_case #>> '{professionals,0,remaining_month_cents}')::bigint <> 5108500
     or (v_exact_case #>> '{professionals,1,remaining_month_cents}')::bigint <> 6126100
     or (v_exact_case #>> '{individual_remaining_totals_cents,today}')::bigint <> 385300
     or (v_exact_case #>> '{individual_remaining_totals_cents,week}')::bigint <> 770600
     or (v_exact_case #>> '{individual_remaining_totals_cents,month}')::bigint <> 11234600 then
    raise exception 'Smoke individual: regressao no caso financeiro de referencia.';
  end if;

  -- Uma correcao para baixo em venda anterior ao cutoff nao pode produzir
  -- realizado negativo nem reabrir saldo acima da meta exibida no card.
  v_cutoff_case := app_private.personalize_good_morning_individual_balances(
    pg_catalog.jsonb_build_object(
      'configured', true,
      'configuration_actual_snapshot_active', true,
      'actual_today_before_configuration', 80,
      'goals', pg_catalog.jsonb_build_object(
        'today', pg_catalog.jsonb_build_object('target', 100, 'actual', 50),
        'week', pg_catalog.jsonb_build_object('target', 700, 'actual', 50),
        'month', pg_catalog.jsonb_build_object('target', 3000, 'actual', 50)
      ),
      'professionals', pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object(
          'id', '00000000-0000-4000-8000-000000000001',
          'good_morning_seller_enabled', true,
          'goal_amount', 1500,
          'actual_month', 25,
          'actual_today', 25,
          'actual_today_before_configuration', 40
        ),
        pg_catalog.jsonb_build_object(
          'id', '00000000-0000-4000-8000-000000000002',
          'good_morning_seller_enabled', true,
          'goal_amount', 1500,
          'actual_month', 25,
          'actual_today', 25,
          'actual_today_before_configuration', 40
        )
      )
    )
  );

  if (v_cutoff_case #>> '{individual_remaining_totals_cents,today}')::bigint <> 10000
     or (v_cutoff_case #>> '{professionals,0,remaining_today_cents}')::bigint <> 5000
     or (v_cutoff_case #>> '{professionals,1,remaining_today_cents}')::bigint <> 5000
     or (v_cutoff_case #>> '{professionals,0,actual_today_against_target_cents}')::bigint <> 0
     or (v_cutoff_case #>> '{professionals,1,actual_today_against_target_cents}')::bigint <> 0 then
    raise exception 'Smoke individual: cutoff criou saldo acima da meta ou realizado negativo.';
  end if;

  select pg_catalog.jsonb_object_agg(
    entry.value->>'id',
    pg_catalog.jsonb_build_object(
      'month_target', entry.value->'goal_month_target_cents',
      'week_target', entry.value->'goal_week_target_cents',
      'today_target', entry.value->'goal_today_target_cents',
      'month_remaining', entry.value->'remaining_month_cents',
      'week_remaining', entry.value->'remaining_week_cents',
      'today_remaining', entry.value->'remaining_today_cents'
    )
  )
  into v_before_projection
  from pg_catalog.jsonb_array_elements(v_before->'professionals') entry(value);

  v_before_current := v_before->>'current_professional_id';
  v_after := public.lc_advance_good_morning_seller_turn(
    v_session_token,
    v_store_id
  );
  v_after_current := v_after->>'current_professional_id';

  select pg_catalog.jsonb_object_agg(
    entry.value->>'id',
    pg_catalog.jsonb_build_object(
      'month_target', entry.value->'goal_month_target_cents',
      'week_target', entry.value->'goal_week_target_cents',
      'today_target', entry.value->'goal_today_target_cents',
      'month_remaining', entry.value->'remaining_month_cents',
      'week_remaining', entry.value->'remaining_week_cents',
      'today_remaining', entry.value->'remaining_today_cents'
    )
  )
  into v_after_projection
  from pg_catalog.jsonb_array_elements(v_after->'professionals') entry(value);

  if v_after_current is not distinct from v_before_current then
    raise exception 'Smoke individual: a rotacao nao avancou no cenario de teste.';
  end if;
  if v_after->>'individual_goal_strategy'
       is distinct from 'team_remaining_personalized_v3' then
    raise exception 'Smoke individual: contrato v3 se perdeu depois da rotacao.';
  end if;
  if v_after_projection is distinct from v_before_projection then
    raise exception 'Smoke individual: girar a vez alterou metas ou saldos.';
  end if;

  if not pg_catalog.has_function_privilege(
       'authenticated',
       'public.lc_get_good_morning_seller_workspace(text,uuid)',
       'EXECUTE'
     ) then
    raise exception 'Smoke individual: ACL publica inesperada.';
  end if;
end;
$integration$;

rollback;
