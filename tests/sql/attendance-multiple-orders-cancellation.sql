-- Smoke transacional para multiplas OS e cancelamento de atendimentos.
--
-- Pre-requisito: migrations aplicadas ate
-- 20260915115122_attendance_multiple_orders_and_cancellation.sql.
--
-- O teste usa somente dados sinteticos. Quando ja existe um Admin, reaproveita
-- apenas seu UUID para respeitar a regra de Admin unico. Loja, usuario, sessao,
-- profissional e atendimentos sao temporarios e o ROLLBACK final desfaz tudo.

begin;

set local lock_timeout = '10s';
set local statement_timeout = '120s';
select pg_catalog.set_config('app.legal_gate_bypass', 'on', true);

do $attendance_multiple_orders_contract$
begin
  if pg_catalog.to_regprocedure(
       'public.lc_upsert_attendance(text,uuid,text,text,text,text,text,numeric,numeric,text,text)'
     ) is null
     or pg_catalog.to_regprocedure(
       'public.lc_upsert_attendance_v2(text,uuid,text,text,text,text,text,text,numeric,numeric,text,text)'
     ) is null
     or pg_catalog.to_regprocedure(
       'public.lc_upsert_attendance_v3(text,uuid,text,text,text,text,text,text,numeric,numeric,text,date,text)'
     ) is null
     or pg_catalog.to_regprocedure(
       'public.lc_upsert_attendance_v4(text,uuid,text,text,text,text,text,text,numeric,jsonb,date,text)'
     ) is null
     or pg_catalog.to_regprocedure(
       'public.lc_update_attendance_v1(text,uuid,uuid,text,date,text,text,text,text,text,numeric,numeric,text,timestamptz)'
     ) is null
     or pg_catalog.to_regprocedure(
       'public.lc_update_attendance_v2(text,uuid,uuid,text,date,text,text,text,text,text,numeric,jsonb,timestamptz)'
     ) is null
     or pg_catalog.to_regprocedure(
       'public.lc_cancel_attendance_v1(text,uuid,uuid,timestamptz,text)'
     ) is null
     or pg_catalog.to_regprocedure(
       'public.lc_list_attendances_v4(text,uuid,text,text,uuid,text,text,date,date,integer,integer)'
     ) is null
     or pg_catalog.to_regprocedure(
       'public.lc_get_attendance_analysis_v1(text,uuid,text,text,uuid,text,text,date,date)'
     ) is null
     or pg_catalog.to_regprocedure(
       'app_private.capture_good_morning_actuals_cents(uuid,uuid,date,timestamptz)'
     ) is null
     or pg_catalog.to_regclass(
       'app_private.attendance_service_orders'
     ) is null
     or pg_catalog.to_regclass(
       'app_private.attendance_service_order_audit'
     ) is null
     or pg_catalog.to_regclass(
       'app_private.attendance_cancellation_audit'
     ) is null then
    raise exception 'QA multiplas OS: contrato SQL incompleto.';
  end if;
end;
$attendance_multiple_orders_contract$;

do $attendance_multiple_orders_smoke$
declare
  v_run_id uuid := extensions.gen_random_uuid();
  v_suffix text;
  v_today date := pg_catalog.timezone(
    'America/Sao_Paulo', pg_catalog.clock_timestamp()
  )::date;
  v_admin_id uuid;
  v_store_user_id uuid;
  v_store_id uuid;
  v_professional_id uuid;
  v_attendance_id uuid;
  v_reused_attendance_id uuid;
  v_idempotency_attendance_id uuid;
  v_legacy_v1_attendance_id uuid;
  v_legacy_v2_attendance_id uuid;
  v_admin_token text;
  v_store_token text;
  v_create_key text;
  v_duplicate_key text;
  v_reuse_key text;
  v_idempotency_key text;
  v_order_a text;
  v_order_b text;
  v_order_c text;
  v_orders_before jsonb;
  v_orders_after jsonb;
  v_reuse_orders jsonb;
  v_idempotency_orders jsonb;
  v_result jsonb;
  v_list jsonb;
  v_workspace jsonb;
  v_metrics jsonb;
  v_meta_actuals jsonb;
  v_analysis jsonb;
  v_error text;
  v_updated_at timestamptz;
  v_canceled_updated_at timestamptz;
  v_canceled_at timestamptz;
  v_canceled_edit_count bigint;
  v_order_count bigint;
  v_active_order_count bigint;
  v_canceled_order_count bigint;
  v_order_total numeric;
  v_order_sequence text;
  v_record public.attendances%rowtype;
  v_order_audit app_private.attendance_service_order_audit%rowtype;
  v_cancellation_audit app_private.attendance_cancellation_audit%rowtype;
