-- Executar depois de aplicar 20260901205903_good_morning_midmonth_historical_actuals.sql.
-- O teste nao persiste dados. A parte publica usa uma sessao efemera para uma
-- loja licenciada existente e reverte tudo na mesma transacao.

begin;

do $smoke$
declare
  v_workspace jsonb;
  v_result jsonb;
  v_sum_week numeric;
  v_sum_today numeric;
begin
  if pg_catalog.to_regprocedure(
       'public.lc_get_good_morning_seller_workspace(text,uuid)'
     ) is null
     or pg_catalog.to_regprocedure(
       'public.lc_save_good_morning_seller_settings_v2(text,uuid,numeric,text,jsonb,jsonb)'
     ) is null
     or pg_catalog.to_regprocedure(
       'app_private.capture_good_morning_actuals_cents(uuid,uuid,date,timestamptz)'
     ) is null
     or pg_catalog.to_regprocedure(
       'app_private.refresh_good_morning_historical_actuals(text,uuid,jsonb)'
     ) is null
     or pg_catalog.to_regprocedure(
       'app_private.rebalance_good_morning_with_configuration_cutoff(jsonb)'
     ) is null then
    raise exception 'Smoke snapshot: contrato SQL incompleto.';
  end if;

  v_workspace := pg_catalog.jsonb_build_object(
    'configured', true,
    'configuration_actual_snapshot_active', true,
    'today', '2026-09-16',
    'week_start', '2026-09-14',
    'week_end', '2026-09-20',
    'monthly_goal', 26000,
    'closed_days', '[]'::jsonb,
    'actual_month_at_configuration', 9000,
    'actual_week_at_configuration', 3000,
    'actual_today_before_configuration', 1000,
    'goals', pg_catalog.jsonb_build_object(
      'month', pg_catalog.jsonb_build_object('target', 26000, 'actual', 9000),
      'week', pg_catalog.jsonb_build_object('target', 0, 'actual', 3000),
      'today', pg_catalog.jsonb_build_object('target', 0, 'actual', 1000)
    ),
    'professionals', pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object(
        'id', '00000000-0000-4000-8000-000000000001',
        'good_morning_seller_enabled', true,
        'goal_month', 13000,
        'actual_month', 4500,
        'actual_week', 1500,
        'actual_today', 700,
        'actual_month_at_configuration', 4500,
        'actual_week_at_configuration', 1500,
        'actual_today_before_configuration', 700
      ),
      pg_catalog.jsonb_build_object(
        'id', '00000000-0000-4000-8000-000000000002',
        'good_morning_seller_enabled', true,
        'goal_month', 13000,
        'actual_month', 4500,
        'actual_week', 1500,
        'actual_today', 300,
        'actual_month_at_configuration', 4500,
        'actual_week_at_configuration', 1500,
        'actual_today_before_configuration', 300
      )
    )
  );

  v_result := app_private.rebalance_good_morning_with_configuration_cutoff(
    v_workspace
  );

  select
    coalesce(pg_catalog.sum((entry.value->>'goal_week')::numeric), 0),
    coalesce(pg_catalog.sum((entry.value->>'goal_today')::numeric), 0)
  into v_sum_week, v_sum_today
  from pg_catalog.jsonb_array_elements(v_result->'professionals') entry(value);

  if (v_result #>> '{goals,week,target}')::numeric <> 8000
     or (v_result #>> '{goals,today,target}')::numeric <> 1250
     or (v_result #>> '{goals,today,actual}')::numeric <> 1000
     or v_sum_week <> 8000
     or v_sum_today <> 1250 then
    raise exception 'Smoke snapshot: alvo inicial ou soma individual incorretos: %',
      v_result;
  end if;

  -- Simula edicao de valor/tag/data/profissional depois da configuracao.
  -- Somente os actuals exibidos mudam; snapshots e alvos ficam imutaveis.
  v_workspace := v_workspace || pg_catalog.jsonb_build_object(
    'goals', pg_catalog.jsonb_build_object(
      'month', pg_catalog.jsonb_build_object('target', 26000, 'actual', 8400),
      'week', pg_catalog.jsonb_build_object('target', 0, 'actual', 2400),
      'today', pg_catalog.jsonb_build_object('target', 0, 'actual', 400)
    ),
    'professionals', pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object(
        'id', '00000000-0000-4000-8000-000000000001',
        'good_morning_seller_enabled', true,
        'goal_month', 13000,
        'actual_month', 2000,
        'actual_week', 100,
        'actual_today', 0,
        'actual_month_at_configuration', 4500,
        'actual_week_at_configuration', 1500,
        'actual_today_before_configuration', 700
      ),
      pg_catalog.jsonb_build_object(
        'id', '00000000-0000-4000-8000-000000000002',
        'good_morning_seller_enabled', true,
        'goal_month', 13000,
        'actual_month', 6400,
        'actual_week', 2300,
        'actual_today', 400,
        'actual_month_at_configuration', 4500,
        'actual_week_at_configuration', 1500,
        'actual_today_before_configuration', 300
      )
    )
  );
  v_result := app_private.rebalance_good_morning_with_configuration_cutoff(
    v_workspace
  );
  if (v_result #>> '{goals,week,target}')::numeric <> 8000
     or (v_result #>> '{goals,today,target}')::numeric <> 1250
     or (v_result #>> '{goals,month,actual}')::numeric <> 8400
     or (v_result #>> '{professionals,0,goal_today}')::numeric <> 625
     or (v_result #>> '{professionals,1,goal_today}')::numeric <> 625 then
    raise exception 'Smoke snapshot: edicao moveu alvo ou congelou realizado.';
  end if;

  -- No dia seguinte o snapshot nao participa mais do calculo.
  v_workspace := v_workspace || pg_catalog.jsonb_build_object(
    'configuration_actual_snapshot_active', false,
    'today', '2026-09-17',
    'goals', pg_catalog.jsonb_build_object(
      'month', pg_catalog.jsonb_build_object('target', 26000, 'actual', 9500),
      'week', pg_catalog.jsonb_build_object('target', 0, 'actual', 3500),
      'today', pg_catalog.jsonb_build_object('target', 0, 'actual', 0)
    )
  );
  v_result := app_private.rebalance_good_morning_with_configuration_cutoff(
    v_workspace
  );
  if (v_result #>> '{goals,today,target}')::numeric <> 1500 then
    raise exception 'Smoke snapshot: dia seguinte nao usou realizado vivo.';
  end if;

  if pg_catalog.has_function_privilege(
       'anon',
       'app_private.capture_good_morning_actuals_cents(uuid,uuid,date,timestamptz)',
       'EXECUTE'
     )
     or pg_catalog.has_function_privilege(
       'authenticated',
       'app_private.capture_good_morning_actuals_cents(uuid,uuid,date,timestamptz)',
       'EXECUTE'
     )
     or not pg_catalog.has_function_privilege(
       'authenticated',
       'public.lc_get_good_morning_seller_workspace(text,uuid)',
       'EXECUTE'
     ) then
    raise exception 'Smoke snapshot: ACL inesperada.';
  end if;
end;
$smoke$;

-- Percorre a RPC publica com uma sessao administrativa efemera e uma loja
-- real licenciada. A transacao inteira e revertida no fim deste arquivo.
do $integration$
declare
  v_admin_user_id uuid;
  v_store_id uuid;
  v_session_token text := 'qa-good-morning-' || extensions.gen_random_uuid()::text;
  v_workspace jsonb;
  v_today date;
  v_month_start date;
  v_month_end date;
  v_month_actual_cents bigint := 0;
  v_week_actual_cents bigint := 0;
  v_today_actual_cents bigint := 0;
  v_professional_week_target_cents bigint := 0;
  v_professional_today_target_cents bigint := 0;
begin
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
  order by settings.store_id
  limit 1;

  if not found then
    raise exception 'Smoke integracao: nenhuma loja real licenciada foi encontrada.';
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

  v_workspace := public.lc_get_good_morning_seller_workspace(
    v_session_token,
    v_store_id
  );

  if coalesce((v_workspace->>'licensed')::boolean, false) is not true
     or v_workspace->>'goal_strategy'
       is distinct from 'hierarchical_weekly_daily_team_balance_v1'
     or v_workspace->>'configuration_actual_snapshot_strategy'
       is distinct from 'immutable_month_week_today_cents_v1'
     or coalesce(
       (v_workspace->>'historical_actuals_include_preconfiguration')::boolean,
       false
     ) is not true then
    raise exception 'Smoke integracao: contrato publico incompleto: %', v_workspace;
  end if;

  v_today := (v_workspace->>'today')::date;
  v_month_start := pg_catalog.date_trunc('month', v_today)::date;
  v_month_end := (v_month_start + interval '1 month')::date;

  select
    coalesce(pg_catalog.sum(
      pg_catalog.round(attendance.purchase_value * 100)::bigint
    ), 0)::bigint,
    coalesce(pg_catalog.sum(
      pg_catalog.round(attendance.purchase_value * 100)::bigint
    ) filter (
      where pg_catalog.timezone(
        'America/Sao_Paulo', attendance.attended_at
      )::date between (v_workspace->>'week_start')::date
        and (v_workspace->>'week_end')::date
    ), 0)::bigint,
    coalesce(pg_catalog.sum(
      pg_catalog.round(attendance.purchase_value * 100)::bigint
    ) filter (
      where pg_catalog.timezone(
        'America/Sao_Paulo', attendance.attended_at
      )::date = v_today
    ), 0)::bigint
  into v_month_actual_cents, v_week_actual_cents, v_today_actual_cents
  from public.attendances attendance
  where attendance.store_id = v_store_id
    and attendance.admin_user_id = v_admin_user_id
    and attendance.tag = 'purchase'
    and attendance.purchase_value > 0
    and attendance.attended_at >= (
      v_month_start::timestamp at time zone 'America/Sao_Paulo'
    )
    and attendance.attended_at < (
      v_month_end::timestamp at time zone 'America/Sao_Paulo'
    );

  if pg_catalog.round(
       coalesce((v_workspace #>> '{goals,month,actual}')::numeric, 0) * 100
     )::bigint <> v_month_actual_cents
     or pg_catalog.round(
       coalesce((v_workspace #>> '{goals,week,actual}')::numeric, 0) * 100
     )::bigint <> v_week_actual_cents
     or pg_catalog.round(
       coalesce((v_workspace #>> '{goals,today,actual}')::numeric, 0) * 100
     )::bigint <> v_today_actual_cents then
    raise exception 'Smoke integracao: realizado publico diverge dos atendimentos.';
  end if;

  select
    coalesce(pg_catalog.sum(
      pg_catalog.round((entry.value->>'goal_week')::numeric * 100)::bigint
    ), 0)::bigint,
    coalesce(pg_catalog.sum(
      pg_catalog.round((entry.value->>'goal_today')::numeric * 100)::bigint
    ), 0)::bigint
  into v_professional_week_target_cents, v_professional_today_target_cents
  from pg_catalog.jsonb_array_elements(v_workspace->'professionals') entry(value);

  if v_professional_week_target_cents <> pg_catalog.round(
       coalesce((v_workspace #>> '{goals,week,target}')::numeric, 0) * 100
     )::bigint
     or v_professional_today_target_cents <> pg_catalog.round(
       coalesce((v_workspace #>> '{goals,today,target}')::numeric, 0) * 100
     )::bigint then
    raise exception 'Smoke integracao: metas individuais nao fecham o total publico.';
  end if;
end;
$integration$;

rollback;
