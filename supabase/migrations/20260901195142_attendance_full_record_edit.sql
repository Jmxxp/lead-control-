-- Atendimentos | edicao integral, ownership explicito e auditoria privada.
--
-- A data operacional pode mudar, mas id/created_at e os artefatos da criacao
-- (idempotency_key, request_fingerprint, metadata e outcome_applied_at) ficam
-- imutaveis. Lead/prospeccao so sao recalculados quando o atendimento ainda e
-- o owner explicito da projecao; uma alteracao manual posterior sempre vence.

begin;

set local lock_timeout = '10s';
set local statement_timeout = '5min';

alter table public.attendances
  add column if not exists updated_by uuid references public.app_users(id) on delete set null,
  add column if not exists edit_count bigint not null default 0;

alter table public.leads
  add column if not exists attendance_visit_source_id uuid,
  add column if not exists attendance_purchase_source_id uuid,
  add column if not exists attendance_visit_manual_override boolean not null default false,
  add column if not exists attendance_purchase_manual_override boolean not null default false;

alter table public.prospections
  add column if not exists attendance_return_source_id uuid,
  add column if not exists attendance_purchase_source_id uuid,
  add column if not exists attendance_return_manual_override boolean not null default false,
  add column if not exists attendance_purchase_manual_override boolean not null default false;

do $$
begin
  if not exists (
    select 1 from pg_catalog.pg_constraint c
    where c.conname = 'attendances_edit_count_check'
      and c.conrelid = 'public.attendances'::pg_catalog.regclass
  ) then
    alter table public.attendances
      add constraint attendances_edit_count_check check (edit_count >= 0);
  end if;

  if not exists (
    select 1 from pg_catalog.pg_constraint c
    where c.conname = 'leads_attendance_visit_source_fk'
      and c.conrelid = 'public.leads'::pg_catalog.regclass
  ) then
    alter table public.leads
      add constraint leads_attendance_visit_source_fk
      foreign key (attendance_visit_source_id)
      references public.attendances(id) on delete set null;
  end if;

  if not exists (
    select 1 from pg_catalog.pg_constraint c
    where c.conname = 'leads_attendance_purchase_source_fk'
      and c.conrelid = 'public.leads'::pg_catalog.regclass
  ) then
    alter table public.leads
      add constraint leads_attendance_purchase_source_fk
      foreign key (attendance_purchase_source_id)
      references public.attendances(id) on delete set null;
  end if;

  if not exists (
    select 1 from pg_catalog.pg_constraint c
    where c.conname = 'prospections_attendance_return_source_fk'
      and c.conrelid = 'public.prospections'::pg_catalog.regclass
  ) then
    alter table public.prospections
      add constraint prospections_attendance_return_source_fk
      foreign key (attendance_return_source_id)
      references public.attendances(id) on delete set null;
  end if;

  if not exists (
    select 1 from pg_catalog.pg_constraint c
    where c.conname = 'prospections_attendance_purchase_source_fk'
      and c.conrelid = 'public.prospections'::pg_catalog.regclass
  ) then
    alter table public.prospections
      add constraint prospections_attendance_purchase_source_fk
      foreign key (attendance_purchase_source_id)
      references public.attendances(id) on delete set null;
  end if;
end;
$$;



create unique index if not exists leads_attendance_visit_source_uidx
  on public.leads (attendance_visit_source_id)
  where attendance_visit_source_id is not null;
create unique index if not exists leads_attendance_purchase_source_uidx
  on public.leads (attendance_purchase_source_id)
  where attendance_purchase_source_id is not null;
create unique index if not exists prospections_attendance_return_source_uidx
  on public.prospections (attendance_return_source_id)
  where attendance_return_source_id is not null;
create unique index if not exists prospections_attendance_purchase_source_uidx
  on public.prospections (attendance_purchase_source_id)
  where attendance_purchase_source_id is not null;

-- O backfill é metadado técnico, não uma edição comercial. Suspende somente
-- os três triggers de timestamp para não reescrever a cronologia histórica.
alter table public.leads disable trigger leads_set_updated_at;
alter table public.prospections disable trigger prospections_updated_at;
alter table public.attendances disable trigger attendances_set_updated_at;

-- Backfill conservador: somente um flag e estado externo exatamente igual ao
-- que o atendimento aplicou. Ambiguidade ou alteracao manual ficam sem owner.
update public.leads leads
set attendance_visit_source_id = (
  select attendance.id
  from public.attendances attendance
  where attendance.lead_id = leads.id
    and attendance.admin_user_id = leads.admin_user_id
    and attendance.store_id = leads.store_id
    and attendance.lead_visit_applied
  order by attendance.created_at, attendance.id
  limit 1
)
where leads.attendance_visit_source_id is null
  and leads.visited = 'Sim'
  and 1 = (
    select count(*)
    from public.attendances attendance
    where attendance.lead_id = leads.id
      and attendance.admin_user_id = leads.admin_user_id
      and attendance.store_id = leads.store_id
      and attendance.lead_visit_applied
  );

update public.leads leads
set attendance_purchase_source_id = (
  select attendance.id
  from public.attendances attendance
  where attendance.lead_id = leads.id
    and attendance.admin_user_id = leads.admin_user_id
    and attendance.store_id = leads.store_id
    and attendance.lead_purchase_applied
    and attendance.tag = 'purchase'
    and leads.purchase_amount is not distinct from attendance.purchase_value
    and pg_catalog.lower(pg_catalog.btrim(coalesce(leads.service_order, '')))
      = pg_catalog.lower(pg_catalog.btrim(coalesce(attendance.service_order, '')))
  order by attendance.created_at, attendance.id
  limit 1
)
where leads.attendance_purchase_source_id is null
  and leads.bought = 'Sim'
  and 1 = (
    select count(*)
    from public.attendances attendance
    where attendance.lead_id = leads.id
      and attendance.admin_user_id = leads.admin_user_id
      and attendance.store_id = leads.store_id
      and attendance.lead_purchase_applied
      and attendance.tag = 'purchase'
      and leads.purchase_amount is not distinct from attendance.purchase_value
      and pg_catalog.lower(pg_catalog.btrim(coalesce(leads.service_order, '')))
        = pg_catalog.lower(pg_catalog.btrim(coalesce(attendance.service_order, '')))
  );

update public.prospections prospections
set attendance_return_source_id = (
  select attendance.id
  from public.attendances attendance
  where attendance.prospection_id = prospections.id
    and attendance.admin_user_id = prospections.admin_user_id
    and attendance.store_id = prospections.store_id
    and attendance.prospection_visit_applied
    and prospections.returned_at is not distinct from attendance.attended_at
  order by attendance.created_at, attendance.id
  limit 1
)
where prospections.attendance_return_source_id is null
  and 1 = (
    select count(*)
    from public.attendances attendance
    where attendance.prospection_id = prospections.id
      and attendance.admin_user_id = prospections.admin_user_id
      and attendance.store_id = prospections.store_id
      and attendance.prospection_visit_applied
      and prospections.returned_at is not distinct from attendance.attended_at
  );

update public.prospections prospections
set attendance_purchase_source_id = (
  select attendance.id
  from public.attendances attendance
  where attendance.prospection_id = prospections.id
    and attendance.admin_user_id = prospections.admin_user_id
    and attendance.store_id = prospections.store_id
    and attendance.prospection_purchase_applied
    and attendance.tag = 'purchase'
    and prospections.purchased_at is not distinct from attendance.attended_at
    and prospections.purchase_amount is not distinct from attendance.purchase_value
    and pg_catalog.lower(pg_catalog.btrim(coalesce(prospections.purchase_order, '')))
      = pg_catalog.lower(pg_catalog.btrim(coalesce(attendance.service_order, '')))
  order by attendance.created_at, attendance.id
  limit 1
)
where prospections.attendance_purchase_source_id is null
  and 1 = (
    select count(*)
    from public.attendances attendance
    where attendance.prospection_id = prospections.id
      and attendance.admin_user_id = prospections.admin_user_id
      and attendance.store_id = prospections.store_id
      and attendance.prospection_purchase_applied
      and attendance.tag = 'purchase'
      and prospections.purchased_at is not distinct from attendance.attended_at
      and prospections.purchase_amount is not distinct from attendance.purchase_value
      and pg_catalog.lower(pg_catalog.btrim(coalesce(prospections.purchase_order, '')))
        = pg_catalog.lower(pg_catalog.btrim(coalesce(attendance.service_order, '')))
  );

-- Flags antigos que já não coincidem com o outcome indicam correção manual
-- anterior a esta migration. O opt-out impede uma edição futura de
-- ressuscitar automaticamente aquilo que a pessoa removeu.
update public.leads leads
set attendance_visit_manual_override = true
where leads.attendance_visit_source_id is null
  and exists (
    select 1 from public.attendances attendance
    where attendance.lead_id = leads.id and attendance.lead_visit_applied
  );

update public.leads leads
set attendance_purchase_manual_override = true
where leads.attendance_purchase_source_id is null
  and exists (
    select 1 from public.attendances attendance
    where attendance.lead_id = leads.id and attendance.lead_purchase_applied
  );

update public.prospections prospections
set attendance_return_manual_override = true
where prospections.attendance_return_source_id is null
  and exists (
    select 1 from public.attendances attendance
    where attendance.prospection_id = prospections.id
      and attendance.prospection_visit_applied
  );

update public.prospections prospections
set attendance_purchase_manual_override = true
where prospections.attendance_purchase_source_id is null
  and exists (
    select 1 from public.attendances attendance
    where attendance.prospection_id = prospections.id
      and (
        attendance.prospection_purchase_applied
        or attendance.purchase_credit_applied
      )
  );

-- Remove apenas ownership órfão. O outcome externo permanece intocado.
update public.attendances attendance
set lead_visit_applied = false
from public.leads leads
where attendance.lead_id = leads.id
  and attendance.lead_visit_applied
  and leads.attendance_visit_source_id is distinct from attendance.id;

update public.attendances attendance
set lead_purchase_applied = false
from public.leads leads
where attendance.lead_id = leads.id
  and attendance.lead_purchase_applied
  and leads.attendance_purchase_source_id is distinct from attendance.id;

update public.attendances attendance
set prospection_visit_applied = false
from public.prospections prospections
where attendance.prospection_id = prospections.id
  and attendance.prospection_visit_applied
  and prospections.attendance_return_source_id is distinct from attendance.id;

update public.attendances attendance
set prospection_purchase_applied = false,
    purchase_credit_applied = false,
    credited_professional_id = null,
    credited_professional_name_snapshot = null,
    bonus_eligible = false,
    bonus_awarded_amount = 0,
    bonus_credit_status = case
      when attendance.tag = 'purchase' then 'already_converted'
      else 'not_applicable'
    end
from public.prospections prospections
where attendance.prospection_id = prospections.id
  and (
    attendance.prospection_purchase_applied
    or attendance.purchase_credit_applied
  )
  and prospections.attendance_purchase_source_id is distinct from attendance.id;

alter table public.leads enable trigger leads_set_updated_at;
alter table public.prospections enable trigger prospections_updated_at;
alter table public.attendances enable trigger attendances_set_updated_at;

create table app_private.attendance_edit_audit (
  id uuid primary key default extensions.gen_random_uuid(),
  attendance_id uuid not null,
  admin_user_id uuid not null,
  store_id uuid not null,
  edit_number bigint not null check (edit_number > 0),
  expected_updated_at timestamptz not null,
  request_fingerprint text not null check (request_fingerprint ~ '^[0-9a-f]{64}$'),
  changed_fields text[] not null check (pg_catalog.cardinality(changed_fields) > 0),
  before_state jsonb not null check (pg_catalog.jsonb_typeof(before_state) = 'object'),
  after_state jsonb not null check (pg_catalog.jsonb_typeof(after_state) = 'object'),
  reconciliation jsonb not null check (pg_catalog.jsonb_typeof(reconciliation) = 'object'),
  response jsonb not null check (pg_catalog.jsonb_typeof(response) = 'object'),
  changed_by uuid,
  changed_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint attendance_edit_audit_attendance_edit_unique
    unique (attendance_id, edit_number)
);

create index attendance_edit_audit_store_attendance_date_idx
  on app_private.attendance_edit_audit (store_id, attendance_id, changed_at desc);

alter table app_private.attendance_edit_audit enable row level security;
revoke all on table app_private.attendance_edit_audit from public, anon, authenticated;
grant select on table app_private.attendance_edit_audit to service_role;

create or replace function app_private.prevent_attendance_edit_audit_mutation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  raise exception 'O histórico de edição de atendimentos é imutável.';
end;
$$;

create trigger attendance_edit_audit_immutable
before update or delete on app_private.attendance_edit_audit
for each row execute function app_private.prevent_attendance_edit_audit_mutation();

