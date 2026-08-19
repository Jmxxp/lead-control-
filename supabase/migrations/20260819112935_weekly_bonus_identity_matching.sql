begin;

set local lock_timeout = '8s';
set local statement_timeout = '120s';
set local search_path = app_private, public, extensions;

do $$
begin
  if to_regclass('public.leads') is null
     or to_regclass('public.prospections') is null
     or to_regclass('public.attendances') is null then
    raise exception 'Leads, Prospecções e Atendimentos precisam estar instalados antes desta migração.';
  end if;
end $$;

create or replace function app_private.attendance_normalize_cpf(p_value text)
returns text
language sql
immutable
set search_path = app_private, public, extensions
as $$
  select case
    when length(regexp_replace(coalesce(p_value, ''), '[^0-9]', '', 'g')) = 11
      then regexp_replace(coalesce(p_value, ''), '[^0-9]', '', 'g')
    else null
  end;
$$;

alter table public.leads
  add column if not exists cpf text;

alter table public.attendances
  add column if not exists customer_cpf text,
  add column if not exists cpf_normalized text;

alter table public.attendances
  alter column phone drop not null,
  alter column phone_normalized drop not null;

alter table public.attendances
  drop constraint if exists attendances_text_check;

alter table public.attendances
  add constraint attendances_text_check check (
    length(btrim(professional_name_snapshot)) between 1 and 200
    and length(btrim(customer_name)) between 1 and 240
    and (phone is null or length(btrim(phone)) between 1 and 80)
    and (phone_normalized is null or length(phone_normalized) between 8 and 15)
    and (customer_cpf is null or length(btrim(customer_cpf)) between 11 and 14)
    and (cpf_normalized is null or length(cpf_normalized) = 11)
    and (phone_normalized is not null or cpf_normalized is not null)
    and length(btrim(description)) between 1 and 4000
    and length(idempotency_key) between 1 and 200
    and request_fingerprint ~ '^[0-9a-f]{64}$'
    and (service_order is null or length(btrim(service_order)) <= 120)
  );

create index if not exists leads_store_cpf_lookup_idx
  on public.leads (store_id, app_private.attendance_normalize_cpf(cpf))
  where cpf is not null;

create index if not exists prospections_store_cpf_lookup_idx
  on public.prospections (store_id, app_private.attendance_normalize_cpf(cpf))
  where cpf is not null;

create index if not exists attendances_store_cpf_date_idx
  on public.attendances (store_id, cpf_normalized, attended_at desc)
  where cpf_normalized is not null;

create or replace function app_private.attendance_validate_links()
returns trigger
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_expected_status text;
begin
  if new.phone_normalized is distinct from app_private.attendance_normalize_phone(new.phone) then
    raise exception 'Telefone normalizado inconsistente.';
  end if;
  if new.cpf_normalized is distinct from app_private.attendance_normalize_cpf(new.customer_cpf) then
    raise exception 'CPF normalizado inconsistente.';
  end if;
  if new.phone_normalized is null and new.cpf_normalized is null then
    raise exception 'Informe telefone ou CPF.';
  end if;

  if new.professional_id is not null and not exists (
    select 1 from public.prospection_professionals pp
    where pp.id = new.professional_id
      and pp.store_id = new.store_id
      and pp.admin_user_id = new.admin_user_id
  ) then raise exception 'Profissional atendente pertence a outro cliente.'; end if;

  if new.credited_professional_id is not null and not exists (
    select 1 from public.prospection_professionals pp
    where pp.id = new.credited_professional_id
      and pp.store_id = new.store_id
      and pp.admin_user_id = new.admin_user_id
  ) then raise exception 'Profissional creditado pertence a outro cliente.'; end if;

  if new.prospection_professional_id is not null and not exists (
    select 1 from public.prospection_professionals pp
    where pp.id = new.prospection_professional_id
      and pp.store_id = new.store_id
      and pp.admin_user_id = new.admin_user_id
  ) then raise exception 'Profissional original da prospecção pertence a outro cliente.'; end if;

  if new.lead_id is not null and not exists (
    select 1 from public.leads l
    where l.id = new.lead_id and l.store_id = new.store_id and l.admin_user_id = new.admin_user_id
  ) then raise exception 'Lead vinculado pertence a outro cliente.'; end if;

  if new.prospection_id is not null and not exists (
    select 1 from public.prospections pr
    where pr.id = new.prospection_id and pr.store_id = new.store_id and pr.admin_user_id = new.admin_user_id
  ) then raise exception 'Prospecção vinculada pertence a outro cliente.'; end if;

  v_expected_status := case
    when new.lead_id is not null and new.prospection_id is not null then 'both'
    when new.lead_id is not null then 'lead'
    when new.prospection_id is not null then 'prospection'
    else 'unmatched'
  end;
  if new.match_status is distinct from v_expected_status then
    raise exception 'Status de vínculo inconsistente.';
  end if;
  return new;