begin
  v_suffix := pg_catalog.replace(v_run_id::text, '-', '');
  v_admin_token := 'qa-multi-os-admin-' || v_suffix;
  v_store_token := 'qa-multi-os-store-' || v_suffix;
  v_create_key := 'qa-multi-os-create-' || v_suffix;
  v_duplicate_key := 'qa-multi-os-duplicate-' || v_suffix;
  v_reuse_key := 'qa-multi-os-reuse-' || v_suffix;
  v_idempotency_key := 'qa-multi-os-idempotency-' || v_suffix;
  v_order_a := 'OS-ALFA-' || left(v_suffix, 10);
  v_order_b := 'OS-BETA-' || left(v_suffix, 10);
  v_order_c := 'OS-GAMA-' || left(v_suffix, 10);

  -- A instalacao aceita um unico Admin. Nenhum dado pessoal e lido; o UUID
  -- tecnico e reaproveitado somente para isolar o tenant sintetico.
  select users.id
  into v_admin_id
  from public.app_users users
  where users.role::text = 'admin'
  order by users.created_at, users.id
  limit 1;

  if v_admin_id is null then
    insert into public.app_users (
      nick,
      nick_key,
      password_hash,
      full_name,
      role,
      is_active
    ) values (
      'qa-multi-os-admin-' || v_suffix,
      'qa-multi-os-admin-' || v_suffix,
      'qa-password-hash-not-used',
      'Admin QA Multiplas OS',
      'admin',
      true
    )
    returning id into v_admin_id;
  else
    update public.app_users users
    set is_active = true
    where users.id = v_admin_id
      and users.is_active = false;
  end if;

  insert into public.stores (
    admin_user_id,
    name,
    nick,
    nick_key,
    is_active,
    lead_enabled,
    prospection_enabled,
    attendance_enabled,
    good_morning_seller_enabled
  ) values (
    v_admin_id,
    'Loja QA Multiplas OS ' || left(v_suffix, 8),
    'qa-multi-os-' || v_suffix,
    'qa-multi-os-' || v_suffix,
    true,
    true,
    true,
    true,
    true
  )
  returning id into v_store_id;

  insert into public.app_users (
    nick,
    nick_key,
    password_hash,
    full_name,
    role,
    admin_user_id,
    store_id,
    is_active
  ) values (
    'qa-multi-os-store-' || v_suffix,
    'qa-multi-os-store-' || v_suffix,
    'qa-password-hash-not-used',
    'Usuario Loja QA Multiplas OS',
    'store',
    v_admin_id,
    v_store_id,
    true
  )
  returning id into v_store_user_id;

  insert into public.app_sessions (user_id, token_hash, expires_at)
  values
    (
      v_admin_id,
      pg_catalog.encode(
        extensions.digest(v_admin_token::bytea, 'sha256'),
        'hex'
      ),
      pg_catalog.clock_timestamp() + interval '1 hour'
    ),
    (
      v_store_user_id,
      pg_catalog.encode(
        extensions.digest(v_store_token::bytea, 'sha256'),
        'hex'
      ),
      pg_catalog.clock_timestamp() + interval '1 hour'
    );

  insert into public.prospection_professionals (
    store_id,
    admin_user_id,
    name,
    is_active
  ) values (
    v_store_id,
    v_admin_id,
    'Atendente QA Multiplas OS',
    true
  )
  returning id into v_professional_id;

  -- Os dois fallbacks de criação ainda aceitos pelo frontend continuam com o
  -- mesmo contrato, mas agora chegam ao motor somente sob o lock da loja.
  v_result := public.lc_upsert_attendance(
    p_session_token => v_store_token,
    p_store_id => null,
    p_professional_name => 'Atendente QA Multiplas OS',
    p_customer_name => 'Cliente QA legado V1',
    p_phone => '11990000005',
    p_description => 'Smoke do writer legado V1 serializado.',
    p_tag => 'other',
    p_service_value => 10,
    p_purchase_value => null,
    p_service_order => null,
    p_idempotency_key => 'qa-legacy-v1-' || v_suffix
  );
  v_legacy_v1_attendance_id := nullif(
    coalesce(
      v_result #>> '{attendance,id}',
      v_result #>> '{record,id}'
    ),
    ''
  )::uuid;

  v_result := public.lc_upsert_attendance_v2(
    p_session_token => v_store_token,
    p_store_id => null,
    p_professional_name => 'Atendente QA Multiplas OS',
    p_customer_name => 'Cliente QA legado V2',
    p_phone => '11990000006',
    p_cpf => null,
    p_description => 'Smoke do writer legado V2 serializado.',
    p_tag => 'other',
    p_service_value => 20,
    p_purchase_value => null,
    p_service_order => null,
    p_idempotency_key => 'qa-legacy-v2-' || v_suffix
  );
  v_legacy_v2_attendance_id := nullif(
    coalesce(
      v_result #>> '{attendance,id}',
      v_result #>> '{record,id}'
    ),
    ''
  )::uuid;

  if v_legacy_v1_attendance_id is null
     or v_legacy_v2_attendance_id is null
     or v_legacy_v1_attendance_id = v_legacy_v2_attendance_id then
    raise exception 'QA multiplas OS: writer legado V1/V2 deixou de funcionar.';
  end if;

  delete from public.attendances attendance
  where attendance.id in (
    v_legacy_v1_attendance_id,
    v_legacy_v2_attendance_id
  );

  -- ---------------------------------------------------------------------
  -- Criacao: duas OS e total sempre derivado dos valores normalizados.
  -- ---------------------------------------------------------------------
  v_orders_before := pg_catalog.jsonb_build_array(
    pg_catalog.jsonb_build_object(
      'service_order', v_order_a,
      'amount', 400.10::numeric
    ),
    pg_catalog.jsonb_build_object(
      'service_order', v_order_b,
      'amount', 800.20::numeric
    )
  );

  v_result := public.lc_upsert_attendance_v4(
    p_session_token => v_store_token,
    p_store_id => v_store_id,
    p_professional_name => 'Atendente QA Multiplas OS',
    p_customer_name => 'Cliente QA duas OS',
    p_phone => '11990000001',
    p_cpf => null,
    p_description => 'Compra sintetica com duas ordens de servico.',
    p_tag => 'purchase',
    -- Valor do atendimento e propositalmente diferente da compra: o total da
    -- compra precisa vir exclusivamente da soma das OS.
    p_service_value => 25.50,
    p_service_orders => v_orders_before,
    p_attended_on => v_today,
    p_idempotency_key => v_create_key
  );

  v_attendance_id := nullif(
    v_result #>> '{attendance,id}',
    ''
  )::uuid;

  if v_attendance_id is null then
    raise exception 'QA multiplas OS: criacao nao retornou o atendimento.';
  end if;

  select attendance.*
  into v_record
  from public.attendances attendance
  where attendance.id = v_attendance_id;

  select
    pg_catalog.count(*),
    coalesce(pg_catalog.sum(service_orders.amount), 0),
    pg_catalog.string_agg(
      service_orders.service_order,
      '|' order by service_orders.position
    )
  into v_order_count, v_order_total, v_order_sequence
  from app_private.attendance_service_orders service_orders
  where service_orders.attendance_id = v_attendance_id;

  if v_record.tag <> 'purchase'
     or v_record.service_value <> 25.50
     or v_record.purchase_value <> 1200.30
     or v_record.service_order <> v_order_a
     or v_record.canceled_at is not null
     or v_order_count <> 2
     or v_order_total <> 1200.30
     or v_order_sequence <> v_order_a || '|' || v_order_b
     or pg_catalog.jsonb_array_length(
       coalesce(v_result #> '{attendance,service_orders}', '[]'::jsonb)
     ) <> 2
     or (v_result #>> '{attendance,purchase_value}')::numeric <> 1200.30 then
    raise exception 'QA multiplas OS: criacao ou soma inicial incorreta. record=% orders=% response=%',
      to_jsonb(v_record),
      app_private.attendance_service_orders_json(v_attendance_id),
      v_result;
  end if;

  -- A busca usa deliberadamente a OS secundaria, ausente da coluna legada.
  v_list := public.lc_list_attendances_v4(
    p_session_token => v_store_token,
    p_store_id => v_store_id,
    p_search => pg_catalog.lower(v_order_b),
    p_tag => 'purchase',
    p_professional_id => null,
    p_professional_name => null,
    p_link_status => null,
    p_start_date => v_today,
    p_end_date => v_today,
    p_limit => 50,
    p_offset => 0
  );

  if coalesce((v_list ->> 'total')::bigint, 0) <> 1
     or v_list #>> '{items,0,id}' <> v_attendance_id::text
     or pg_catalog.jsonb_array_length(
       coalesce(v_list #> '{items,0,service_orders}', '[]'::jsonb)
     ) <> 2
     or not exists (
       select 1
       from pg_catalog.jsonb_array_elements(
         coalesce(v_list #> '{items,0,service_orders}', '[]'::jsonb)
       ) listed_order(value)
       where listed_order.value ->> 'service_order' = v_order_b
         and (listed_order.value ->> 'amount')::numeric = 800.20
     ) then
    raise exception 'QA multiplas OS: lista nao encontrou a OS secundaria: %',
      v_list;
  end if;

  -- ---------------------------------------------------------------------
  -- Edicao: tres OS, novo total e trilha especifica da lista de OS.
  -- ---------------------------------------------------------------------
  v_orders_after := pg_catalog.jsonb_build_array(
    pg_catalog.jsonb_build_object(
      'service_order', v_order_a,
      'amount', 400.10::numeric
    ),
    pg_catalog.jsonb_build_object(
      'service_order', v_order_b,
      'amount', 500.20::numeric
    ),
    pg_catalog.jsonb_build_object(
      'service_order', v_order_c,
      'amount', 333.33::numeric
    )
  );

  v_updated_at := v_record.updated_at;
  v_result := public.lc_update_attendance_v2(
    p_session_token => v_store_token,
    p_attendance_id => v_attendance_id,
    p_store_id => v_store_id,
    p_professional_name => 'Atendente QA Multiplas OS',
    p_attended_on => v_today,
    p_customer_name => 'Cliente QA tres OS',
    p_phone => '11990000001',
    p_cpf => null,
    p_description => 'Compra sintetica editada para tres ordens de servico.',
    p_tag => 'purchase',
    p_service_value => 40.40,
    p_service_orders => v_orders_after,
    p_expected_updated_at => v_updated_at
  );

  select attendance.*
  into v_record
  from public.attendances attendance
  where attendance.id = v_attendance_id;

  select
    pg_catalog.count(*),
    coalesce(pg_catalog.sum(service_orders.amount), 0),
    pg_catalog.string_agg(
      service_orders.service_order,
      '|' order by service_orders.position
    )
  into v_order_count, v_order_total, v_order_sequence
  from app_private.attendance_service_orders service_orders
  where service_orders.attendance_id = v_attendance_id;

  if v_record.purchase_value <> 1233.63
     or v_record.service_value <> 40.40
     or v_record.service_order <> v_order_a
     or v_record.customer_name <> 'Cliente QA tres OS'
     or v_record.updated_at is not distinct from v_updated_at
     or v_order_count <> 3
     or v_order_total <> 1233.63
     or v_order_sequence <> v_order_a || '|' || v_order_b || '|' || v_order_c
     or coalesce((v_result ->> 'updated')::boolean, false) is not true
     or not coalesce(v_result -> 'changed_fields', '[]'::jsonb)
       @> '["service_orders"]'::jsonb
     or (v_result #>> '{attendance,purchase_value}')::numeric <> 1233.63 then
    raise exception 'QA multiplas OS: edicao para tres OS ficou incorreta. record=% orders=% response=%',
      to_jsonb(v_record),
      app_private.attendance_service_orders_json(v_attendance_id),
      v_result;
  end if;

  if (
    select pg_catalog.count(*)
    from app_private.attendance_service_order_audit audit
    where audit.attendance_id = v_attendance_id
  ) <> 1 then
    raise exception 'QA multiplas OS: edicao nao gerou uma auditoria de OS.';
  end if;

  select audit.*
  into v_order_audit
  from app_private.attendance_service_order_audit audit
  where audit.attendance_id = v_attendance_id
  order by audit.changed_at desc
  limit 1;

  if v_order_audit.before_orders is distinct from v_orders_before
     or v_order_audit.after_orders is distinct from v_orders_after
     or v_order_audit.changed_by is distinct from v_store_user_id then
    raise exception 'QA multiplas OS: snapshots da edicao de OS incorretos: %',
      to_jsonb(v_order_audit);
  end if;

  -- Uma OS secundaria ativa tambem deve bloquear outra venda, sem deixar
  -- efeitos parciais da tentativa que falhou.
  v_error := null;
  begin
    perform public.lc_upsert_attendance_v4(
      p_session_token => v_store_token,
      p_store_id => v_store_id,
      p_professional_name => 'Atendente QA Multiplas OS',
      p_customer_name => 'Cliente QA OS duplicada',
      p_phone => '11990000002',
      p_cpf => null,
      p_description => 'Tentativa com uma OS secundaria ja ativa.',
      p_tag => 'purchase',
      p_service_value => 600,
      p_service_orders => pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object(
          'service_order', 'OS-NOVA-' || left(v_suffix, 10),
          'amount', 100::numeric
        ),
        pg_catalog.jsonb_build_object(
          'service_order', pg_catalog.lower(v_order_b),
          'amount', 500::numeric
        )
      ),
      p_attended_on => v_today,
      p_idempotency_key => v_duplicate_key
    );
  exception when others then
    v_error := sqlerrm;
  end;

  if v_error is null or v_error not like '%já está vinculada%' then
    raise exception 'QA multiplas OS: duplicata ativa nao foi rejeitada: %',
      coalesce(v_error, 'sem erro');
  end if;

  if exists (
    select 1
    from public.attendances attendance
    where attendance.store_id = v_store_id
      and attendance.idempotency_key = v_duplicate_key
  ) then
    raise exception 'QA multiplas OS: tentativa duplicada deixou atendimento parcial.';
  end if;

  -- Baseline: a compra ativa participa integralmente de metricas, meta e
  -- conversao antes do cancelamento.
  v_metrics := app_private.attendance_metrics_json(v_admin_id, v_store_id);
  v_meta_actuals := app_private.capture_good_morning_actuals_cents(
    v_store_id,
    v_admin_id,
    v_today,
    null
  );
  v_analysis := public.lc_get_attendance_analysis_v1(
    p_session_token => v_store_token,
    p_store_id => v_store_id,
    p_search => null,
    p_tag => null,
    p_professional_id => null,
    p_professional_name => null,
    p_link_status => null,
    p_start_date => v_today,
    p_end_date => v_today
  );

  if coalesce((v_metrics #>> '{all,total}')::bigint, 0) <> 1
     or coalesce((v_metrics #>> '{all,purchases}')::bigint, 0) <> 1
     or coalesce((v_metrics #>> '{all,purchase_revenue}')::numeric, 0) <> 1233.63
     or coalesce((v_metrics #>> '{all,conversion}')::numeric, 0) <> 100
     or coalesce((v_meta_actuals ->> 'month')::bigint, 0) <> 123363
     or coalesce((v_meta_actuals ->> 'today')::bigint, 0) <> 123363
     or coalesce((v_meta_actuals #>> array[
       'professionals', v_professional_id::text, 'month'
     ])::bigint, 0) <> 123363
     or coalesce((v_meta_actuals #>> array[
       'professionals', v_professional_id::text, 'today'
     ])::bigint, 0) <> 123363
     or coalesce((v_analysis #>> '{metrics,total}')::bigint, 0) <> 1
     or coalesce((v_analysis #>> '{metrics,purchases}')::bigint, 0) <> 1
     or coalesce((v_analysis #>> '{metrics,revenue}')::numeric, 0) <> 1233.63
     or coalesce((v_analysis #>> '{metrics,conversion}')::numeric, 0) <> 100
     or coalesce(
       (v_analysis #>> '{metrics,attendance_conversion}')::numeric,
       0
     ) <> 100 then
    raise exception 'QA multiplas OS: baseline operacional incorreta. metrics=% meta=% analysis=%',
      v_metrics,
      v_meta_actuals,
      v_analysis;
  end if;

  -- ---------------------------------------------------------------------
  -- Cancelamento: snapshot imutavel, OS liberadas e indicadores zerados.
  -- ---------------------------------------------------------------------
  v_updated_at := v_record.updated_at;
  v_result := public.lc_cancel_attendance_v1(
    p_session_token => v_store_token,
    p_attendance_id => v_attendance_id,
    p_store_id => v_store_id,
    p_expected_updated_at => v_updated_at,
    p_reason => 'Cancelamento QA para validar snapshots.'
  );

  select attendance.*
  into v_record
  from public.attendances attendance
  where attendance.id = v_attendance_id;

  v_canceled_at := v_record.canceled_at;
  v_canceled_updated_at := v_record.updated_at;
  v_canceled_edit_count := v_record.edit_count;

  select
    pg_catalog.count(*),
    coalesce(pg_catalog.sum(service_orders.amount), 0),
    pg_catalog.count(*) filter (
      where service_orders.canceled_at = v_record.canceled_at
    )
  into v_order_count, v_order_total, v_canceled_order_count
  from app_private.attendance_service_orders service_orders
  where service_orders.attendance_id = v_attendance_id;

  if v_record.canceled_at is null
     or v_record.canceled_by is distinct from v_store_user_id
     or v_record.cancellation_reason
       <> 'Cancelamento QA para validar snapshots.'
     or v_record.canceled_original_tag <> 'purchase'
     or v_record.canceled_original_service_value <> 40.40
     or v_record.canceled_original_purchase_value <> 1233.63
     or v_record.canceled_original_service_order <> v_order_a
     or v_record.canceled_original_idempotency_key <> v_create_key
     or v_record.tag <> 'other'
     or v_record.purchase_value is not null
     or v_record.service_order is not null
     or v_record.idempotency_key <> v_create_key
     or v_order_count <> 3
     or v_order_total <> 1233.63
     or v_canceled_order_count <> 3
     or coalesce((v_result ->> 'canceled')::boolean, false) is not true
     or coalesce((v_result ->> 'cancellation_replay')::boolean, true) is true
     or coalesce(
       (v_result #>> '{attendance,editable}')::boolean,
       true
     ) is true
     or v_result #>> '{attendance,tag}' <> 'purchase'
     or (v_result #>> '{attendance,purchase_value}')::numeric <> 1233.63
     or (v_result #>> '{attendance,service_order}') <> v_order_a
     or pg_catalog.jsonb_array_length(
       coalesce(v_result #> '{attendance,service_orders}', '[]'::jsonb)
     ) <> 3 then
    raise exception 'QA multiplas OS: estado cancelado incorreto. record=% orders=% response=%',
      to_jsonb(v_record),
      app_private.attendance_service_orders_json(v_attendance_id),
      v_result;
  end if;

  if (
    select pg_catalog.count(*)
    from app_private.attendance_cancellation_audit audit
    where audit.attendance_id = v_attendance_id
  ) <> 1 then
    raise exception 'QA multiplas OS: cancelamento nao gerou auditoria unica.';
  end if;

  select audit.*
  into v_cancellation_audit
  from app_private.attendance_cancellation_audit audit
  where audit.attendance_id = v_attendance_id;

  if v_cancellation_audit.reason
       <> 'Cancelamento QA para validar snapshots.'
     or v_cancellation_audit.canceled_by is distinct from v_store_user_id
     or v_cancellation_audit.canceled_at is distinct from v_canceled_at
     or v_cancellation_audit.before_state #>> '{attendance,tag}' <> 'purchase'
     or (
       v_cancellation_audit.before_state
         #>> '{attendance,purchase_value}'
     )::numeric <> 1233.63
     or v_cancellation_audit.before_state -> 'service_orders'
       is distinct from v_orders_after
     or v_cancellation_audit.after_state #>> '{attendance,tag}' <> 'other'
     or (
       v_cancellation_audit.after_state
         #>> '{attendance,canceled_original_purchase_value}'
     )::numeric <> 1233.63
     or v_cancellation_audit.after_state -> 'service_orders'
       is distinct from v_orders_after
     or coalesce(
       (v_cancellation_audit.response ->> 'canceled')::boolean,
       false
     ) is not true
     or coalesce(
       (
         v_cancellation_audit.response
           ->> 'cancellation_replay'
       )::boolean,
       true
     ) is true then
    raise exception 'QA multiplas OS: auditoria/snapshots do cancelamento incorretos: %',
      to_jsonb(v_cancellation_audit);
  end if;

  -- O historico continua pesquisavel por qualquer OS e retorna os flags que
  -- permitem ao frontend destacar o card sem oferecer edicao/cancelamento.
  v_list := public.lc_list_attendances_v4(
    p_session_token => v_store_token,
    p_store_id => v_store_id,
    p_search => pg_catalog.lower(v_order_c),
    p_tag => 'purchase',
    p_professional_id => null,
    p_professional_name => null,
    p_link_status => null,
    p_start_date => v_today,
    p_end_date => v_today,
    p_limit => 50,
    p_offset => 0
  );

  if coalesce((v_list ->> 'total')::bigint, 0) <> 1
     or v_list #>> '{items,0,id}' <> v_attendance_id::text
     or coalesce(
       (v_list #>> '{items,0,canceled}')::boolean,
       false
     ) is not true
     or coalesce(
       (v_list #>> '{items,0,editable}')::boolean,
       true
     ) is true
     or coalesce(
       (v_list #>> '{items,0,cancelable}')::boolean,
       true
     ) is true
     or v_list #>> '{items,0,tag}' <> 'purchase'
     or pg_catalog.jsonb_array_length(
       coalesce(v_list #> '{items,0,service_orders}', '[]'::jsonb)
     ) <> 3 then
    raise exception 'QA multiplas OS: historico cancelado nao foi listado pela OS secundaria: %',
      v_list;
  end if;

  -- A busca textual oferecida na interface também encontra o status visual,
  -- sem depender de nome, descrição ou número da OS.
  v_list := public.lc_list_attendances_v4(
    p_session_token => v_store_token,
    p_store_id => v_store_id,
    p_search => 'cancelado',
    p_tag => null,
    p_professional_id => null,
    p_professional_name => null,
    p_link_status => null,
    p_start_date => v_today,
    p_end_date => v_today,
    p_limit => 50,
    p_offset => 0
  );

  if coalesce((v_list ->> 'total')::bigint, 0) <> 1
     or v_list #>> '{items,0,id}' <> v_attendance_id::text
     or coalesce(
       (v_list #>> '{items,0,canceled}')::boolean,
       false
     ) is not true then
    raise exception 'QA multiplas OS: busca textual nao encontrou o cancelado: %',
      v_list;
  end if;

  -- O primeiro carregamento usa o mesmo contrato V4: sem flash de registro
  -- cancelado como ativo e sem perder as OS secundarias.
  v_workspace := public.lc_get_attendance_workspace(
    p_session_token => v_store_token,
    p_store_id => v_store_id
  );

  if not exists (
    select 1
    from pg_catalog.jsonb_array_elements(
      coalesce(v_workspace -> 'attendances', '[]'::jsonb)
    ) workspace_record(value)
    where workspace_record.value ->> 'id' = v_attendance_id::text
      and coalesce(
        (workspace_record.value ->> 'canceled')::boolean,
        false
      ) is true
      and coalesce(
        (workspace_record.value ->> 'editable')::boolean,
        true
      ) is false
      and pg_catalog.jsonb_array_length(
        coalesce(workspace_record.value -> 'service_orders', '[]'::jsonb)
      ) = 3
  ) then
    raise exception 'QA multiplas OS: workspace inicial nao preservou cancelamento/OS: %',
      v_workspace;
  end if;

  v_metrics := app_private.attendance_metrics_json(v_admin_id, v_store_id);
  v_meta_actuals := app_private.capture_good_morning_actuals_cents(
    v_store_id,
    v_admin_id,
    v_today,
    null
  );
  v_analysis := public.lc_get_attendance_analysis_v1(
    p_session_token => v_store_token,
    p_store_id => v_store_id,
    p_search => null,
    p_tag => null,
    p_professional_id => null,
    p_professional_name => null,
    p_link_status => null,
    p_start_date => v_today,
    p_end_date => v_today
  );

  if coalesce((v_metrics #>> '{all,total}')::bigint, 0) <> 0
     or coalesce((v_metrics #>> '{all,purchases}')::bigint, 0) <> 0
     or coalesce((v_metrics #>> '{all,purchase_revenue}')::numeric, 0) <> 0
     or coalesce((v_metrics #>> '{all,conversion}')::numeric, 0) <> 0
     or coalesce((v_meta_actuals ->> 'month')::bigint, 0) <> 0
     or coalesce((v_meta_actuals ->> 'week')::bigint, 0) <> 0
     or coalesce((v_meta_actuals ->> 'today')::bigint, 0) <> 0
     or coalesce((v_meta_actuals #>> array[
       'professionals', v_professional_id::text, 'month'
     ])::bigint, 0) <> 0
     or coalesce((v_analysis #>> '{metrics,total}')::bigint, 0) <> 0
     or coalesce((v_analysis #>> '{metrics,purchases}')::bigint, 0) <> 0
     or coalesce((v_analysis #>> '{metrics,revenue}')::numeric, 0) <> 0
     or coalesce((v_analysis #>> '{metrics,conversion}')::numeric, 0) <> 0
     or coalesce(
       (v_analysis #>> '{metrics,attendance_conversion}')::numeric,
       0
     ) <> 0 then
    raise exception 'QA multiplas OS: cancelado ainda aparece em metricas/meta/conversao. metrics=% meta=% analysis=%',
      v_metrics,
      v_meta_actuals,
      v_analysis;
  end if;

  -- Repetir com a versao anterior deve ser um replay idempotente: nenhuma
  -- segunda auditoria e nenhum novo timestamp/edit_count.
  v_result := public.lc_cancel_attendance_v1(
    p_session_token => v_store_token,
    p_attendance_id => v_attendance_id,
    p_store_id => v_store_id,
    p_expected_updated_at => v_updated_at,
    p_reason => 'Motivo ignorado no replay.'
  );

  select attendance.*
  into v_record
  from public.attendances attendance
  where attendance.id = v_attendance_id;

  if coalesce((v_result ->> 'cancellation_replay')::boolean, false) is not true
     or v_record.canceled_at is distinct from v_canceled_at
     or v_record.updated_at is distinct from v_canceled_updated_at
     or v_record.edit_count <> v_canceled_edit_count
     or v_record.cancellation_reason
       <> 'Cancelamento QA para validar snapshots.'
     or (
       select pg_catalog.count(*)
       from app_private.attendance_cancellation_audit audit
       where audit.attendance_id = v_attendance_id
     ) <> 1 then
    raise exception 'QA multiplas OS: cancelamento repetido nao foi idempotente. record=% response=%',
      to_jsonb(v_record),
      v_result;
  end if;

  -- Um cancelado nao volta a ser editavel, mesmo com a versao atual.
  v_error := null;
  begin
    perform public.lc_update_attendance_v2(
      p_session_token => v_store_token,
      p_attendance_id => v_attendance_id,
      p_store_id => v_store_id,
      p_professional_name => 'Atendente QA Multiplas OS',
      p_attended_on => v_today,
      p_customer_name => 'Tentativa de editar cancelado',
      p_phone => '11990000001',
      p_cpf => null,
      p_description => 'Esta edicao deve ser bloqueada.',
      p_tag => 'purchase',
      p_service_value => 40.40,
      p_service_orders => v_orders_after,
      p_expected_updated_at => v_canceled_updated_at
    );
  exception when others then
    v_error := sqlerrm;
  end;

  if v_error is null or v_error not like '%cancelado não pode ser editado%' then
    raise exception 'QA multiplas OS: edicao de cancelado nao foi bloqueada: %',
      coalesce(v_error, 'sem erro');
  end if;

  select attendance.*
  into v_record
  from public.attendances attendance
  where attendance.id = v_attendance_id;

  if v_record.updated_at is distinct from v_canceled_updated_at
     or v_record.edit_count <> v_canceled_edit_count then
    raise exception 'QA multiplas OS: tentativa de editar cancelado deixou efeitos.';
  end if;

  -- A OS secundaria cancelada fica no historico, mas sua chave ativa e
  -- liberada para uma nova compra valida da mesma loja.
  v_reuse_orders := pg_catalog.jsonb_build_array(
    pg_catalog.jsonb_build_object(
      'service_order', pg_catalog.lower(v_order_b),
      'amount', 99.99::numeric
    )
  );

  v_result := public.lc_upsert_attendance_v4(
    p_session_token => v_store_token,
    p_store_id => v_store_id,
    p_professional_name => 'Atendente QA Multiplas OS',
    p_customer_name => 'Cliente QA reutilizacao de OS',
    p_phone => '11990000003',
    p_cpf => null,
    p_description => 'Nova compra reutilizando uma OS cancelada.',
    p_tag => 'purchase',
    p_service_value => 99.99,
    p_service_orders => v_reuse_orders,
    p_attended_on => v_today,
    p_idempotency_key => v_reuse_key
  );

  v_reused_attendance_id := nullif(
    v_result #>> '{attendance,id}',
    ''
  )::uuid;

  select
    pg_catalog.count(*) filter (
      where service_orders.canceled_at is null
    ),
    pg_catalog.count(*) filter (
      where service_orders.canceled_at is not null
    )
  into v_active_order_count, v_canceled_order_count
  from app_private.attendance_service_orders service_orders
  where service_orders.store_id = v_store_id
    and service_orders.service_order_key = pg_catalog.lower(v_order_b);

  if v_reused_attendance_id is null
     or v_reused_attendance_id = v_attendance_id
     or (v_result #>> '{attendance,purchase_value}')::numeric <> 99.99
     or v_active_order_count <> 1
     or v_canceled_order_count <> 1
     or not exists (
       select 1
       from app_private.attendance_service_orders service_orders
       where service_orders.attendance_id = v_reused_attendance_id
         and service_orders.service_order_key = pg_catalog.lower(v_order_b)
         and service_orders.amount = 99.99
         and service_orders.canceled_at is null
     )
     or not exists (
       select 1
       from app_private.attendance_service_orders service_orders
       where service_orders.attendance_id = v_attendance_id
         and service_orders.service_order_key = pg_catalog.lower(v_order_b)
         and service_orders.amount = 500.20
         and service_orders.canceled_at = v_canceled_at
     ) then
    raise exception 'QA multiplas OS: OS cancelada nao foi reutilizada com historico preservado. response=%',
      v_result;
  end if;

  -- Um retry tardio da criacao, por exemplo vindo de um dispositivo offline,
  -- nunca pode ressuscitar uma venda cancelada. A chave original permanece
  -- reservada; payload igual devolve o mesmo cancelado e payload diferente
  -- conflita sem criar uma segunda linha.
  v_idempotency_orders := pg_catalog.jsonb_build_array(
    pg_catalog.jsonb_build_object(
      'service_order', 'OS-IDEMP-' || left(v_suffix, 10),
      'amount', 77.77::numeric
    )
  );

  v_result := public.lc_upsert_attendance_v4(
    p_session_token => v_store_token,
    p_store_id => v_store_id,
    p_professional_name => 'Atendente QA Multiplas OS',
    p_customer_name => 'Cliente QA idempotencia cancelada',
    p_phone => '11990000004',
    p_cpf => null,
    p_description => 'Compra que sera cancelada antes do retry.',
    p_tag => 'purchase',
    p_service_value => 77.77,
    p_service_orders => v_idempotency_orders,
    p_attended_on => v_today,
    p_idempotency_key => v_idempotency_key
  );
  v_idempotency_attendance_id := nullif(
    v_result #>> '{attendance,id}',
    ''
  )::uuid;

  select attendance.updated_at
  into v_updated_at
  from public.attendances attendance
  where attendance.id = v_idempotency_attendance_id;

  perform public.lc_cancel_attendance_v1(
    p_session_token => v_store_token,
    p_attendance_id => v_idempotency_attendance_id,
    p_store_id => v_store_id,
    p_expected_updated_at => v_updated_at,
    p_reason => 'Cancelamento QA para retry tardio.'
  );

  v_result := public.lc_upsert_attendance_v4(
    p_session_token => v_store_token,
    p_store_id => v_store_id,
    p_professional_name => 'Atendente QA Multiplas OS',
    p_customer_name => 'Cliente QA idempotencia cancelada',
    p_phone => '11990000004',
    p_cpf => null,
    p_description => 'Compra que sera cancelada antes do retry.',
    p_tag => 'purchase',
    p_service_value => 77.77,
    p_service_orders => v_idempotency_orders,
    p_attended_on => v_today,
    p_idempotency_key => v_idempotency_key
  );

  select pg_catalog.count(*)
  into v_order_count
  from public.attendances attendance
  where attendance.store_id = v_store_id
    and attendance.idempotency_key = v_idempotency_key;

  v_metrics := app_private.attendance_metrics_json(v_admin_id, v_store_id);
  if v_idempotency_attendance_id is null
     or v_result #>> '{attendance,id}'
       is distinct from v_idempotency_attendance_id::text
     or not coalesce((v_result ->> 'idempotent_replay')::boolean, false)
     or not coalesce((v_result ->> 'canceled')::boolean, false)
     or v_order_count <> 1
     or coalesce((v_metrics #>> '{all,total}')::bigint, 0) <> 1
     or coalesce((v_metrics #>> '{all,purchases}')::bigint, 0) <> 1
     or coalesce(
       (v_metrics #>> '{all,purchase_revenue}')::numeric,
       0
     ) <> 99.99 then
    raise exception 'QA multiplas OS: retry tardio ressuscitou cancelado. response=% metrics=%',
      v_result,
      v_metrics;
  end if;

  v_error := null;
  begin
    perform public.lc_upsert_attendance_v4(
      p_session_token => v_store_token,
      p_store_id => v_store_id,
      p_professional_name => 'Atendente QA Multiplas OS',
      p_customer_name => 'Cliente QA idempotencia cancelada',
      p_phone => '11990000004',
      p_cpf => null,
      p_description => 'Payload diferente usando a mesma chave.',
      p_tag => 'purchase',
      p_service_value => 77.77,
      p_service_orders => v_idempotency_orders,
      p_attended_on => v_today,
      p_idempotency_key => v_idempotency_key
    );
  exception when others then
    v_error := sqlerrm;
  end;

  if v_error is null or v_error not like '%já foi usada%' then
    raise exception 'QA multiplas OS: chave cancelada aceitou payload diferente: %',
      coalesce(v_error, 'sem erro');
  end if;

  if (
    select pg_catalog.count(*)
    from public.attendances attendance
    where attendance.store_id = v_store_id
      and attendance.idempotency_key = v_idempotency_key
  ) <> 1 then
    raise exception 'QA multiplas OS: conflito idempotente criou linha parcial.';
  end if;

  raise notice 'attendance-multiple-orders-cancellation smoke passou: 2->3 OS, soma, busca secundaria, duplicata ativa, cancelamento auditavel/idempotente, retry tardio seguro, metricas/meta/conversao, bloqueio de edicao e reutilizacao.';
end;
$attendance_multiple_orders_smoke$;

rollback;
