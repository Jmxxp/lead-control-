-- Modulo de Atendimentos | Lead Control
--
-- Dependencias: database.sql consolidado (usuarios, lojas, leads e prospeccoes).
-- A migracao e aditiva, idempotente e usa a sessao x-app-session por meio do
-- parametro p_session_token validado em app_private.session_user(text).
-- Execute no SQL Editor depois de database.sql.

begin;

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
create schema if not exists app_private;
set search_path = public, extensions;

do $$
begin
  if to_regclass('public.app_users') is null
     or to_regclass('public.stores') is null
     or to_regclass('public.leads') is null
     or to_regclass('public.prospections') is null
     or to_regclass('public.prospection_professionals') is null
     or to_regprocedure('app_private.session_user(text)') is null then
    raise exception 'Instale primeiro o database.sql consolidado do Lead Control.';
  end if;
end $$;

-- Canoniza telefones brasileiros sem depender do modulo WhatsApp. O retorno
-- contem apenas digitos: DDD+número recebe o prefixo 55; números que já têm
-- DDI são preservados. A função é imutável para permitir índices funcionais.
create or replace function app_private.attendance_normalize_phone(p_value text)
returns text
language plpgsql
immutable
set search_path = app_private, public, extensions
as $$
declare
  v_digits text := regexp_replace(coalesce(p_value, ''), '[^0-9]', '', 'g');
begin
  if left(v_digits, 2) = '00' then
    v_digits := substr(v_digits, 3);
  end if;

  -- Remove o zero de operadora/tronco antes de normalizar um telefone BR.
  if left(v_digits, 1) = '0' and length(v_digits) in (11, 12) then
    v_digits := substr(v_digits, 2);
  end if;

  -- Com 10/11 dígitos, os dois primeiros caracteres são DDD (inclusive o
  -- DDD 55 de Santa Maria), nunca DDI.
  if length(v_digits) in (10, 11) then
    v_digits := '55' || v_digits;
  end if;

  if length(v_digits) < 8 or length(v_digits) > 15 then
    return null;
  end if;
  return v_digits;
end;
$$;

create or replace function app_private.attendance_normalize_tag(p_value text)
returns text
language sql
immutable
set search_path = app_private, public, extensions
as $$
  select case lower(btrim(coalesce(p_value, '')))
    when 'budget' then 'budget'
    when 'quote' then 'budget'
    when 'orcamento' then 'budget'
    when 'orçamento' then 'budget'
    when 'purchase' then 'purchase'
    when 'sale' then 'purchase'
    when 'compra' then 'purchase'
    when 'venda' then 'purchase'
    when 'other' then 'other'
    when 'outro' then 'other'
    when 'outra' then 'other'
    else null
  end;
$$;

create or replace function app_private.attendance_bonus_credit_reason(p_status text)
returns text
language sql
immutable
set search_path = app_private, public, extensions
as $$
  select case p_status
    when 'no_prospection' then 'Nenhuma prospecção única foi encontrada para atribuir o crédito.'
    when 'ambiguous_prospection' then 'Há mais de uma prospecção com este telefone; revise os candidatos antes de atribuir crédito.'
    when 'already_converted' then 'A prospecção já possuía compra registrada; nenhum crédito foi duplicado.'
    when 'missing_professional' then 'A prospecção original não possui responsável; o atendente não foi atribuído automaticamente e o crédito exige revisão.'
    when 'below_minimum' then 'Compra creditada ao responsável original, mas abaixo do valor mínimo de bonificação.'
    when 'awarded' then 'Compra creditada e bonificação congelada para o responsável original da prospecção.'
    else 'Bonificação não se aplica a este atendimento.'
  end;
$$;