create or replace function app_private.attendance_edit_fingerprint(
  p_store_id uuid,
  p_professional_id uuid,
  p_professional_name text,
  p_attended_on date,
  p_customer_name text,
  p_phone text,
  p_phone_normalized text,
  p_cpf text,
  p_cpf_normalized text,
  p_description text,
  p_tag text,
  p_service_value numeric,
  p_purchase_value numeric,
  p_service_order text
)
returns text
language sql
immutable
security invoker
set search_path = ''
as $$
  select pg_catalog.encode(
    extensions.digest(
      pg_catalog.convert_to(
        pg_catalog.jsonb_build_object(
          'store_id', p_store_id,
          'professional_id', p_professional_id,
          'professional_name', pg_catalog.lower(p_professional_name),
          'attended_on', p_attended_on,
          'customer_name', pg_catalog.lower(p_customer_name),
          'phone', p_phone,
          'phone_normalized', p_phone_normalized,
          'cpf', p_cpf,
          'cpf_normalized', p_cpf_normalized,
          'description', p_description,
          'tag', p_tag,
          'service_value', p_service_value,
          'purchase_value', p_purchase_value,
          'service_order', pg_catalog.lower(coalesce(p_service_order, ''))
        )::text,
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );
$$;

-- clock_timestamp evita devolver a mesma versao otimista quando uma unica
-- transacao faz mais de uma atualizacao de reconciliacao.
create or replace function app_private.attendance_set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := pg_catalog.clock_timestamp();
  return new;
end;
$$;

-- Escritas manuais em outcomes removem o ownership. A RPC de atendimento
-- sinaliza suas escritas internas e valida o source contra loja e vinculo.
create or replace function app_private.attendance_guard_lead_ownership()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_internal boolean := coalesce(
    pg_catalog.current_setting('app_private.attendance_projection_write', true),
    ''
  ) = '1';
begin
  if not v_internal then
    if new.visited is distinct from old.visited then
      if old.attendance_visit_source_id is not null then
        new.attendance_visit_source_id := null;
        new.attendance_visit_manual_override := true;
        update public.attendances attendance
        set lead_visit_applied = false
        where attendance.id = old.attendance_visit_source_id
          and attendance.lead_id = old.id;
      else
        -- A criação v2/v3 atualiza o outcome antes de inserir a attendance.
        -- Uma transição positiva sem owner não precisa de opt-out: o próprio
        -- estado positivo já impede claims futuros; o AFTER INSERT pode então
        -- capturar somente a attendance criada na mesma operação.
        new.attendance_visit_source_id := null;
        new.attendance_visit_manual_override := coalesce(new.visited, '') <> 'Sim';
      end if;
    end if;
    if new.bought is distinct from old.bought
       or new.purchase_amount is distinct from old.purchase_amount
       or new.service_order is distinct from old.service_order then
      if old.attendance_purchase_source_id is not null then
        new.attendance_purchase_source_id := null;
        new.attendance_purchase_manual_override := true;
        update public.attendances attendance
        set lead_purchase_applied = false
        where attendance.id = old.attendance_purchase_source_id
          and attendance.lead_id = old.id;
      else
        new.attendance_purchase_source_id := null;
        new.attendance_purchase_manual_override := coalesce(new.bought, '') <> 'Sim';
      end if;
    end if;
  end if;

  if new.attendance_visit_source_id is not null and not exists (
    select 1 from public.attendances attendance
    where attendance.id = new.attendance_visit_source_id
      and attendance.lead_id = new.id
      and attendance.store_id = new.store_id
      and attendance.admin_user_id = new.admin_user_id
      and new.visited = 'Sim'
      and not new.attendance_visit_manual_override
  ) then
    raise exception 'Origem do retorno do lead é inválida.';
  end if;

  if new.attendance_purchase_source_id is not null and not exists (
    select 1 from public.attendances attendance
    where attendance.id = new.attendance_purchase_source_id
      and attendance.lead_id = new.id
      and attendance.store_id = new.store_id
      and attendance.admin_user_id = new.admin_user_id
      and attendance.tag = 'purchase'
      and new.bought = 'Sim'
      and new.purchase_amount is not distinct from attendance.purchase_value
      and pg_catalog.lower(pg_catalog.btrim(coalesce(new.service_order, '')))
        = pg_catalog.lower(pg_catalog.btrim(coalesce(attendance.service_order, '')))
      and not new.attendance_purchase_manual_override
  ) then
    raise exception 'Origem da compra do lead é inválida.';
  end if;
  return new;
end;
$$;

create or replace function app_private.attendance_guard_prospection_ownership()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_internal boolean := coalesce(
    pg_catalog.current_setting('app_private.attendance_projection_write', true),
    ''
  ) = '1';
begin
  if not v_internal then
    if new.returned_at is distinct from old.returned_at then
      if old.attendance_return_source_id is not null then
        new.attendance_return_source_id := null;
        new.attendance_return_manual_override := true;
        update public.attendances attendance
        set prospection_visit_applied = false
        where attendance.id = old.attendance_return_source_id
          and attendance.prospection_id = old.id;
      else
        new.attendance_return_source_id := null;
        new.attendance_return_manual_override := new.returned_at is null;
      end if;
    end if;
    if new.purchased_at is distinct from old.purchased_at
       or new.purchase_amount is distinct from old.purchase_amount
       or new.purchase_order is distinct from old.purchase_order then
      if old.attendance_purchase_source_id is not null then
        new.attendance_purchase_source_id := null;
        new.attendance_purchase_manual_override := true;
        update public.attendances attendance
        set prospection_purchase_applied = false,
            purchase_credit_applied = false,
            credited_professional_id = null,
            credited_professional_name_snapshot = null,
            bonus_eligible = false,
            bonus_awarded_amount = 0,
            bonus_credit_status = case
              when attendance.tag = 'purchase' then 'already_converted'
              else 'not_applicable'
            end
        where attendance.id = old.attendance_purchase_source_id
          and attendance.prospection_id = old.id;
      else
        new.attendance_purchase_source_id := null;
        new.attendance_purchase_manual_override := new.purchased_at is null;
      end if;
    end if;
  end if;

  if new.attendance_return_source_id is not null and not exists (
    select 1 from public.attendances attendance
    where attendance.id = new.attendance_return_source_id
      and attendance.prospection_id = new.id
      and attendance.store_id = new.store_id
      and attendance.admin_user_id = new.admin_user_id
      and new.returned_at is not distinct from attendance.attended_at
      and not new.attendance_return_manual_override
  ) then
    raise exception 'Origem do retorno da prospecção é inválida.';
  end if;

  if new.attendance_purchase_source_id is not null and not exists (
    select 1 from public.attendances attendance
    where attendance.id = new.attendance_purchase_source_id
      and attendance.prospection_id = new.id
      and attendance.store_id = new.store_id
      and attendance.admin_user_id = new.admin_user_id
      and attendance.tag = 'purchase'
      and new.purchased_at is not distinct from attendance.attended_at
      and new.purchase_amount is not distinct from attendance.purchase_value
      and pg_catalog.lower(pg_catalog.btrim(coalesce(new.purchase_order, '')))
        = pg_catalog.lower(pg_catalog.btrim(coalesce(attendance.service_order, '')))
      and not new.attendance_purchase_manual_override
  ) then
    raise exception 'Origem da compra da prospecção é inválida.';
  end if;
  return new;
end;
$$;

drop trigger if exists leads_attendance_ownership_guard on public.leads;
create trigger leads_attendance_ownership_guard
before update of visited, bought, purchase_amount, service_order,
  attendance_visit_source_id, attendance_purchase_source_id
on public.leads
for each row execute function app_private.attendance_guard_lead_ownership();

drop trigger if exists prospections_attendance_ownership_guard on public.prospections;
create trigger prospections_attendance_ownership_guard
before update of returned_at, purchased_at, purchase_amount, purchase_order,
  attendance_return_source_id, attendance_purchase_source_id
on public.prospections
for each row execute function app_private.attendance_guard_prospection_ownership();

create or replace function app_private.attendance_capture_projection_ownership()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_previous_setting text := coalesce(
    pg_catalog.current_setting('app_private.attendance_projection_write', true),
    ''
  );
begin
  perform pg_catalog.set_config('app_private.attendance_projection_write', '1', true);

  if new.lead_id is not null then
    update public.leads leads
    set attendance_visit_source_id = case
          when new.lead_visit_applied
           and leads.attendance_visit_source_id is null
           and not leads.attendance_visit_manual_override
           and leads.visited = 'Sim'
            then new.id
          else leads.attendance_visit_source_id
        end,
        attendance_purchase_source_id = case
          when new.lead_purchase_applied
           and leads.attendance_purchase_source_id is null
           and not leads.attendance_purchase_manual_override
           and leads.bought = 'Sim'
           and leads.purchase_amount is not distinct from new.purchase_value
           and pg_catalog.lower(pg_catalog.btrim(coalesce(leads.service_order, '')))
             = pg_catalog.lower(pg_catalog.btrim(coalesce(new.service_order, '')))
            then new.id
          else leads.attendance_purchase_source_id
        end,
        attendance_visit_manual_override = case
          when new.lead_visit_applied
           and leads.attendance_visit_source_id is null
           and not leads.attendance_visit_manual_override
           and leads.visited = 'Sim' then false
          else leads.attendance_visit_manual_override
        end,
        attendance_purchase_manual_override = case
          when new.lead_purchase_applied
           and leads.attendance_purchase_source_id is null
           and not leads.attendance_purchase_manual_override
           and leads.bought = 'Sim' then false
          else leads.attendance_purchase_manual_override
        end
    where leads.id = new.lead_id
      and leads.store_id = new.store_id
      and leads.admin_user_id = new.admin_user_id;
  end if;

  if new.prospection_id is not null then
    update public.prospections prospections
    set attendance_return_source_id = case
          when new.prospection_visit_applied
           and prospections.attendance_return_source_id is null
           and not prospections.attendance_return_manual_override
           and prospections.returned_at is not distinct from new.attended_at
            then new.id
          else prospections.attendance_return_source_id
        end,
        attendance_purchase_source_id = case
          when new.prospection_purchase_applied
           and prospections.attendance_purchase_source_id is null
           and not prospections.attendance_purchase_manual_override
           and prospections.purchased_at is not distinct from new.attended_at
           and prospections.purchase_amount is not distinct from new.purchase_value
           and pg_catalog.lower(pg_catalog.btrim(coalesce(prospections.purchase_order, '')))
             = pg_catalog.lower(pg_catalog.btrim(coalesce(new.service_order, '')))
            then new.id
          else prospections.attendance_purchase_source_id
        end,
        attendance_return_manual_override = case
          when new.prospection_visit_applied
           and prospections.attendance_return_source_id is null
           and not prospections.attendance_return_manual_override then false
          else prospections.attendance_return_manual_override
        end,
        attendance_purchase_manual_override = case
          when new.prospection_purchase_applied
           and prospections.attendance_purchase_source_id is null
           and not prospections.attendance_purchase_manual_override then false
          else prospections.attendance_purchase_manual_override
        end
    where prospections.id = new.prospection_id
      and prospections.store_id = new.store_id
      and prospections.admin_user_id = new.admin_user_id;
  end if;

  -- Se um outcome manual bloqueou a captura, a linha recém-criada não pode
  -- conservar flags/crédito órfãos nem ocupar a unicidade financeira.
  update public.attendances attendance
  set lead_visit_applied = attendance.lead_visit_applied and exists (
        select 1 from public.leads leads
        where leads.id = attendance.lead_id
          and leads.attendance_visit_source_id = attendance.id
      ),
      lead_purchase_applied = attendance.lead_purchase_applied and exists (
        select 1 from public.leads leads
        where leads.id = attendance.lead_id
          and leads.attendance_purchase_source_id = attendance.id
      ),
      prospection_visit_applied = attendance.prospection_visit_applied and exists (
        select 1 from public.prospections prospections
        where prospections.id = attendance.prospection_id
          and prospections.attendance_return_source_id = attendance.id
      ),
      prospection_purchase_applied = attendance.prospection_purchase_applied and exists (
        select 1 from public.prospections prospections
        where prospections.id = attendance.prospection_id
          and prospections.attendance_purchase_source_id = attendance.id
      ),
      purchase_credit_applied = attendance.purchase_credit_applied and exists (
        select 1 from public.prospections prospections
        where prospections.id = attendance.prospection_id
          and prospections.attendance_purchase_source_id = attendance.id
      ),
      credited_professional_id = case when exists (
        select 1 from public.prospections prospections
        where prospections.id = attendance.prospection_id
          and prospections.attendance_purchase_source_id = attendance.id
      ) then attendance.credited_professional_id else null end,
      credited_professional_name_snapshot = case when exists (
        select 1 from public.prospections prospections
        where prospections.id = attendance.prospection_id
          and prospections.attendance_purchase_source_id = attendance.id
      ) then attendance.credited_professional_name_snapshot else null end,
      bonus_eligible = attendance.bonus_eligible and exists (
        select 1 from public.prospections prospections
        where prospections.id = attendance.prospection_id
          and prospections.attendance_purchase_source_id = attendance.id
      ),
      bonus_awarded_amount = case when exists (
        select 1 from public.prospections prospections
        where prospections.id = attendance.prospection_id
          and prospections.attendance_purchase_source_id = attendance.id
      ) then attendance.bonus_awarded_amount else 0 end,
      bonus_credit_status = case when exists (
        select 1 from public.prospections prospections
        where prospections.id = attendance.prospection_id
          and prospections.attendance_purchase_source_id = attendance.id
      ) then attendance.bonus_credit_status
        when attendance.tag = 'purchase' then 'already_converted'
        else 'not_applicable' end
  where attendance.id = new.id;

  perform pg_catalog.set_config(
    'app_private.attendance_projection_write',
    v_previous_setting,
    true
  );
  return new;
end;
$$;

drop trigger if exists attendances_capture_projection_ownership on public.attendances;
create trigger attendances_capture_projection_ownership
after insert on public.attendances
for each row execute function app_private.attendance_capture_projection_ownership();

-- Versões finais: podem transferir apenas o source externo para o próximo
-- registro por ordem imutável de criação; nunca mutam o sibling. Assim uma
-- compra real não some e não existe ciclo de locks attendance-A/B.
create or replace function app_private.reconcile_lead_from_attendances(
  p_lead_id uuid,
  p_admin_user_id uuid,
  p_store_id uuid,
  p_edit_attendance_id uuid,
  p_updated_by uuid,
  p_reconcile_visit boolean,
  p_reconcile_purchase boolean,
  p_claim_if_unowned boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_lead public.leads%rowtype;
  v_attendance public.attendances%rowtype;
  v_visit_candidate public.attendances%rowtype;
  v_purchase_candidate public.attendances%rowtype;
  v_visit_owned boolean := false;
  v_purchase_owned boolean := false;
  v_visit_claimed boolean := false;
  v_purchase_claimed boolean := false;
  v_visit_eligible boolean := false;
  v_purchase_eligible boolean := false;
  v_visit_source_id uuid;
  v_purchase_source_id uuid;
  v_previous_setting text := coalesce(
    pg_catalog.current_setting('app_private.attendance_projection_write', true), ''
  );
begin
  if p_lead_id is null then
    return pg_catalog.jsonb_build_object('lead_id', null);
  end if;

  select leads.* into v_lead
  from public.leads leads
  where leads.id = p_lead_id
    and leads.admin_user_id = p_admin_user_id
    and leads.store_id = p_store_id
  for update;
  if not found then
    raise exception 'Lead vinculado não foi encontrado nesta loja.';
  end if;

  select attendance.* into v_attendance
  from public.attendances attendance
  where attendance.id = p_edit_attendance_id
    and attendance.admin_user_id = p_admin_user_id
    and attendance.store_id = p_store_id;
  if not found then
    raise exception 'Atendimento da reconciliação não foi encontrado.';
  end if;

  v_visit_eligible := v_attendance.lead_id = p_lead_id;
  v_purchase_eligible := v_visit_eligible and v_attendance.tag = 'purchase';
  v_visit_owned := v_lead.attendance_visit_source_id = p_edit_attendance_id;
  v_purchase_owned := v_lead.attendance_purchase_source_id = p_edit_attendance_id;
  v_visit_claimed := coalesce(p_claim_if_unowned, false)
    and v_visit_eligible
    and v_lead.attendance_visit_source_id is null
    and not v_lead.attendance_visit_manual_override
    and coalesce(v_lead.visited, '') <> 'Sim';
  v_purchase_claimed := coalesce(p_claim_if_unowned, false)
    and v_purchase_eligible
    and v_lead.attendance_purchase_source_id is null
    and not v_lead.attendance_purchase_manual_override
    and coalesce(v_lead.bought, '') <> 'Sim';

  if v_visit_owned and not v_visit_eligible then
    select sibling.* into v_visit_candidate
    from public.attendances sibling
    where sibling.lead_id = p_lead_id
      and sibling.admin_user_id = p_admin_user_id
      and sibling.store_id = p_store_id
      and sibling.id <> p_edit_attendance_id
    order by sibling.created_at, sibling.id
    limit 1;
  end if;
  if v_purchase_owned and not v_purchase_eligible then
    select sibling.* into v_purchase_candidate
    from public.attendances sibling
    where sibling.lead_id = p_lead_id
      and sibling.admin_user_id = p_admin_user_id
      and sibling.store_id = p_store_id
      and sibling.id <> p_edit_attendance_id
      and sibling.tag = 'purchase'
    order by sibling.created_at, sibling.id
    limit 1;
  end if;

  v_visit_source_id := case
    when v_visit_owned and v_visit_eligible then p_edit_attendance_id
    when v_visit_claimed then p_edit_attendance_id
    when v_visit_owned then v_visit_candidate.id
    else v_lead.attendance_visit_source_id
  end;
  v_purchase_source_id := case
    when v_purchase_owned and v_purchase_eligible then p_edit_attendance_id
    when v_purchase_claimed then p_edit_attendance_id
    when v_purchase_owned then v_purchase_candidate.id
    else v_lead.attendance_purchase_source_id
  end;

  if coalesce(p_reconcile_visit, false) and (v_visit_owned or v_visit_claimed) then
    perform pg_catalog.set_config('app_private.attendance_projection_write', '1', true);
    update public.leads leads
    set visited = case when v_visit_source_id is null then 'Não' else 'Sim' end,
        attendance_visit_source_id = v_visit_source_id,
        attendance_visit_manual_override = false,
        updated_by = p_updated_by
    where leads.id = p_lead_id;
    perform pg_catalog.set_config(
      'app_private.attendance_projection_write', v_previous_setting, true
    );
  end if;

  if coalesce(p_reconcile_purchase, false) and (v_purchase_owned or v_purchase_claimed) then
    perform pg_catalog.set_config('app_private.attendance_projection_write', '1', true);
    update public.leads leads
    set bought = case when v_purchase_source_id is null then 'Não' else 'Sim' end,
        purchase_amount = case
          when v_purchase_source_id is null then null
          when v_purchase_source_id = p_edit_attendance_id then v_attendance.purchase_value
          else v_purchase_candidate.purchase_value
        end,
        service_order = case
          when v_purchase_source_id is null then null
          when v_purchase_source_id = p_edit_attendance_id then v_attendance.service_order
          else v_purchase_candidate.service_order
        end,
        attendance_purchase_source_id = v_purchase_source_id,
        attendance_purchase_manual_override = false,
        updated_by = p_updated_by
    where leads.id = p_lead_id;
    perform pg_catalog.set_config(
      'app_private.attendance_projection_write', v_previous_setting, true
    );
  end if;

  update public.attendances attendance
      set lead_visit_applied = case
        when coalesce(p_reconcile_visit, false)
          then coalesce(v_visit_source_id = p_edit_attendance_id, false)
        else attendance.lead_visit_applied
      end,
      lead_purchase_applied = case
        when coalesce(p_reconcile_purchase, false)
          then coalesce(v_purchase_source_id = p_edit_attendance_id, false)
        else attendance.lead_purchase_applied
      end
  where attendance.id = p_edit_attendance_id
    and (
      attendance.lead_visit_applied is distinct from (
        case when coalesce(p_reconcile_visit, false)
          then coalesce(v_visit_source_id = p_edit_attendance_id, false)
          else attendance.lead_visit_applied end
      )
      or attendance.lead_purchase_applied is distinct from (
        case when coalesce(p_reconcile_purchase, false)
          then coalesce(v_purchase_source_id = p_edit_attendance_id, false)
          else attendance.lead_purchase_applied end
      )
    );

  -- A RPC serializa edicoes pelo advisory lock da loja antes de bloquear
  -- qualquer attendance. Portanto, quando o source sai da linha editada, o
  -- novo owner pode ter seus flags materializados sem criar o ciclo A -> B / B
  -- -> A que existia antes do lock global. Source_id continua sendo a verdade;
  -- estes flags mantêm consumidores legados (lista/métricas) coerentes.
  if coalesce(p_reconcile_visit, false)
     and v_visit_source_id is not null
     and v_visit_source_id <> p_edit_attendance_id then
    update public.attendances attendance
    set lead_visit_applied = true
    where attendance.id = v_visit_source_id
      and attendance.lead_id = p_lead_id
      and attendance.admin_user_id = p_admin_user_id
      and attendance.store_id = p_store_id
      and not attendance.lead_visit_applied;
  end if;

  if coalesce(p_reconcile_purchase, false)
     and v_purchase_source_id is not null
     and v_purchase_source_id <> p_edit_attendance_id then
    update public.attendances attendance
    set lead_purchase_applied = true
    where attendance.id = v_purchase_source_id
      and attendance.lead_id = p_lead_id
      and attendance.admin_user_id = p_admin_user_id
      and attendance.store_id = p_store_id
      and attendance.tag = 'purchase'
      and not attendance.lead_purchase_applied;
  end if;

  return pg_catalog.jsonb_build_object(
    'lead_id', p_lead_id,
    'visit_was_owned', v_visit_owned,
    'visit_claimed', v_visit_claimed,
    'visit_source_id', v_visit_source_id,
    'purchase_was_owned', v_purchase_owned,
    'purchase_claimed', v_purchase_claimed,
    'purchase_source_id', v_purchase_source_id,
    'visit_sibling_synced',
      v_visit_source_id is not null
      and v_visit_source_id <> p_edit_attendance_id,
    'purchase_sibling_synced',
      v_purchase_source_id is not null
      and v_purchase_source_id <> p_edit_attendance_id,
    'sibling_promoted',
      v_visit_source_id = v_visit_candidate.id
      or v_purchase_source_id = v_purchase_candidate.id
  );
end;
$$;

create or replace function app_private.reconcile_prospection_from_attendances(
  p_prospection_id uuid,
  p_admin_user_id uuid,
  p_store_id uuid,
  p_edit_attendance_id uuid,
  p_updated_by uuid,
  p_reconcile_return boolean,
  p_reconcile_purchase boolean,
  p_claim_if_unowned boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_prospection public.prospections%rowtype;
  v_attendance public.attendances%rowtype;
  v_return_candidate public.attendances%rowtype;
  v_purchase_candidate public.attendances%rowtype;
  v_return_projection public.attendances%rowtype;
  v_purchase_projection public.attendances%rowtype;
  v_return_owned boolean := false;
  v_purchase_owned boolean := false;
  v_return_claimed boolean := false;
  v_purchase_claimed boolean := false;
  v_return_eligible boolean := false;
  v_purchase_eligible boolean := false;
  v_return_source_id uuid;
  v_purchase_source_id uuid;
  v_professional_name text;
  v_credited_professional_id uuid;
  v_credited_professional_name text;
  v_bonus_minimum numeric(14,2);
  v_bonus_amount numeric(14,2);
  v_bonus_eligible boolean := false;
  v_bonus_status text := 'not_applicable';
  v_previous_setting text := coalesce(
    pg_catalog.current_setting('app_private.attendance_projection_write', true), ''
  );
begin
  if p_prospection_id is null then
    return pg_catalog.jsonb_build_object('prospection_id', null);
  end if;

  select prospections.* into v_prospection
  from public.prospections prospections
  where prospections.id = p_prospection_id
    and prospections.admin_user_id = p_admin_user_id
    and prospections.store_id = p_store_id
  for update;
  if not found then
    raise exception 'Prospecção vinculada não foi encontrada nesta loja.';
  end if;

  select attendance.* into v_attendance
  from public.attendances attendance
  where attendance.id = p_edit_attendance_id
    and attendance.admin_user_id = p_admin_user_id
    and attendance.store_id = p_store_id;
  if not found then
    raise exception 'Atendimento da reconciliação não foi encontrado.';
  end if;

  v_return_eligible := v_attendance.prospection_id = p_prospection_id;
  v_purchase_eligible := v_return_eligible and v_attendance.tag = 'purchase';
  v_return_owned := v_prospection.attendance_return_source_id = p_edit_attendance_id;
  v_purchase_owned := v_prospection.attendance_purchase_source_id = p_edit_attendance_id;
  v_return_claimed := coalesce(p_claim_if_unowned, false)
    and v_return_eligible
    and v_prospection.attendance_return_source_id is null
    and not v_prospection.attendance_return_manual_override
    and v_prospection.returned_at is null;
  v_purchase_claimed := coalesce(p_claim_if_unowned, false)
    and v_purchase_eligible
    and v_prospection.attendance_purchase_source_id is null
    and not v_prospection.attendance_purchase_manual_override
    and v_prospection.purchased_at is null;

  if v_return_owned and not v_return_eligible then
    select sibling.* into v_return_candidate
    from public.attendances sibling
    where sibling.prospection_id = p_prospection_id
      and sibling.admin_user_id = p_admin_user_id
      and sibling.store_id = p_store_id
      and sibling.id <> p_edit_attendance_id
    order by sibling.created_at, sibling.id
    limit 1;
  end if;
  if v_purchase_owned and not v_purchase_eligible then
    select sibling.* into v_purchase_candidate
    from public.attendances sibling
    where sibling.prospection_id = p_prospection_id
      and sibling.admin_user_id = p_admin_user_id
      and sibling.store_id = p_store_id
      and sibling.id <> p_edit_attendance_id
      and sibling.tag = 'purchase'
    order by sibling.created_at, sibling.id
    limit 1;
  end if;

  v_return_source_id := case
    when v_return_owned and v_return_eligible then p_edit_attendance_id
    when v_return_claimed then p_edit_attendance_id
    when v_return_owned then v_return_candidate.id
    else v_prospection.attendance_return_source_id
  end;
  v_purchase_source_id := case
    when v_purchase_owned and v_purchase_eligible then p_edit_attendance_id
    when v_purchase_claimed then p_edit_attendance_id
    when v_purchase_owned then v_purchase_candidate.id
    else v_prospection.attendance_purchase_source_id
  end;

  if v_return_source_id = p_edit_attendance_id then
    v_return_projection := v_attendance;
  elsif v_return_source_id = v_return_candidate.id then
    v_return_projection := v_return_candidate;
  end if;
  if v_purchase_source_id = p_edit_attendance_id then
    v_purchase_projection := v_attendance;
  elsif v_purchase_source_id = v_purchase_candidate.id then
    v_purchase_projection := v_purchase_candidate;
  end if;

  if coalesce(p_reconcile_return, false) and (v_return_owned or v_return_claimed) then
    perform pg_catalog.set_config('app_private.attendance_projection_write', '1', true);
    update public.prospections prospections
    set returned_at = case
          when v_return_source_id is null then null else v_return_projection.attended_at
        end,
        attendance_return_source_id = v_return_source_id,
        attendance_return_manual_override = false,
        updated_by = p_updated_by
    where prospections.id = p_prospection_id;
    perform pg_catalog.set_config(
      'app_private.attendance_projection_write', v_previous_setting, true
    );
  end if;

  if coalesce(p_reconcile_purchase, false) and (v_purchase_owned or v_purchase_claimed) then
    if v_purchase_source_id is not null then
      select professionals.name into v_professional_name
      from public.prospection_professionals professionals
      where professionals.id = v_prospection.professional_id
        and professionals.store_id = p_store_id
        and professionals.admin_user_id = p_admin_user_id;
      select professionals.id into v_credited_professional_id
      from public.prospection_professionals professionals
      where professionals.id = coalesce(
          v_prospection.bonus_professional_id_snapshot,
          v_prospection.professional_id
        )
        and professionals.store_id = p_store_id
        and professionals.admin_user_id = p_admin_user_id;
      v_credited_professional_name := coalesce(
        nullif(pg_catalog.btrim(v_prospection.bonus_professional_name_snapshot), ''),
        nullif(pg_catalog.btrim(v_professional_name), ''),
        nullif(pg_catalog.btrim(v_prospection.professional_name_snapshot), '')
      );
      v_bonus_minimum := coalesce(v_purchase_projection.bonus_minimum_snapshot, 300);
      v_bonus_amount := coalesce(v_purchase_projection.bonus_amount_snapshot, 20);
      v_bonus_eligible := (
        v_credited_professional_id is not null
        or v_credited_professional_name is not null
      ) and v_purchase_projection.purchase_value >= v_bonus_minimum;
      v_bonus_status := case
        when v_credited_professional_id is null
         and v_credited_professional_name is null then 'missing_professional'
        when v_bonus_eligible then 'awarded'
        else 'below_minimum'
      end;
    end if;

    perform pg_catalog.set_config('app_private.attendance_projection_write', '1', true);
    update public.prospections prospections
    set returned_at = case
          when v_purchase_source_id is null then prospections.returned_at
          else coalesce(prospections.returned_at, v_purchase_projection.attended_at)
        end,
        purchased_at = case
          when v_purchase_source_id is null then null else v_purchase_projection.attended_at
        end,
        purchase_amount = case
          when v_purchase_source_id is null then null else v_purchase_projection.purchase_value
        end,
        purchase_order = case
          when v_purchase_source_id is null then null else v_purchase_projection.service_order
        end,
        bonus_professional_id_snapshot = v_credited_professional_id,
        bonus_professional_name_snapshot = v_credited_professional_name,
        bonus_minimum_snapshot = v_bonus_minimum,
        bonus_amount_snapshot = v_bonus_amount,
        bonus_eligible_snapshot = case
          when v_purchase_source_id is null then null else v_bonus_eligible
        end,
        bonus_awarded_amount_snapshot = case
          when v_purchase_source_id is null then null
          when v_bonus_eligible then v_bonus_amount else 0
        end,
        bonus_credit_status_snapshot = case
          when v_purchase_source_id is null then null else v_bonus_status
        end,
        attendance_purchase_source_id = v_purchase_source_id,
        attendance_purchase_manual_override = false,
        updated_by = p_updated_by
    where prospections.id = p_prospection_id;
    perform pg_catalog.set_config(
      'app_private.attendance_projection_write', v_previous_setting, true
    );
  end if;

  update public.attendances attendance
      set prospection_visit_applied = case
        when coalesce(p_reconcile_return, false)
          then coalesce(v_return_source_id = p_edit_attendance_id, false)
        else attendance.prospection_visit_applied
      end,
      prospection_purchase_applied = case
        when coalesce(p_reconcile_purchase, false)
          then coalesce(v_purchase_source_id = p_edit_attendance_id, false)
        else attendance.prospection_purchase_applied
      end,
      purchase_credit_applied = case
        when coalesce(p_reconcile_purchase, false) then
          coalesce(v_purchase_source_id = p_edit_attendance_id, false)
          and (v_credited_professional_id is not null or v_credited_professional_name is not null)
        else attendance.purchase_credit_applied
      end,
      credited_professional_id = case
        when not coalesce(p_reconcile_purchase, false) then attendance.credited_professional_id
        when v_purchase_source_id = p_edit_attendance_id then v_credited_professional_id
        else null
      end,
      credited_professional_name_snapshot = case
        when not coalesce(p_reconcile_purchase, false) then attendance.credited_professional_name_snapshot
        when v_purchase_source_id = p_edit_attendance_id then v_credited_professional_name
        else null
      end,
      bonus_eligible = case
        when not coalesce(p_reconcile_purchase, false) then attendance.bonus_eligible
        else coalesce(v_purchase_source_id = p_edit_attendance_id, false)
          and v_bonus_eligible
      end,
      bonus_awarded_amount = case
        when not coalesce(p_reconcile_purchase, false) then attendance.bonus_awarded_amount
        when v_purchase_source_id = p_edit_attendance_id and v_bonus_eligible
          then v_bonus_amount
        else 0
      end,
      bonus_credit_status = case
        when not coalesce(p_reconcile_purchase, false) then attendance.bonus_credit_status
        when v_purchase_source_id = p_edit_attendance_id then v_bonus_status
        when attendance.tag = 'purchase' then 'already_converted'
        else 'not_applicable'
      end
  where attendance.id = p_edit_attendance_id;

  if coalesce(p_reconcile_return, false)
     and v_return_source_id is not null
     and v_return_source_id <> p_edit_attendance_id then
    update public.attendances attendance
    set prospection_visit_applied = true
    where attendance.id = v_return_source_id
      and attendance.prospection_id = p_prospection_id
      and attendance.admin_user_id = p_admin_user_id
      and attendance.store_id = p_store_id
      and not attendance.prospection_visit_applied;
  end if;

  if coalesce(p_reconcile_purchase, false)
     and v_purchase_source_id is not null
     and v_purchase_source_id <> p_edit_attendance_id then
    update public.attendances attendance
    set prospection_purchase_applied = true,
        purchase_credit_applied = (
          v_credited_professional_id is not null
          or v_credited_professional_name is not null
        ),
        credited_professional_id = v_credited_professional_id,
        credited_professional_name_snapshot = v_credited_professional_name,
        bonus_minimum_snapshot = v_bonus_minimum,
        bonus_amount_snapshot = v_bonus_amount,
        bonus_eligible = v_bonus_eligible,
        bonus_awarded_amount = case
          when v_bonus_eligible then v_bonus_amount else 0
        end,
        bonus_credit_status = v_bonus_status
    where attendance.id = v_purchase_source_id
      and attendance.prospection_id = p_prospection_id
      and attendance.admin_user_id = p_admin_user_id
      and attendance.store_id = p_store_id
      and attendance.tag = 'purchase'
      and (
        not attendance.prospection_purchase_applied
        or attendance.purchase_credit_applied is distinct from (
          v_credited_professional_id is not null
          or v_credited_professional_name is not null
        )
        or attendance.credited_professional_id is distinct from v_credited_professional_id
        or attendance.credited_professional_name_snapshot is distinct from v_credited_professional_name
        or attendance.bonus_minimum_snapshot is distinct from v_bonus_minimum
        or attendance.bonus_amount_snapshot is distinct from v_bonus_amount
        or attendance.bonus_eligible is distinct from v_bonus_eligible
        or attendance.bonus_awarded_amount is distinct from (
          case when v_bonus_eligible then v_bonus_amount else 0 end
        )
        or attendance.bonus_credit_status is distinct from v_bonus_status
      );
  end if;

  return pg_catalog.jsonb_build_object(
    'prospection_id', p_prospection_id,
    'return_was_owned', v_return_owned,
    'return_claimed', v_return_claimed,
    'return_source_id', v_return_source_id,
    'purchase_was_owned', v_purchase_owned,
    'purchase_claimed', v_purchase_claimed,
    'purchase_source_id', v_purchase_source_id,
    'bonus_credit_status', v_bonus_status,
    'return_sibling_synced',
      v_return_source_id is not null
      and v_return_source_id <> p_edit_attendance_id,
    'purchase_sibling_synced',
      v_purchase_source_id is not null
      and v_purchase_source_id <> p_edit_attendance_id,
    'sibling_promoted',
      v_return_source_id = v_return_candidate.id
      or v_purchase_source_id = v_purchase_candidate.id
  );
end;
$$;

create or replace function app_private.rpc_update_attendance_v1(
  p_session_token text,
  p_attendance_id uuid,
  p_store_id uuid,
  p_professional_name text,
  p_attended_on date,
  p_customer_name text,
  p_phone text,
  p_cpf text,
  p_description text,
  p_tag text,
  p_service_value numeric,
  p_purchase_value numeric,
  p_service_order text,
  p_expected_updated_at timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_session record;
  v_existing public.attendances%rowtype;
  v_current public.attendances%rowtype;
  v_store_id uuid;
  v_professional_id uuid;
  v_professional_name text := left(pg_catalog.btrim(coalesce(p_professional_name, '')), 200);
  v_professional_found boolean := false;
  v_customer_name text := left(pg_catalog.btrim(coalesce(p_customer_name, '')), 240);
  v_phone text := nullif(left(pg_catalog.btrim(coalesce(p_phone, '')), 80), '');
  v_phone_normalized text;
  v_cpf text := nullif(left(pg_catalog.btrim(coalesce(p_cpf, '')), 14), '');
  v_cpf_normalized text;
  v_description text := left(pg_catalog.btrim(coalesce(p_description, '')), 4000);
  v_tag text;
  v_service_value numeric(14,2);
  v_purchase_value numeric(14,2);
  v_service_order text := nullif(left(pg_catalog.btrim(coalesce(p_service_order, '')), 120), '');
  v_today date;
  v_min_attended_on date;
  v_attended_at timestamptz;
  v_local_time time;
  v_identity_changed boolean;
  v_same_content boolean;
  v_request_fingerprint text;
  v_lead_id uuid;
  v_prospection_id uuid;
  v_old_lead_id uuid;
  v_old_prospection_id uuid;
  v_lead_count integer := 0;
  v_prospection_count integer := 0;
  v_lead_candidates jsonb := '[]'::jsonb;
  v_prospection_candidates jsonb := '[]'::jsonb;
  v_match_status text := 'unmatched';
  v_prospection_professional_id uuid;
  v_prospection_professional_name text;
  v_bonus_minimum numeric(14,2) := 300;
  v_bonus_amount numeric(14,2) := 20;
  v_initial_bonus_status text := 'not_applicable';
  v_lock_key text;
  v_before_state jsonb;
  v_after_state jsonb;
  v_reconciliation jsonb := '{}'::jsonb;
  v_decision jsonb;
  v_changed_fields text[];
  v_audit_id uuid := extensions.gen_random_uuid();
  v_response jsonb;
  v_message text;
begin
  if p_attendance_id is null then
    raise exception 'Informe o atendimento que será editado.';
  end if;
  if p_expected_updated_at is null then
    raise exception 'Atualize a lista antes de editar este atendimento.';
  end if;

  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text = 'store' then
    if p_store_id is not null and p_store_id <> v_session.user_store_id then
      raise exception 'Cliente não pode editar atendimento de outra loja.';
    end if;
    v_store_id := v_session.user_store_id;
  else
    v_store_id := p_store_id;
  end if;

  if v_store_id is null then
    raise exception 'Selecione o cliente do atendimento.';
  end if;
  if not app_private.attendance_store_allowed(
    v_session.admin_user_id,
    v_session.user_id,
    v_session.user_role,
    v_session.user_store_id,
    v_store_id
  ) then
    raise exception 'Atendimento não encontrado ou sem permissão.';
  end if;

  -- Uma única edição de atendimento por loja por vez. Evita ciclos ao
  -- reconciliar dois registros que compartilham lead/prospecção.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('attendance:store-edit:' || v_store_id::text, 0)
  );

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('attendance:edit:' || p_attendance_id::text, 0)
  );

  select attendance.* into v_existing
  from public.attendances attendance
  where attendance.id = p_attendance_id
    and attendance.store_id = v_store_id
    and attendance.admin_user_id = v_session.admin_user_id
  for update;

  if not found then
    raise exception 'Atendimento não encontrado ou sem permissão.';
  end if;

  v_old_lead_id := v_existing.lead_id;
  v_old_prospection_id := v_existing.prospection_id;

  v_today := pg_catalog.timezone('America/Sao_Paulo', pg_catalog.clock_timestamp())::date;
  v_min_attended_on := (v_today - interval '2 years')::date;
  if p_attended_on is null then
    raise exception 'Informe a data do atendimento.';
  end if;
  if p_attended_on > v_today then
    raise exception 'A data do atendimento não pode estar no futuro.';
  end if;
  if p_attended_on < v_min_attended_on then
    raise exception 'A data do atendimento deve estar dentro dos últimos 2 anos.';
  end if;

  -- Troca somente a data local; hora/minuto/segundo originais permanecem.
  v_local_time := pg_catalog.timezone(
    'America/Sao_Paulo', v_existing.attended_at
  )::time;
  v_attended_at := (p_attended_on + v_local_time)
    at time zone 'America/Sao_Paulo';

  if v_professional_name = '' then
    raise exception 'Informe o profissional atendente.';
  end if;
  if v_customer_name = '' then
    raise exception 'Informe o nome do cliente.';
  end if;
  if v_description = '' then
    raise exception 'Descreva o atendimento.';
  end if;

  v_phone_normalized := app_private.attendance_normalize_phone(v_phone);
  v_cpf_normalized := app_private.attendance_normalize_cpf(v_cpf);
  if v_phone is not null and v_phone_normalized is null then
    raise exception 'Informe um telefone válido com DDD.';
  end if;
  if v_cpf is not null
     and (v_cpf_normalized is null or not app_private.is_valid_cpf(v_cpf)) then
    raise exception 'Informe um CPF válido.';
  end if;
  if v_phone_normalized is null and v_cpf_normalized is null then
    raise exception 'Informe o telefone ou o CPF do cliente.';
  end if;

  v_tag := app_private.attendance_normalize_tag(p_tag);
  if v_tag is null then
    raise exception 'Use a etiqueta Orçamento, Compra ou Outro.';
  end if;

  begin
    v_service_value := case when p_service_value is null then null else round(p_service_value, 2) end;
    v_purchase_value := case when p_purchase_value is null then null else round(p_purchase_value, 2) end;
  exception
    when numeric_value_out_of_range then
      raise exception 'Um dos valores informados está fora do limite permitido.';
  end;

  if v_service_value is not null and v_service_value < 0 then
    raise exception 'O valor do atendimento não pode ser negativo.';
  end if;
  if v_tag = 'purchase' then
    if coalesce(v_purchase_value, 0) <= 0 then
      raise exception 'Informe um valor de compra maior que zero.';
    end if;
    if v_service_order is null then
      raise exception 'Informe o número da OS.';
    end if;
  else
    if v_purchase_value is not null or v_service_order is not null then
      raise exception 'Valor da compra e OS só podem ser informados na etiqueta Compra.';
    end if;
    v_purchase_value := null;
    v_service_order := null;
  end if;

  -- Manter o mesmo snapshot permite editar registros cujo atendente foi
  -- arquivado depois. Qualquer troca exige profissional não arquivado da loja.
  if pg_catalog.lower(v_professional_name)
     = pg_catalog.lower(pg_catalog.btrim(v_existing.professional_name_snapshot)) then
    if v_existing.professional_id is null then
      v_professional_id := null;
      v_professional_name := v_existing.professional_name_snapshot;
      v_professional_found := true;
    else
      select professionals.id, professionals.name
      into v_professional_id, v_professional_name
      from public.prospection_professionals professionals
      where professionals.id = v_existing.professional_id
        and professionals.store_id = v_store_id
        and professionals.admin_user_id = v_session.admin_user_id
      for share;
      v_professional_found := found;
    end if;
  end if;

  if not v_professional_found then
    select professionals.id, professionals.name
    into v_professional_id, v_professional_name
    from public.prospection_professionals professionals
    where professionals.store_id = v_store_id
      and professionals.admin_user_id = v_session.admin_user_id
      and professionals.archived_at is null
      and pg_catalog.lower(pg_catalog.btrim(professionals.name))
        = pg_catalog.lower(v_professional_name)
    order by professionals.created_at, professionals.id
    limit 1
    for share;
    if not found then
      raise exception 'Selecione um profissional não arquivado desta empresa.';
    end if;
  end if;

  v_request_fingerprint := app_private.attendance_edit_fingerprint(
    v_store_id, v_professional_id, v_professional_name, p_attended_on,
    v_customer_name, v_phone, v_phone_normalized, v_cpf, v_cpf_normalized,
    v_description, v_tag, v_service_value, v_purchase_value, v_service_order
  );

  v_same_content :=
    v_existing.professional_id is not distinct from v_professional_id
    and v_existing.professional_name_snapshot is not distinct from v_professional_name
    and pg_catalog.timezone('America/Sao_Paulo', v_existing.attended_at)::date = p_attended_on
    and v_existing.customer_name is not distinct from v_customer_name
    and v_existing.phone is not distinct from v_phone
    and v_existing.phone_normalized is not distinct from v_phone_normalized
    and v_existing.customer_cpf is not distinct from v_cpf
    and v_existing.cpf_normalized is not distinct from v_cpf_normalized
    and v_existing.description is not distinct from v_description
    and v_existing.tag is not distinct from v_tag
    and v_existing.service_value is not distinct from v_service_value
    and v_existing.purchase_value is not distinct from v_purchase_value
    and v_existing.service_order is not distinct from v_service_order;

  if p_expected_updated_at is distinct from v_existing.updated_at then
    if v_same_content then
      v_response := app_private.attendance_result_with_identity(v_existing.id, true);
      return v_response || pg_catalog.jsonb_build_object(
        'message', 'Esta atualização já havia sido salva; nada foi duplicado.',
        'mensagem', 'Esta atualização já havia sido salva; nada foi duplicado.',
        'updated', true,
        'edit_replay', true,
        'expected_updated_at', v_existing.updated_at,
        'edit_count', v_existing.edit_count
      );
    end if;
    raise exception 'Este atendimento foi alterado em outra tela. Recarregue a lista e tente novamente.';
  end if;

  if v_same_content then
    v_response := app_private.attendance_result_with_identity(v_existing.id, true);
    return v_response || pg_catalog.jsonb_build_object(
      'message', 'Nenhuma alteração foi necessária.',
      'mensagem', 'Nenhuma alteração foi necessária.',
      'updated', false,
      'edit_replay', true,
      'expected_updated_at', v_existing.updated_at,
      'edit_count', v_existing.edit_count
    );
  end if;

  if v_tag = 'purchase' then
    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended(
        'attendance:os:' || v_store_id::text || ':'
          || pg_catalog.lower(pg_catalog.btrim(v_service_order)),
        0
      )
    );
    if exists (
      select 1 from public.attendances attendance
      where attendance.store_id = v_store_id
        and attendance.id <> p_attendance_id
        and attendance.tag = 'purchase'
        and pg_catalog.lower(pg_catalog.btrim(attendance.service_order))
          = pg_catalog.lower(pg_catalog.btrim(v_service_order))
    ) then
      raise exception 'Esta OS já está vinculada a outro atendimento.';
    end if;
  end if;

  v_identity_changed :=
    v_existing.phone_normalized is distinct from v_phone_normalized
    or v_existing.cpf_normalized is distinct from v_cpf_normalized;

  if v_identity_changed then
    for v_lock_key in
      select lock_keys.value
      from (
        select distinct values_list.value
        from unnest(array[
          case when v_existing.phone_normalized is null then null
            else 'phone:' || v_existing.phone_normalized end,
          case when v_phone_normalized is null then null
            else 'phone:' || v_phone_normalized end,
          case when v_existing.cpf_normalized is null then null
            else 'cpf:' || v_existing.cpf_normalized end,
          case when v_cpf_normalized is null then null
            else 'cpf:' || v_cpf_normalized end
        ]) values_list(value)
        where values_list.value is not null
      ) lock_keys
      order by lock_keys.value
    loop
      perform pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtextextended(
          'attendance:identity:' || v_store_id::text || ':' || v_lock_key,
          0
        )
      );
    end loop;

    select count(*)::integer into v_lead_count
    from public.leads leads
    where leads.store_id = v_store_id
      and leads.admin_user_id = v_session.admin_user_id
      and (
        (v_phone_normalized is not null
          and app_private.attendance_normalize_phone(leads.phone) = v_phone_normalized)
        or (v_cpf_normalized is not null
          and app_private.attendance_normalize_cpf(leads.cpf) = v_cpf_normalized)
      );

    select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id', candidates.id, 'name', candidates.name, 'phone', candidates.phone,
      'cpf', candidates.cpf, 'visited', candidates.visited,
      'purchased', candidates.bought, 'created_at', candidates.created_at
    ) order by candidates.created_at desc, candidates.id desc), '[]'::jsonb)
    into v_lead_candidates
    from (
      select leads.* from public.leads leads
      where leads.store_id = v_store_id
        and leads.admin_user_id = v_session.admin_user_id
        and (
          (v_phone_normalized is not null
            and app_private.attendance_normalize_phone(leads.phone) = v_phone_normalized)
          or (v_cpf_normalized is not null
            and app_private.attendance_normalize_cpf(leads.cpf) = v_cpf_normalized)
        )
      order by leads.created_at desc, leads.id desc
      limit 20
    ) candidates;

    if v_lead_count = 1 then
      select leads.id into v_lead_id
      from public.leads leads
      where leads.store_id = v_store_id
        and leads.admin_user_id = v_session.admin_user_id
        and (
          (v_phone_normalized is not null
            and app_private.attendance_normalize_phone(leads.phone) = v_phone_normalized)
          or (v_cpf_normalized is not null
            and app_private.attendance_normalize_cpf(leads.cpf) = v_cpf_normalized)
        );
    end if;

    select count(*)::integer into v_prospection_count
    from public.prospections prospections
    where prospections.store_id = v_store_id
      and prospections.admin_user_id = v_session.admin_user_id
      and (
        (v_phone_normalized is not null
          and app_private.attendance_normalize_phone(prospections.phone) = v_phone_normalized)
        or (v_cpf_normalized is not null
          and app_private.attendance_normalize_cpf(prospections.cpf) = v_cpf_normalized)
      );

    select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id', candidates.id, 'name', candidates.name, 'phone', candidates.phone,
      'cpf', candidates.cpf, 'professional_id', candidates.professional_id,
      'professional_name', coalesce(professionals.name, candidates.professional_name_snapshot),
      'returned_at', candidates.returned_at, 'purchased_at', candidates.purchased_at,
      'purchase_value', candidates.purchase_amount,
      'service_order', candidates.purchase_order, 'created_at', candidates.created_at
    ) order by candidates.created_at desc, candidates.id desc), '[]'::jsonb)
    into v_prospection_candidates
    from (
      select prospections.* from public.prospections prospections
      where prospections.store_id = v_store_id
        and prospections.admin_user_id = v_session.admin_user_id
        and (
          (v_phone_normalized is not null
            and app_private.attendance_normalize_phone(prospections.phone) = v_phone_normalized)
          or (v_cpf_normalized is not null
            and app_private.attendance_normalize_cpf(prospections.cpf) = v_cpf_normalized)
        )
      order by prospections.created_at desc, prospections.id desc
      limit 20
    ) candidates
    left join public.prospection_professionals professionals
      on professionals.id = candidates.professional_id;

    if v_prospection_count = 1 then
      select prospections.id into v_prospection_id
      from public.prospections prospections
      where prospections.store_id = v_store_id
        and prospections.admin_user_id = v_session.admin_user_id
        and (
          (v_phone_normalized is not null
            and app_private.attendance_normalize_phone(prospections.phone) = v_phone_normalized)
          or (v_cpf_normalized is not null
            and app_private.attendance_normalize_cpf(prospections.cpf) = v_cpf_normalized)
        );
    end if;
  else
    v_lead_id := v_existing.lead_id;
    v_prospection_id := v_existing.prospection_id;
    v_lead_count := v_existing.lead_match_count;
    v_prospection_count := v_existing.prospection_match_count;
    v_lead_candidates := v_existing.lead_candidates;
    v_prospection_candidates := v_existing.prospection_candidates;
  end if;

  v_match_status := case
    when v_lead_id is not null and v_prospection_id is not null then 'both'
    when v_lead_id is not null then 'lead'
    when v_prospection_id is not null then 'prospection'
    else 'unmatched'
  end;

  -- Ordem global evita deadlock quando duas edicoes trocam de identidade.
  for v_lock_key in
    select entities.value
    from (
      select distinct values_list.value
      from unnest(array[
        case when v_old_lead_id is null then null else 'lead:' || v_old_lead_id::text end,
        case when v_lead_id is null then null else 'lead:' || v_lead_id::text end,
        case when v_old_prospection_id is null then null else 'prospection:' || v_old_prospection_id::text end,
        case when v_prospection_id is null then null else 'prospection:' || v_prospection_id::text end
      ]) values_list(value)
      where values_list.value is not null
    ) entities
    order by entities.value
  loop
    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended(
        'attendance:projection:' || v_store_id::text || ':' || v_lock_key,
        0
      )
    );
  end loop;

  perform 1 from public.leads leads
  where leads.id = any(array[v_old_lead_id, v_lead_id])
    and leads.store_id = v_store_id
    and leads.admin_user_id = v_session.admin_user_id
  order by leads.id
  for update;

  perform 1 from public.prospections prospections
  where prospections.id = any(array[v_old_prospection_id, v_prospection_id])
    and prospections.store_id = v_store_id
    and prospections.admin_user_id = v_session.admin_user_id
  order by prospections.id
  for update;

  if v_prospection_id is not null then
    select
      prospections.professional_id,
      coalesce(professionals.name, prospections.professional_name_snapshot)
    into v_prospection_professional_id, v_prospection_professional_name
    from public.prospections prospections
    left join public.prospection_professionals professionals
      on professionals.id = prospections.professional_id
     and professionals.store_id = prospections.store_id
     and professionals.admin_user_id = prospections.admin_user_id
    where prospections.id = v_prospection_id
      and prospections.store_id = v_store_id
      and prospections.admin_user_id = v_session.admin_user_id;
  end if;

  select coalesce(settings.bonus_minimum, 300), coalesce(settings.bonus_amount, 20)
  into v_bonus_minimum, v_bonus_amount
  from public.stores stores
  left join public.prospection_store_settings settings
    on settings.store_id = stores.id
   and settings.admin_user_id = stores.admin_user_id
  where stores.id = v_store_id
    and stores.admin_user_id = v_session.admin_user_id;

  -- Regra financeira do instante da criação: relink/correção nunca troca o
  -- mínimo ou prêmio pelo valor configurado hoje.
  v_bonus_minimum := v_existing.bonus_minimum_snapshot;
  v_bonus_amount := v_existing.bonus_amount_snapshot;

  v_initial_bonus_status := case
    when v_tag <> 'purchase' then 'not_applicable'
    when v_prospection_count = 0 then 'no_prospection'
    when v_prospection_count > 1 then 'ambiguous_prospection'
    else 'already_converted'
  end;

  v_before_state := pg_catalog.jsonb_build_object(
    'attendance', to_jsonb(v_existing),
    'leads', coalesce((
      select pg_catalog.jsonb_agg(to_jsonb(leads) order by leads.id)
      from public.leads leads
      where leads.id = any(array[v_old_lead_id, v_lead_id])
        and leads.store_id = v_store_id
        and leads.admin_user_id = v_session.admin_user_id
    ), '[]'::jsonb),
    'prospections', coalesce((
      select pg_catalog.jsonb_agg(to_jsonb(prospections) order by prospections.id)
      from public.prospections prospections
      where prospections.id = any(array[v_old_prospection_id, v_prospection_id])
        and prospections.store_id = v_store_id
        and prospections.admin_user_id = v_session.admin_user_id
    ), '[]'::jsonb)
  );

  update public.attendances attendance
  set professional_id = v_professional_id,
      professional_name_snapshot = v_professional_name,
      customer_name = v_customer_name,
      phone = v_phone,
      phone_normalized = v_phone_normalized,
      customer_cpf = v_cpf,
      cpf_normalized = v_cpf_normalized,
      description = v_description,
      tag = v_tag,
      service_value = v_service_value,
      purchase_value = v_purchase_value,
      service_order = v_service_order,
      attended_at = v_attended_at,
      lead_id = v_lead_id,
      prospection_id = v_prospection_id,
      match_status = v_match_status,
      lead_match_count = v_lead_count,
      prospection_match_count = v_prospection_count,
      match_ambiguous = v_lead_count > 1 or v_prospection_count > 1,
      lead_candidates = v_lead_candidates,
      prospection_candidates = v_prospection_candidates,
      prospection_professional_id = v_prospection_professional_id,
      prospection_professional_name_snapshot = v_prospection_professional_name,
      lead_visit_applied = attendance.lead_visit_applied
        and v_lead_id is not distinct from v_old_lead_id,
      lead_purchase_applied = attendance.lead_purchase_applied
        and v_tag = 'purchase'
        and v_lead_id is not distinct from v_old_lead_id,
      prospection_visit_applied = attendance.prospection_visit_applied
        and v_prospection_id is not distinct from v_old_prospection_id,
      prospection_purchase_applied = attendance.prospection_purchase_applied
        and v_tag = 'purchase'
        and v_prospection_id is not distinct from v_old_prospection_id,
      purchase_credit_applied = attendance.purchase_credit_applied
        and v_tag = 'purchase'
        and v_prospection_id is not distinct from v_old_prospection_id,
      credited_professional_id = case
        when attendance.purchase_credit_applied
         and v_tag = 'purchase'
         and v_prospection_id is not distinct from v_old_prospection_id
          then attendance.credited_professional_id
        else null
      end,
      credited_professional_name_snapshot = case
        when attendance.purchase_credit_applied
         and v_tag = 'purchase'
         and v_prospection_id is not distinct from v_old_prospection_id
          then attendance.credited_professional_name_snapshot
        else null
      end,
      bonus_minimum_snapshot = v_bonus_minimum,
      bonus_amount_snapshot = v_bonus_amount,
      bonus_eligible = case
        when attendance.purchase_credit_applied
         and v_tag = 'purchase'
         and v_prospection_id is not distinct from v_old_prospection_id
          then v_purchase_value >= attendance.bonus_minimum_snapshot
        else false
      end,
      bonus_awarded_amount = case
        when attendance.purchase_credit_applied
         and v_tag = 'purchase'
         and v_prospection_id is not distinct from v_old_prospection_id
         and v_purchase_value >= attendance.bonus_minimum_snapshot
          then attendance.bonus_amount_snapshot
        else 0
      end,
      bonus_credit_status = case
        when attendance.purchase_credit_applied
         and v_tag = 'purchase'
         and v_prospection_id is not distinct from v_old_prospection_id
          then case
            when v_purchase_value >= attendance.bonus_minimum_snapshot
              then 'awarded'
            else 'below_minimum'
          end
        else v_initial_bonus_status
      end,
      updated_by = v_session.user_id,
      edit_count = attendance.edit_count + 1
  where attendance.id = p_attendance_id
    and attendance.store_id = v_store_id
    and attendance.admin_user_id = v_session.admin_user_id;

  if v_old_lead_id is not null and v_old_lead_id is distinct from v_lead_id then
    v_decision := app_private.reconcile_lead_from_attendances(
      v_old_lead_id, v_session.admin_user_id, v_store_id, p_attendance_id,
      v_session.user_id, true, true, false
    );
    v_reconciliation := v_reconciliation || pg_catalog.jsonb_build_object('old_lead', v_decision);
  end if;
  if v_lead_id is not null and (
    v_old_lead_id is distinct from v_lead_id
    or v_existing.tag is distinct from v_tag
    or v_existing.purchase_value is distinct from v_purchase_value
    or v_existing.service_order is distinct from v_service_order
  ) then
    v_decision := app_private.reconcile_lead_from_attendances(
      v_lead_id, v_session.admin_user_id, v_store_id, p_attendance_id,
      v_session.user_id,
      v_old_lead_id is distinct from v_lead_id,
      v_old_lead_id is distinct from v_lead_id
        or v_tag = 'purchase' or v_existing.tag = 'purchase',
      true
    );
    v_reconciliation := v_reconciliation || pg_catalog.jsonb_build_object('current_lead', v_decision);
  end if;

  if v_old_prospection_id is not null
     and v_old_prospection_id is distinct from v_prospection_id then
    v_decision := app_private.reconcile_prospection_from_attendances(
      v_old_prospection_id, v_session.admin_user_id, v_store_id, p_attendance_id,
      v_session.user_id, true, true, false
    );
    v_reconciliation := v_reconciliation || pg_catalog.jsonb_build_object('old_prospection', v_decision);
  end if;
  if v_prospection_id is not null and (
    v_old_prospection_id is distinct from v_prospection_id
    or v_existing.attended_at is distinct from v_attended_at
    or v_existing.tag is distinct from v_tag
    or v_existing.purchase_value is distinct from v_purchase_value
    or v_existing.service_order is distinct from v_service_order
  ) then
    v_decision := app_private.reconcile_prospection_from_attendances(
      v_prospection_id, v_session.admin_user_id, v_store_id, p_attendance_id,
      v_session.user_id,
      v_old_prospection_id is distinct from v_prospection_id
        or v_existing.attended_at is distinct from v_attended_at,
      v_old_prospection_id is distinct from v_prospection_id
        or v_existing.attended_at is distinct from v_attended_at
        or v_tag = 'purchase' or v_existing.tag = 'purchase',
      true
    );
    v_reconciliation := v_reconciliation || pg_catalog.jsonb_build_object('current_prospection', v_decision);
  end if;

  select attendance.* into v_current
  from public.attendances attendance
  where attendance.id = p_attendance_id
    and attendance.store_id = v_store_id
    and attendance.admin_user_id = v_session.admin_user_id;

  v_after_state := pg_catalog.jsonb_build_object(
    'attendance', to_jsonb(v_current),
    'leads', coalesce((
      select pg_catalog.jsonb_agg(to_jsonb(leads) order by leads.id)
      from public.leads leads
      where leads.id = any(array[v_old_lead_id, v_lead_id])
        and leads.store_id = v_store_id
        and leads.admin_user_id = v_session.admin_user_id
    ), '[]'::jsonb),
    'prospections', coalesce((
      select pg_catalog.jsonb_agg(to_jsonb(prospections) order by prospections.id)
      from public.prospections prospections
      where prospections.id = any(array[v_old_prospection_id, v_prospection_id])
        and prospections.store_id = v_store_id
        and prospections.admin_user_id = v_session.admin_user_id
    ), '[]'::jsonb)
  );

  v_changed_fields := array_remove(array[
    case when v_existing.professional_id is distinct from v_current.professional_id
      or v_existing.professional_name_snapshot is distinct from v_current.professional_name_snapshot
      then 'professional' end,
    case when v_existing.attended_at is distinct from v_current.attended_at then 'attended_on' end,
    case when v_existing.customer_name is distinct from v_current.customer_name then 'customer_name' end,
    case when v_existing.phone is distinct from v_current.phone then 'phone' end,
    case when v_existing.customer_cpf is distinct from v_current.customer_cpf then 'cpf' end,
    case when v_existing.description is distinct from v_current.description then 'description' end,
    case when v_existing.tag is distinct from v_current.tag then 'tag' end,
    case when v_existing.service_value is distinct from v_current.service_value then 'service_value' end,
    case when v_existing.purchase_value is distinct from v_current.purchase_value then 'purchase_value' end,
    case when v_existing.service_order is distinct from v_current.service_order then 'service_order' end,
    case when v_existing.lead_id is distinct from v_current.lead_id then 'lead_link' end,
    case when v_existing.prospection_id is distinct from v_current.prospection_id then 'prospection_link' end,
    case when v_existing.purchase_credit_applied is distinct from v_current.purchase_credit_applied
      or v_existing.bonus_eligible is distinct from v_current.bonus_eligible
      or v_existing.bonus_awarded_amount is distinct from v_current.bonus_awarded_amount
      then 'bonus_credit' end,
    case when (v_before_state -> 'leads') is distinct from (v_after_state -> 'leads')
      or (v_before_state -> 'prospections') is distinct from (v_after_state -> 'prospections')
      then 'linked_projection' end
  ], null);

  if pg_catalog.cardinality(v_changed_fields) = 0 then
    v_changed_fields := array['normalized_payload'];
  end if;

  v_message := case
    when v_current.match_status = 'both' then 'Atendimento atualizado e vínculos recalculados.'
    when v_current.match_status in ('lead', 'prospection') then 'Atendimento atualizado e vínculo recalculado.'
    else 'Atendimento atualizado com sucesso.'
  end;

  v_response := app_private.attendance_result_with_identity(v_current.id, false)
    || pg_catalog.jsonb_build_object(
      'message', v_message,
      'mensagem', v_message,
      'updated', true,
      'edit_replay', false,
      'audit_id', v_audit_id,
      'expected_updated_at', v_current.updated_at,
      'edit_count', v_current.edit_count,
      'changed_fields', to_jsonb(v_changed_fields)
    );

  insert into app_private.attendance_edit_audit (
    id, attendance_id, admin_user_id, store_id, edit_number,
    expected_updated_at, request_fingerprint, changed_fields,
    before_state, after_state, reconciliation, response, changed_by
  ) values (
    v_audit_id, v_current.id, v_current.admin_user_id, v_current.store_id,
    v_current.edit_count, p_expected_updated_at, v_request_fingerprint,
    v_changed_fields, v_before_state, v_after_state, v_reconciliation,
    v_response, v_session.user_id
  );

  return v_response;
