-- Smoke test transacional para lc_update_attendance_v1.
--
-- Pre-requisito: migrations aplicadas ate
-- 20260901195142_attendance_full_record_edit.sql.
--
-- O teste usa somente dados comerciais sinteticos. Quando ja existe um Admin,
-- reaproveita apenas seu UUID para respeitar a regra de Admin unico; sessoes,
-- lojas, usuarios, profissionais, clientes e atendimentos sao temporarios.
-- Toda alteracao e revertida pelo ROLLBACK final.

begin;

set local lock_timeout = '10s';
set local statement_timeout = '120s';
select pg_catalog.set_config('app.legal_gate_bypass', 'on', true);

do $attendance_edit_smoke$
declare
  v_run_id uuid := extensions.gen_random_uuid();
  v_suffix text;
  v_today date := pg_catalog.timezone(
    'America/Sao_Paulo', pg_catalog.clock_timestamp()
  )::date;
  v_admin_id uuid;
  v_store_user_id uuid;
  v_store_a uuid;
  v_store_b uuid;
  v_attendant_a uuid;
  v_attendant_b uuid;
  v_prospector uuid;
  v_prospection_id uuid;
  v_sibling_prospection_id uuid;
  v_v2_prospection_id uuid;
  v_full_attendance_id uuid;
  v_bonus_attendance_id uuid;
  v_duplicate_attendance_id uuid;
  v_source_attendance_id uuid;
  v_sibling_attendance_id uuid;
  v_v2_attendance_id uuid;
  v_audit_id uuid;
  v_admin_token text;
  v_store_token text;
  v_full_key text;
  v_bonus_key text;
  v_duplicate_key text;
  v_source_key text;
  v_sibling_key text;
  v_v2_key text;
  v_created_at timestamptz;
  v_updated_at timestamptz;
  v_stale_updated_at timestamptz;
  v_idempotency_key text;
  v_request_fingerprint text;
  v_error text;
  v_result jsonb;
  v_effective_bonus_count bigint;
  v_effective_bonus_total numeric;
  v_metrics jsonb;
  v_record public.attendances%rowtype;
  v_sibling_record public.attendances%rowtype;
  v_projection public.prospections%rowtype;
