-- Regressao: uma compra gravada hoje com data operacional no mes anterior
-- nunca pode alterar os realizados ou metas do Bom Dia Vendedor deste mes.
-- Todas as gravacoes abaixo sao revertidas no final.

begin;

do $retroactive_month_boundary$
declare
  v_admin_user_id uuid;
  v_store_id uuid;
  v_professional_id uuid;
  v_professional_name text;
  v_session_token text := 'qa-retroactive-' || extensions.gen_random_uuid()::text;
  v_random_suffix text := pg_catalog.translate(
    pg_catalog.substring(
      pg_catalog.md5(extensions.gen_random_uuid()::text),
      1,
      8
    ),
    'abcdef',
    '123456'
  );
  v_phone text;
  v_current_phone text;
  v_today date := pg_catalog.timezone(
    'America/Sao_Paulo', pg_catalog.now()
  )::date;
  v_previous_month_day date := (
    pg_catalog.date_trunc(
      'month',
      pg_catalog.timezone('America/Sao_Paulo', pg_catalog.now())
    )::date - 1
  );
  v_before jsonb;
  v_after jsonb;
  v_saved jsonb;
  v_attendance_id uuid;
  v_persisted_day date;
  v_before_month_cents bigint;
  v_before_week_cents bigint;
  v_before_today_cents bigint;
  v_after_month_cents bigint;
  v_after_week_cents bigint;
  v_after_today_cents bigint;
  v_before_professional_month_cents bigint;
  v_before_professional_week_cents bigint;
  v_before_professional_today_cents bigint;
  v_after_professional_month_cents bigint;
  v_after_professional_week_cents bigint;
  v_after_professional_today_cents bigint;
  v_before_month_target_cents bigint;
  v_before_week_target_cents bigint;
  v_before_today_target_cents bigint;
  v_current_saved jsonb;
  v_current_workspace jsonb;
  v_moved_workspace jsonb;
  v_restored_workspace jsonb;
  v_current_attendance_id uuid;
  v_expected_updated_at timestamptz;
  v_current_created_at timestamptz;
  v_error text;
  v_error_state text;