create or replace function app_private.attendance_store_allowed(
  p_admin_user_id uuid,
  p_user_id uuid,
  p_user_role public.app_user_role,
  p_user_store_id uuid,
  p_store_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = app_private, public, extensions
as $$
  select exists (
    select 1
    from public.stores st
    where st.id = p_store_id
      and st.admin_user_id = p_admin_user_id
      and st.is_active = true
      and (
        p_user_role::text = 'admin'
        or (p_user_role::text = 'technician' and st.technician_user_id = p_user_id)
        or (p_user_role::text = 'store' and st.id = p_user_store_id)
      )
  );
$$;

create table if not exists public.attendances (
  id uuid primary key default gen_random_uuid(),
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
  store_id uuid not null,
  professional_id uuid references public.prospection_professionals(id) on delete set null,
  professional_name_snapshot text not null,
  credited_professional_id uuid references public.prospection_professionals(id) on delete set null,
  credited_professional_name_snapshot text,
  prospection_professional_id uuid references public.prospection_professionals(id) on delete set null,
  prospection_professional_name_snapshot text,
  bonus_minimum_snapshot numeric(14,2) not null default 300,
  bonus_amount_snapshot numeric(14,2) not null default 20,
  bonus_eligible boolean not null default false,
  bonus_awarded_amount numeric(14,2) not null default 0,
  bonus_credit_status text not null default 'not_applicable',
  customer_name text not null,
  phone text not null,
  phone_normalized text not null,
  description text not null,
  tag text not null,
  service_value numeric(14,2),
  purchase_value numeric(14,2),
  service_order text,
  lead_id uuid references public.leads(id) on delete set null,
  prospection_id uuid references public.prospections(id) on delete set null,
  match_status text not null default 'unmatched',
  lead_match_count integer not null default 0,
  prospection_match_count integer not null default 0,
  match_ambiguous boolean not null default false,
  lead_candidates jsonb not null default '[]'::jsonb,
  prospection_candidates jsonb not null default '[]'::jsonb,
  lead_visit_applied boolean not null default false,
  lead_purchase_applied boolean not null default false,
  prospection_visit_applied boolean not null default false,
  prospection_purchase_applied boolean not null default false,
  purchase_credit_applied boolean not null default false,
  attended_at timestamptz not null default now(),
  outcome_applied_at timestamptz,
  idempotency_key text not null,
  request_fingerprint text not null,
  metadata jsonb not null default '{}'::jsonb,
  created_by uuid references public.app_users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint attendances_store_admin_fk
    foreign key (store_id, admin_user_id)
    references public.stores(id, admin_user_id)
    on delete cascade,
  constraint attendances_tag_check
    check (tag in ('budget', 'purchase', 'other')),
  constraint attendances_match_status_check
    check (match_status in ('unmatched', 'lead', 'prospection', 'both')),
  constraint attendances_bonus_credit_status_check
    check (bonus_credit_status in (
      'not_applicable', 'no_prospection', 'ambiguous_prospection',
      'already_converted', 'missing_professional', 'below_minimum', 'awarded'
    )),
  constraint attendances_values_check
    check (
      (service_value is null or service_value >= 0)
      and (purchase_value is null or purchase_value > 0)
    ),
  constraint attendances_purchase_consistency_check
    check (
      (
        tag = 'purchase'
        and purchase_value > 0
        and service_order is not null
        and length(btrim(service_order)) > 0
      )
      or
      (
        tag <> 'purchase'
        and purchase_value is null
        and service_order is null
        and purchase_credit_applied = false
        and lead_purchase_applied = false
        and prospection_purchase_applied = false
      )
    ),
  constraint attendances_match_counts_check
    check (
      lead_match_count >= 0
      and prospection_match_count >= 0
      and match_ambiguous = (lead_match_count > 1 or prospection_match_count > 1)
      and jsonb_typeof(lead_candidates) = 'array'
      and jsonb_typeof(prospection_candidates) = 'array'
    ),
  constraint attendances_bonus_snapshot_check
    check (
      bonus_minimum_snapshot >= 0
      and bonus_amount_snapshot >= 0
      and bonus_awarded_amount >= 0
      and (
        (bonus_eligible and purchase_credit_applied and tag = 'purchase' and prospection_id is not null
          and purchase_value >= bonus_minimum_snapshot and bonus_awarded_amount = bonus_amount_snapshot)
        or
        (not bonus_eligible and bonus_awarded_amount = 0)
      )
    ),
  constraint attendances_text_check
    check (
      length(btrim(professional_name_snapshot)) between 1 and 200
      and length(btrim(customer_name)) between 1 and 240
      and length(btrim(phone)) between 1 and 80
      and length(phone_normalized) between 8 and 15
      and length(btrim(description)) between 1 and 4000
      and length(idempotency_key) between 1 and 200
      and request_fingerprint ~ '^[0-9a-f]{64}$'
      and (service_order is null or length(btrim(service_order)) <= 120)
    ),
  constraint attendances_store_idempotency_key unique (store_id, idempotency_key)
);

create index if not exists attendances_store_date_idx
  on public.attendances (store_id, attended_at desc, id desc);
create index if not exists attendances_store_tag_date_idx
  on public.attendances (store_id, tag, attended_at desc);
create index if not exists attendances_store_professional_date_idx
  on public.attendances (store_id, professional_id, attended_at desc);
create index if not exists attendances_store_phone_date_idx
  on public.attendances (store_id, phone_normalized, attended_at desc);
create index if not exists attendances_retention_idx
  on public.attendances (attended_at);
create index if not exists attendances_lead_idx
  on public.attendances (lead_id) where lead_id is not null;
create index if not exists attendances_prospection_idx
  on public.attendances (prospection_id) where prospection_id is not null;

-- Somente o primeiro atendimento que converte uma prospecção pode reivindicar
-- o crédito. A bonificação existente continua sendo calculada uma única vez
-- sobre public.prospections, nunca sobre a quantidade de atendimentos.
create unique index if not exists attendances_one_purchase_credit_per_prospection_uidx
  on public.attendances (prospection_id)
  where prospection_id is not null and purchase_credit_applied;
create unique index if not exists attendances_store_purchase_order_uidx
  on public.attendances (store_id, lower(btrim(service_order)))
  where tag = 'purchase';

create index if not exists attendances_leads_phone_lookup_idx
  on public.leads (store_id, app_private.attendance_normalize_phone(phone));
create index if not exists attendances_prospections_phone_lookup_idx
  on public.prospections (store_id, app_private.attendance_normalize_phone(phone));

alter table public.attendances enable row level security;
revoke all on table public.attendances from public, anon, authenticated;
grant select, insert, update, delete on table public.attendances to service_role;

comment on table public.attendances is
  'Registro imutável de atendimento por loja, com vínculo automático a lead/prospecção e crédito de compra auditável.';
comment on column public.attendances.professional_id is
  'Profissional que realizou o atendimento.';
comment on column public.attendances.credited_professional_id is
  'Profissional original da prospecção ao qual a compra/bonificação permanece atribuída.';
comment on column public.attendances.purchase_credit_applied is
  'Verdadeiro somente no primeiro atendimento que confirmou a compra desta prospecção.';
comment on column public.attendances.bonus_credit_status is
  'Motivo auditável do crédito/bonificação, inclusive pendência por ausência do profissional original.';
comment on column public.attendances.phone_normalized is
  'Telefone canônico somente com dígitos, usado exclusivamente dentro da mesma loja.';

create or replace function app_private.attendance_set_updated_at()
returns trigger
language plpgsql
set search_path = app_private, public, extensions
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

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

  if new.professional_id is not null and not exists (
    select 1 from public.prospection_professionals pp
    where pp.id = new.professional_id
      and pp.store_id = new.store_id
      and pp.admin_user_id = new.admin_user_id
  ) then
    raise exception 'Profissional atendente pertence a outro cliente.';
  end if;

  if new.credited_professional_id is not null and not exists (
    select 1 from public.prospection_professionals pp
    where pp.id = new.credited_professional_id
      and pp.store_id = new.store_id
      and pp.admin_user_id = new.admin_user_id
  ) then
    raise exception 'Profissional creditado pertence a outro cliente.';
  end if;

  if new.prospection_professional_id is not null and not exists (
    select 1 from public.prospection_professionals pp
    where pp.id = new.prospection_professional_id
      and pp.store_id = new.store_id
      and pp.admin_user_id = new.admin_user_id
  ) then
    raise exception 'Profissional original da prospecção pertence a outro cliente.';
  end if;

  if new.lead_id is not null and not exists (
    select 1 from public.leads l
    where l.id = new.lead_id
      and l.store_id = new.store_id
      and l.admin_user_id = new.admin_user_id
  ) then
    raise exception 'Lead vinculado pertence a outro cliente.';
  end if;

  if new.prospection_id is not null and not exists (
    select 1 from public.prospections pr
    where pr.id = new.prospection_id
      and pr.store_id = new.store_id
      and pr.admin_user_id = new.admin_user_id
  ) then
    raise exception 'Prospecção vinculada pertence a outro cliente.';
  end if;

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

drop trigger if exists attendances_set_updated_at on public.attendances;
create trigger attendances_set_updated_at
before update on public.attendances
for each row execute function app_private.attendance_set_updated_at();

drop trigger if exists attendances_validate_links on public.attendances;
create trigger attendances_validate_links
before insert or update on public.attendances
for each row execute function app_private.attendance_validate_links();

create or replace function app_private.attendance_result_json(
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
  v_row record;
  v_record jsonb;
  v_links jsonb;
  v_message text;
begin
  select
    a.*,
    st.name as store_name,
    l.name as lead_name,
    l.phone as lead_phone,
    l.visited as lead_visited,
    l.bought as lead_bought,
    l.purchase_amount as lead_purchase_value,
    l.service_order as lead_service_order,
    pr.name as prospection_name,
    pr.phone as prospection_phone,
    pr.returned_at as prospection_returned_at,
    pr.purchased_at as prospection_purchased_at,
    pr.purchase_amount as prospection_purchase_value,
    pr.purchase_order as prospection_service_order
  into v_row
  from public.attendances a
  join public.stores st on st.id = a.store_id and st.admin_user_id = a.admin_user_id
  left join public.leads l on l.id = a.lead_id
  left join public.prospections pr on pr.id = a.prospection_id
  where a.id = p_attendance_id;

  if not found then
    return null;
  end if;

  v_record := jsonb_build_object(
    'id', v_row.id,
    'store_id', v_row.store_id,
    'store_name', v_row.store_name,
    'professional_id', v_row.professional_id,
    'professional_name', v_row.professional_name_snapshot,
    'credited_professional_id', v_row.credited_professional_id,
    'credited_professional_name', v_row.credited_professional_name_snapshot,
    'prospection_professional_id', v_row.prospection_professional_id,
    'prospection_professional_name', v_row.prospection_professional_name_snapshot,
    'bonus_minimum_snapshot', v_row.bonus_minimum_snapshot,
    'bonus_amount_snapshot', v_row.bonus_amount_snapshot,
    'bonus_eligible', v_row.bonus_eligible,
    'bonus_awarded_amount', v_row.bonus_awarded_amount,
    'bonus_credit_status', v_row.bonus_credit_status,
    'bonus_review_required', v_row.bonus_credit_status in ('ambiguous_prospection', 'missing_professional'),
    'bonus_credit_reason', app_private.attendance_bonus_credit_reason(v_row.bonus_credit_status),
    'bonus_reason', app_private.attendance_bonus_credit_reason(v_row.bonus_credit_status),
    'customer_name', v_row.customer_name,
    'phone', v_row.phone,
    'phone_normalized', v_row.phone_normalized,
    'description', v_row.description,
    'tag', v_row.tag,
    'tag_label', case v_row.tag when 'budget' then 'Orçamento' when 'purchase' then 'Compra' else 'Outro' end,
    'service_value', v_row.service_value,
    'purchase_value', v_row.purchase_value,
    'service_order', v_row.service_order,
    'match_status', v_row.match_status,
    'purchase_credit_applied', v_row.purchase_credit_applied,
    'attended_at', v_row.attended_at,
    'created_at', v_row.created_at
  );

  v_links := jsonb_build_object(
    'status', v_row.match_status,
    'lead_match_count', v_row.lead_match_count,
    'prospection_match_count', v_row.prospection_match_count,
    'ambiguous', v_row.match_ambiguous,
    'lead_candidates', v_row.lead_candidates,
    'prospection_candidates', v_row.prospection_candidates,
    'lead', case when v_row.lead_id is null then null else jsonb_build_object(
      'id', v_row.lead_id,
      'name', v_row.lead_name,
      'phone', v_row.lead_phone,
      'visited', v_row.lead_visited,
      'purchased', v_row.lead_bought,
      'purchase_value', v_row.lead_purchase_value,
      'service_order', v_row.lead_service_order,
      'visit_applied', v_row.lead_visit_applied,
      'purchase_applied', v_row.lead_purchase_applied
    ) end,
    'prospection', case when v_row.prospection_id is null then null else jsonb_build_object(
      'id', v_row.prospection_id,
      'name', v_row.prospection_name,
      'phone', v_row.prospection_phone,
      'returned_at', v_row.prospection_returned_at,
      'purchased_at', v_row.prospection_purchased_at,
      'purchase_value', v_row.prospection_purchase_value,
      'service_order', v_row.prospection_service_order,
      'visit_applied', v_row.prospection_visit_applied,
      'purchase_applied', v_row.prospection_purchase_applied,
      'purchase_credit_applied', v_row.purchase_credit_applied,
      'credited_professional_id', v_row.credited_professional_id,
      'credited_professional_name', v_row.credited_professional_name_snapshot,
      'prospection_professional_id', v_row.prospection_professional_id,
      'prospection_professional_name', v_row.prospection_professional_name_snapshot,
      'bonus_eligible', v_row.bonus_eligible,
      'bonus_awarded_amount', v_row.bonus_awarded_amount,
      'bonus_credit_status', v_row.bonus_credit_status,
      'bonus_review_required', v_row.bonus_credit_status in ('ambiguous_prospection', 'missing_professional'),
      'bonus_credit_reason', app_private.attendance_bonus_credit_reason(v_row.bonus_credit_status)
    ) end
  );

  v_message := case
    when p_idempotent_replay then 'Este atendimento já havia sido registrado; nenhum resultado foi duplicado.'
    when v_row.match_status = 'both' then 'Atendimento registrado e vinculado ao lead e à prospecção.'
    when v_row.match_status = 'lead' then 'Atendimento registrado e vinculado ao lead encontrado.'
    when v_row.match_status = 'prospection' then 'Atendimento registrado e vinculado à prospecção encontrada.'
    else 'Atendimento registrado sem correspondência; o histórico foi preservado.'
  end;

  return jsonb_build_object(
    'attendance', v_record,
    'record', v_record,
    'registro', v_record,
    'links', v_links,
    'vinculos', v_links,
    'message', v_message,
    'mensagem', v_message,
    'professional_name', v_row.professional_name_snapshot,
    'credited_professional_id', v_row.credited_professional_id,
    'credited_professional_name', v_row.credited_professional_name_snapshot,
    'prospection_professional_id', v_row.prospection_professional_id,
    'prospection_professional_name', v_row.prospection_professional_name_snapshot,
    'bonus_eligible', v_row.bonus_eligible,
    'bonus_awarded_amount', v_row.bonus_awarded_amount,
    'bonus_credit_status', v_row.bonus_credit_status,
    'bonus_review_required', v_row.bonus_credit_status in ('ambiguous_prospection', 'missing_professional'),
    'bonus_reason', app_private.attendance_bonus_credit_reason(v_row.bonus_credit_status),
    'idempotent_replay', coalesce(p_idempotent_replay, false)
  );
end;
$$;

create or replace function app_private.rpc_list_attendances(
  p_session_token text,
  p_store_id uuid default null,
  p_search text default null,
  p_tag text default null,
  p_professional_id uuid default null,
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

  if v_store_id is null then
    raise exception 'Selecione um cliente para consultar os atendimentos.';
  end if;
  if not app_private.attendance_store_allowed(
    v_session.admin_user_id, v_session.user_id, v_session.user_role,
    v_session.user_store_id, v_store_id
  ) then
    raise exception 'Cliente não encontrado ou sem permissão.';
  end if;

  if nullif(btrim(coalesce(p_tag, '')), '') is not null
     and lower(btrim(p_tag)) <> 'all' then
    v_tag := app_private.attendance_normalize_tag(p_tag);
    if v_tag is null then raise exception 'Etiqueta de atendimento inválida.'; end if;
  end if;
  if v_link_status is not null
     and v_link_status not in ('all', 'matched', 'unmatched', 'lead', 'prospection', 'both') then
    raise exception 'Filtro de vínculo inválido.';
  end if;
  if p_start_date is not null and p_end_date is not null and p_start_date > p_end_date then
    raise exception 'Período inválido.';
  end if;
  select count(*) into v_total
  from public.attendances a
  where a.store_id = v_store_id
    and a.admin_user_id = v_session.admin_user_id
    and a.attended_at >= now() - interval '2 years'
    and (v_tag is null or a.tag = v_tag)
    and (p_professional_id is null or a.professional_id = p_professional_id)
    and (p_start_date is null or a.attended_at >= p_start_date::timestamptz)
    and (p_end_date is null or a.attended_at < (p_end_date + 1)::timestamptz)
    and (
      v_link_status is null or v_link_status = 'all'
      or (v_link_status = 'matched' and a.match_status <> 'unmatched')
      or a.match_status = v_link_status
    )
    and (
      v_search is null
      or a.customer_name ilike '%' || v_search || '%'
      or a.description ilike '%' || v_search || '%'
      or a.professional_name_snapshot ilike '%' || v_search || '%'
      or coalesce(a.credited_professional_name_snapshot, '') ilike '%' || v_search || '%'
      or coalesce(a.service_order, '') ilike '%' || v_search || '%'
      or (v_search_digits is not null and a.phone_normalized like '%' || v_search_digits || '%')
    );

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', q.id,
    'store_id', q.store_id,
    'professional_id', q.professional_id,
    'professional_name', q.professional_name_snapshot,
    'credited_professional_id', q.credited_professional_id,
    'credited_professional_name', q.credited_professional_name_snapshot,
    'prospection_professional_id', q.prospection_professional_id,
    'prospection_professional_name', q.prospection_professional_name_snapshot,
    'bonus_minimum_snapshot', q.bonus_minimum_snapshot,
    'bonus_amount_snapshot', q.bonus_amount_snapshot,
    'bonus_eligible', q.bonus_eligible,
    'bonus_awarded_amount', q.bonus_awarded_amount,
    'bonus_credit_status', q.bonus_credit_status,
    'bonus_review_required', q.bonus_credit_status in ('ambiguous_prospection', 'missing_professional'),
    'bonus_credit_reason', app_private.attendance_bonus_credit_reason(q.bonus_credit_status),
    'bonus_reason', app_private.attendance_bonus_credit_reason(q.bonus_credit_status),
    'customer_name', q.customer_name,
    'phone', q.phone,
    'phone_normalized', q.phone_normalized,
    'description', q.description,
    'tag', q.tag,
    'tag_label', case q.tag when 'budget' then 'Orçamento' when 'purchase' then 'Compra' else 'Outro' end,
    'service_value', q.service_value,
    'purchase_value', q.purchase_value,
    'service_order', q.service_order,
    'match_status', q.match_status,
    'purchase_credit_applied', q.purchase_credit_applied,
    'attended_at', q.attended_at,
    'created_at', q.created_at,
    'links', jsonb_build_object(
      'status', q.match_status,
      'lead_match_count', q.lead_match_count,
      'prospection_match_count', q.prospection_match_count,
      'ambiguous', q.match_ambiguous,
      'lead_candidates', q.lead_candidates,
      'prospection_candidates', q.prospection_candidates,
      'lead', case when q.lead_id is null then null else jsonb_build_object(
        'id', q.lead_id, 'name', q.lead_name, 'visited', q.lead_visited,
        'purchased', q.lead_bought, 'visit_applied', q.lead_visit_applied,
        'purchase_applied', q.lead_purchase_applied
      ) end,
      'prospection', case when q.prospection_id is null then null else jsonb_build_object(
        'id', q.prospection_id, 'name', q.prospection_name,
        'returned_at', q.prospection_returned_at,
        'purchased_at', q.prospection_purchased_at,
        'visit_applied', q.prospection_visit_applied,
        'purchase_applied', q.prospection_purchase_applied,
        'purchase_credit_applied', q.purchase_credit_applied,
        'bonus_credit_status', q.bonus_credit_status,
        'bonus_credit_reason', app_private.attendance_bonus_credit_reason(q.bonus_credit_status)
      ) end
    )
  ) order by q.attended_at desc, q.id desc), '[]'::jsonb)
  into v_items
  from (
    select
      a.*,
      l.name as lead_name, l.visited as lead_visited, l.bought as lead_bought,
      pr.name as prospection_name, pr.returned_at as prospection_returned_at,
      pr.purchased_at as prospection_purchased_at
    from public.attendances a
    left join public.leads l on l.id = a.lead_id
    left join public.prospections pr on pr.id = a.prospection_id
    where a.store_id = v_store_id
      and a.admin_user_id = v_session.admin_user_id
      and a.attended_at >= now() - interval '2 years'
      and (v_tag is null or a.tag = v_tag)
      and (p_professional_id is null or a.professional_id = p_professional_id)
      and (p_start_date is null or a.attended_at >= p_start_date::timestamptz)
      and (p_end_date is null or a.attended_at < (p_end_date + 1)::timestamptz)
      and (
        v_link_status is null or v_link_status = 'all'
        or (v_link_status = 'matched' and a.match_status <> 'unmatched')
        or a.match_status = v_link_status
      )
      and (
        v_search is null
        or a.customer_name ilike '%' || v_search || '%'
        or a.description ilike '%' || v_search || '%'
        or a.professional_name_snapshot ilike '%' || v_search || '%'
        or coalesce(a.credited_professional_name_snapshot, '') ilike '%' || v_search || '%'
        or coalesce(a.service_order, '') ilike '%' || v_search || '%'
        or (v_search_digits is not null and a.phone_normalized like '%' || v_search_digits || '%')
      )
    order by a.attended_at desc, a.id desc
    limit v_limit offset v_offset
  ) q;

  return jsonb_build_object(
    'store_id', v_store_id,
    'items', v_items,
    'attendances', v_items,
    'total', v_total,
    'limit', v_limit,
    'offset', v_offset,
    'has_more', v_offset + jsonb_array_length(v_items) < v_total
  );