end;
$$;

-- Defesa em profundidade: snapshot de attendance só participa do bônus se for
-- exatamente o source explícito atual da prospecção.
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
volatile
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_today date := timezone('America/Sao_Paulo', now())::date;
  v_start date := coalesce(
    p_start_date,
    timezone('America/Sao_Paulo', now())::date
      - extract(isodow from timezone('America/Sao_Paulo', now()))::integer + 1
  );
  v_end date := coalesce(p_end_date, timezone('America/Sao_Paulo', now())::date);
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_start > v_end then
    raise exception 'Período inválido.';
  end if;
  if v_end > v_today then
    raise exception 'A data final não pode estar no futuro.';
  end if;
  if p_store_id is not null and not app_private.prospection_store_allowed(
    v_session.admin_user_id,
    v_session.user_id,
    v_session.user_role,
    v_session.user_store_id,
    p_store_id,
    false
  ) then
    raise exception 'Cliente não encontrado ou sem permissão.';
  end if;

  return query
  select
    pr.id,
    pr.store_id,
    st.name,
    pr.name,
    coalesce(
      a.credited_professional_id,
      pr.bonus_professional_id_snapshot,
      pr.professional_id
    ),
    coalesce(
      a.credited_professional_name_snapshot,
      pr.bonus_professional_name_snapshot,
      pp.name,
      pr.professional_name_snapshot,
      'Sem responsável'
    ),
    pr.purchased_at,
    coalesce(pr.purchase_amount, a.purchase_value, 0)::numeric,
    coalesce(pr.purchase_order, a.service_order),
    coalesce(
      a.bonus_minimum_snapshot,
      pr.bonus_minimum_snapshot,
      ps.bonus_minimum,
      300
    )::numeric,
    coalesce(
      a.bonus_amount_snapshot,
      pr.bonus_amount_snapshot,
      ps.bonus_amount,
      20
    )::numeric,
    coalesce(
      a.bonus_eligible,
      pr.bonus_eligible_snapshot,
      (
        (
          coalesce(pr.bonus_professional_id_snapshot, pr.professional_id) is not null
          or coalesce(
            nullif(btrim(pr.bonus_professional_name_snapshot), ''),
            nullif(btrim(pr.professional_name_snapshot), '')
          ) is not null
        )
        and coalesce(pr.purchase_amount, 0) >= coalesce(pr.bonus_minimum_snapshot, ps.bonus_minimum, 300)
      )
    ),
    coalesce(
      a.bonus_awarded_amount,
      pr.bonus_awarded_amount_snapshot,
      case when (
        coalesce(pr.bonus_professional_id_snapshot, pr.professional_id) is not null
        or coalesce(
          nullif(btrim(pr.bonus_professional_name_snapshot), ''),
          nullif(btrim(pr.professional_name_snapshot), '')
        ) is not null
      ) and coalesce(pr.purchase_amount, 0) >= coalesce(pr.bonus_minimum_snapshot, ps.bonus_minimum, 300)
        then coalesce(pr.bonus_amount_snapshot, ps.bonus_amount, 20)
        else 0
      end
    )::numeric,
    coalesce(
      a.bonus_credit_status,
      pr.bonus_credit_status_snapshot,
      case
        when coalesce(pr.bonus_professional_id_snapshot, pr.professional_id) is null
         and coalesce(
           nullif(btrim(pr.bonus_professional_name_snapshot), ''),
           nullif(btrim(pr.professional_name_snapshot), '')
         ) is null
          then 'missing_professional'
        when coalesce(pr.purchase_amount, 0) >= coalesce(pr.bonus_minimum_snapshot, ps.bonus_minimum, 300)
          then 'awarded'
        else 'below_minimum'
      end
    )
  from public.prospections pr
  join public.stores st
    on st.id = pr.store_id
   and st.admin_user_id = pr.admin_user_id
  left join public.prospection_store_settings ps
    on ps.store_id = pr.store_id
   and ps.admin_user_id = pr.admin_user_id
  left join public.prospection_professionals pp
    on pp.id = pr.professional_id
   and pp.store_id = pr.store_id
   and pp.admin_user_id = pr.admin_user_id
  left join lateral (
    select attendance.*
    from public.attendances attendance
    where attendance.prospection_id = pr.id
      and attendance.store_id = pr.store_id
      and attendance.admin_user_id = pr.admin_user_id
      and attendance.purchase_credit_applied
      and attendance.id = pr.attendance_purchase_source_id
    order by attendance.attended_at, attendance.id
    limit 1
  ) a on true
  where pr.admin_user_id = v_session.admin_user_id
    and pr.purchased_at is not null
    and timezone('America/Sao_Paulo', pr.purchased_at)::date between v_start and v_end
    and (p_store_id is null or pr.store_id = p_store_id)
    and app_private.prospection_store_allowed(
      v_session.admin_user_id,
      v_session.user_id,
      v_session.user_role,
      v_session.user_store_id,
      pr.store_id,
      false
    )
  order by pr.purchased_at desc, pr.id desc;