end;
$$;

create or replace function app_private.rpc_set_lead_cpf(
  p_session_token text,
  p_lead_id uuid,
  p_cpf text default null
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_store_id uuid;
  v_cpf text := nullif(btrim(coalesce(p_cpf, '')), '');
begin
  select * into v_session from app_private.session_user(p_session_token);
  select l.store_id into v_store_id
  from public.leads l
  where l.id = p_lead_id and l.admin_user_id = v_session.admin_user_id;

  if v_store_id is null or not app_private.attendance_store_allowed(
    v_session.admin_user_id, v_session.user_id, v_session.user_role,
    v_session.user_store_id, v_store_id
  ) then
    raise exception 'Lead não encontrado ou sem permissão.';
  end if;
  if v_cpf is not null and not app_private.is_valid_cpf(v_cpf) then
    raise exception 'Informe um CPF válido.';
  end if;

  update public.leads
  set cpf = v_cpf, updated_by = v_session.user_id
  where id = p_lead_id and admin_user_id = v_session.admin_user_id;
  return true;
end;
$$;

create or replace function app_private.rpc_list_leads_v2(p_session_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_rows jsonb;
begin
  select coalesce(
    jsonb_agg(to_jsonb(base_row) || jsonb_build_object('cpf', l.cpf) order by base_row.created_at desc),
    '[]'::jsonb
  )
  into v_rows
  from app_private.rpc_list_leads_b2b(p_session_token) base_row
  join public.leads l on l.id = base_row.id;
  return v_rows;
end;
$$;

create or replace function public.lc_list_leads_v2(p_session_token text)
returns jsonb
language sql
security invoker
set search_path = app_private, public, extensions
as $$
  select app_private.rpc_list_leads_v2(p_session_token);
$$;

create or replace function public.lc_upsert_lead_v2(
  p_session_token text,
  p_lead_id uuid,
  p_name text,
  p_phone text,
  p_cpf text default null,
  p_channel text default null,
  p_campaign text default null,
  p_conversation_start text default null,
  p_conclusion text default null,
  p_scheduled text default null,
  p_scheduled_visit_date date default null,
  p_scheduled_visit_time time default null,
  p_visited text default null,
  p_bought text default null,
  p_purchase_amount numeric default null,
  p_service_order text default null,
  p_notes text default null,
  p_custom_values jsonb default '[]'::jsonb,
  p_store_id uuid default null,
  p_contact_date date default null
)
returns uuid
language plpgsql
security invoker
set search_path = app_private, public, extensions
as $$
declare
  v_lead_id uuid;
begin
  v_lead_id := public.lc_upsert_lead(
    p_session_token, p_lead_id, p_name, p_phone, p_channel, p_campaign,
    p_conversation_start, p_conclusion, p_scheduled, p_scheduled_visit_date,
    p_scheduled_visit_time, p_visited, p_bought, p_purchase_amount,
    p_service_order, p_notes, p_custom_values, p_store_id, p_contact_date
  );
  perform app_private.rpc_set_lead_cpf(p_session_token, v_lead_id, p_cpf);
  return v_lead_id;
end;
$$;

create or replace function public.lc_upsert_lead_with_intelligence_v2(
  p_session_token text,
  p_lead_id uuid,
  p_name text,
  p_phone text,
  p_cpf text default null,
  p_channel text default null,
  p_campaign text default null,
  p_conversation_start text default null,
  p_conclusion text default null,
  p_scheduled text default null,
  p_scheduled_visit_date date default null,
  p_scheduled_visit_time time default null,
  p_visited text default null,
  p_bought text default null,
  p_purchase_amount numeric default null,
  p_service_order text default null,
  p_notes text default null,
  p_custom_values jsonb default '[]'::jsonb,
  p_store_id uuid default null,
  p_contact_date date default null,
  p_intelligence jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security invoker
set search_path = app_private, public, extensions
as $$
declare
  v_lead_id uuid;
begin
  v_lead_id := public.lc_upsert_lead_v2(
    p_session_token, p_lead_id, p_name, p_phone, p_cpf, p_channel, p_campaign,
    p_conversation_start, p_conclusion, p_scheduled, p_scheduled_visit_date,
    p_scheduled_visit_time, p_visited, p_bought, p_purchase_amount,
    p_service_order, p_notes, p_custom_values, p_store_id, p_contact_date
  );
  perform app_private.rpc_save_lead_intelligence(p_session_token, v_lead_id, p_intelligence);
  return v_lead_id;
end;
$$;

create or replace function app_private.attendance_result_with_identity(
  p_attendance_id uuid,
  p_idempotent_replay boolean default false
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_result jsonb;
  v_record jsonb;
  v_cpf text;
  v_cpf_normalized text;
begin
  v_result := app_private.attendance_result_json(p_attendance_id, p_idempotent_replay);
  if v_result is null then return null; end if;
  select a.customer_cpf, a.cpf_normalized
  into v_cpf, v_cpf_normalized
  from public.attendances a
  where a.id = p_attendance_id;
  v_record := coalesce(v_result -> 'attendance', '{}'::jsonb) || jsonb_build_object(
    'customer_cpf', v_cpf,
    'cpf', v_cpf,
    'cpf_normalized', v_cpf_normalized
  );
  return jsonb_set(
    jsonb_set(
      jsonb_set(v_result, '{attendance}', v_record, true),
      '{record}', v_record, true
    ),
    '{registro}', v_record, true
  );
end;
$$;

create or replace function app_private.rpc_upsert_attendance_v2(
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
    'service_order', lower(coalesce(v_service_order, ''))
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
      returned_at = coalesce(pr.returned_at, v_now),
      purchased_at = case when v_tag = 'purchase' then coalesce(pr.purchased_at, v_now) else pr.purchased_at end,
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
    v_purchase_credit_applied, v_now,
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
      'retention_years', 2
    ),
    v_session.user_id
  ) returning id into v_attendance_id;

  delete from public.attendances
  where store_id = v_store_id and attended_at < now() - interval '2 years';

  return app_private.attendance_result_with_identity(v_attendance_id, false);
end;
$$;

create or replace function public.lc_upsert_attendance_v2(
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
  p_idempotency_key text default null
)
returns jsonb
language sql
security invoker
set search_path = app_private, public, extensions
as $$
  select app_private.rpc_upsert_attendance_v2(
    p_session_token, p_store_id, p_professional_name, p_customer_name,
    p_phone, p_cpf, p_description, p_tag, p_service_value,
    p_purchase_value, p_service_order, p_idempotency_key
  );
$$;

create or replace function app_private.rpc_list_attendances_v3(
  p_session_token text,
  p_store_id uuid default null,
  p_search text default null,
  p_tag text default null,
  p_professional_id uuid default null,
  p_professional_name text default null,
  p_link_status text default null,
  p_start_date date default null,
  p_end_date date default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_store_id uuid;
  v_search text := nullif(left(btrim(coalesce(p_search, '')), 200), '');
  v_search_digits text := nullif(regexp_replace(coalesce(p_search, ''), '[^0-9]', '', 'g'), '');
  v_tag text;
  v_professional_name text := nullif(left(btrim(coalesce(p_professional_name, '')), 200), '');
  v_link_status text := lower(nullif(btrim(coalesce(p_link_status, '')), ''));
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_total bigint := 0;
  v_items jsonb := '[]'::jsonb;
begin
  select * into v_session from app_private.session_user(p_session_token);
  if v_session.user_role::text = 'store' then
    if p_store_id is not null and p_store_id <> v_session.user_store_id then
      raise exception 'Cliente não pode consultar atendimentos de outra loja.';
    end if;
    v_store_id := v_session.user_store_id;
  else
    v_store_id := p_store_id;
  end if;
  if v_store_id is null then raise exception 'Selecione um cliente para consultar os atendimentos.'; end if;
  if not app_private.attendance_store_allowed(
    v_session.admin_user_id, v_session.user_id, v_session.user_role,
    v_session.user_store_id, v_store_id
  ) then raise exception 'Cliente não encontrado ou sem permissão.'; end if;

  if nullif(btrim(coalesce(p_tag, '')), '') is not null and lower(btrim(p_tag)) <> 'all' then
    v_tag := app_private.attendance_normalize_tag(p_tag);
    if v_tag is null then raise exception 'Etiqueta de atendimento inválida.'; end if;
  end if;
  if v_link_status is not null and v_link_status not in (
    'all', 'matched', 'standalone', 'review', 'unmatched', 'lead', 'prospection', 'both'
  ) then raise exception 'Filtro de vínculo inválido.'; end if;
  if p_start_date is not null and p_end_date is not null and p_start_date > p_end_date then
    raise exception 'Período inválido.';
  end if;

  with filtered as materialized (
    select a.id, a.attended_at
    from public.attendances a
    where a.store_id = v_store_id
      and a.admin_user_id = v_session.admin_user_id
      and a.attended_at >= now() - interval '2 years'
      and (v_tag is null or a.tag = v_tag)
      and (p_professional_id is null or a.professional_id = p_professional_id)
      and (v_professional_name is null or a.professional_name_snapshot = v_professional_name)
      and (p_start_date is null or a.attended_at >= (p_start_date::timestamp at time zone 'America/Sao_Paulo'))
      and (p_end_date is null or a.attended_at < ((p_end_date + 1)::timestamp at time zone 'America/Sao_Paulo'))
      and (
        v_link_status is null or v_link_status = 'all'
        or (v_link_status = 'matched' and a.match_status <> 'unmatched')
        or (v_link_status = 'standalone' and a.match_status = 'unmatched' and not a.match_ambiguous)
        or (v_link_status = 'review' and a.match_ambiguous)
        or (v_link_status in ('unmatched', 'lead', 'prospection', 'both') and a.match_status = v_link_status)
      )
      and (
        v_search is null
        or a.customer_name ilike '%' || v_search || '%'
        or a.description ilike '%' || v_search || '%'
        or a.professional_name_snapshot ilike '%' || v_search || '%'
        or coalesce(a.credited_professional_name_snapshot, '') ilike '%' || v_search || '%'
        or coalesce(a.service_order, '') ilike '%' || v_search || '%'
        or (
          v_search_digits is not null
          and (
            coalesce(a.phone_normalized, '') like '%' || v_search_digits || '%'
            or coalesce(a.cpf_normalized, '') like '%' || v_search_digits || '%'
          )
        )
      )
  ), page as (
    select * from filtered
    order by attended_at desc, id desc
    limit v_limit offset v_offset
  )
  select
    (select count(*) from filtered),
    coalesce(jsonb_agg(
      (result.payload -> 'attendance') || jsonb_build_object('links', result.payload -> 'links')
      order by p.attended_at desc, p.id desc
    ), '[]'::jsonb)
  into v_total, v_items
  from page p
  cross join lateral (
    select app_private.attendance_result_with_identity(p.id, false) as payload
  ) result;

  return jsonb_build_object(
    'store_id', v_store_id,
    'items', v_items,
    'attendances', v_items,
    'total', v_total,
    'limit', v_limit,
    'offset', v_offset,
    'has_more', v_offset::bigint + jsonb_array_length(v_items)::bigint < v_total
  );
end;
$$;

create or replace function public.lc_list_attendances_v3(
  p_session_token text,
  p_store_id uuid default null,
  p_search text default null,
  p_tag text default null,
  p_professional_id uuid default null,
  p_professional_name text default null,
  p_link_status text default null,
  p_start_date date default null,
  p_end_date date default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language sql
security invoker
set search_path = app_private, public, extensions
as $$
  select app_private.rpc_list_attendances_v3(
    p_session_token, p_store_id, p_search, p_tag, p_professional_id,
    p_professional_name, p_link_status, p_start_date, p_end_date,
    p_limit, p_offset
  );
$$;

create index if not exists prospections_store_purchased_at_idx
  on public.prospections (store_id, purchased_at desc)
  where purchased_at is not null;

create or replace function app_private.rpc_list_prospection_bonus_purchases(
  p_session_token text,
  p_start_date date default null,
  p_end_date date default null,
  p_store_id uuid default null
)
returns table (
  prospection_id uuid,
  store_id uuid,
  store_name text,
  customer_name text,
  professional_id uuid,
  professional_name text,
  purchased_at timestamptz,
  purchase_amount numeric,
  purchase_order text,
  bonus_minimum numeric,
  bonus_amount numeric,
  bonus_eligible boolean,
  bonus_awarded_amount numeric,
  bonus_credit_status text
)
language plpgsql
stable
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_start date := coalesce(
    p_start_date,
    timezone('America/Sao_Paulo', now())::date
      - extract(isodow from timezone('America/Sao_Paulo', now()))::integer + 1
  );
  v_end date := coalesce(p_end_date, timezone('America/Sao_Paulo', now())::date);
begin
  select * into v_session from app_private.session_user(p_session_token);
  if v_start > v_end then raise exception 'Período inválido.'; end if;
  if p_store_id is not null and not app_private.attendance_store_allowed(
    v_session.admin_user_id, v_session.user_id, v_session.user_role,
    v_session.user_store_id, p_store_id
  ) then raise exception 'Cliente não encontrado ou sem permissão.'; end if;

  return query
  select
    pr.id,
    pr.store_id,
    st.name,
    pr.name,
    coalesce(a.credited_professional_id, pr.professional_id),
    coalesce(
      a.credited_professional_name_snapshot,
      pp.name,
      pr.professional_name_snapshot,
      'Sem responsável'
    ),
    pr.purchased_at,
    coalesce(pr.purchase_amount, a.purchase_value, 0)::numeric,
    coalesce(pr.purchase_order, a.service_order),
    coalesce(a.bonus_minimum_snapshot, ps.bonus_minimum, 300)::numeric,
    coalesce(a.bonus_amount_snapshot, ps.bonus_amount, 20)::numeric,
    coalesce(
      a.bonus_eligible,
      (
        (pr.professional_id is not null or nullif(btrim(coalesce(pr.professional_name_snapshot, '')), '') is not null)
        and coalesce(pr.purchase_amount, 0) >= coalesce(ps.bonus_minimum, 300)
      )
    ),
    coalesce(
      a.bonus_awarded_amount,
      case when (
        pr.professional_id is not null or nullif(btrim(coalesce(pr.professional_name_snapshot, '')), '') is not null
      ) and coalesce(pr.purchase_amount, 0) >= coalesce(ps.bonus_minimum, 300)
        then coalesce(ps.bonus_amount, 20) else 0 end
    )::numeric,
    coalesce(
      a.bonus_credit_status,
      case
        when pr.professional_id is null and nullif(btrim(coalesce(pr.professional_name_snapshot, '')), '') is null
          then 'missing_professional'
        when coalesce(pr.purchase_amount, 0) >= coalesce(ps.bonus_minimum, 300)
          then 'awarded'
        else 'below_minimum'
      end
    )
  from public.prospections pr
  join public.stores st
    on st.id = pr.store_id and st.admin_user_id = pr.admin_user_id
  left join public.prospection_store_settings ps
    on ps.store_id = pr.store_id and ps.admin_user_id = pr.admin_user_id
  left join public.prospection_professionals pp on pp.id = pr.professional_id
  left join lateral (
    select ax.*
    from public.attendances ax
    where ax.prospection_id = pr.id and ax.purchase_credit_applied
    order by ax.attended_at, ax.id
    limit 1
  ) a on true
  where pr.admin_user_id = v_session.admin_user_id
    and pr.purchased_at is not null
    and timezone('America/Sao_Paulo', pr.purchased_at)::date between v_start and v_end
    and (p_store_id is null or pr.store_id = p_store_id)
    and app_private.attendance_store_allowed(
      v_session.admin_user_id, v_session.user_id, v_session.user_role,
      v_session.user_store_id, pr.store_id
    )
  order by pr.purchased_at desc, pr.id desc;
end;
$$;

create or replace function public.lc_list_prospection_bonus_purchases(
  p_session_token text,
  p_start_date date default null,
  p_end_date date default null,
  p_store_id uuid default null
)
returns table (
  prospection_id uuid,
  store_id uuid,
  store_name text,
  customer_name text,
  professional_id uuid,
  professional_name text,
  purchased_at timestamptz,
  purchase_amount numeric,
  purchase_order text,
  bonus_minimum numeric,
  bonus_amount numeric,
  bonus_eligible boolean,
  bonus_awarded_amount numeric,
  bonus_credit_status text
)
language sql
security invoker
set search_path = app_private, public, extensions
as $$
  select * from app_private.rpc_list_prospection_bonus_purchases(
    p_session_token, p_start_date, p_end_date, p_store_id
  );
$$;

revoke all on function app_private.attendance_normalize_cpf(text) from public, anon, authenticated;
revoke all on function app_private.rpc_set_lead_cpf(text, uuid, text) from public, anon, authenticated;
revoke all on function app_private.rpc_list_leads_v2(text) from public, anon, authenticated;
revoke all on function app_private.attendance_result_with_identity(uuid, boolean) from public, anon, authenticated;
revoke all on function app_private.rpc_upsert_attendance_v2(text, uuid, text, text, text, text, text, text, numeric, numeric, text, text) from public, anon, authenticated;
revoke all on function app_private.rpc_list_attendances_v3(text, uuid, text, text, uuid, text, text, date, date, integer, integer) from public, anon, authenticated;
revoke all on function app_private.rpc_list_prospection_bonus_purchases(text, date, date, uuid) from public, anon, authenticated;

grant execute on function app_private.rpc_set_lead_cpf(text, uuid, text) to anon, authenticated;
grant execute on function app_private.rpc_list_leads_v2(text) to anon, authenticated;
grant execute on function app_private.rpc_upsert_attendance_v2(text, uuid, text, text, text, text, text, text, numeric, numeric, text, text) to anon, authenticated;
grant execute on function app_private.rpc_list_attendances_v3(text, uuid, text, text, uuid, text, text, date, date, integer, integer) to anon, authenticated;
grant execute on function app_private.rpc_list_prospection_bonus_purchases(text, date, date, uuid) to anon, authenticated;

revoke all on function public.lc_list_leads_v2(text) from public, anon, authenticated;
revoke all on function public.lc_upsert_lead_v2(text, uuid, text, text, text, text, text, text, text, text, date, time, text, text, numeric, text, text, jsonb, uuid, date) from public, anon, authenticated;
revoke all on function public.lc_upsert_lead_with_intelligence_v2(text, uuid, text, text, text, text, text, text, text, text, date, time, text, text, numeric, text, text, jsonb, uuid, date, jsonb) from public, anon, authenticated;
revoke all on function public.lc_upsert_attendance_v2(text, uuid, text, text, text, text, text, text, numeric, numeric, text, text) from public, anon, authenticated;
revoke all on function public.lc_list_attendances_v3(text, uuid, text, text, uuid, text, text, date, date, integer, integer) from public, anon, authenticated;
revoke all on function public.lc_list_prospection_bonus_purchases(text, date, date, uuid) from public, anon, authenticated;

grant execute on function public.lc_list_leads_v2(text) to anon, authenticated;
grant execute on function public.lc_upsert_lead_v2(text, uuid, text, text, text, text, text, text, text, text, date, time, text, text, numeric, text, text, jsonb, uuid, date) to anon, authenticated;
grant execute on function public.lc_upsert_lead_with_intelligence_v2(text, uuid, text, text, text, text, text, text, text, text, date, time, text, text, numeric, text, text, jsonb, uuid, date, jsonb) to anon, authenticated;
grant execute on function public.lc_upsert_attendance_v2(text, uuid, text, text, text, text, text, text, numeric, numeric, text, text) to anon, authenticated;
grant execute on function public.lc_list_attendances_v3(text, uuid, text, text, uuid, text, text, date, date, integer, integer) to anon, authenticated;
grant execute on function public.lc_list_prospection_bonus_purchases(text, date, date, uuid) to anon, authenticated;

comment on column public.leads.cpf is 'CPF opcional usado para reconhecer retornos do mesmo cliente dentro da loja.';
comment on column public.attendances.cpf_normalized is 'CPF normalizado usado somente para cruzamento seguro dentro da mesma loja.';
comment on function public.lc_upsert_attendance_v2(text, uuid, text, text, text, text, text, text, numeric, numeric, text, text) is
  'Registra atendimento idempotente e cruza telefone ou CPF com Lead e Prospecção da mesma loja.';
comment on function public.lc_list_prospection_bonus_purchases(text, date, date, uuid) is
  'Lista compras de prospecções e snapshots auditáveis de bonificação no escopo autorizado.';

notify pgrst, 'reload schema';

commit;
