-- Atendimentos retroativos e metas exatas do Bom Dia Vendedor.
-- A data operacional usa America/Sao_Paulo; created_at continua sendo a
-- data de auditoria da gravacao. O RPC v2 e preservado sem alteracoes.

begin;

set local lock_timeout = '8s';
set local statement_timeout = '120s';
set local search_path = app_private, public, extensions;

create or replace function app_private.rpc_upsert_attendance_v3(
  p_session_token text,
  p_store_id uuid,
  p_professional_name text,
  p_customer_name text,
  p_phone text,
  p_cpf text,
  p_description text,
  p_tag text,
  p_service_value numeric,
  p_purchase_value numeric,
  p_service_order text,
  p_attended_on date default null,
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_store_id uuid;
  v_professional public.prospection_professionals%rowtype;
  v_lead public.leads%rowtype;
  v_prospection public.prospections%rowtype;
  v_existing public.attendances%rowtype;
  v_attendance_id uuid;
  v_customer_name text := left(btrim(coalesce(p_customer_name, '')), 240);
  v_professional_name text := left(btrim(coalesce(p_professional_name, '')), 200);
  v_phone text := nullif(left(btrim(coalesce(p_phone, '')), 80), '');
  v_phone_normalized text;
  v_cpf text := nullif(left(btrim(coalesce(p_cpf, '')), 14), '');
  v_cpf_normalized text;
  v_description text := left(btrim(coalesce(p_description, '')), 4000);
  v_tag text;
  v_service_value numeric(14,2) := p_service_value;
  v_purchase_value numeric(14,2) := p_purchase_value;
  v_service_order text := nullif(left(btrim(coalesce(p_service_order, '')), 120), '');
  v_idempotency_key text;
  v_fingerprint text;
  v_fingerprint_payload jsonb;
  v_lead_count integer := 0;
  v_prospection_count integer := 0;
  v_lead_candidates jsonb := '[]'::jsonb;
  v_prospection_candidates jsonb := '[]'::jsonb;
  v_lead_found boolean := false;
  v_prospection_found boolean := false;
  v_lead_visit_applied boolean := false;
  v_lead_purchase_applied boolean := false;
  v_prospection_visit_applied boolean := false;
  v_prospection_purchase_applied boolean := false;
  v_purchase_credit_applied boolean := false;
  v_match_status text := 'unmatched';
  v_prospection_professional_id uuid;
  v_prospection_professional_name text;
  v_credited_professional_id uuid;
  v_credited_professional_name text;
  v_bonus_minimum numeric(14,2) := 300;
  v_bonus_amount numeric(14,2) := 20;
  v_bonus_eligible boolean := false;
  v_bonus_awarded numeric(14,2) := 0;
  v_bonus_credit_status text := 'not_applicable';
  v_now timestamptz := clock_timestamp();
  v_today date;
  v_min_attended_on date;
  v_attended_on date;
  v_attended_at timestamptz;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text = 'store' then
    if p_store_id is not null and p_store_id <> v_session.user_store_id then
      raise exception 'Cliente não pode registrar atendimento em outra loja.';
    end if;
    v_store_id := v_session.user_store_id;
  else
    v_store_id := p_store_id;
  end if;
  if v_store_id is null then raise exception 'Selecione o cliente do atendimento.'; end if;
  if not app_private.attendance_store_allowed(
    v_session.admin_user_id, v_session.user_id, v_session.user_role,
    v_session.user_store_id, v_store_id
  ) then raise exception 'Cliente não encontrado ou sem permissão.'; end if;

  v_today := timezone('America/Sao_Paulo', v_now)::date;
  v_min_attended_on := (v_today - interval '2 years')::date;
  v_attended_on := coalesce(p_attended_on, v_today);
  if v_attended_on > v_today then
    raise exception 'A data do atendimento não pode estar no futuro.';
  end if;

  -- Mantem a hora local da gravacao na data escolhida. Assim, registros do
  -- mesmo dia continuam ordenaveis sem depender de meia-noite/UTC.
  v_attended_at := (
    v_attended_on + timezone('America/Sao_Paulo', v_now)::time
  ) at time zone 'America/Sao_Paulo';

  if v_attended_on < v_min_attended_on then
    raise exception 'A data do atendimento deve estar dentro dos últimos 2 anos.';
  end if;

  if v_professional_name = '' then raise exception 'Informe o profissional atendente.'; end if;
  if v_customer_name = '' then raise exception 'Informe o nome do cliente.'; end if;
  if v_description = '' then raise exception 'Descreva o atendimento.'; end if;

  v_phone_normalized := app_private.attendance_normalize_phone(v_phone);
  v_cpf_normalized := app_private.attendance_normalize_cpf(v_cpf);
  if v_phone is not null and v_phone_normalized is null then
    raise exception 'Informe um telefone válido com DDD.';
  end if;
  if v_cpf is not null and (v_cpf_normalized is null or not app_private.is_valid_cpf(v_cpf)) then
    raise exception 'Informe um CPF válido.';
  end if;
  if v_phone_normalized is null and v_cpf_normalized is null then
    raise exception 'Informe o telefone ou o CPF do cliente.';
  end if;

  v_tag := app_private.attendance_normalize_tag(p_tag);
  if v_tag is null then raise exception 'Use a etiqueta Orçamento, Compra ou Outro.'; end if;
  if v_service_value is not null and v_service_value < 0 then
    raise exception 'O valor do atendimento não pode ser negativo.';
  end if;
  if v_tag = 'purchase' then
    v_purchase_value := coalesce(v_purchase_value, v_service_value);
    if coalesce(v_purchase_value, 0) <= 0 then raise exception 'Informe um valor de compra maior que zero.'; end if;
    if v_service_order is null then raise exception 'Informe o número da OS.'; end if;
  elsif v_purchase_value is not null or v_service_order is not null then
    raise exception 'Valor da compra e OS só podem ser informados na etiqueta Compra.';
  end if;

  select pp.* into v_professional
  from public.prospection_professionals pp
  where pp.store_id = v_store_id
    and pp.admin_user_id = v_session.admin_user_id
    and pp.archived_at is null
    and lower(btrim(pp.name)) = lower(v_professional_name)
  order by pp.created_at
  limit 1
  for share;
  if not found then raise exception 'Selecione um profissional cadastrado para esta empresa.'; end if;
  v_professional_name := v_professional.name;

  select coalesce(ps.bonus_minimum, 300), coalesce(ps.bonus_amount, 20)
  into v_bonus_minimum, v_bonus_amount
  from public.stores st
  left join public.prospection_store_settings ps
    on ps.store_id = st.id and ps.admin_user_id = st.admin_user_id
  where st.id = v_store_id and st.admin_user_id = v_session.admin_user_id;

  v_fingerprint_payload := jsonb_build_object(
    'store_id', v_store_id,
    'professional_id', v_professional.id,
    'professional_name', lower(v_professional_name),
    'customer_name', lower(v_customer_name),
    'phone', v_phone_normalized,
    'cpf', v_cpf_normalized,
    'description', v_description,
    'tag', v_tag,
    'service_value', v_service_value,
    'purchase_value', v_purchase_value,
    'service_order', lower(coalesce(v_service_order, '')),
    'attended_on', v_attended_on
  );
  v_fingerprint := encode(extensions.digest(convert_to(v_fingerprint_payload::text, 'UTF8'), 'sha256'), 'hex');

  v_idempotency_key := nullif(left(btrim(coalesce(p_idempotency_key, '')), 200), '');
  if v_idempotency_key is null and v_tag = 'purchase' then
    v_idempotency_key := 'purchase-os:' || encode(
      extensions.digest(convert_to(lower(v_service_order), 'UTF8'), 'sha256'), 'hex'
    );
  elsif v_idempotency_key is null then
    v_idempotency_key := 'auto:' || encode(extensions.digest(convert_to(
      v_fingerprint || ':' || floor(extract(epoch from v_now) / 600)::bigint::text,
      'UTF8'
    ), 'sha256'), 'hex');
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('attendance:key:' || v_store_id::text || ':' || v_idempotency_key, 0)
  );
  select * into v_existing
  from public.attendances a
  where a.store_id = v_store_id and a.idempotency_key = v_idempotency_key
  for update;
  if not found and v_tag = 'purchase' then
    select * into v_existing
    from public.attendances a
    where a.store_id = v_store_id and a.tag = 'purchase'
      and lower(btrim(a.service_order)) = lower(v_service_order)
    for update;
  end if;
  if found then
    if v_existing.request_fingerprint <> v_fingerprint then
      raise exception 'Esta chave ou OS já foi usada em outro atendimento com dados diferentes.';
    end if;
    return app_private.attendance_result_with_identity(v_existing.id, true);
  end if;

  if v_phone_normalized is not null then
    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended('attendance:phone:' || v_store_id::text || ':' || v_phone_normalized, 0)
    );
  end if;
  if v_cpf_normalized is not null then
    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended('attendance:cpf:' || v_store_id::text || ':' || v_cpf_normalized, 0)
    );
  end if;

  select count(*)::integer into v_lead_count
  from public.leads l
  where l.store_id = v_store_id and l.admin_user_id = v_session.admin_user_id
    and (
      (v_phone_normalized is not null and app_private.attendance_normalize_phone(l.phone) = v_phone_normalized)
      or (v_cpf_normalized is not null and app_private.attendance_normalize_cpf(l.cpf) = v_cpf_normalized)
    );
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', c.id, 'name', c.name, 'phone', c.phone, 'cpf', c.cpf,
    'visited', c.visited, 'purchased', c.bought, 'created_at', c.created_at
  ) order by c.created_at desc, c.id desc), '[]'::jsonb)
  into v_lead_candidates
  from (
    select l.* from public.leads l
    where l.store_id = v_store_id and l.admin_user_id = v_session.admin_user_id
      and (
        (v_phone_normalized is not null and app_private.attendance_normalize_phone(l.phone) = v_phone_normalized)
        or (v_cpf_normalized is not null and app_private.attendance_normalize_cpf(l.cpf) = v_cpf_normalized)
      )
    order by l.created_at desc, l.id desc limit 20
  ) c;
  if v_lead_count = 1 then
    select l.* into v_lead from public.leads l
    where l.store_id = v_store_id and l.admin_user_id = v_session.admin_user_id
      and (
        (v_phone_normalized is not null and app_private.attendance_normalize_phone(l.phone) = v_phone_normalized)
        or (v_cpf_normalized is not null and app_private.attendance_normalize_cpf(l.cpf) = v_cpf_normalized)
      )
    for update;
    v_lead_found := found;
  end if;

  select count(*)::integer into v_prospection_count
  from public.prospections pr
  where pr.store_id = v_store_id and pr.admin_user_id = v_session.admin_user_id
    and (
      (v_phone_normalized is not null and app_private.attendance_normalize_phone(pr.phone) = v_phone_normalized)
      or (v_cpf_normalized is not null and app_private.attendance_normalize_cpf(pr.cpf) = v_cpf_normalized)
    );
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', c.id, 'name', c.name, 'phone', c.phone, 'cpf', c.cpf,
    'professional_id', c.professional_id,
    'professional_name', coalesce(pp.name, c.professional_name_snapshot),
    'returned_at', c.returned_at, 'purchased_at', c.purchased_at,
    'purchase_value', c.purchase_amount, 'service_order', c.purchase_order,
    'created_at', c.created_at
  ) order by c.created_at desc, c.id desc), '[]'::jsonb)
  into v_prospection_candidates
  from (
    select pr.* from public.prospections pr
    where pr.store_id = v_store_id and pr.admin_user_id = v_session.admin_user_id
      and (
        (v_phone_normalized is not null and app_private.attendance_normalize_phone(pr.phone) = v_phone_normalized)
        or (v_cpf_normalized is not null and app_private.attendance_normalize_cpf(pr.cpf) = v_cpf_normalized)
      )
    order by pr.created_at desc, pr.id desc limit 20
  ) c
  left join public.prospection_professionals pp on pp.id = c.professional_id;
  if v_prospection_count = 1 then
    select pr.* into v_prospection from public.prospections pr
    where pr.store_id = v_store_id and pr.admin_user_id = v_session.admin_user_id
      and (
        (v_phone_normalized is not null and app_private.attendance_normalize_phone(pr.phone) = v_phone_normalized)
        or (v_cpf_normalized is not null and app_private.attendance_normalize_cpf(pr.cpf) = v_cpf_normalized)
      )
    for update;
    v_prospection_found := found;
  end if;

  if v_tag = 'purchase' then
    v_bonus_credit_status := case
      when v_prospection_count = 0 then 'no_prospection'
      when v_prospection_count > 1 then 'ambiguous_prospection'
      else 'already_converted'
    end;
  end if;

  if v_lead_found then
    v_lead_visit_applied := coalesce(v_lead.visited, '') <> 'Sim';
    v_lead_purchase_applied := v_tag = 'purchase' and coalesce(v_lead.bought, '') <> 'Sim';
    update public.leads l set
      visited = 'Sim',
      bought = case when v_tag = 'purchase' then 'Sim' else l.bought end,
      purchase_amount = case when v_tag = 'purchase' then coalesce(l.purchase_amount, v_purchase_value) else l.purchase_amount end,
      service_order = case when v_tag = 'purchase' then coalesce(l.service_order, v_service_order) else l.service_order end,
      updated_by = v_session.user_id
    where l.id = v_lead.id;
  end if;

  if v_prospection_found then
    v_prospection_visit_applied := v_prospection.returned_at is null;
    v_prospection_purchase_applied := v_tag = 'purchase' and v_prospection.purchased_at is null;
    v_prospection_professional_id := v_prospection.professional_id;
    select coalesce(
      (select pp.name from public.prospection_professionals pp where pp.id = v_prospection.professional_id),
      nullif(btrim(coalesce(v_prospection.professional_name_snapshot, '')), '')
    ) into v_prospection_professional_name;

    if v_tag = 'purchase' then
      if not v_prospection_purchase_applied then
        v_bonus_credit_status := 'already_converted';
      elsif v_prospection_professional_id is null and v_prospection_professional_name is null then
        v_bonus_credit_status := 'missing_professional';
      else
        v_purchase_credit_applied := true;
        v_credited_professional_id := v_prospection_professional_id;
        v_credited_professional_name := v_prospection_professional_name;
        v_bonus_eligible := v_purchase_value >= v_bonus_minimum;
        v_bonus_awarded := case when v_bonus_eligible then v_bonus_amount else 0 end;
        v_bonus_credit_status := case when v_bonus_eligible then 'awarded' else 'below_minimum' end;
      end if;
    end if;

    update public.prospections pr set
      returned_at = coalesce(pr.returned_at, v_attended_at),
      purchased_at = case when v_tag = 'purchase' then coalesce(pr.purchased_at, v_attended_at) else pr.purchased_at end,
      purchase_amount = case when v_tag = 'purchase' then coalesce(pr.purchase_amount, v_purchase_value) else pr.purchase_amount end,
      purchase_order = case when v_tag = 'purchase' then coalesce(pr.purchase_order, v_service_order) else pr.purchase_order end,
      updated_by = v_session.user_id
    where pr.id = v_prospection.id;
  end if;

  v_match_status := case
    when v_lead_found and v_prospection_found then 'both'
    when v_lead_found then 'lead'
    when v_prospection_found then 'prospection'
    else 'unmatched'
  end;

  insert into public.attendances (
    admin_user_id, store_id,
    professional_id, professional_name_snapshot,
    credited_professional_id, credited_professional_name_snapshot,
    prospection_professional_id, prospection_professional_name_snapshot,
    bonus_minimum_snapshot, bonus_amount_snapshot, bonus_eligible, bonus_awarded_amount,
    bonus_credit_status, customer_name, phone, phone_normalized, customer_cpf, cpf_normalized,
    description, tag, service_value, purchase_value, service_order,
    lead_id, prospection_id, match_status,
    lead_match_count, prospection_match_count, match_ambiguous,
    lead_candidates, prospection_candidates,
    lead_visit_applied, lead_purchase_applied,
    prospection_visit_applied, prospection_purchase_applied,
    purchase_credit_applied, attended_at, outcome_applied_at,
    idempotency_key, request_fingerprint, metadata, created_by
  ) values (
    v_session.admin_user_id, v_store_id,
    v_professional.id, v_professional_name,
    v_credited_professional_id, v_credited_professional_name,
    v_prospection_professional_id, v_prospection_professional_name,
    v_bonus_minimum, v_bonus_amount, v_bonus_eligible, v_bonus_awarded,
    v_bonus_credit_status, v_customer_name, v_phone, v_phone_normalized, v_cpf, v_cpf_normalized,
    v_description, v_tag, v_service_value,
    case when v_tag = 'purchase' then v_purchase_value end,
    case when v_tag = 'purchase' then v_service_order end,
    case when v_lead_found then v_lead.id end,
    case when v_prospection_found then v_prospection.id end,
    v_match_status, v_lead_count, v_prospection_count,
    v_lead_count > 1 or v_prospection_count > 1,
    v_lead_candidates, v_prospection_candidates,
    v_lead_visit_applied, v_lead_purchase_applied,
    v_prospection_visit_applied, v_prospection_purchase_applied,
    v_purchase_credit_applied, v_attended_at,
    case when v_lead_found or v_prospection_found then v_now end,
    v_idempotency_key, v_fingerprint,
    jsonb_build_object(
      'matching_strategy', 'unique_phone_or_cpf_same_store',
      'matched_by_phone', v_phone_normalized is not null,
      'matched_by_cpf', v_cpf_normalized is not null,
      'lead_candidates', v_lead_count,
      'prospection_candidates', v_prospection_count,
      'ambiguous', v_lead_count > 1 or v_prospection_count > 1,
      'bonus_credit_status', v_bonus_credit_status,
      'bonus_credit_reason', app_private.attendance_bonus_credit_reason(v_bonus_credit_status),
      'bonus_review_required', v_bonus_credit_status in ('ambiguous_prospection', 'missing_professional'),
      'attended_on', v_attended_on,
      'recorded_at', v_now,
      'retroactive', v_attended_on < v_today,
      'retention_years', 2
    ),
    v_session.user_id
  ) returning id into v_attendance_id;

  delete from public.attendances
  where store_id = v_store_id and attended_at < v_now - interval '2 years';

  return app_private.attendance_result_with_identity(v_attendance_id, false);