begin
  select
    settings.admin_user_id,
    settings.store_id,
    professional.id,
    professional.name
  into
    v_admin_user_id,
    v_store_id,
    v_professional_id,
    v_professional_name
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
  join public.prospection_professionals professional
    on professional.store_id = settings.store_id
   and professional.admin_user_id = settings.admin_user_id
   and professional.is_active = true
   and professional.archived_at is null
   and professional.good_morning_seller_enabled = true
  order by exists (
    select 1
    from public.attendances prior_attendance
    where prior_attendance.store_id = settings.store_id
      and prior_attendance.admin_user_id = settings.admin_user_id
      and prior_attendance.tag = 'purchase'
      and prior_attendance.attended_at < (
        pg_catalog.date_trunc(
          'month',
          pg_catalog.timezone('America/Sao_Paulo', pg_catalog.now())
        )::date::timestamp at time zone 'America/Sao_Paulo'
      )
  ) desc,
  settings.store_id,
  professional.created_at,
  professional.id
  limit 1;

  if not found then
    raise exception 'QA retroativo: loja/profissional licenciado nao encontrado.';
  end if;

  v_phone := '119' || v_random_suffix;
  v_current_phone := '118' || v_random_suffix;

  insert into public.app_sessions (user_id, token_hash, expires_at)
  values (
    v_admin_user_id,
    pg_catalog.encode(
      extensions.digest(v_session_token, 'sha256'),
      'hex'
    ),
    pg_catalog.now() + interval '5 minutes'
  );

  -- Depois da migration de data obrigatoria, NULL explicito no cadastro V3
  -- precisa falhar antes de qualquer fallback silencioso para o dia atual.
  if pg_catalog.to_regprocedure(
       'app_private.rpc_upsert_attendance_v3_required_date(text,uuid,text,text,text,text,text,text,numeric,numeric,text,date,text)'
     ) is not null then
    v_error := null;
    v_error_state := null;
    begin
      perform public.lc_upsert_attendance_v3(
        p_session_token => v_session_token,
        p_store_id => v_store_id,
        p_professional_name => v_professional_name,
        p_customer_name => 'QA data obrigatoria',
        p_phone => v_phone,
        p_cpf => null,
        p_description => 'NULL explicito nao pode virar atendimento de hoje',
        p_tag => 'purchase',
        p_service_value => 123.45,
        p_purchase_value => 123.45,
        p_service_order => 'QA-NULL-' || extensions.gen_random_uuid()::text,
        p_attended_on => null,
        p_idempotency_key => 'qa-null-' || extensions.gen_random_uuid()::text
      );
    exception when others then
      get stacked diagnostics
        v_error = message_text,
        v_error_state = returned_sqlstate;
    end;
    if v_error_state is distinct from '22004'
       or v_error not like '%data%atendimento%' then
      raise exception 'QA retroativo: NULL explicito no cadastro nao foi rejeitado: [%] %.',
        coalesce(v_error_state, 'sem SQLSTATE'),
        coalesce(v_error, 'sem erro');
    end if;
  end if;

  v_before := public.lc_get_good_morning_seller_workspace(
    v_session_token,
    v_store_id
  );

  v_before_month_cents := pg_catalog.round(
    coalesce((v_before #>> '{goals,month,actual}')::numeric, 0) * 100
  )::bigint;
  v_before_week_cents := pg_catalog.round(
    coalesce((v_before #>> '{goals,week,actual}')::numeric, 0) * 100
  )::bigint;
  v_before_today_cents := pg_catalog.round(
    coalesce((v_before #>> '{goals,today,actual}')::numeric, 0) * 100
  )::bigint;
  v_before_month_target_cents := pg_catalog.round(
    coalesce((v_before #>> '{goals,month,target}')::numeric, 0) * 100
  )::bigint;
  v_before_week_target_cents := pg_catalog.round(
    coalesce((v_before #>> '{goals,week,target}')::numeric, 0) * 100
  )::bigint;
  v_before_today_target_cents := pg_catalog.round(
    coalesce((v_before #>> '{goals,today,target}')::numeric, 0) * 100
  )::bigint;

  select
    coalesce(pg_catalog.sum(
      pg_catalog.round((entry.value->>'actual_month')::numeric * 100)::bigint
    ) filter (
      where entry.value->>'id' = v_professional_id::text
    ), 0)::bigint,
    coalesce(pg_catalog.sum(
      pg_catalog.round((entry.value->>'actual_week')::numeric * 100)::bigint
    ) filter (
      where entry.value->>'id' = v_professional_id::text
    ), 0)::bigint,
    coalesce(pg_catalog.sum(
      pg_catalog.round((entry.value->>'actual_today')::numeric * 100)::bigint
    ) filter (
      where entry.value->>'id' = v_professional_id::text
    ), 0)::bigint
  into
    v_before_professional_month_cents,
    v_before_professional_week_cents,
    v_before_professional_today_cents
  from pg_catalog.jsonb_array_elements(v_before->'professionals') entry(value);

  v_saved := public.lc_upsert_attendance_v3(
    v_session_token,
    v_store_id,
    v_professional_name,
    'QA limite de mes',
    v_phone,
    null,
    'Compra retroativa criada por teste transacional',
    'purchase',
    123.45,
    123.45,
    'QA-RETRO-' || extensions.gen_random_uuid()::text,
    v_previous_month_day,
    'qa-retro-' || extensions.gen_random_uuid()::text
  );

  v_attendance_id := nullif(v_saved #>> '{attendance,id}', '')::uuid;
  if v_attendance_id is null then
    raise exception 'QA retroativo: RPC nao retornou o atendimento criado: %', v_saved;
  end if;

  select pg_catalog.timezone(
    'America/Sao_Paulo', attendance.attended_at
  )::date
  into v_persisted_day
  from public.attendances attendance
  where attendance.id = v_attendance_id
    and attendance.store_id = v_store_id
    and attendance.admin_user_id = v_admin_user_id;

  if v_persisted_day is distinct from v_previous_month_day then
    raise exception 'QA retroativo: data persistida %, esperada %.',
      v_persisted_day,
      v_previous_month_day;
  end if;

  v_after := public.lc_get_good_morning_seller_workspace(
    v_session_token,
    v_store_id
  );

  v_after_month_cents := pg_catalog.round(
    coalesce((v_after #>> '{goals,month,actual}')::numeric, 0) * 100
  )::bigint;
  v_after_week_cents := pg_catalog.round(
    coalesce((v_after #>> '{goals,week,actual}')::numeric, 0) * 100
  )::bigint;
  v_after_today_cents := pg_catalog.round(
    coalesce((v_after #>> '{goals,today,actual}')::numeric, 0) * 100
  )::bigint;

  select
    coalesce(pg_catalog.sum(
      pg_catalog.round((entry.value->>'actual_month')::numeric * 100)::bigint
    ) filter (
      where entry.value->>'id' = v_professional_id::text
    ), 0)::bigint,
    coalesce(pg_catalog.sum(
      pg_catalog.round((entry.value->>'actual_week')::numeric * 100)::bigint
    ) filter (
      where entry.value->>'id' = v_professional_id::text
    ), 0)::bigint,
    coalesce(pg_catalog.sum(
      pg_catalog.round((entry.value->>'actual_today')::numeric * 100)::bigint
    ) filter (
      where entry.value->>'id' = v_professional_id::text
    ), 0)::bigint
  into
    v_after_professional_month_cents,
    v_after_professional_week_cents,
    v_after_professional_today_cents
  from pg_catalog.jsonb_array_elements(v_after->'professionals') entry(value);

  if v_after_month_cents is distinct from v_before_month_cents
     or v_after_week_cents is distinct from v_before_week_cents
     or v_after_today_cents is distinct from v_before_today_cents
     or v_after_professional_month_cents
       is distinct from v_before_professional_month_cents
     or v_after_professional_week_cents
       is distinct from v_before_professional_week_cents
     or v_after_professional_today_cents
       is distinct from v_before_professional_today_cents then
    raise exception 'QA retroativo: compra do mes anterior vazou para o mes atual. Antes %, depois %.',
      v_before,
      v_after;
  end if;

  -- Cria uma compra de hoje: mes, semana, dia e profissional precisam subir
  -- exatamente R$ 123,45. Os alvos nao mudam durante o expediente.
  v_current_saved := public.lc_upsert_attendance_v3(
    p_session_token => v_session_token,
    p_store_id => v_store_id,
    p_professional_name => v_professional_name,
    p_customer_name => 'QA movimento entre meses',
    p_phone => v_current_phone,
    p_cpf => null,
    p_description => 'Compra atual movida entre meses por teste transacional',
    p_tag => 'purchase',
    p_service_value => 123.45,
    p_purchase_value => 123.45,
    p_service_order => 'QA-MOVE-' || extensions.gen_random_uuid()::text,
    p_attended_on => v_today,
    p_idempotency_key => 'qa-move-' || extensions.gen_random_uuid()::text
  );

  v_current_attendance_id := nullif(
    v_current_saved #>> '{attendance,id}',
    ''
  )::uuid;
  if v_current_attendance_id is null then
    raise exception 'QA edicao de mes: RPC nao retornou a compra atual: %',
      v_current_saved;
  end if;

  select attendance.updated_at, attendance.created_at
  into v_expected_updated_at, v_current_created_at
  from public.attendances attendance
  where attendance.id = v_current_attendance_id
    and attendance.store_id = v_store_id
    and attendance.admin_user_id = v_admin_user_id;

  v_current_workspace := public.lc_get_good_morning_seller_workspace(
    v_session_token,
    v_store_id
  );

  select
    coalesce(pg_catalog.sum(
      pg_catalog.round((entry.value->>'actual_month')::numeric * 100)::bigint
    ) filter (
      where entry.value->>'id' = v_professional_id::text
    ), 0)::bigint,
    coalesce(pg_catalog.sum(
      pg_catalog.round((entry.value->>'actual_week')::numeric * 100)::bigint
    ) filter (
      where entry.value->>'id' = v_professional_id::text
    ), 0)::bigint,
    coalesce(pg_catalog.sum(
      pg_catalog.round((entry.value->>'actual_today')::numeric * 100)::bigint
    ) filter (
      where entry.value->>'id' = v_professional_id::text
    ), 0)::bigint
  into
    v_after_professional_month_cents,
    v_after_professional_week_cents,
    v_after_professional_today_cents
  from pg_catalog.jsonb_array_elements(
    v_current_workspace->'professionals'
  ) entry(value);

  if pg_catalog.round(
       coalesce((v_current_workspace #>> '{goals,month,actual}')::numeric, 0) * 100
     )::bigint <> v_before_month_cents + 12345
     or pg_catalog.round(
       coalesce((v_current_workspace #>> '{goals,week,actual}')::numeric, 0) * 100
     )::bigint <> v_before_week_cents + 12345
     or pg_catalog.round(
       coalesce((v_current_workspace #>> '{goals,today,actual}')::numeric, 0) * 100
     )::bigint <> v_before_today_cents + 12345
     or v_after_professional_month_cents
       <> v_before_professional_month_cents + 12345
     or v_after_professional_week_cents
       <> v_before_professional_week_cents + 12345
     or v_after_professional_today_cents
       <> v_before_professional_today_cents + 12345 then
    raise exception 'QA edicao de mes: compra atual nao somou 123,45 em todos os realizados. Antes %, depois %.',
      v_before,
      v_current_workspace;
  end if;

  if pg_catalog.round(
       coalesce((v_current_workspace #>> '{goals,month,target}')::numeric, 0) * 100
     )::bigint <> v_before_month_target_cents
     or pg_catalog.round(
       coalesce((v_current_workspace #>> '{goals,week,target}')::numeric, 0) * 100
     )::bigint <> v_before_week_target_cents
     or pg_catalog.round(
       coalesce((v_current_workspace #>> '{goals,today,target}')::numeric, 0) * 100
     )::bigint <> v_before_today_target_cents then
    raise exception 'QA edicao de mes: compra de hoje moveu os alvos durante o expediente.';
  end if;

  -- Move a mesma compra para o ultimo dia do mes anterior. A data de criacao
  -- permanece atual, mas todos os realizados deste mes voltam ao baseline.
  perform public.lc_update_attendance_v1(
    p_session_token => v_session_token,
    p_attendance_id => v_current_attendance_id,
    p_store_id => v_store_id,
    p_professional_name => v_professional_name,
    p_attended_on => v_previous_month_day,
    p_customer_name => 'QA movimento entre meses',
    p_phone => v_current_phone,
    p_cpf => null,
    p_description => 'Compra atual movida entre meses por teste transacional',
    p_tag => 'purchase',
    p_service_value => 123.45,
    p_purchase_value => 123.45,
    p_service_order => v_current_saved #>> '{attendance,service_order}',
    p_expected_updated_at => v_expected_updated_at
  );

  select attendance.updated_at
  into v_expected_updated_at
  from public.attendances attendance
  where attendance.id = v_current_attendance_id;

  v_moved_workspace := public.lc_get_good_morning_seller_workspace(
    v_session_token,
    v_store_id
  );

  select
    coalesce(pg_catalog.sum(
      pg_catalog.round((entry.value->>'actual_month')::numeric * 100)::bigint
    ) filter (
      where entry.value->>'id' = v_professional_id::text
    ), 0)::bigint,
    coalesce(pg_catalog.sum(
      pg_catalog.round((entry.value->>'actual_week')::numeric * 100)::bigint
    ) filter (
      where entry.value->>'id' = v_professional_id::text
    ), 0)::bigint,
    coalesce(pg_catalog.sum(
      pg_catalog.round((entry.value->>'actual_today')::numeric * 100)::bigint
    ) filter (
      where entry.value->>'id' = v_professional_id::text
    ), 0)::bigint
  into
    v_after_professional_month_cents,
    v_after_professional_week_cents,
    v_after_professional_today_cents
  from pg_catalog.jsonb_array_elements(
    v_moved_workspace->'professionals'
  ) entry(value);

  if pg_catalog.round(
       coalesce((v_moved_workspace #>> '{goals,month,actual}')::numeric, 0) * 100
     )::bigint <> v_before_month_cents
     or pg_catalog.round(
       coalesce((v_moved_workspace #>> '{goals,week,actual}')::numeric, 0) * 100
     )::bigint <> v_before_week_cents
     or pg_catalog.round(
       coalesce((v_moved_workspace #>> '{goals,today,actual}')::numeric, 0) * 100
     )::bigint <> v_before_today_cents
     or v_after_professional_month_cents <> v_before_professional_month_cents
     or v_after_professional_week_cents <> v_before_professional_week_cents
     or v_after_professional_today_cents <> v_before_professional_today_cents then
    raise exception 'QA edicao de mes: mover para o mes anterior nao removeu 123,45 de todos os realizados. Antes %, depois %.',
      v_before,
      v_moved_workspace;
  end if;

  if not exists (
       select 1
       from public.attendances attendance
       where attendance.id = v_current_attendance_id
         and attendance.created_at = v_current_created_at
         and pg_catalog.timezone(
           'America/Sao_Paulo', attendance.attended_at
         )::date = v_previous_month_day
     ) then
    raise exception 'QA edicao de mes: data operacional ou created_at foi alterado incorretamente.';
  end if;

  -- Null explicito deve falhar, sem converter silenciosamente para hoje.
  v_error := null;
  begin
    perform public.lc_update_attendance_v1(
      p_session_token => v_session_token,
      p_attendance_id => v_current_attendance_id,
      p_store_id => v_store_id,
      p_professional_name => v_professional_name,
      p_attended_on => null,
      p_customer_name => 'QA movimento entre meses',
      p_phone => v_current_phone,
      p_cpf => null,
      p_description => 'Compra atual movida entre meses por teste transacional',
      p_tag => 'purchase',
      p_service_value => 123.45,
      p_purchase_value => 123.45,
      p_service_order => v_current_saved #>> '{attendance,service_order}',
      p_expected_updated_at => v_expected_updated_at
    );
  exception when others then
    v_error := sqlerrm;
  end;
  if v_error is null or v_error not like '%data do atendimento%' then
    raise exception 'QA edicao de mes: data NULL nao foi rejeitada corretamente: %',
      coalesce(v_error, 'sem erro');
  end if;

  -- Move de volta para hoje. O mesmo valor precisa reaparecer exatamente uma
  -- vez na equipe e no profissional, sem alterar created_at nem os alvos.
  perform public.lc_update_attendance_v1(
    p_session_token => v_session_token,
    p_attendance_id => v_current_attendance_id,
    p_store_id => v_store_id,
    p_professional_name => v_professional_name,
    p_attended_on => v_today,
    p_customer_name => 'QA movimento entre meses',
    p_phone => v_current_phone,
    p_cpf => null,
    p_description => 'Compra atual movida entre meses por teste transacional',
    p_tag => 'purchase',
    p_service_value => 123.45,
    p_purchase_value => 123.45,
    p_service_order => v_current_saved #>> '{attendance,service_order}',
    p_expected_updated_at => v_expected_updated_at
  );

  v_restored_workspace := public.lc_get_good_morning_seller_workspace(
    v_session_token,
    v_store_id
  );

  select
    coalesce(pg_catalog.sum(
      pg_catalog.round((entry.value->>'actual_month')::numeric * 100)::bigint
    ) filter (
      where entry.value->>'id' = v_professional_id::text
    ), 0)::bigint,
    coalesce(pg_catalog.sum(
      pg_catalog.round((entry.value->>'actual_week')::numeric * 100)::bigint
    ) filter (
      where entry.value->>'id' = v_professional_id::text
    ), 0)::bigint,
    coalesce(pg_catalog.sum(
      pg_catalog.round((entry.value->>'actual_today')::numeric * 100)::bigint
    ) filter (
      where entry.value->>'id' = v_professional_id::text
    ), 0)::bigint
  into
    v_after_professional_month_cents,
    v_after_professional_week_cents,
    v_after_professional_today_cents
  from pg_catalog.jsonb_array_elements(
    v_restored_workspace->'professionals'
  ) entry(value);

  if pg_catalog.round(
       coalesce((v_restored_workspace #>> '{goals,month,actual}')::numeric, 0) * 100
     )::bigint <> v_before_month_cents + 12345
     or pg_catalog.round(
       coalesce((v_restored_workspace #>> '{goals,week,actual}')::numeric, 0) * 100
     )::bigint <> v_before_week_cents + 12345
     or pg_catalog.round(
       coalesce((v_restored_workspace #>> '{goals,today,actual}')::numeric, 0) * 100
     )::bigint <> v_before_today_cents + 12345
     or v_after_professional_month_cents
       <> v_before_professional_month_cents + 12345
     or v_after_professional_week_cents
       <> v_before_professional_week_cents + 12345
     or v_after_professional_today_cents
       <> v_before_professional_today_cents + 12345 then
    raise exception 'QA edicao de mes: mover de volta para hoje nao restaurou exatamente 123,45. Antes %, depois %.',
      v_before,
      v_restored_workspace;
  end if;

  if pg_catalog.round(
       coalesce((v_restored_workspace #>> '{goals,month,target}')::numeric, 0) * 100
     )::bigint <> v_before_month_target_cents
     or pg_catalog.round(
       coalesce((v_restored_workspace #>> '{goals,week,target}')::numeric, 0) * 100
     )::bigint <> v_before_week_target_cents
     or pg_catalog.round(
       coalesce((v_restored_workspace #>> '{goals,today,target}')::numeric, 0) * 100
     )::bigint <> v_before_today_target_cents
     or not exists (
       select 1
       from public.attendances attendance
       where attendance.id = v_current_attendance_id
         and attendance.created_at = v_current_created_at
         and pg_catalog.timezone(
           'America/Sao_Paulo', attendance.attended_at
         )::date = v_today
     ) then
    raise exception 'QA edicao de mes: restauracao moveu alvo, created_at ou data operacional.';
  end if;
end;
$retroactive_month_boundary$;

rollback;