end;
$$;

-- Métricas financeiras usam o source atual da prospecção como autoridade. Os
-- flags da attendance continuam materializados por compatibilidade, mas não
-- conseguem duplicar nem apagar crédito quando um sibling assume o source.
create or replace function app_private.attendance_metrics_json(
  p_admin_user_id uuid,
  p_store_id uuid
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with windows(window_key, start_at) as (
    values
      ('today'::text, pg_catalog.date_trunc('day', pg_catalog.now())),
      ('7d'::text, pg_catalog.date_trunc('day', pg_catalog.now()) - interval '6 days'),
      ('30d'::text, pg_catalog.date_trunc('day', pg_catalog.now()) - interval '29 days'),
      ('all'::text, pg_catalog.now() - interval '2 years')
  ), effective_attendances as (
    select
      attendance.*,
      (
        prospections.attendance_purchase_source_id = attendance.id
        and (
          prospections.bonus_professional_id_snapshot is not null
          or prospections.professional_id is not null
          or nullif(pg_catalog.btrim(prospections.bonus_professional_name_snapshot), '') is not null
          or nullif(pg_catalog.btrim(prospections.professional_name_snapshot), '') is not null
        )
      ) as effective_purchase_credit,
      (
        prospections.attendance_purchase_source_id = attendance.id
        and coalesce(
          prospections.bonus_eligible_snapshot,
          (
            prospections.bonus_professional_id_snapshot is not null
            or prospections.professional_id is not null
            or nullif(pg_catalog.btrim(prospections.bonus_professional_name_snapshot), '') is not null
            or nullif(pg_catalog.btrim(prospections.professional_name_snapshot), '') is not null
          ) and coalesce(prospections.purchase_amount, 0)
            >= coalesce(
              prospections.bonus_minimum_snapshot,
              attendance.bonus_minimum_snapshot,
              300
            )
        )
      ) as effective_bonus_eligible,
      case
        when prospections.attendance_purchase_source_id = attendance.id
         and coalesce(
           prospections.bonus_eligible_snapshot,
           (
             prospections.bonus_professional_id_snapshot is not null
             or prospections.professional_id is not null
             or nullif(pg_catalog.btrim(prospections.bonus_professional_name_snapshot), '') is not null
             or nullif(pg_catalog.btrim(prospections.professional_name_snapshot), '') is not null
           ) and coalesce(prospections.purchase_amount, 0)
             >= coalesce(
               prospections.bonus_minimum_snapshot,
               attendance.bonus_minimum_snapshot,
               300
             )
         )
          then coalesce(
            prospections.bonus_awarded_amount_snapshot,
            prospections.bonus_amount_snapshot,
            attendance.bonus_amount_snapshot,
            20
          )
        else 0
      end::numeric(14,2) as effective_bonus_awarded_amount,
      case
        when prospections.attendance_purchase_source_id = attendance.id then
          coalesce(
            prospections.bonus_credit_status_snapshot,
            case
              when prospections.bonus_professional_id_snapshot is null
               and prospections.professional_id is null
               and nullif(pg_catalog.btrim(prospections.bonus_professional_name_snapshot), '') is null
               and nullif(pg_catalog.btrim(prospections.professional_name_snapshot), '') is null
                then 'missing_professional'
              when coalesce(prospections.purchase_amount, 0)
                >= coalesce(
                  prospections.bonus_minimum_snapshot,
                  attendance.bonus_minimum_snapshot,
                  300
                ) then 'awarded'
              else 'below_minimum'
            end
          )
        else attendance.bonus_credit_status
      end as effective_bonus_credit_status
    from public.attendances attendance
    left join public.prospections prospections
      on prospections.id = attendance.prospection_id
     and prospections.store_id = attendance.store_id
     and prospections.admin_user_id = attendance.admin_user_id
    where attendance.admin_user_id = p_admin_user_id
      and attendance.store_id = p_store_id
      and attendance.attended_at >= pg_catalog.now() - interval '2 years'
  ), stats as (
    select
      windows.window_key,
      windows.start_at,
      count(attendance.id)::bigint as total,
      count(attendance.id) filter (where attendance.tag = 'budget')::bigint as budgets,
      count(attendance.id) filter (where attendance.tag = 'purchase')::bigint as purchases,
      count(attendance.id) filter (where attendance.tag = 'other')::bigint as others,
      coalesce(
        sum(attendance.purchase_value) filter (where attendance.tag = 'purchase'),
        0
      )::numeric(14,2) as purchase_revenue,
      coalesce(sum(attendance.service_value), 0)::numeric(14,2) as service_value,
      count(attendance.id) filter (where attendance.match_status <> 'unmatched')::bigint as linked,
      count(attendance.id) filter (where attendance.match_status = 'unmatched')::bigint as unmatched,
      count(attendance.id) filter (where attendance.match_ambiguous)::bigint as ambiguous,
      count(attendance.id) filter (
        where attendance.effective_purchase_credit
      )::bigint as purchase_credits,
      count(attendance.id) filter (
        where attendance.effective_bonus_eligible
      )::bigint as bonuses_awarded,
      coalesce(sum(attendance.effective_bonus_awarded_amount), 0)::numeric(14,2)
        as bonus_awarded_amount,
      count(attendance.id) filter (
        where attendance.effective_bonus_credit_status in (
          'ambiguous_prospection', 'missing_professional'
        )
      )::bigint as bonus_pending_review,
      count(distinct attendance.phone_normalized)::bigint as unique_customers,
      min(attendance.attended_at) as first_attendance_at,
      max(attendance.attended_at) as last_attendance_at
    from windows
    left join effective_attendances attendance
      on attendance.attended_at >= windows.start_at
    group by windows.window_key, windows.start_at
  )
  select coalesce(pg_catalog.jsonb_object_agg(
    stats.window_key,
    pg_catalog.jsonb_build_object(
      'start_at', stats.start_at,
      'total', stats.total,
      'budgets', stats.budgets,
      'purchases', stats.purchases,
      'others', stats.others,
      'conversion', case when stats.total = 0 then 0
        else pg_catalog.round((stats.purchases * 100.0) / stats.total, 2) end,
      'conversion_rate', case when stats.total = 0 then 0
        else pg_catalog.round((stats.purchases * 100.0) / stats.total, 2) end,
      'revenue', stats.purchase_revenue,
      'purchase_revenue', stats.purchase_revenue,
      'service_value', stats.service_value,
      'linked', stats.linked,
      'unmatched', stats.unmatched,
      'ambiguous', stats.ambiguous,
      'purchase_credits', stats.purchase_credits,
      'bonuses_awarded', stats.bonuses_awarded,
      'bonus_awarded_amount', stats.bonus_awarded_amount,
      'bonus_pending_review', stats.bonus_pending_review,
      'unique_customers', stats.unique_customers,
      'first_attendance_at', stats.first_attendance_at,
      'last_attendance_at', stats.last_attendance_at
    )
  ), '{}'::jsonb)
  from stats;
$$;

-- Contrato de retorno compartilhado por create/list/workspace/update. Aditivo:
-- consumidores antigos continuam recebendo as mesmas chaves.
create or replace function app_private.attendance_result_with_identity(
  p_attendance_id uuid,
  p_idempotent_replay boolean default false
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_result jsonb;
  v_record jsonb;
  v_links jsonb;
  v_attendance public.attendances%rowtype;
  v_lead public.leads%rowtype;
  v_prospection public.prospections%rowtype;
  v_lead_visit_applied boolean := false;
  v_lead_purchase_applied boolean := false;
  v_prospection_visit_applied boolean := false;
  v_prospection_purchase_applied boolean := false;
  v_purchase_credit_applied boolean := false;
  v_credited_professional_id uuid;
  v_credited_professional_name text;
  v_bonus_minimum numeric(14,2);
  v_bonus_amount numeric(14,2);
  v_bonus_eligible boolean := false;
  v_bonus_awarded_amount numeric(14,2) := 0;
  v_bonus_credit_status text;
begin
  v_result := app_private.attendance_result_json(
    p_attendance_id,
    p_idempotent_replay
  );
  if v_result is null then
    return null;
  end if;

  select attendance.* into v_attendance
  from public.attendances attendance
  where attendance.id = p_attendance_id;

  if v_attendance.lead_id is not null then
    select leads.* into v_lead
    from public.leads leads
    where leads.id = v_attendance.lead_id
      and leads.store_id = v_attendance.store_id
      and leads.admin_user_id = v_attendance.admin_user_id;
    if found then
      v_lead_visit_applied :=
        v_lead.attendance_visit_source_id = v_attendance.id;
      v_lead_purchase_applied :=
        v_lead.attendance_purchase_source_id = v_attendance.id;
    end if;
  end if;

  if v_attendance.prospection_id is not null then
    select prospections.* into v_prospection
    from public.prospections prospections
    where prospections.id = v_attendance.prospection_id
      and prospections.store_id = v_attendance.store_id
      and prospections.admin_user_id = v_attendance.admin_user_id;
    if found then
      v_prospection_visit_applied :=
        v_prospection.attendance_return_source_id = v_attendance.id;
      v_prospection_purchase_applied :=
        v_prospection.attendance_purchase_source_id = v_attendance.id;
    end if;
  end if;

  if v_prospection_purchase_applied then
    v_credited_professional_id := coalesce(
      v_prospection.bonus_professional_id_snapshot,
      v_prospection.professional_id
    );
    v_credited_professional_name := coalesce(
      nullif(pg_catalog.btrim(v_prospection.bonus_professional_name_snapshot), ''),
      nullif(pg_catalog.btrim(v_prospection.professional_name_snapshot), ''),
      nullif(pg_catalog.btrim(v_attendance.credited_professional_name_snapshot), '')
    );
    v_bonus_minimum := coalesce(
      v_prospection.bonus_minimum_snapshot,
      v_attendance.bonus_minimum_snapshot,
      300
    );
    v_bonus_amount := coalesce(
      v_prospection.bonus_amount_snapshot,
      v_attendance.bonus_amount_snapshot,
      20
    );
    v_purchase_credit_applied :=
      v_credited_professional_id is not null
      or v_credited_professional_name is not null;
    v_bonus_eligible := coalesce(
      v_prospection.bonus_eligible_snapshot,
      v_purchase_credit_applied
        and coalesce(v_prospection.purchase_amount, 0) >= v_bonus_minimum
    );
    v_bonus_awarded_amount := coalesce(
      v_prospection.bonus_awarded_amount_snapshot,
      case when v_bonus_eligible then v_bonus_amount else 0 end
    );
    v_bonus_credit_status := coalesce(
      v_prospection.bonus_credit_status_snapshot,
      case
        when not v_purchase_credit_applied then 'missing_professional'
        when v_bonus_eligible then 'awarded'
        else 'below_minimum'
      end
    );
  else
    v_purchase_credit_applied := false;
    v_credited_professional_id := null;
    v_credited_professional_name := null;
    v_bonus_minimum := v_attendance.bonus_minimum_snapshot;
    v_bonus_amount := v_attendance.bonus_amount_snapshot;
    v_bonus_eligible := false;
    v_bonus_awarded_amount := 0;
    v_bonus_credit_status := case
      when v_attendance.bonus_credit_status in (
        'no_prospection', 'ambiguous_prospection', 'missing_professional'
      ) then v_attendance.bonus_credit_status
      when v_attendance.tag = 'purchase' then 'already_converted'
      else 'not_applicable'
    end;
  end if;

  v_record := coalesce(v_result -> 'attendance', '{}'::jsonb)
    || pg_catalog.jsonb_build_object(
      'customer_cpf', v_attendance.customer_cpf,
      'cpf', v_attendance.customer_cpf,
      'cpf_normalized', v_attendance.cpf_normalized,
      'attended_on', pg_catalog.timezone(
        'America/Sao_Paulo', v_attendance.attended_at
      )::date,
      'created_at', v_attendance.created_at,
      'updated_at', v_attendance.updated_at,
      'expected_updated_at', v_attendance.updated_at,
      'updated_by', v_attendance.updated_by,
      'edit_count', v_attendance.edit_count,
      'purchase_credit_applied', v_purchase_credit_applied,
      'credited_professional_id', v_credited_professional_id,
      'credited_professional_name', v_credited_professional_name,
      'bonus_minimum_snapshot', v_bonus_minimum,
      'bonus_amount_snapshot', v_bonus_amount,
      'bonus_eligible', v_bonus_eligible,
      'bonus_awarded_amount', v_bonus_awarded_amount,
      'bonus_credit_status', v_bonus_credit_status,
      'bonus_review_required', v_bonus_credit_status in (
        'ambiguous_prospection', 'missing_professional'
      ),
      'bonus_credit_reason', app_private.attendance_bonus_credit_reason(
        v_bonus_credit_status
      ),
      'bonus_reason', app_private.attendance_bonus_credit_reason(
        v_bonus_credit_status
      ),
      'editable', true
    );

  v_links := coalesce(v_result -> 'links', '{}'::jsonb);
  if v_attendance.lead_id is not null then
    v_links := pg_catalog.jsonb_set(
      v_links,
      '{lead}',
      coalesce(v_links -> 'lead', '{}'::jsonb)
        || pg_catalog.jsonb_build_object(
          'visit_applied', v_lead_visit_applied,
          'purchase_applied', v_lead_purchase_applied
        ),
      true
    );
  end if;
  if v_attendance.prospection_id is not null then
    v_links := pg_catalog.jsonb_set(
      v_links,
      '{prospection}',
      coalesce(v_links -> 'prospection', '{}'::jsonb)
        || pg_catalog.jsonb_build_object(
          'visit_applied', v_prospection_visit_applied,
          'purchase_applied', v_prospection_purchase_applied,
          'purchase_credit_applied', v_purchase_credit_applied,
          'credited_professional_id', v_credited_professional_id,
          'credited_professional_name', v_credited_professional_name,
          'bonus_eligible', v_bonus_eligible,
          'bonus_awarded_amount', v_bonus_awarded_amount,
          'bonus_credit_status', v_bonus_credit_status,
          'bonus_review_required', v_bonus_credit_status in (
            'ambiguous_prospection', 'missing_professional'
          ),
          'bonus_credit_reason', app_private.attendance_bonus_credit_reason(
            v_bonus_credit_status
          )
        ),
      true
    );
  end if;

  v_result := v_result || pg_catalog.jsonb_build_object(
    'attendance', v_record,
    'record', v_record,
    'registro', v_record,
    'links', v_links,
    'vinculos', v_links
  );

  return v_result || pg_catalog.jsonb_build_object(
    'expected_updated_at', v_attendance.updated_at,
    'edit_count', v_attendance.edit_count,
    'purchase_credit_applied', v_purchase_credit_applied,
    'credited_professional_id', v_credited_professional_id,
    'credited_professional_name', v_credited_professional_name,
    'bonus_eligible', v_bonus_eligible,
    'bonus_awarded_amount', v_bonus_awarded_amount,
    'bonus_credit_status', v_bonus_credit_status,
    'bonus_review_required', v_bonus_credit_status in (
      'ambiguous_prospection', 'missing_professional'
    ),
    'bonus_reason', app_private.attendance_bonus_credit_reason(
      v_bonus_credit_status
    )
  );
end;
$$;

create or replace function public.lc_update_attendance_v1(
  p_session_token text,
  p_attendance_id uuid,
  p_store_id uuid,
  p_professional_name text,
  p_attended_on date,
  p_customer_name text,
  p_phone text,
  p_cpf text,
  p_description text,
  p_tag text,
  p_service_value numeric,
  p_purchase_value numeric,
  p_service_order text,
  p_expected_updated_at timestamptz
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select app_private.rpc_update_attendance_v1(
    p_session_token,
    p_attendance_id,
    p_store_id,
    p_professional_name,
    p_attended_on,
    p_customer_name,
    p_phone,
    p_cpf,
    p_description,
    p_tag,
    p_service_value,
    p_purchase_value,
    p_service_order,
    p_expected_updated_at
  );
$$;

comment on table public.attendances is
  'Registro auditável de atendimento por loja; edição somente pelo RPC autorizado, com histórico privado.';
comment on column public.attendances.updated_at is
  'Versão otimista retornada ao cliente e exigida em toda edição.';
comment on column public.attendances.edit_count is
  'Quantidade de edições efetivas; replays idempotentes não incrementam.';
comment on column public.leads.attendance_visit_source_id is
  'Atendimento owner da projeção visited; fica nulo após alteração manual do outcome.';
comment on column public.leads.attendance_purchase_source_id is
  'Atendimento owner da projeção de compra; fica nulo após alteração manual do outcome.';
comment on column public.prospections.attendance_return_source_id is
  'Atendimento owner da data de retorno; fica nulo após alteração manual do outcome.';
comment on column public.prospections.attendance_purchase_source_id is
  'Atendimento owner da compra e snapshots de bonificação; fica nulo após alteração manual.';
comment on table app_private.attendance_edit_audit is
  'Histórico privado e imutável, com before/after e decisões de reconciliação; não exposto à Data API.';
comment on function public.lc_update_attendance_v1(
  text, uuid, uuid, text, date, text, text, text, text, text,
  numeric, numeric, text, timestamptz
) is
  'Edita integralmente um atendimento autorizado, preserva hora local/created_at e reconcilia somente projeções que ainda possuem ownership.';

-- Nenhum helper SECURITY DEFINER fica chamável pela Data API. Somente o
-- wrapper público recebe EXECUTE; ele sempre delega ao RPC que valida sessão.
revoke all on function app_private.prevent_attendance_edit_audit_mutation()
  from public, anon, authenticated;
revoke all on function app_private.attendance_edit_fingerprint(
  uuid, uuid, text, date, text, text, text, text, text, text, text,
  numeric, numeric, text
) from public, anon, authenticated;
revoke all on function app_private.attendance_guard_lead_ownership()
  from public, anon, authenticated;
revoke all on function app_private.attendance_guard_prospection_ownership()
  from public, anon, authenticated;
revoke all on function app_private.attendance_capture_projection_ownership()
  from public, anon, authenticated;
revoke all on function app_private.reconcile_lead_from_attendances(
  uuid, uuid, uuid, uuid, uuid, boolean, boolean, boolean
) from public, anon, authenticated;
revoke all on function app_private.reconcile_prospection_from_attendances(
  uuid, uuid, uuid, uuid, uuid, boolean, boolean, boolean
) from public, anon, authenticated;
revoke all on function app_private.rpc_update_attendance_v1(
  text, uuid, uuid, text, date, text, text, text, text, text,
  numeric, numeric, text, timestamptz
) from public, anon, authenticated;
revoke all on function app_private.attendance_metrics_json(uuid, uuid)
  from public, anon, authenticated;
revoke all on function app_private.attendance_result_with_identity(uuid, boolean)
  from public, anon, authenticated;

revoke all on function public.lc_update_attendance_v1(
  text, uuid, uuid, text, date, text, text, text, text, text,
  numeric, numeric, text, timestamptz
) from public, anon, authenticated;
grant execute on function public.lc_update_attendance_v1(
  text, uuid, uuid, text, date, text, text, text, text, text,
  numeric, numeric, text, timestamptz
) to anon, authenticated;

-- QA estrutural/ACL falha a migration antes do commit se o contrato ficar
-- exposto ou incompleto. Fluxos funcionais ficam no teste transacional irmão.
do $$
declare
  v_fingerprint text;
begin
  if pg_catalog.to_regclass('app_private.attendance_edit_audit') is null then
    raise exception 'QA attendance edit: tabela privada de auditoria ausente.';
  end if;
  if pg_catalog.to_regclass('public.attendance_edit_audit') is not null then
    raise exception 'QA attendance edit: auditoria não pode estar no schema public.';
  end if;
  if not exists (
    select 1 from pg_catalog.pg_attribute attributes
    where attributes.attrelid = 'public.attendances'::pg_catalog.regclass
      and attributes.attname = 'edit_count'
      and not attributes.attisdropped
  ) then
    raise exception 'QA attendance edit: versão de edição ausente.';
  end if;
  if pg_catalog.has_table_privilege('anon', 'app_private.attendance_edit_audit', 'SELECT')
     or pg_catalog.has_table_privilege('authenticated', 'app_private.attendance_edit_audit', 'SELECT') then
    raise exception 'QA attendance edit: PII da auditoria exposta ao browser.';
  end if;
  if pg_catalog.has_function_privilege(
    'anon',
    'app_private.rpc_update_attendance_v1(text,uuid,uuid,text,date,text,text,text,text,text,numeric,numeric,text,timestamptz)',
    'EXECUTE'
  ) then
    raise exception 'QA attendance edit: RPC privado exposto ao anon.';
  end if;
  if not pg_catalog.has_function_privilege(
    'authenticated',
    'public.lc_update_attendance_v1(text,uuid,uuid,text,date,text,text,text,text,text,numeric,numeric,text,timestamptz)',
    'EXECUTE'
  ) then
    raise exception 'QA attendance edit: wrapper autenticado sem EXECUTE.';
  end if;
  if pg_catalog.has_function_privilege(
    'authenticated',
    'app_private.reconcile_prospection_from_attendances(uuid,uuid,uuid,uuid,uuid,boolean,boolean,boolean)',
    'EXECUTE'
  ) then
    raise exception 'QA attendance edit: helper de bonificação exposto.';
  end if;
  if pg_catalog.has_function_privilege(
    'authenticated',
    'app_private.attendance_metrics_json(uuid,uuid)',
    'EXECUTE'
  ) then
    raise exception 'QA attendance edit: métricas privadas expostas.';
  end if;

  v_fingerprint := app_private.attendance_edit_fingerprint(
    '00000000-0000-0000-0000-000000000001'::uuid,
    '00000000-0000-0000-0000-000000000002'::uuid,
    'Profissional', date '2026-09-01', 'Cliente', '5599999999999',
    '5599999999999', null, null, 'Descrição', 'purchase',
    0.01, 0.02, 'OS-1'
  );
  if v_fingerprint !~ '^[0-9a-f]{64}$' then
    raise exception 'QA attendance edit: fingerprint inválido.';
  end if;
end;
$$;

notify pgrst, 'reload schema';

commit;