end;
$$;

create or replace function public.lc_upsert_attendance_v3(
  p_session_token text,
  p_store_id uuid,
  p_professional_name text,
  p_customer_name text,
  p_phone text,
  p_cpf text,
  p_description text,
  p_tag text,
  p_service_value numeric,
  p_purchase_value numeric,
  p_service_order text,
  p_attended_on date default null,
  p_idempotency_key text default null
)
returns jsonb
language sql
security invoker
set search_path = app_private, public, extensions
as $$
  select app_private.rpc_upsert_attendance_v3(
    p_session_token, p_store_id, p_professional_name, p_customer_name,
    p_phone, p_cpf, p_description, p_tag, p_service_value,
    p_purchase_value, p_service_order, p_attended_on, p_idempotency_key
  );
$$;

-- Rateio cumulativo em centavos. A diferenca entre dois pontos cumulativos
-- distribui os centavos residuais ao longo do mes e garante fechamento exato.
create or replace function app_private.good_morning_seller_cumulative_goal_cents(
  p_goal_cents bigint,
  p_workdays integer,
  p_completed_workdays integer
)
returns bigint
language sql
immutable
security invoker
set search_path = app_private, public, extensions
as $$
  select case
    when coalesce(p_goal_cents, 0) <= 0
      or coalesce(p_workdays, 0) <= 0
      or coalesce(p_completed_workdays, 0) <= 0 then 0::bigint
    when p_completed_workdays >= p_workdays then p_goal_cents
    else round(
      p_goal_cents::numeric * p_completed_workdays::numeric / p_workdays::numeric
    )::bigint
  end;