end;
$$;

create or replace function app_private.rpc_upsert_attendance(
  p_session_token text,
  p_store_id uuid,
  p_professional_name text,
  p_customer_name text,
  p_phone text,
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
  v_professional_found boolean := false;
  v_lead public.leads%rowtype;
  v_prospection public.prospections%rowtype;
  v_existing public.attendances%rowtype;
  v_existing_found boolean := false;
  v_attendance_id uuid;
  v_customer_name text := left(btrim(coalesce(p_customer_name, '')), 240);
  v_professional_name text := left(btrim(coalesce(p_professional_name, '')), 200);
  v_phone text := left(btrim(coalesce(p_phone, '')), 80);
  v_phone_normalized text;
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
  ) then
    raise exception 'Cliente não encontrado ou sem permissão.';
  end if;

  if v_professional_name = '' then raise exception 'Informe o profissional atendente.'; end if;
  if v_customer_name = '' then raise exception 'Informe o nome do cliente.'; end if;
  if v_description = '' then raise exception 'Descreva o atendimento.'; end if;

  v_phone_normalized := app_private.attendance_normalize_phone(v_phone);
  if v_phone_normalized is null then raise exception 'Informe um telefone válido com DDD.'; end if;

  v_tag := app_private.attendance_normalize_tag(p_tag);
  if v_tag is null then raise exception 'Use a etiqueta Orçamento, Compra ou Outro.'; end if;
  if v_service_value is not null and v_service_value < 0 then
    raise exception 'O valor do atendimento não pode ser negativo.';
  end if;
  if v_tag = 'purchase' then
    v_purchase_value := coalesce(v_purchase_value, v_service_value);
    if coalesce(v_purchase_value, 0) <= 0 then
      raise exception 'Informe um valor de compra maior que zero.';
    end if;
    if v_service_order is null then raise exception 'Informe o número da OS.'; end if;
  elsif v_purchase_value is not null or v_service_order is not null then
    raise exception 'Valor da compra e OS só podem ser informados na etiqueta Compra.';
  end if;

  select pp.* into v_professional
  from public.prospection_professionals pp
  where pp.store_id = v_store_id
    and pp.admin_user_id = v_session.admin_user_id
    and pp.is_active = true
    and lower(pp.name) = lower(v_professional_name)
  order by pp.created_at
  limit 1;
  v_professional_found := found;
  if v_professional_found then
    -- Aproveita o cadastro quando existe, mas o módulo de Atendimentos não
    -- depende de licença nem de configuração prévia de Prospecções.
    v_professional_name := v_professional.name;
  end if;

  select coalesce(ps.bonus_minimum, 300), coalesce(ps.bonus_amount, 20)
  into v_bonus_minimum, v_bonus_amount
  from public.stores st
  left join public.prospection_store_settings ps
    on ps.store_id = st.id and ps.admin_user_id = st.admin_user_id
  where st.id = v_store_id and st.admin_user_id = v_session.admin_user_id;

  v_fingerprint_payload := jsonb_build_object(
    'store_id', v_store_id,
    'professional_id', case when v_professional_found then v_professional.id end,
    'professional_name', lower(v_professional_name),
    'customer_name', lower(v_customer_name),
    'phone', v_phone_normalized,
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
    -- Sem chave do navegador, uma janela curta ainda protege clique duplo e
    -- retry imediato sem impedir um novo atendimento legítimo no futuro.
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
  v_existing_found := found;

  if not v_existing_found and v_tag = 'purchase' then
    select * into v_existing
    from public.attendances a
    where a.store_id = v_store_id
      and a.tag = 'purchase'
      and lower(btrim(a.service_order)) = lower(v_service_order)
    for update;
    v_existing_found := found;
  end if;

  if v_existing_found then
    if v_existing.request_fingerprint <> v_fingerprint then
      raise exception 'Esta chave ou OS já foi usada em outro atendimento com dados diferentes.';
    end if;
    return app_private.attendance_result_json(v_existing.id, true);
  end if;

  -- Serializa o desfecho por telefone/loja. Isso impede que dois terminais
  -- confirmem simultaneamente o mesmo retorno ou crédito de bonificação.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('attendance:phone:' || v_store_id::text || ':' || v_phone_normalized, 0)
  );

  select count(*)::integer into v_lead_count
  from public.leads l
  where l.store_id = v_store_id
    and l.admin_user_id = v_session.admin_user_id
    and app_private.attendance_normalize_phone(l.phone) = v_phone_normalized;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', c.id, 'name', c.name, 'phone', c.phone,
    'visited', c.visited, 'purchased', c.bought, 'created_at', c.created_at
  ) order by c.created_at desc, c.id desc), '[]'::jsonb)
  into v_lead_candidates
  from (
    select l.* from public.leads l
    where l.store_id = v_store_id
      and l.admin_user_id = v_session.admin_user_id
      and app_private.attendance_normalize_phone(l.phone) = v_phone_normalized
    order by l.created_at desc, l.id desc limit 20
  ) c;

  if v_lead_count = 1 then
    select l.* into v_lead
    from public.leads l
    where l.store_id = v_store_id
      and l.admin_user_id = v_session.admin_user_id
      and app_private.attendance_normalize_phone(l.phone) = v_phone_normalized
    for update;
    v_lead_found := found;
  end if;

  select count(*)::integer into v_prospection_count
  from public.prospections pr
  where pr.store_id = v_store_id
    and pr.admin_user_id = v_session.admin_user_id
    and app_private.attendance_normalize_phone(pr.phone) = v_phone_normalized;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', c.id, 'name', c.name, 'phone', c.phone,
    'professional_id', c.professional_id,
    'professional_name', coalesce(pp.name, c.professional_name_snapshot),
    'returned_at', c.returned_at, 'purchased_at', c.purchased_at,
    'purchase_value', c.purchase_amount, 'service_order', c.purchase_order,
    'created_at', c.created_at
  ) order by c.created_at desc, c.id desc), '[]'::jsonb)
  into v_prospection_candidates
  from (
    select pr.* from public.prospections pr
    where pr.store_id = v_store_id
      and pr.admin_user_id = v_session.admin_user_id
      and app_private.attendance_normalize_phone(pr.phone) = v_phone_normalized
    order by pr.created_at desc, pr.id desc limit 20
  ) c
  left join public.prospection_professionals pp on pp.id = c.professional_id;

  if v_prospection_count = 1 then
    select pr.* into v_prospection
    from public.prospections pr
    where pr.store_id = v_store_id
      and pr.admin_user_id = v_session.admin_user_id
      and app_private.attendance_normalize_phone(pr.phone) = v_phone_normalized
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
      elsif v_prospection_professional_id is null
            and v_prospection_professional_name is null then
        -- Nunca converte o atendente em autor da prospecção. Sem origem
        -- responsável, a compra é registrada e fica explicitamente em revisão.
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
    bonus_credit_status,
    customer_name, phone, phone_normalized, description, tag,
    service_value, purchase_value, service_order,
    lead_id, prospection_id, match_status,
    lead_match_count, prospection_match_count, match_ambiguous,
    lead_candidates, prospection_candidates,
    lead_visit_applied, lead_purchase_applied,
    prospection_visit_applied, prospection_purchase_applied,
    purchase_credit_applied, attended_at, outcome_applied_at,
    idempotency_key, request_fingerprint, metadata, created_by
  ) values (
    v_session.admin_user_id, v_store_id,
    case when v_professional_found then v_professional.id end, v_professional_name,
    v_credited_professional_id, v_credited_professional_name,
    v_prospection_professional_id, v_prospection_professional_name,
    v_bonus_minimum, v_bonus_amount, v_bonus_eligible, v_bonus_awarded,
    v_bonus_credit_status,
    v_customer_name, v_phone, v_phone_normalized, v_description, v_tag,
    v_service_value, case when v_tag = 'purchase' then v_purchase_value end,
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
      'matching_strategy', 'unique_phone_same_store',
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

  -- Garante retenção mesmo em projetos sem pg_cron. O índice de retenção
  -- evita varredura integral e a exclusão não toca leads nem prospecções.
  delete from public.attendances
  where store_id = v_store_id
    and attended_at < now() - interval '2 years';

  return app_private.attendance_result_json(v_attendance_id, false);
end;
$$;

-- Métricas são calculadas sobre todo o período retido. A lista recente do
-- workspace é paginada separadamente e, portanto, nunca limita os totais.
create or replace function app_private.attendance_metrics_json(
  p_admin_user_id uuid,
  p_store_id uuid
)
returns jsonb
language sql
stable
security definer
set search_path = app_private, public, extensions
as $$
  with windows(window_key, start_at) as (
    values
      ('today'::text, date_trunc('day', now())),
      ('7d'::text, date_trunc('day', now()) - interval '6 days'),
      ('30d'::text, date_trunc('day', now()) - interval '29 days'),
      ('all'::text, now() - interval '2 years')
  ), stats as (
    select
      w.window_key,
      w.start_at,
      count(a.id)::bigint as total,
      count(a.id) filter (where a.tag = 'budget')::bigint as budgets,
      count(a.id) filter (where a.tag = 'purchase')::bigint as purchases,
      count(a.id) filter (where a.tag = 'other')::bigint as others,
      coalesce(sum(a.purchase_value) filter (where a.tag = 'purchase'), 0)::numeric(14,2) as purchase_revenue,
      coalesce(sum(a.service_value), 0)::numeric(14,2) as service_value,
      count(a.id) filter (where a.match_status <> 'unmatched')::bigint as linked,
      count(a.id) filter (where a.match_status = 'unmatched')::bigint as unmatched,
      count(a.id) filter (where a.match_ambiguous)::bigint as ambiguous,
      count(a.id) filter (where a.purchase_credit_applied)::bigint as purchase_credits,
      count(a.id) filter (where a.bonus_eligible)::bigint as bonuses_awarded,
      coalesce(sum(a.bonus_awarded_amount), 0)::numeric(14,2) as bonus_awarded_amount,
      count(a.id) filter (
        where a.bonus_credit_status in ('ambiguous_prospection', 'missing_professional')
      )::bigint as bonus_pending_review,
      count(distinct a.phone_normalized)::bigint as unique_customers,
      min(a.attended_at) as first_attendance_at,
      max(a.attended_at) as last_attendance_at
    from windows w
    left join public.attendances a
      on a.admin_user_id = p_admin_user_id
     and a.store_id = p_store_id
     and a.attended_at >= w.start_at
     and a.attended_at >= now() - interval '2 years'
    group by w.window_key, w.start_at
  )
  select coalesce(jsonb_object_agg(
    s.window_key,
    jsonb_build_object(
      'start_at', s.start_at,
      'total', s.total,
      'budgets', s.budgets,
      'purchases', s.purchases,
      'others', s.others,
      'conversion', case when s.total = 0 then 0 else round((s.purchases * 100.0) / s.total, 2) end,
      'conversion_rate', case when s.total = 0 then 0 else round((s.purchases * 100.0) / s.total, 2) end,
      'revenue', s.purchase_revenue,
      'purchase_revenue', s.purchase_revenue,
      'service_value', s.service_value,
      'linked', s.linked,
      'unmatched', s.unmatched,
      'ambiguous', s.ambiguous,
      'purchase_credits', s.purchase_credits,
      'bonuses_awarded', s.bonuses_awarded,
      'bonus_awarded_amount', s.bonus_awarded_amount,
      'bonus_pending_review', s.bonus_pending_review,
      'unique_customers', s.unique_customers,
      'first_attendance_at', s.first_attendance_at,
      'last_attendance_at', s.last_attendance_at
    )
  ), '{}'::jsonb)
  from stats s;
$$;

create or replace function app_private.rpc_get_attendance_workspace(
  p_session_token text,
  p_store_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_store_id uuid;
  v_store jsonb;
  v_settings jsonb;
  v_professionals jsonb := '[]'::jsonb;
  v_recent jsonb;
  v_metrics jsonb;
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

  if v_store_id is null then
    raise exception 'Selecione um cliente para consultar os atendimentos.';
  end if;
  if not app_private.attendance_store_allowed(
    v_session.admin_user_id, v_session.user_id, v_session.user_role,
    v_session.user_store_id, v_store_id
  ) then
    raise exception 'Cliente não encontrado ou sem permissão.';
  end if;

  select jsonb_build_object(
    'id', st.id,
    'name', st.name,
    'nick', st.nick,
    'avatar_url', st.avatar_url,
    'technician_user_id', st.technician_user_id,
    'is_active', st.is_active
  ), jsonb_build_object(
    'bonus_minimum', coalesce(ps.bonus_minimum, 300),
    'bonus_amount', coalesce(ps.bonus_amount, 20),
    'accent_color', coalesce(ps.accent_color, '#16855f'),
    'retention_years', 2
  )
  into v_store, v_settings
  from public.stores st
  left join public.prospection_store_settings ps
    on ps.store_id = st.id and ps.admin_user_id = st.admin_user_id
  where st.id = v_store_id
    and st.admin_user_id = v_session.admin_user_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', pp.id,
    'name', pp.name,
    'is_active', pp.is_active
  ) order by pp.name), '[]'::jsonb)
  into v_professionals
  from public.prospection_professionals pp
  where pp.store_id = v_store_id
    and pp.admin_user_id = v_session.admin_user_id
    and pp.is_active = true;

  v_metrics := app_private.attendance_metrics_json(v_session.admin_user_id, v_store_id);
  v_recent := app_private.rpc_list_attendances(
    p_session_token, v_store_id, null, null, null, null, null, null, 100, 0
  );

  return jsonb_build_object(
    'store', v_store,
    'settings', v_settings,
    'permissions', jsonb_build_object(
      'role', v_session.user_role::text,
      'can_view', true,
      'can_create', true,
      'can_manage', v_session.user_role::text in ('admin', 'technician')
    ),
    'tags', jsonb_build_array(
      jsonb_build_object('value', 'budget', 'label', 'Orçamento'),
      jsonb_build_object('value', 'purchase', 'label', 'Compra'),
      jsonb_build_object('value', 'other', 'label', 'Outro')
    ),
    'professionals', v_professionals,
    'metrics', v_metrics,
    'summary', coalesce(v_metrics -> 'all', '{}'::jsonb),
    'attendances', coalesce(v_recent -> 'items', '[]'::jsonb),
    'records', coalesce(v_recent -> 'items', '[]'::jsonb),
    'recent_attendances', coalesce(v_recent -> 'items', '[]'::jsonb),
    'total', coalesce((v_recent ->> 'total')::bigint, 0),
    'pagination', jsonb_build_object(
      'limit', coalesce((v_recent ->> 'limit')::integer, 100),
      'offset', coalesce((v_recent ->> 'offset')::integer, 0),
      'has_more', coalesce((v_recent ->> 'has_more')::boolean, false)
    ),
    'retention', jsonb_build_object(
      'years', 2,
      'cutoff', now() - interval '2 years',
      'policy', 'rolling'
    )
  );
