-- Executar depois de aplicar
-- 20260904123948_personalize_good_morning_individual_balances.sql.
-- Usa uma sessao administrativa efemera, gira a rotacao e reverte tudo.

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
       is distinct from 'own_remaining_balance_v2'
     or coalesce(
       (v_before->>'rotation_affects_individual_goals')::boolean,
       true
     ) then
    raise exception 'Smoke individual: contrato publico novo nao foi retornado.';
  end if;

  -- Valida todas as identidades monetarias diretamente em centavos.
  select pg_catalog.count(*)::integer
  into v_invalid_count
  from pg_catalog.jsonb_array_elements(v_before->'professionals') entry(value)
  where coalesce(
          (entry.value->>'good_morning_seller_enabled')::boolean,
          true
        )
    and (
      (entry.value->>'remaining_month_cents')::bigint is distinct from
        greatest(
          (entry.value->>'goal_month_target_cents')::bigint
            - pg_catalog.round(
              coalesce((entry.value->>'actual_month')::numeric, 0) * 100
            )::bigint,
          0
        )
      or (entry.value->>'remaining_week_cents')::bigint is distinct from
        greatest(
          (entry.value->>'goal_week_target_cents')::bigint
            - pg_catalog.round(
              coalesce((entry.value->>'actual_week')::numeric, 0) * 100
            )::bigint,
          0
        )
      or (entry.value->>'remaining_today_cents')::bigint is distinct from
        greatest(
          (entry.value->>'goal_today_target_cents')::bigint
            - (entry.value->>'actual_today_against_target_cents')::bigint,
          0
        )
    );

  if v_invalid_count <> 0 then
    raise exception 'Smoke individual: alguma identidade de saldo divergiu.';
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