begin
  v_suffix := pg_catalog.replace(v_run_id::text, '-', '');
  v_admin_token := 'qa-attendance-admin-' || v_suffix;
  v_store_token := 'qa-attendance-store-' || v_suffix;
  v_full_key := 'qa-attendance-full-' || v_suffix;
  v_bonus_key := 'qa-attendance-bonus-' || v_suffix;
  v_duplicate_key := 'qa-attendance-duplicate-' || v_suffix;
  v_source_key := 'qa-attendance-source-' || v_suffix;
  v_sibling_key := 'qa-attendance-sibling-' || v_suffix;
  v_v2_key := 'qa-attendance-v2-' || v_suffix;

  -- A instalacao admite um unico Admin. Nenhum dado pessoal e lido: somente
  -- o UUID tecnico necessario para manter o isolamento de tenant.
  select users.id
  into v_admin_id
  from public.app_users users
  where users.role::text = 'admin'
  order by users.created_at, users.id
  limit 1;

  if v_admin_id is null then
    insert into public.app_users (
      nick, nick_key, password_hash, full_name, role, is_active
    ) values (
      'qa-admin-' || v_suffix,
      'qa-admin-' || v_suffix,
      'qa-password-hash-not-used',
      'Admin QA Atendimento',
      'admin',
      true
    )
    returning id into v_admin_id;
  else
    -- Apenas garante que a sessao sintetica seja valida durante esta
    -- transacao; o ROLLBACK restaura o estado anterior.
    update public.app_users users
    set is_active = true
    where users.id = v_admin_id
      and users.is_active = false;
  end if;

  insert into public.stores (
    admin_user_id, name, nick, nick_key, is_active,
    lead_enabled, prospection_enabled, attendance_enabled,
    good_morning_seller_enabled
  ) values
    (
      v_admin_id,
      'Loja QA Atendimento A ' || left(v_suffix, 8),
      'qa-att-a-' || v_suffix,
      'qa-att-a-' || v_suffix,
      true, true, true, true, false
    ),
    (
      v_admin_id,
      'Loja QA Atendimento B ' || left(v_suffix, 8),
      'qa-att-b-' || v_suffix,
      'qa-att-b-' || v_suffix,
      true, true, true, true, false
    );

  -- Resolve ambos os IDs de modo deterministico pelo nick sintetico.
  select stores.id into v_store_a
  from public.stores stores
  where stores.nick = 'qa-att-a-' || v_suffix;

  select stores.id into v_store_b
  from public.stores stores
  where stores.nick = 'qa-att-b-' || v_suffix;

  insert into public.app_users (
    nick, nick_key, password_hash, full_name, role,
    admin_user_id, store_id, is_active
  ) values (
    'qa-store-' || v_suffix,
    'qa-store-' || v_suffix,
    'qa-password-hash-not-used',
    'Usuario Loja QA Atendimento',
    'store',
    v_admin_id,
    v_store_a,
    true
  )
  returning id into v_store_user_id;

  insert into public.app_sessions (user_id, token_hash, expires_at)
  values
    (
      v_admin_id,
      pg_catalog.encode(
        extensions.digest(v_admin_token::bytea, 'sha256'), 'hex'
      ),
      pg_catalog.clock_timestamp() + interval '1 hour'
    ),
    (
      v_store_user_id,
      pg_catalog.encode(
        extensions.digest(v_store_token::bytea, 'sha256'), 'hex'
      ),
      pg_catalog.clock_timestamp() + interval '1 hour'
    );

  insert into public.prospection_store_settings (
    store_id, admin_user_id, daily_goal, bonus_minimum, bonus_amount
  ) values (
    v_store_a, v_admin_id, 15, 300, 20
  );

  insert into public.prospection_professionals (
    store_id, admin_user_id, name, is_active
  ) values
    (v_store_a, v_admin_id, 'Atendente A QA', true),
    (v_store_a, v_admin_id, 'Atendente B QA', true),
    (v_store_a, v_admin_id, 'Prospector QA', true);

  select professionals.id into v_attendant_a
  from public.prospection_professionals professionals
  where professionals.store_id = v_store_a
    and professionals.name = 'Atendente A QA';

  select professionals.id into v_attendant_b
  from public.prospection_professionals professionals
  where professionals.store_id = v_store_a
    and professionals.name = 'Atendente B QA';

  select professionals.id into v_prospector
  from public.prospection_professionals professionals
  where professionals.store_id = v_store_a
    and professionals.name = 'Prospector QA';

  -- -----------------------------------------------------------------------
  -- Loja e Admin editam todos os campos comerciais do mesmo atendimento.
  -- -----------------------------------------------------------------------
  perform public.lc_upsert_attendance_v3(
    p_session_token => v_admin_token,
    p_store_id => v_store_a,
    p_professional_name => 'Atendente A QA',
    p_customer_name => 'Cliente inicial QA',
    p_phone => '11911111111',
    p_cpf => null,
    p_description => 'Registro inicial para edicao integral.',
    p_tag => 'budget',
    p_service_value => 50,
    p_purchase_value => null,
    p_service_order => null,
    p_attended_on => v_today - 4,
    p_idempotency_key => v_full_key
  );

  select
    attendance.id,
    attendance.created_at,
    attendance.updated_at,
    attendance.idempotency_key,
    attendance.request_fingerprint
  into
    v_full_attendance_id,
    v_created_at,
    v_updated_at,
    v_idempotency_key,
    v_request_fingerprint
  from public.attendances attendance
  where attendance.store_id = v_store_a
    and attendance.idempotency_key = v_full_key;

  v_result := public.lc_update_attendance_v1(
    p_session_token => v_store_token,
    p_attendance_id => v_full_attendance_id,
    p_store_id => v_store_a,
    p_professional_name => 'Atendente B QA',
    p_attended_on => v_today - 3,
    p_customer_name => 'Cliente editado pela loja QA',
    p_phone => '11922222222',
    p_cpf => '52998224725',
    p_description => 'Loja alterou profissional, data, identidade, tipo e valores.',
    p_tag => 'purchase',
    p_service_value => 125.55,
    p_purchase_value => 500,
    p_service_order => 'FULL-STORE-' || left(v_suffix, 8),
    p_expected_updated_at => v_updated_at
  );

  select attendance.* into v_record
  from public.attendances attendance
  where attendance.id = v_full_attendance_id;

  if v_record.professional_id is distinct from v_attendant_b
     or v_record.professional_name_snapshot <> 'Atendente B QA'
     or pg_catalog.timezone('America/Sao_Paulo', v_record.attended_at)::date <> v_today - 3
     or v_record.customer_name <> 'Cliente editado pela loja QA'
     or v_record.phone <> '11922222222'
     or v_record.customer_cpf <> '52998224725'
     or v_record.description <> 'Loja alterou profissional, data, identidade, tipo e valores.'
     or v_record.tag <> 'purchase'
     or v_record.service_value <> 125.55
     or v_record.purchase_value <> 500
     or v_record.service_order <> ('FULL-STORE-' || left(v_suffix, 8))
     or v_record.updated_by is distinct from v_store_user_id
     or v_record.edit_count <> 1 then
    raise exception 'QA: a Loja nao conseguiu editar integralmente o atendimento.';
  end if;

  if v_record.created_at is distinct from v_created_at
     or v_record.idempotency_key is distinct from v_idempotency_key
     or v_record.request_fingerprint is distinct from v_request_fingerprint then
    raise exception 'QA: a edicao da Loja alterou artefatos imutaveis.';
  end if;

  v_updated_at := v_record.updated_at;
  v_result := public.lc_update_attendance_v1(
    p_session_token => v_admin_token,
    p_attendance_id => v_full_attendance_id,
    p_store_id => v_store_a,
    p_professional_name => 'Atendente A QA',
    p_attended_on => v_today - 2,
    p_customer_name => 'Cliente editado pelo Admin QA',
    p_phone => '11933333333',
    p_cpf => '11144477735',
    p_description => 'Admin alterou novamente todos os campos comerciais.',
    p_tag => 'other',
    p_service_value => 10.25,
    p_purchase_value => null,
    p_service_order => null,
    p_expected_updated_at => v_updated_at
  );

  select attendance.* into v_record
  from public.attendances attendance
  where attendance.id = v_full_attendance_id;

  if v_record.professional_id is distinct from v_attendant_a
     or v_record.professional_name_snapshot <> 'Atendente A QA'
     or pg_catalog.timezone('America/Sao_Paulo', v_record.attended_at)::date <> v_today - 2
     or v_record.customer_name <> 'Cliente editado pelo Admin QA'
     or v_record.phone <> '11933333333'
     or v_record.customer_cpf <> '11144477735'
     or v_record.description <> 'Admin alterou novamente todos os campos comerciais.'
     or v_record.tag <> 'other'
     or v_record.service_value <> 10.25
     or v_record.purchase_value is not null
     or v_record.service_order is not null
     or v_record.updated_by is distinct from v_admin_id
     or v_record.edit_count <> 2 then
    raise exception 'QA: o Admin nao conseguiu editar integralmente o atendimento.';
  end if;

  if v_record.created_at is distinct from v_created_at
     or v_record.idempotency_key is distinct from v_idempotency_key
     or v_record.request_fingerprint is distinct from v_request_fingerprint then
    raise exception 'QA: a edicao do Admin alterou artefatos imutaveis.';
  end if;

  if coalesce((v_result ->> 'updated')::boolean, false) is not true
     or coalesce((v_result ->> 'edit_count')::bigint, -1) <> 2 then
    raise exception 'QA: resposta da edicao integral nao confirmou versao 2.';
  end if;

  -- -----------------------------------------------------------------------
  -- Compra vinculada: 500 -> 100 recalcula bonus, mas o credito permanece
  -- com o Prospector original, nunca com quem atendeu.
  -- -----------------------------------------------------------------------
  insert into public.prospections (
    admin_user_id, store_id, name, phone, cpf, notes,
    professional_id, professional_name_snapshot, created_by
  ) values (
    v_admin_id,
    v_store_a,
    'Cliente prospectado QA',
    '11944444444',
    null,
    'Prospecção sintetica do smoke test.',
    v_prospector,
    'Prospector QA',
    v_admin_id
  )
  returning id into v_prospection_id;

  perform public.lc_upsert_attendance_v3(
    p_session_token => v_admin_token,
    p_store_id => v_store_a,
    p_professional_name => 'Atendente A QA',
    p_customer_name => 'Cliente prospectado QA',
    p_phone => '11944444444',
    p_cpf => null,
    p_description => 'Compra inicial elegivel para bonus.',
    p_tag => 'purchase',
    p_service_value => 500,
    p_purchase_value => 500,
    p_service_order => 'BONUS-500-' || left(v_suffix, 8),
    p_attended_on => v_today - 1,
    p_idempotency_key => v_bonus_key
  );

  select
    attendance.id,
    attendance.created_at,
    attendance.updated_at,
    attendance.idempotency_key,
    attendance.request_fingerprint
  into
    v_bonus_attendance_id,
    v_created_at,
    v_stale_updated_at,
    v_idempotency_key,
    v_request_fingerprint
  from public.attendances attendance
  where attendance.store_id = v_store_a
    and attendance.idempotency_key = v_bonus_key;

  select attendance.* into v_record
  from public.attendances attendance
  where attendance.id = v_bonus_attendance_id;

  select prospections.* into v_projection
  from public.prospections prospections
  where prospections.id = v_prospection_id;

  if v_record.purchase_value <> 500
     or v_record.credited_professional_id is distinct from v_prospector
     or not v_record.purchase_credit_applied
     or not v_record.bonus_eligible
     or v_record.bonus_awarded_amount <> 20
     or v_record.bonus_credit_status <> 'awarded'
     or v_projection.attendance_purchase_source_id is distinct from v_bonus_attendance_id then
    raise exception 'QA: compra inicial nao congelou credito/bonus/source corretamente.';
  end if;

  v_result := public.lc_update_attendance_v1(
    p_session_token => v_admin_token,
    p_attendance_id => v_bonus_attendance_id,
    p_store_id => v_store_a,
    p_professional_name => 'Atendente B QA',
    p_attended_on => v_today - 1,
    p_customer_name => 'Cliente prospectado QA',
    p_phone => '11944444444',
    p_cpf => null,
    p_description => 'Compra corrigida de 500 para 100.',
    p_tag => 'purchase',
    p_service_value => 100,
    p_purchase_value => 100,
    p_service_order => 'BONUS-100-' || left(v_suffix, 8),
    p_expected_updated_at => v_stale_updated_at
  );

  select attendance.* into v_record
  from public.attendances attendance
  where attendance.id = v_bonus_attendance_id;

  select prospections.* into v_projection
  from public.prospections prospections
  where prospections.id = v_prospection_id;

  if v_record.professional_id is distinct from v_attendant_b
     or v_record.purchase_value <> 100
     or v_record.credited_professional_id is distinct from v_prospector
     or not v_record.purchase_credit_applied
     or v_record.bonus_eligible
     or v_record.bonus_awarded_amount <> 0
     or v_record.bonus_credit_status <> 'below_minimum'
     or v_projection.purchase_amount <> 100
     or v_projection.purchase_order <> ('BONUS-100-' || left(v_suffix, 8))
     or v_projection.bonus_professional_id_snapshot is distinct from v_prospector
     or v_projection.bonus_eligible_snapshot is distinct from false
     or v_projection.bonus_awarded_amount_snapshot is distinct from 0
     or v_projection.bonus_credit_status_snapshot is distinct from 'below_minimum'
     or v_projection.attendance_purchase_source_id is distinct from v_bonus_attendance_id then
    raise exception 'QA: correcao 500 -> 100 ou credito ao Prospector esta incorreta.';
  end if;

  if v_record.created_at is distinct from v_created_at
     or v_record.idempotency_key is distinct from v_idempotency_key
     or v_record.request_fingerprint is distinct from v_request_fingerprint then
    raise exception 'QA: correcao financeira alterou artefatos imutaveis.';
  end if;

  v_updated_at := v_record.updated_at;

  -- Concorrencia otimista: payload diferente com versao antiga deve falhar.
  v_error := null;
  begin
    perform public.lc_update_attendance_v1(
      p_session_token => v_admin_token,
      p_attendance_id => v_bonus_attendance_id,
      p_store_id => v_store_a,
      p_professional_name => 'Atendente B QA',
      p_attended_on => v_today - 1,
      p_customer_name => 'Cliente prospectado QA',
      p_phone => '11944444444',
      p_cpf => null,
      p_description => 'Tentativa com versao obsoleta.',
      p_tag => 'purchase',
      p_service_value => 100,
      p_purchase_value => 100,
      p_service_order => 'BONUS-100-' || left(v_suffix, 8),
      p_expected_updated_at => v_stale_updated_at
    );
  exception when others then
    v_error := sqlerrm;
  end;
  if v_error is null or v_error not like '%alterado em outra tela%' then
    raise exception 'QA: versao obsoleta nao foi rejeitada: %', coalesce(v_error, 'sem erro');
  end if;

  -- Isolamento por loja: nem o Admin pode mover/editar a linha pelo tenant B.
  v_error := null;
  begin
    perform public.lc_update_attendance_v1(
      p_session_token => v_admin_token,
      p_attendance_id => v_bonus_attendance_id,
      p_store_id => v_store_b,
      p_professional_name => 'Atendente B QA',
      p_attended_on => v_today - 1,
      p_customer_name => 'Cliente prospectado QA',
      p_phone => '11944444444',
      p_cpf => null,
      p_description => 'Tentativa cruzada entre lojas.',
      p_tag => 'purchase',
      p_service_value => 100,
      p_purchase_value => 100,
      p_service_order => 'BONUS-100-' || left(v_suffix, 8),
      p_expected_updated_at => v_updated_at
    );
  exception when others then
    v_error := sqlerrm;
  end;
  if v_error is null or v_error not like '%não encontrado ou sem permissão%' then
    raise exception 'QA: isolamento cross-store nao foi aplicado: %', coalesce(v_error, 'sem erro');
  end if;

  -- Unicidade case-insensitive da OS durante a edicao.
  perform public.lc_upsert_attendance_v3(
    p_session_token => v_admin_token,
    p_store_id => v_store_a,
    p_professional_name => 'Atendente A QA',
    p_customer_name => 'Cliente OS duplicada QA',
    p_phone => '11955555555',
    p_cpf => null,
    p_description => 'Registro que reserva uma OS distinta.',
    p_tag => 'purchase',
    p_service_value => 250,
    p_purchase_value => 250,
    p_service_order => 'OS-DUP-' || left(v_suffix, 8),
    p_attended_on => v_today,
    p_idempotency_key => v_duplicate_key
  );

  select attendance.id into v_duplicate_attendance_id
  from public.attendances attendance
  where attendance.store_id = v_store_a
    and attendance.idempotency_key = v_duplicate_key;

  if v_duplicate_attendance_id is null then
    raise exception 'QA: fixture da OS duplicada nao foi criada.';
  end if;

  v_error := null;
  begin
    perform public.lc_update_attendance_v1(
      p_session_token => v_admin_token,
      p_attendance_id => v_bonus_attendance_id,
      p_store_id => v_store_a,
      p_professional_name => 'Atendente B QA',
      p_attended_on => v_today - 1,
      p_customer_name => 'Cliente prospectado QA',
      p_phone => '11944444444',
      p_cpf => null,
      p_description => 'Tentativa de reaproveitar OS existente.',
      p_tag => 'purchase',
      p_service_value => 100,
      p_purchase_value => 100,
      p_service_order => pg_catalog.lower('OS-DUP-' || left(v_suffix, 8)),
      p_expected_updated_at => v_updated_at
    );
  exception when others then
    v_error := sqlerrm;
  end;
  if v_error is null or v_error not like '%OS já está vinculada%' then
    raise exception 'QA: OS duplicada nao foi rejeitada: %', coalesce(v_error, 'sem erro');
  end if;

  -- -----------------------------------------------------------------------
  -- Dois atendimentos para a mesma prospeccao. Ao remover a compra do source,
  -- o sibling mais antigo elegivel assume a projecao, e o resumo efetivo de
  -- bonificacao continua refletindo a compra/Prospector corretos.
  -- -----------------------------------------------------------------------
  insert into public.prospections (
    admin_user_id, store_id, name, phone, cpf, notes,
    professional_id, professional_name_snapshot, created_by
  ) values (
    v_admin_id,
    v_store_a,
    'Cliente com sibling QA',
    '11966666666',
    null,
    'Prospecção sintetica para promocao de sibling.',
    v_prospector,
    'Prospector QA',
    v_admin_id
  )
  returning id into v_sibling_prospection_id;

  perform public.lc_upsert_attendance_v3(
    p_session_token => v_admin_token,
    p_store_id => v_store_a,
    p_professional_name => 'Atendente A QA',
    p_customer_name => 'Cliente com sibling QA',
    p_phone => '11966666666',
    p_cpf => null,
    p_description => 'Primeira compra, source original.',
    p_tag => 'purchase',
    p_service_value => 500,
    p_purchase_value => 500,
    p_service_order => 'SOURCE-500-' || left(v_suffix, 8),
    p_attended_on => v_today,
    p_idempotency_key => v_source_key
  );

  select attendance.id, attendance.updated_at
  into v_source_attendance_id, v_updated_at
  from public.attendances attendance
  where attendance.store_id = v_store_a
    and attendance.idempotency_key = v_source_key;

  perform public.lc_upsert_attendance_v3(
    p_session_token => v_admin_token,
    p_store_id => v_store_a,
    p_professional_name => 'Atendente B QA',
    p_customer_name => 'Cliente com sibling QA',
    p_phone => '11966666666',
    p_cpf => null,
    p_description => 'Segunda compra elegivel para assumir o source.',
    p_tag => 'purchase',
    p_service_value => 450,
    p_purchase_value => 450,
    p_service_order => 'SIBLING-450-' || left(v_suffix, 8),
    p_attended_on => v_today,
    p_idempotency_key => v_sibling_key
  );

  select attendance.id into v_sibling_attendance_id
  from public.attendances attendance
  where attendance.store_id = v_store_a
    and attendance.idempotency_key = v_sibling_key;

  select prospections.* into v_projection
  from public.prospections prospections
  where prospections.id = v_sibling_prospection_id;

  select attendance.* into v_record
  from public.attendances attendance
  where attendance.id = v_source_attendance_id;

  if v_projection.attendance_return_source_id is distinct from v_source_attendance_id
     or v_projection.attendance_purchase_source_id is distinct from v_source_attendance_id
     or v_projection.attendance_return_manual_override
     or v_projection.attendance_purchase_manual_override
     or not v_record.prospection_visit_applied
     or not v_record.prospection_purchase_applied
     or not v_record.purchase_credit_applied
     or not v_record.bonus_eligible
     or v_record.bonus_awarded_amount <> 20 then
    raise exception 'QA: criação v3 não capturou source/crédito antes da promoção.';
  end if;

  perform public.lc_update_attendance_v1(
    p_session_token => v_admin_token,
    p_attendance_id => v_source_attendance_id,
    p_store_id => v_store_a,
    p_professional_name => 'Atendente A QA',
    p_attended_on => v_today,
    p_customer_name => 'Cliente com sibling QA',
    p_phone => '11966666666',
    p_cpf => null,
    p_description => 'Source corrigido para atendimento sem compra.',
    p_tag => 'other',
    p_service_value => 25,
    p_purchase_value => null,
    p_service_order => null,
    p_expected_updated_at => v_updated_at
  );

  select prospections.* into v_projection
  from public.prospections prospections
  where prospections.id = v_sibling_prospection_id;

  select attendance.* into v_record
  from public.attendances attendance
  where attendance.id = v_source_attendance_id;

  select attendance.* into v_sibling_record
  from public.attendances attendance
  where attendance.id = v_sibling_attendance_id;

  if v_projection.attendance_return_source_id is distinct from v_source_attendance_id
     or v_projection.attendance_purchase_source_id is distinct from v_sibling_attendance_id
     or v_projection.purchase_amount <> 450
     or v_projection.purchase_order <> ('SIBLING-450-' || left(v_suffix, 8))
     or v_projection.bonus_professional_id_snapshot is distinct from v_prospector
     or v_projection.bonus_eligible_snapshot is distinct from true
     or v_projection.bonus_awarded_amount_snapshot is distinct from 20
     or v_projection.bonus_credit_status_snapshot is distinct from 'awarded'
     or v_record.tag <> 'other'
     or v_record.prospection_purchase_applied
     or v_record.purchase_credit_applied
     or v_record.bonus_eligible
     or v_record.bonus_awarded_amount <> 0
     or v_sibling_record.prospection_visit_applied
     or not v_sibling_record.prospection_purchase_applied
     or not v_sibling_record.purchase_credit_applied
     or v_sibling_record.credited_professional_id is distinct from v_prospector
     or not v_sibling_record.bonus_eligible
     or v_sibling_record.bonus_awarded_amount <> 20
     or v_sibling_record.bonus_credit_status <> 'awarded' then
    raise exception 'QA: promocao do sibling ou snapshots efetivos ficaram incorretos. projection=% source=% sibling=%',
      pg_catalog.jsonb_build_object(
        'source_id', v_projection.attendance_purchase_source_id,
        'purchase_amount', v_projection.purchase_amount,
        'purchase_order', v_projection.purchase_order,
        'professional_id', v_projection.bonus_professional_id_snapshot,
        'eligible', v_projection.bonus_eligible_snapshot,
        'awarded', v_projection.bonus_awarded_amount_snapshot,
        'status', v_projection.bonus_credit_status_snapshot
      ),
      pg_catalog.jsonb_build_object(
        'tag', v_record.tag,
        'purchase_applied', v_record.prospection_purchase_applied,
        'credit_applied', v_record.purchase_credit_applied,
        'eligible', v_record.bonus_eligible,
        'awarded', v_record.bonus_awarded_amount
      ),
      (
        select pg_catalog.jsonb_build_object(
          'id', sibling.id,
          'purchase_applied', sibling.prospection_purchase_applied,
          'credit_applied', sibling.purchase_credit_applied,
          'professional_id', sibling.credited_professional_id,
          'eligible', sibling.bonus_eligible,
          'awarded', sibling.bonus_awarded_amount,
          'status', sibling.bonus_credit_status
        )
        from public.attendances sibling
        where sibling.id = v_sibling_attendance_id
      );
  end if;

  v_result := app_private.attendance_result_with_identity(
    v_sibling_attendance_id,
    false
  );
  if coalesce((v_result #>> '{attendance,purchase_credit_applied}')::boolean, false) is not true
     or coalesce((v_result #>> '{attendance,bonus_eligible}')::boolean, false) is not true
     or coalesce((v_result #>> '{attendance,bonus_awarded_amount}')::numeric, 0) <> 20
     or coalesce((v_result #>> '{links,prospection,purchase_applied}')::boolean, false) is not true
     or coalesce((v_result #>> '{links,prospection,purchase_credit_applied}')::boolean, false) is not true then
    raise exception 'QA: JSON efetivo nao derivou ownership/bonus do source promovido.';
  end if;

  v_metrics := app_private.attendance_metrics_json(v_admin_id, v_store_a);
  if coalesce((v_metrics #>> '{today,purchase_credits}')::bigint, 0) < 1
     or coalesce((v_metrics #>> '{today,bonuses_awarded}')::bigint, 0) < 1
     or coalesce((v_metrics #>> '{today,bonus_awarded_amount}')::numeric, 0) < 20 then
    raise exception 'QA: metricas efetivas perderam o credito/bonus do source promovido: %',
      v_metrics -> 'today';
  end if;

  select
    summary.eligible_purchase_count,
    summary.total_bonus
  into v_effective_bonus_count, v_effective_bonus_total
  from public.lc_get_prospection_weekly_bonus_summary(
    v_admin_token,
    v_store_a
  ) summary;

  if coalesce(v_effective_bonus_count, 0) < 1
     or coalesce(v_effective_bonus_total, 0) <> 20 then
    raise exception 'QA: resumo efetivo perdeu a bonificacao apos promover sibling (% / %).',
      v_effective_bonus_count, v_effective_bonus_total;
  end if;

  -- O fallback público v2 também atualiza o outcome antes do INSERT. O guard
  -- deve aceitar a transição positiva e o AFTER INSERT deve capturar os sources.
  insert into public.prospections (
    admin_user_id, store_id, name, phone, cpf, notes,
    professional_id, professional_name_snapshot, created_by
  ) values (
    v_admin_id,
    v_store_a,
    'Cliente fallback v2 QA',
    '11977777777',
    null,
    'Prospecção sintética para compatibilidade v2.',
    v_prospector,
    'Prospector QA',
    v_admin_id
  )
  returning id into v_v2_prospection_id;

  perform public.lc_upsert_attendance_v2(
    p_session_token => v_admin_token,
    p_store_id => v_store_a,
    p_professional_name => 'Atendente A QA',
    p_customer_name => 'Cliente fallback v2 QA',
    p_phone => '11977777777',
    p_cpf => null,
    p_description => 'Compra criada pelo fallback v2.',
    p_tag => 'purchase',
    p_service_value => 350,
    p_purchase_value => 350,
    p_service_order => 'FALLBACK-V2-' || left(v_suffix, 8),
    p_idempotency_key => v_v2_key
  );

  select attendance.id into v_v2_attendance_id
  from public.attendances attendance
  where attendance.store_id = v_store_a
    and attendance.idempotency_key = v_v2_key;

  select prospections.* into v_projection
  from public.prospections prospections
  where prospections.id = v_v2_prospection_id;

  if v_projection.attendance_return_source_id is distinct from v_v2_attendance_id
     or v_projection.attendance_purchase_source_id is distinct from v_v2_attendance_id
     or v_projection.attendance_return_manual_override
     or v_projection.attendance_purchase_manual_override then
    raise exception 'QA: fallback v2 não capturou ownership após os guards.';
  end if;

  -- Override manual vence a projecao do atendimento e nao pode ser desfeito
  -- por uma edicao posterior da linha de atendimento.
  update public.prospections prospections
  set purchased_at = prospections.purchased_at + interval '1 hour',
      purchase_amount = 777,
      purchase_order = 'MANUAL-' || left(v_suffix, 8),
      updated_by = v_admin_id
  where prospections.id = v_prospection_id;

  select prospections.* into v_projection
  from public.prospections prospections
  where prospections.id = v_prospection_id;

  select attendance.* into v_record
  from public.attendances attendance
  where attendance.id = v_bonus_attendance_id;

  if v_projection.attendance_purchase_source_id is not null
     or not v_projection.attendance_purchase_manual_override
     or v_projection.purchase_amount <> 777
     or v_projection.purchase_order <> ('MANUAL-' || left(v_suffix, 8))
     or v_record.purchase_credit_applied
     or v_record.bonus_eligible
     or v_record.bonus_awarded_amount <> 0 then
    raise exception 'QA: override manual nao removeu ownership/credito corretamente.';
  end if;

  v_updated_at := v_record.updated_at;
  perform public.lc_update_attendance_v1(
    p_session_token => v_admin_token,
    p_attendance_id => v_bonus_attendance_id,
    p_store_id => v_store_a,
    p_professional_name => 'Atendente B QA',
    p_attended_on => v_today - 1,
    p_customer_name => 'Cliente prospectado QA',
    p_phone => '11944444444',
    p_cpf => null,
    p_description => 'Atendimento corrigido depois do override manual.',
    p_tag => 'purchase',
    p_service_value => 90,
    p_purchase_value => 90,
    p_service_order => 'BONUS-90-' || left(v_suffix, 8),
    p_expected_updated_at => v_updated_at
  );

  select prospections.* into v_projection
  from public.prospections prospections
  where prospections.id = v_prospection_id;

  select attendance.* into v_record
  from public.attendances attendance
  where attendance.id = v_bonus_attendance_id;

  if v_projection.attendance_purchase_source_id is not null
     or not v_projection.attendance_purchase_manual_override
     or v_projection.purchase_amount <> 777
     or v_projection.purchase_order <> ('MANUAL-' || left(v_suffix, 8))
     or v_record.purchase_value <> 90
     or v_record.purchase_credit_applied
     or v_record.bonus_eligible
     or v_record.bonus_awarded_amount <> 0
     or v_record.bonus_credit_status <> 'already_converted' then
    raise exception 'QA: edicao posterior sobrescreveu o outcome manual.';
  end if;

  if v_record.created_at is distinct from v_created_at
     or v_record.idempotency_key is distinct from v_idempotency_key
     or v_record.request_fingerprint is distinct from v_request_fingerprint then
    raise exception 'QA: edicao pos-override alterou artefatos imutaveis.';
  end if;

  -- Somente as duas edicoes bem-sucedidas do atendimento de bonus geram
  -- auditoria. Falhas esperadas nao podem deixar efeitos parciais.
  if (
    select count(*)
    from app_private.attendance_edit_audit audit
    where audit.attendance_id = v_bonus_attendance_id
  ) <> 2 then
    raise exception 'QA: quantidade inesperada de auditorias do atendimento de bonus.';
  end if;

  if (
    select count(*)
    from app_private.attendance_edit_audit audit
    where audit.attendance_id = v_full_attendance_id
  ) <> 2 then
    raise exception 'QA: Loja/Admin nao geraram duas auditorias completas.';
  end if;

  select audit.id into v_audit_id
  from app_private.attendance_edit_audit audit
  where audit.attendance_id = v_bonus_attendance_id
  order by audit.edit_number
  limit 1;

  v_error := null;
  begin
    update app_private.attendance_edit_audit audit
    set changed_at = audit.changed_at
    where audit.id = v_audit_id;
  exception when others then
    v_error := sqlerrm;
  end;
  if v_error is null or v_error not like '%imutável%' then
    raise exception 'QA: trilha de auditoria aceitou mutacao: %', coalesce(v_error, 'sem erro');
  end if;

  raise notice 'attendance-edit smoke passou: Loja/Admin, campos, bonus 500->100, source sibling, métricas/JSON, criação v2/v3, concorrência, tenant, OS e override manual.';
end;
$attendance_edit_smoke$;

rollback;