end;
$$;

create or replace function app_private.attendance_purge_retention()
returns integer
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_deleted integer := 0;
begin
  delete from public.attendances
  where attended_at < now() - interval '2 years';
  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;

-- No Supabase com pg_cron habilitado, agenda uma limpeza diária. Em projetos
-- sem a extensão, o upsert continua executando a limpeza indexada da loja.
do $$
declare
  v_job_exists boolean := false;
  v_job_id bigint;
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    begin
      execute 'select exists (select 1 from cron.job where jobname = $1)'
        into v_job_exists using 'lc_attendance_retention_daily';
      if not v_job_exists then
        execute 'select cron.schedule($1, $2, $3)'
          into v_job_id
          using
            'lc_attendance_retention_daily',
            '17 3 * * *',
            'select app_private.attendance_purge_retention();';
      end if;
    exception
      when undefined_table or undefined_function or insufficient_privilege then
        raise notice 'pg_cron disponível, mas o agendamento de retenção será feito pelo fallback do upsert.';
    end;
  end if;
end $$;

-- API pública consumida pelo frontend via /rest/v1/rpc/*.
create or replace function public.lc_get_attendance_workspace(
  p_session_token text,
  p_store_id uuid default null
)
returns jsonb
language sql
security invoker
set search_path = app_private, public, extensions
as $$
  select app_private.rpc_get_attendance_workspace(p_session_token, p_store_id);
$$;

create or replace function public.lc_upsert_attendance(
  p_session_token text,
  p_store_id uuid,
  p_professional_name text,
  p_customer_name text,
  p_phone text,
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
  select app_private.rpc_upsert_attendance(
    p_session_token, p_store_id, p_professional_name, p_customer_name,
    p_phone, p_description, p_tag, p_service_value, p_purchase_value,
    p_service_order, p_idempotency_key
  );
$$;

create or replace function public.lc_list_attendances(
  p_session_token text,
  p_store_id uuid default null,
  p_search text default null,
  p_tag text default null,
  p_professional_id uuid default null,
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
  select app_private.rpc_list_attendances(
    p_session_token, p_store_id, p_search, p_tag, p_professional_id,
    p_link_status, p_start_date, p_end_date, p_limit, p_offset
  );
$$;

revoke all on function app_private.attendance_normalize_phone(text) from public;
revoke all on function app_private.attendance_normalize_tag(text) from public;
revoke all on function app_private.attendance_bonus_credit_reason(text) from public;
revoke all on function app_private.attendance_store_allowed(uuid, uuid, public.app_user_role, uuid, uuid) from public;
revoke all on function app_private.attendance_result_json(uuid, boolean) from public;
revoke all on function app_private.attendance_metrics_json(uuid, uuid) from public;
revoke all on function app_private.rpc_get_attendance_workspace(text, uuid) from public;
revoke all on function app_private.rpc_upsert_attendance(text, uuid, text, text, text, text, text, numeric, numeric, text, text) from public;
revoke all on function app_private.rpc_list_attendances(text, uuid, text, text, uuid, text, date, date, integer, integer) from public;
revoke all on function app_private.attendance_purge_retention() from public;

grant execute on function app_private.rpc_get_attendance_workspace(text, uuid) to anon, authenticated;
grant execute on function app_private.rpc_upsert_attendance(text, uuid, text, text, text, text, text, numeric, numeric, text, text) to anon, authenticated;
grant execute on function app_private.rpc_list_attendances(text, uuid, text, text, uuid, text, date, date, integer, integer) to anon, authenticated;
grant execute on function app_private.attendance_purge_retention() to service_role;

revoke all on function public.lc_get_attendance_workspace(text, uuid) from public;
revoke all on function public.lc_upsert_attendance(text, uuid, text, text, text, text, text, numeric, numeric, text, text) from public;
revoke all on function public.lc_list_attendances(text, uuid, text, text, uuid, text, date, date, integer, integer) from public;

grant execute on function public.lc_get_attendance_workspace(text, uuid) to anon, authenticated;
grant execute on function public.lc_upsert_attendance(text, uuid, text, text, text, text, text, numeric, numeric, text, text) to anon, authenticated;
grant execute on function public.lc_list_attendances(text, uuid, text, text, uuid, text, date, date, integer, integer) to anon, authenticated;

comment on function public.lc_get_attendance_workspace(text, uuid) is
  'Workspace isolado por cliente: profissionais, 100 atendimentos recentes e métricas completas em today/7d/30d/all.';
comment on function public.lc_upsert_attendance(text, uuid, text, text, text, text, text, numeric, numeric, text, text) is
  'Registra atendimento idempotente e aplica desfechos somente a vínculos únicos por telefone na mesma loja.';
comment on function public.lc_list_attendances(text, uuid, text, text, uuid, text, date, date, integer, integer) is
  'Busca paginada de atendimentos com filtros por cliente, período, etiqueta, profissional e vínculo.';

commit;

-- Verificação rápida após executar no SQL Editor:
-- select
--   to_regprocedure('public.lc_get_attendance_workspace(text,uuid)') as workspace,
--   to_regprocedure('public.lc_upsert_attendance(text,uuid,text,text,text,text,text,numeric,numeric,text,text)') as gravacao,
--   to_regprocedure('public.lc_list_attendances(text,uuid,text,text,uuid,text,date,date,integer,integer)') as listagem;