$$;

create or replace function app_private.rpc_get_good_morning_seller_workspace(
  p_session_token text,
  p_store_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_settings public.good_morning_seller_settings%rowtype;
  v_today date := timezone('America/Sao_Paulo', now())::date;
  v_month_start date;
  v_month_end date;
  v_iso_week_start date;
  v_iso_week_end date;
  v_week_start date;
  v_week_end date;
  v_workdays_in_month integer := 0;
  v_workdays_in_week integer := 0;
  v_today_workday_ordinal integer := 0;
  v_before_today_workdays integer := 0;
  v_before_week_workdays integer := 0;
  v_through_week_workdays integer := 0;
  v_today_is_working_day boolean := false;
  v_has_settings boolean := false;
  v_configured boolean := false;
  v_allocations_match_team boolean := false;
  v_current_professional_valid boolean := false;
  v_queue_min integer := 0;
  v_queue_max integer := 0;
  v_active_professional_count integer := 0;
  v_allocation_count integer := 0;
  v_allocation_sum_cents bigint := 0;
  v_monthly_goal numeric(14, 2) := 0;
  v_monthly_goal_cents bigint := 0;
  v_day_goal_cents bigint := 0;
  v_week_goal_cents bigint := 0;
  v_month_goal_cents bigint := 0;
  v_month_actual numeric(14, 2) := 0;
  v_week_actual numeric(14, 2) := 0;
  v_day_actual numeric(14, 2) := 0;
  v_professionals jsonb := '[]'::jsonb;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if not app_private.good_morning_seller_store_allowed(
    v_session.admin_user_id,
    v_session.user_id,
    v_session.user_role,
    v_session.user_store_id,
    p_store_id
  ) then
    raise exception 'Bom Dia Vendedor não está licenciado para este cliente.';
  end if;

  v_month_start := date_trunc('month', v_today)::date;
  v_month_end := (v_month_start + interval '1 month - 1 day')::date;
  v_iso_week_start := v_today - (extract(isodow from v_today)::integer - 1);
  v_iso_week_end := v_iso_week_start + 6;
  v_week_start := greatest(v_month_start, v_iso_week_start);
  v_week_end := least(v_month_end, v_iso_week_end);
  v_today_is_working_day := extract(isodow from v_today)::integer between 1 and 6;

  select
    count(*)::integer,
    count(*) filter (where business_day <= v_today)::integer,
    count(*) filter (where business_day < v_today)::integer,
    count(*) filter (where business_day < v_week_start)::integer,
    count(*) filter (where business_day <= v_week_end)::integer
  into
    v_workdays_in_month,
    v_today_workday_ordinal,
    v_before_today_workdays,
    v_before_week_workdays,
    v_through_week_workdays
  from (
    select v_month_start + offsets.day_offset as business_day
    from generate_series(0, v_month_end - v_month_start) as offsets(day_offset)
    where extract(isodow from (v_month_start + offsets.day_offset))::integer between 1 and 6
  ) calendar;

  v_workdays_in_week := greatest(v_through_week_workdays - v_before_week_workdays, 0);

  select *
  into v_settings
  from public.good_morning_seller_settings settings
  where settings.store_id = p_store_id;
  v_has_settings := found;

  if v_has_settings then
    v_monthly_goal := v_settings.monthly_goal;
    v_monthly_goal_cents := round(v_settings.monthly_goal * 100)::bigint;
  end if;

  select count(*)::integer
  into v_active_professional_count
  from public.prospection_professionals pp
  where pp.store_id = p_store_id
    and pp.admin_user_id = v_session.admin_user_id
    and pp.is_active = true
    and pp.archived_at is null;

  select
    count(*)::integer,
    coalesce(sum(round(allocation.goal_amount * 100)::bigint), 0)::bigint,
    coalesce(min(allocation.queue_position), 0)::integer,
    coalesce(max(allocation.queue_position), 0)::integer
  into
    v_allocation_count,
    v_allocation_sum_cents,
    v_queue_min,
    v_queue_max
  from public.good_morning_seller_allocations allocation
  where allocation.store_id = p_store_id;

  select
    not exists (
      select 1
      from public.prospection_professionals pp
      left join public.good_morning_seller_allocations allocation
        on allocation.store_id = pp.store_id
       and allocation.professional_id = pp.id
      where pp.store_id = p_store_id
        and pp.admin_user_id = v_session.admin_user_id
        and pp.is_active = true
        and pp.archived_at is null
        and allocation.professional_id is null
    )
    and not exists (
      select 1
      from public.good_morning_seller_allocations allocation
      left join public.prospection_professionals pp
        on pp.id = allocation.professional_id
       and pp.store_id = allocation.store_id
       and pp.admin_user_id = allocation.admin_user_id
       and pp.is_active = true
       and pp.archived_at is null
      where allocation.store_id = p_store_id
        and pp.id is null
    )
  into v_allocations_match_team;

  select exists (
    select 1
    from public.good_morning_seller_allocations allocation
    join public.prospection_professionals pp
      on pp.id = allocation.professional_id
     and pp.store_id = allocation.store_id
     and pp.admin_user_id = allocation.admin_user_id
     and pp.is_active = true
     and pp.archived_at is null
    where allocation.store_id = p_store_id
      and allocation.professional_id = v_settings.current_professional_id
  ) into v_current_professional_valid;

  v_configured := v_has_settings
    and v_settings.goal_month = v_month_start
    and v_active_professional_count > 0
    and v_allocation_count = v_active_professional_count
    and v_allocations_match_team
    and v_allocation_sum_cents = v_monthly_goal_cents
    and v_queue_min = 1
    and v_queue_max = v_allocation_count
    and v_current_professional_valid;

  select
    coalesce(sum(a.purchase_value) filter (
      where timezone('America/Sao_Paulo', a.attended_at)::date between v_month_start and v_month_end
    ), 0),
    coalesce(sum(a.purchase_value) filter (
      where timezone('America/Sao_Paulo', a.attended_at)::date between v_week_start and v_week_end
    ), 0),
    coalesce(sum(a.purchase_value) filter (
      where timezone('America/Sao_Paulo', a.attended_at)::date = v_today
    ), 0)
  into v_month_actual, v_week_actual, v_day_actual
  from public.attendances a
  where a.store_id = p_store_id
    and a.admin_user_id = v_session.admin_user_id
    and a.tag = 'purchase'
    and a.purchase_value > 0
    and a.attended_at >= (v_month_start::timestamp at time zone 'America/Sao_Paulo')
    and a.attended_at < ((v_month_end + 1)::timestamp at time zone 'America/Sao_Paulo');

  with team as (
    select
      pp.id,
      pp.name,
      pp.is_active,
      row_number() over (order by pp.created_at, pp.name)::integer as default_position,
      coalesce(sum(a.purchase_value) filter (
        where a.tag = 'purchase'
          and a.purchase_value > 0
          and timezone('America/Sao_Paulo', a.attended_at)::date between v_month_start and v_month_end
      ), 0) as actual_month,
      coalesce(sum(a.purchase_value) filter (
        where a.tag = 'purchase'
          and a.purchase_value > 0
          and timezone('America/Sao_Paulo', a.attended_at)::date between v_week_start and v_week_end
      ), 0) as actual_week,
      coalesce(sum(a.purchase_value) filter (
        where a.tag = 'purchase'
          and a.purchase_value > 0
          and timezone('America/Sao_Paulo', a.attended_at)::date = v_today
      ), 0) as actual_today
    from public.prospection_professionals pp
    left join public.attendances a
      on a.professional_id = pp.id
      and a.store_id = pp.store_id
      and a.admin_user_id = pp.admin_user_id
      and a.attended_at >= (v_month_start::timestamp at time zone 'America/Sao_Paulo')
      and a.attended_at < ((v_month_end + 1)::timestamp at time zone 'America/Sao_Paulo')
    where pp.store_id = p_store_id
      and pp.admin_user_id = v_session.admin_user_id
      and pp.is_active = true
      and pp.archived_at is null
    group by pp.id, pp.name, pp.is_active, pp.created_at
  ), calculated as (
    select
      team.*,
      case
        when v_configured then coalesce(allocation.queue_position, team.default_position)
        else team.default_position
      end as queue_position,
      case
        when v_configured then round(coalesce(allocation.goal_amount, 0) * 100)::bigint
        else 0::bigint
      end as goal_month_cents,
      case
        when v_configured and v_today_is_working_day then
          app_private.good_morning_seller_cumulative_goal_cents(
            round(coalesce(allocation.goal_amount, 0) * 100)::bigint,
            v_workdays_in_month,
            v_today_workday_ordinal
          )
          - app_private.good_morning_seller_cumulative_goal_cents(
            round(coalesce(allocation.goal_amount, 0) * 100)::bigint,
            v_workdays_in_month,
            v_before_today_workdays
          )
        else 0::bigint
      end as goal_today_cents,
      case
        when v_configured then
          app_private.good_morning_seller_cumulative_goal_cents(
            round(coalesce(allocation.goal_amount, 0) * 100)::bigint,
            v_workdays_in_month,
            v_through_week_workdays
          )
          - app_private.good_morning_seller_cumulative_goal_cents(
            round(coalesce(allocation.goal_amount, 0) * 100)::bigint,
            v_workdays_in_month,
            v_before_week_workdays
          )
        else 0::bigint
      end as goal_week_cents
    from team
    left join public.good_morning_seller_allocations allocation
      on allocation.store_id = p_store_id
      and allocation.professional_id = team.id
  )
  select
    coalesce(jsonb_agg(
      jsonb_build_object(
        'id', calculated.id,
        'name', calculated.name,
        'is_active', calculated.is_active,
        'goal_amount', calculated.goal_month_cents::numeric / 100,
        'goal_month', calculated.goal_month_cents::numeric / 100,
        'goal_week', calculated.goal_week_cents::numeric / 100,
        'goal_today', calculated.goal_today_cents::numeric / 100,
        'queue_position', calculated.queue_position,
        'is_current', v_configured and calculated.id = v_settings.current_professional_id,
        'actual_month', calculated.actual_month,
        'actual_week', calculated.actual_week,
        'actual_today', calculated.actual_today
      ) order by calculated.queue_position, calculated.name
    ), '[]'::jsonb),
    coalesce(sum(calculated.goal_today_cents), 0)::bigint,
    coalesce(sum(calculated.goal_week_cents), 0)::bigint,
    coalesce(sum(calculated.goal_month_cents), 0)::bigint
  into
    v_professionals,
    v_day_goal_cents,
    v_week_goal_cents,
    v_month_goal_cents
  from calculated;

  return jsonb_build_object(
    'licensed', true,
    'configured', v_configured,
    'goal_month', v_month_start,
    'saved_goal_month', case when v_has_settings then v_settings.goal_month else null end,
    'allocation_mode', coalesce(v_settings.allocation_mode, 'equal'),
    'monthly_goal', case when v_configured then v_month_goal_cents::numeric / 100 else 0 end,
    'last_monthly_goal', v_monthly_goal,
    'today', v_today,
    'week_start', v_week_start,
    'week_end', v_week_end,
    'workdays_in_month', v_workdays_in_month,
    'workdays_in_week', v_workdays_in_week,
    'today_is_working_day', v_today_is_working_day,
    'goals', jsonb_build_object(
      'today', jsonb_build_object('target', v_day_goal_cents::numeric / 100, 'actual', v_day_actual),
      'week', jsonb_build_object('target', v_week_goal_cents::numeric / 100, 'actual', v_week_actual),
      'month', jsonb_build_object('target', v_month_goal_cents::numeric / 100, 'actual', v_month_actual)
    ),
    'current_professional_id', case when v_configured then v_settings.current_professional_id else null end,
    'professionals', v_professionals
  );
end;
$$;

revoke all on function app_private.rpc_upsert_attendance_v3(
  text, uuid, text, text, text, text, text, text, numeric, numeric, text, date, text
) from public, anon, authenticated;
grant execute on function app_private.rpc_upsert_attendance_v3(
  text, uuid, text, text, text, text, text, text, numeric, numeric, text, date, text
) to anon, authenticated;

revoke all on function public.lc_upsert_attendance_v3(
  text, uuid, text, text, text, text, text, text, numeric, numeric, text, date, text
) from public, anon, authenticated;
grant execute on function public.lc_upsert_attendance_v3(
  text, uuid, text, text, text, text, text, text, numeric, numeric, text, date, text
) to anon, authenticated;

revoke all on function app_private.good_morning_seller_cumulative_goal_cents(
  bigint, integer, integer
) from public, anon, authenticated;

comment on function public.lc_upsert_attendance_v3(
  text, uuid, text, text, text, text, text, text, numeric, numeric, text, date, text
) is
  'Registra atendimento na data operacional informada, com auditoria, idempotencia e vinculos isolados por cliente.';

comment on function app_private.good_morning_seller_cumulative_goal_cents(
  bigint, integer, integer
) is
  'Calcula a parcela cumulativa exata de uma meta em centavos ao longo dos dias uteis de segunda a sabado.';

comment on function public.lc_get_good_morning_seller_workspace(text, uuid) is
  'Retorna metas mensal, semanal, diaria e individuais com rateio exato em centavos, considerando segunda a sabado.';

notify pgrst, 'reload schema';

commit;
