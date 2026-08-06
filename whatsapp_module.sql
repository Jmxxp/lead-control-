-- =============================================================================
-- CONTROLE DE LEADS | MODULO WHATSAPP BUSINESS CLOUD API OFICIAL
-- =============================================================================
-- Atualizacao incremental e idempotente para Supabase/PostgreSQL.
-- Pre-requisitos: database.sql aplicado (app_users, stores, app_sessions,
-- app_private.session_user, app_private.set_updated_at e extensao pgcrypto).
--
-- Seguranca:
--   * nenhuma tabela deste modulo e acessivel diretamente por anon/authenticated;
--   * o navegador usa somente RPCs wa_* com p_session_token;
--   * Access Token, App Secret e Verify Token ficam cifrados em app_private;
--   * somente Edge Functions com service_role e a chave externa de criptografia
--     conseguem gravar ou materializar credenciais.
--
-- Execute este arquivo inteiro no SQL Editor do Supabase.
-- =============================================================================

begin;

create schema if not exists app_private;
create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
set search_path = public, app_private, extensions;

-- -----------------------------------------------------------------------------
-- Tabelas publicas protegidas por RLS (acesso somente via RPC/Edge Function)
-- -----------------------------------------------------------------------------

create table if not exists public.whatsapp_connections (
  id uuid primary key default gen_random_uuid(),
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
  store_id uuid not null,
  name text not null check (length(btrim(name)) between 1 and 160),
  display_phone_number text not null default '',
  normalized_phone text not null default '',
  phone_number_id text not null check (length(btrim(phone_number_id)) between 3 and 160),
  business_account_id text not null check (length(btrim(business_account_id)) between 3 and 160),
  app_id text not null default '',
  graph_api_version text not null default 'v26.0',
  webhook_url text not null default '',
  status text not null default 'disconnected',
  token_expires_at timestamptz,
  quality_rating text,
  last_validated_at timestamptz,
  last_connected_at timestamptz,
  disconnected_at timestamptz,
  last_error_code text,
  last_error_message text,
  public_config jsonb not null default '{}'::jsonb,
  created_by uuid references public.app_users(id) on delete set null,
  updated_by uuid references public.app_users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint whatsapp_connections_status_check check (
    status in ('draft', 'validating', 'connected', 'token_expiring', 'disconnected', 'error')
  ),
  constraint whatsapp_connections_app_id_check check (length(btrim(app_id)) between 3 and 160),
  constraint whatsapp_connections_api_version_check check (graph_api_version ~ '^v[0-9]{2,3}[.][0-9]+$'),
  constraint whatsapp_connections_store_admin_fk
    foreign key (store_id, admin_user_id)
    references public.stores(id, admin_user_id)
    on delete cascade,
  constraint whatsapp_connections_phone_number_id_key unique (phone_number_id),
  constraint whatsapp_connections_store_name_key unique (store_id, name)
);
alter table public.whatsapp_connections alter column graph_api_version set default 'v26.0';
alter table public.whatsapp_connections alter column app_id drop default;
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname='whatsapp_connections_app_id_check'
      and conrelid='public.whatsapp_connections'::regclass
  ) then
    alter table public.whatsapp_connections
      add constraint whatsapp_connections_app_id_check
      check (length(btrim(app_id)) between 3 and 160) not valid;
  end if;
end $$;

-- Uma WABA pertence a um unico tenant e a um unico App Meta dentro deste SaaS.
-- O advisory lock fecha a corrida entre duas conexoes criadas simultaneamente.
create or replace function app_private.whatsapp_guard_waba_ownership()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, app_private, public
as $$
begin
  new.business_account_id:=btrim(new.business_account_id);
  new.app_id:=btrim(new.app_id);
  if length(new.app_id)<3 then
    raise exception 'App ID obrigatorio para vincular a conta comercial do WhatsApp.';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('whatsapp:waba:'||new.business_account_id,0)
  );
  if exists(
    select 1
    from public.whatsapp_connections sibling
    where sibling.business_account_id=new.business_account_id
      and sibling.id<>new.id
      and (
        sibling.admin_user_id is distinct from new.admin_user_id
        or btrim(sibling.app_id) is distinct from new.app_id
      )
  ) then
    raise exception 'Esta conta comercial do WhatsApp ja pertence a outro tenant ou App Meta.';
  end if;
  return new;
end;
$$;

drop trigger if exists whatsapp_connections_waba_ownership on public.whatsapp_connections;
create trigger whatsapp_connections_waba_ownership
before insert or update of business_account_id,admin_user_id,app_id
on public.whatsapp_connections
for each row execute function app_private.whatsapp_guard_waba_ownership();

-- Os segredos nunca ficam no schema public. A chave de criptografia nao e
-- armazenada no banco; ela deve existir somente como secret da Edge Function.
create table if not exists app_private.whatsapp_connection_secrets (
  connection_id uuid primary key references public.whatsapp_connections(id) on delete cascade,
  secret_cipher bytea not null,
  verify_token_hash text not null,
  secret_version integer not null default 1 check (secret_version > 0),
  rotated_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.whatsapp_contacts (
  id uuid primary key default gen_random_uuid(),
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
  store_id uuid not null,
  wa_id text,
  phone_e164 text not null check (phone_e164 ~ '^[+][1-9][0-9]{6,14}$'),
  name text not null default '',
  profile_name text not null default '',
  profile_picture_url text,
  email text,
  company text,
  language_code text,
  notes text,
  internal_notes text,
  custom_fields jsonb not null default '{}'::jsonb,
  marketing_opt_in boolean not null default false,
  opt_in_source text,
  opt_in_at timestamptz,
  opt_in_purpose text,
  opt_in_categories text[] not null default '{}'::text[],
  opt_in_text_version text,
  opt_in_evidence jsonb not null default '{}'::jsonb,
  opt_out_at timestamptz,
  revoked_at timestamptz,
  is_favorite boolean not null default false,
  is_blocked boolean not null default false,
  is_active boolean not null default true,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz,
  deleted_at timestamptz,
  created_by uuid references public.app_users(id) on delete set null,
  updated_by uuid references public.app_users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint whatsapp_contacts_store_admin_fk
    foreign key (store_id, admin_user_id)
    references public.stores(id, admin_user_id)
    on delete cascade,
  constraint whatsapp_contacts_store_phone_key unique (store_id, phone_e164),
  constraint whatsapp_contacts_opt_in_proof_check check (
    marketing_opt_in = false
    or (
      opt_in_at is not null
      and length(btrim(coalesce(opt_in_source, ''))) > 0
      and length(btrim(coalesce(opt_in_purpose, ''))) > 0
      and length(btrim(coalesce(opt_in_text_version, ''))) > 0
      and jsonb_typeof(opt_in_evidence) = 'object'
      and opt_in_evidence <> '{}'::jsonb
      and length(btrim(coalesce(opt_in_evidence->>'note', opt_in_evidence->>'reference', opt_in_evidence->>'hash', ''))) > 0
      and opt_in_evidence->>'consented_phone' = phone_e164
      and opt_out_at is null
      and revoked_at is null
    )
  )
);

-- Compatibilidade caso uma versao anterior deste arquivo tenha sido aplicada.
alter table public.whatsapp_contacts add column if not exists internal_notes text;
alter table public.whatsapp_contacts add column if not exists marketing_opt_in boolean not null default false;
alter table public.whatsapp_contacts add column if not exists opt_in_source text;
alter table public.whatsapp_contacts add column if not exists opt_in_at timestamptz;
alter table public.whatsapp_contacts add column if not exists opt_in_purpose text;
alter table public.whatsapp_contacts add column if not exists opt_in_categories text[] not null default '{}'::text[];
alter table public.whatsapp_contacts add column if not exists opt_in_text_version text;
alter table public.whatsapp_contacts add column if not exists opt_in_evidence jsonb not null default '{}'::jsonb;
alter table public.whatsapp_contacts add column if not exists opt_out_at timestamptz;
alter table public.whatsapp_contacts add column if not exists revoked_at timestamptz;
do $$ begin
  if exists(
    select 1 from pg_constraint
    where conname='whatsapp_contacts_opt_in_proof_check'
      and conrelid='public.whatsapp_contacts'::regclass
      and (
        position('opt_in_purpose' in pg_get_constraintdef(oid))=0
        or position('consented_phone' in pg_get_constraintdef(oid))=0
      )
  ) then
    alter table public.whatsapp_contacts drop constraint whatsapp_contacts_opt_in_proof_check;
  end if;
  if not exists(select 1 from pg_constraint where conname='whatsapp_contacts_opt_in_proof_check' and conrelid='public.whatsapp_contacts'::regclass) then
    alter table public.whatsapp_contacts add constraint whatsapp_contacts_opt_in_proof_check check (
      marketing_opt_in=false or (
        opt_in_at is not null
        and length(btrim(coalesce(opt_in_source,'')))>0
        and length(btrim(coalesce(opt_in_purpose,'')))>0
        and length(btrim(coalesce(opt_in_text_version,'')))>0
        and jsonb_typeof(opt_in_evidence)='object'
        and opt_in_evidence<>'{}'::jsonb
        and length(btrim(coalesce(opt_in_evidence->>'note',opt_in_evidence->>'reference',opt_in_evidence->>'hash','')))>0
        and opt_in_evidence->>'consented_phone'=phone_e164
        and opt_out_at is null and revoked_at is null
      )
    ) not valid;
    if not exists(
      select 1 from public.whatsapp_contacts
      where marketing_opt_in and not (
        opt_in_at is not null
        and length(btrim(coalesce(opt_in_source,'')))>0
        and length(btrim(coalesce(opt_in_purpose,'')))>0
        and length(btrim(coalesce(opt_in_text_version,'')))>0
        and jsonb_typeof(opt_in_evidence)='object'
        and opt_in_evidence<>'{}'::jsonb
        and length(btrim(coalesce(opt_in_evidence->>'note',opt_in_evidence->>'reference',opt_in_evidence->>'hash','')))>0
        and opt_in_evidence->>'consented_phone'=phone_e164
        and opt_out_at is null and revoked_at is null
      )
    ) then
      alter table public.whatsapp_contacts validate constraint whatsapp_contacts_opt_in_proof_check;
    end if;
  end if;
end $$;

create table if not exists public.whatsapp_tags (
  id uuid primary key default gen_random_uuid(),
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
  store_id uuid not null,
  name text not null check (length(btrim(name)) between 1 and 80),
  color text not null default '#2f80ed' check (color ~ '^#[0-9A-Fa-f]{6}$'),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint whatsapp_tags_store_admin_fk
    foreign key (store_id, admin_user_id)
    references public.stores(id, admin_user_id)
    on delete cascade,
  constraint whatsapp_tags_store_name_key unique (store_id, name)
);

create table if not exists public.whatsapp_contact_tags (
  contact_id uuid not null references public.whatsapp_contacts(id) on delete cascade,
  tag_id uuid not null references public.whatsapp_tags(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (contact_id, tag_id)
);

create table if not exists public.whatsapp_conversations (
  id uuid primary key default gen_random_uuid(),
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
  store_id uuid not null,
  connection_id uuid not null references public.whatsapp_connections(id) on delete cascade,
  contact_id uuid not null references public.whatsapp_contacts(id) on delete restrict,
  status text not null default 'open',
  is_favorite boolean not null default false,
  unread_count integer not null default 0 check (unread_count >= 0),
  assigned_user_id uuid references public.app_users(id) on delete set null,
  assigned_at timestamptz,
  last_message_id uuid,
  last_message_preview text,
  last_message_direction text,
  last_message_at timestamptz,
  customer_service_window_expires_at timestamptz,
  resolved_at timestamptz,
  archived_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint whatsapp_conversations_status_check check (status in ('open', 'pending', 'resolved', 'archived')),
  constraint whatsapp_conversations_direction_check check (
    last_message_direction is null or last_message_direction in ('inbound', 'outbound')
  ),
  constraint whatsapp_conversations_store_admin_fk
    foreign key (store_id, admin_user_id)
    references public.stores(id, admin_user_id)
    on delete cascade,
  constraint whatsapp_conversations_connection_contact_key unique (connection_id, contact_id)
);

create table if not exists public.whatsapp_messages (
  id uuid primary key default gen_random_uuid(),
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
  store_id uuid not null,
  connection_id uuid not null references public.whatsapp_connections(id) on delete cascade,
  conversation_id uuid not null references public.whatsapp_conversations(id) on delete cascade,
  contact_id uuid not null references public.whatsapp_contacts(id) on delete restrict,
  provider_message_id text,
  idempotency_key text not null,
  direction text not null,
  message_type text not null default 'text',
  status text not null default 'queued',
  text_body text,
  reply_to_provider_message_id text,
  template_name text,
  template_language text,
  template_parameters jsonb not null default '[]'::jsonb,
  provider_payload jsonb not null default '{}'::jsonb,
  error_code text,
  error_message text,
  sent_at timestamptz,
  delivered_at timestamptz,
  read_at timestamptz,
  failed_at timestamptz,
  received_at timestamptz,
  created_by uuid references public.app_users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint whatsapp_messages_direction_check check (direction in ('inbound', 'outbound')),
  constraint whatsapp_messages_type_check check (
    message_type in ('text', 'image', 'document', 'audio', 'video', 'sticker', 'location', 'contacts', 'interactive', 'reaction', 'template', 'unknown')
  ),
  constraint whatsapp_messages_status_check check (
    status in ('queued', 'processing', 'sent', 'delivered', 'read', 'received', 'failed', 'cancelled')
  ),
  constraint whatsapp_messages_store_admin_fk
    foreign key (store_id, admin_user_id)
    references public.stores(id, admin_user_id)
    on delete cascade,
  constraint whatsapp_messages_connection_idempotency_key unique (connection_id, idempotency_key)
);

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'whatsapp_conversations_last_message_fk'
      and conrelid = 'public.whatsapp_conversations'::regclass
  ) then
    alter table public.whatsapp_conversations
      add constraint whatsapp_conversations_last_message_fk
      foreign key (last_message_id) references public.whatsapp_messages(id) on delete set null;
  end if;
end $$;

create table if not exists public.whatsapp_attachments (
  id uuid primary key default gen_random_uuid(),
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
  store_id uuid not null,
  message_id uuid not null references public.whatsapp_messages(id) on delete cascade,
  provider_media_id text,
  storage_bucket text,
  storage_path text,
  original_filename text,
  mime_type text,
  file_size bigint check (file_size is null or file_size >= 0),
  sha256 text,
  caption text,
  media_status text not null default 'remote',
  expires_at timestamptz,
  created_at timestamptz not null default now(),
  constraint whatsapp_attachments_status_check check (media_status in ('remote', 'downloading', 'stored', 'expired', 'failed')),
  constraint whatsapp_attachments_store_admin_fk
    foreign key (store_id, admin_user_id)
    references public.stores(id, admin_user_id)
    on delete cascade
);

create table if not exists public.whatsapp_templates (
  id uuid primary key default gen_random_uuid(),
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
  store_id uuid not null,
  connection_id uuid not null references public.whatsapp_connections(id) on delete cascade,
  provider_template_id text,
  name text not null check (length(btrim(name)) between 1 and 512),
  language_code text not null,
  category text not null,
  status text not null default 'PENDING',
  parameter_format text,
  components jsonb not null default '[]'::jsonb,
  quality_score jsonb not null default '{}'::jsonb,
  rejection_reason text,
  last_synced_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint whatsapp_templates_store_admin_fk
    foreign key (store_id, admin_user_id)
    references public.stores(id, admin_user_id)
    on delete cascade,
  constraint whatsapp_templates_connection_name_language_key unique (connection_id, name, language_code)
);

create table if not exists public.whatsapp_campaigns (
  id uuid primary key default gen_random_uuid(),
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
  store_id uuid not null,
  connection_id uuid not null references public.whatsapp_connections(id) on delete restrict,
  template_id uuid not null references public.whatsapp_templates(id) on delete restrict,
  name text not null check (length(btrim(name)) between 1 and 200),
  status text not null default 'draft',
  scheduled_at timestamptz,
  started_at timestamptz,
  paused_at timestamptz,
  completed_at timestamptz,
  cancelled_at timestamptz,
  messages_per_second numeric(8,2) not null default 5 check (messages_per_second > 0 and messages_per_second <= 80),
  audience_filter jsonb not null default '{}'::jsonb,
  template_parameters jsonb not null default '[]'::jsonb,
  total_recipients integer not null default 0 check (total_recipients >= 0),
  queued_count integer not null default 0 check (queued_count >= 0),
  sent_count integer not null default 0 check (sent_count >= 0),
  delivered_count integer not null default 0 check (delivered_count >= 0),
  read_count integer not null default 0 check (read_count >= 0),
  failed_count integer not null default 0 check (failed_count >= 0),
  cancelled_count integer not null default 0 check (cancelled_count >= 0),
  last_error text,
  created_by uuid references public.app_users(id) on delete set null,
  updated_by uuid references public.app_users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint whatsapp_campaigns_status_check check (
    status in ('draft', 'scheduled', 'running', 'paused', 'completed', 'cancelled', 'failed')
  ),
  constraint whatsapp_campaigns_store_admin_fk
    foreign key (store_id, admin_user_id)
    references public.stores(id, admin_user_id)
    on delete cascade
);

create table if not exists public.whatsapp_campaign_recipients (
  id uuid primary key default gen_random_uuid(),
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
  store_id uuid not null,
  campaign_id uuid not null references public.whatsapp_campaigns(id) on delete cascade,
  contact_id uuid not null references public.whatsapp_contacts(id) on delete restrict,
  status text not null default 'pending',
  resolved_parameters jsonb not null default '[]'::jsonb,
  message_id uuid references public.whatsapp_messages(id) on delete set null,
  queued_at timestamptz,
  sent_at timestamptz,
  delivered_at timestamptz,
  read_at timestamptz,
  failed_at timestamptz,
  error_code text,
  error_message text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint whatsapp_campaign_recipients_status_check check (
    status in ('pending', 'queued', 'processing', 'sent', 'delivered', 'read', 'failed', 'cancelled')
  ),
  constraint whatsapp_campaign_recipients_store_admin_fk
    foreign key (store_id, admin_user_id)
    references public.stores(id, admin_user_id)
    on delete cascade,
  constraint whatsapp_campaign_recipients_campaign_contact_key unique (campaign_id, contact_id)
);

create table if not exists public.whatsapp_send_queue (
  id uuid primary key default gen_random_uuid(),
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
  store_id uuid not null,
  connection_id uuid not null references public.whatsapp_connections(id) on delete cascade,
  message_id uuid references public.whatsapp_messages(id) on delete cascade,
  campaign_id uuid references public.whatsapp_campaigns(id) on delete cascade,
  campaign_recipient_id uuid references public.whatsapp_campaign_recipients(id) on delete cascade,
  idempotency_key text not null,
  payload jsonb not null,
  status text not null default 'pending',
  priority smallint not null default 100,
  attempt_count integer not null default 0 check (attempt_count >= 0),
  max_attempts integer not null default 10 check (max_attempts between 1 and 30),
  available_at timestamptz not null default now(),
  locked_at timestamptz,
  locked_by text,
  reserved_dispatch_at timestamptz,
  provider_message_id text,
  provider_response jsonb,
  last_http_status integer,
  last_error_code text,
  last_error_message text,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint whatsapp_send_queue_status_check check (
    status in ('pending', 'processing', 'retry', 'sent', 'sent_unconfirmed', 'failed', 'cancelled')
  ),
  constraint whatsapp_send_queue_target_check check (message_id is not null or campaign_recipient_id is not null),
  constraint whatsapp_send_queue_connection_idempotency_key unique (connection_id, idempotency_key),
  constraint whatsapp_send_queue_store_admin_fk
    foreign key (store_id, admin_user_id)
    references public.stores(id, admin_user_id)
    on delete cascade
);
alter table public.whatsapp_send_queue add column if not exists reserved_dispatch_at timestamptz;
do $$ begin
  if exists(
    select 1 from pg_constraint
    where conname='whatsapp_send_queue_status_check'
      and conrelid='public.whatsapp_send_queue'::regclass
      and position('sent_unconfirmed' in pg_get_constraintdef(oid))=0
  ) then
    alter table public.whatsapp_send_queue drop constraint whatsapp_send_queue_status_check;
    alter table public.whatsapp_send_queue add constraint whatsapp_send_queue_status_check check (
      status in ('pending','processing','retry','sent','sent_unconfirmed','failed','cancelled')
    );
  end if;
end $$;

-- Versoes iniciais usavam uma chave global. Alem de limitar tenants distintos,
-- uma chave adivinhada podia colidir com dados de outra conexao. A identidade
-- idempotente e sempre local ao numero oficial que realiza o envio.
alter table public.whatsapp_messages drop constraint if exists whatsapp_messages_idempotency_key;
alter table public.whatsapp_messages drop constraint if exists whatsapp_messages_idempotency_key_key;
alter table public.whatsapp_send_queue drop constraint if exists whatsapp_send_queue_idempotency_key_key;
do $$ begin
  if not exists(
    select 1 from pg_constraint
    where conname='whatsapp_messages_connection_idempotency_key'
      and conrelid='public.whatsapp_messages'::regclass
  ) then
    alter table public.whatsapp_messages
      add constraint whatsapp_messages_connection_idempotency_key unique(connection_id,idempotency_key);
  end if;
  if not exists(
    select 1 from pg_constraint
    where conname='whatsapp_send_queue_connection_idempotency_key'
      and conrelid='public.whatsapp_send_queue'::regclass
  ) then
    alter table public.whatsapp_send_queue
      add constraint whatsapp_send_queue_connection_idempotency_key unique(connection_id,idempotency_key);
  end if;
end $$;

-- Slots atomicos de throughput. A chave "__connection__" representa o limite
-- global; as demais chaves sao pares conexao+destinatario.
create table if not exists public.whatsapp_dispatch_limits (
  connection_id uuid not null references public.whatsapp_connections(id) on delete cascade,
  scope_key text not null,
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
  store_id uuid not null,
  next_available_at timestamptz not null default now(),
  in_flight_queue_id uuid references public.whatsapp_send_queue(id) on delete set null,
  lease_expires_at timestamptz,
  updated_at timestamptz not null default now(),
  primary key(connection_id,scope_key),
  constraint whatsapp_dispatch_limits_store_admin_fk foreign key(store_id,admin_user_id)
    references public.stores(id,admin_user_id) on delete cascade
);
alter table public.whatsapp_dispatch_limits add column if not exists in_flight_queue_id uuid references public.whatsapp_send_queue(id) on delete set null;
alter table public.whatsapp_dispatch_limits add column if not exists lease_expires_at timestamptz;

create table if not exists public.whatsapp_webhook_events (
  id uuid primary key default gen_random_uuid(),
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
  store_id uuid not null,
  connection_id uuid not null references public.whatsapp_connections(id) on delete cascade,
  event_key text not null,
  event_type text not null default 'unknown',
  provider_object text,
  provider_message_id text,
  signature_valid boolean not null default true,
  headers jsonb not null default '{}'::jsonb,
  payload jsonb not null,
  processing_status text not null default 'pending',
  processing_attempts integer not null default 0,
  locked_at timestamptz,
  locked_by text,
  received_count integer not null default 1,
  first_received_at timestamptz not null default now(),
  last_received_at timestamptz not null default now(),
  processed_at timestamptz,
  next_attempt_at timestamptz not null default now(),
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint whatsapp_webhook_events_status_check check (
    processing_status in ('pending', 'processing', 'processed', 'failed', 'ignored')
  ),
  constraint whatsapp_webhook_events_store_admin_fk
    foreign key (store_id, admin_user_id)
    references public.stores(id, admin_user_id)
    on delete cascade,
  constraint whatsapp_webhook_events_connection_event_key unique (connection_id, event_key)
);
alter table public.whatsapp_webhook_events add column if not exists locked_at timestamptz;
alter table public.whatsapp_webhook_events add column if not exists locked_by text;

create table if not exists public.whatsapp_status_history (
  id bigint generated by default as identity primary key,
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
  store_id uuid not null,
  entity_type text not null,
  entity_id uuid not null,
  previous_status text,
  new_status text not null,
  source text not null default 'system',
  provider_timestamp timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  actor_user_id uuid references public.app_users(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint whatsapp_status_history_entity_type_check check (
    entity_type in ('connection', 'conversation', 'message', 'campaign', 'campaign_recipient', 'queue', 'webhook')
  ),
  constraint whatsapp_status_history_store_admin_fk
    foreign key (store_id, admin_user_id)
    references public.stores(id, admin_user_id)
    on delete cascade
);

create table if not exists public.whatsapp_logs (
  id bigint generated by default as identity primary key,
  admin_user_id uuid references public.app_users(id) on delete cascade,
  store_id uuid references public.stores(id) on delete cascade,
  connection_id uuid references public.whatsapp_connections(id) on delete set null,
  user_id uuid references public.app_users(id) on delete set null,
  level text not null default 'info',
  category text not null,
  action text not null,
  correlation_id text,
  request_id text,
  http_method text,
  endpoint text,
  http_status integer,
  latency_ms integer check (latency_ms is null or latency_ms >= 0),
  success boolean not null default true,
  error_code text,
  message text not null default '',
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint whatsapp_logs_level_check check (level in ('debug', 'info', 'warning', 'error', 'critical')),
  constraint whatsapp_logs_category_check check (
    category in ('connection', 'credential', 'api', 'message', 'media', 'template', 'campaign', 'webhook', 'queue', 'security', 'system')
  )
);

-- -----------------------------------------------------------------------------
-- Indices para busca, timeline, filas e relatorios em grande volume
-- -----------------------------------------------------------------------------

create index if not exists whatsapp_connections_store_status_idx on public.whatsapp_connections(store_id, status, created_at desc);
create index if not exists whatsapp_contacts_store_name_idx on public.whatsapp_contacts(store_id, lower(name), updated_at desc) where is_active;
create index if not exists whatsapp_contacts_store_wa_idx on public.whatsapp_contacts(store_id, wa_id) where wa_id is not null;
create index if not exists whatsapp_contact_tags_tag_idx on public.whatsapp_contact_tags(tag_id, contact_id);
create index if not exists whatsapp_conversations_store_last_idx on public.whatsapp_conversations(store_id, last_message_at desc nulls last, updated_at desc);
create index if not exists whatsapp_conversations_store_unread_idx on public.whatsapp_conversations(store_id, unread_count, last_message_at desc) where unread_count > 0;
create index if not exists whatsapp_messages_conversation_created_idx on public.whatsapp_messages(conversation_id, created_at desc, id);
create unique index if not exists whatsapp_messages_provider_id_key on public.whatsapp_messages(connection_id, provider_message_id) where provider_message_id is not null;
create index if not exists whatsapp_messages_store_status_idx on public.whatsapp_messages(store_id, status, created_at desc);
create index if not exists whatsapp_attachments_message_idx on public.whatsapp_attachments(message_id, created_at);
create unique index if not exists whatsapp_attachments_message_media_key
  on public.whatsapp_attachments(message_id, provider_media_id)
  where provider_media_id is not null;
create index if not exists whatsapp_templates_connection_status_idx on public.whatsapp_templates(connection_id, status, name, language_code);
create index if not exists whatsapp_campaigns_store_status_idx on public.whatsapp_campaigns(store_id, status, created_at desc);
create index if not exists whatsapp_campaign_recipients_campaign_status_idx on public.whatsapp_campaign_recipients(campaign_id, status, created_at);
create index if not exists whatsapp_send_queue_claim_idx on public.whatsapp_send_queue(status, available_at, priority, created_at) where status in ('pending', 'retry');
create index if not exists whatsapp_send_queue_connection_idx on public.whatsapp_send_queue(connection_id, status, available_at);
create index if not exists whatsapp_send_queue_campaign_active_idx on public.whatsapp_send_queue(campaign_id,status) where campaign_id is not null and status in ('pending','retry','processing');
create index if not exists whatsapp_dispatch_limits_next_idx on public.whatsapp_dispatch_limits(next_available_at);
create index if not exists whatsapp_webhook_events_store_date_idx on public.whatsapp_webhook_events(store_id, created_at desc);
create index if not exists whatsapp_webhook_events_processing_idx on public.whatsapp_webhook_events(processing_status, next_attempt_at, created_at) where processing_status in ('pending', 'failed');
create index if not exists whatsapp_status_history_entity_idx on public.whatsapp_status_history(entity_type, entity_id, created_at desc);
create index if not exists whatsapp_logs_store_date_idx on public.whatsapp_logs(store_id, created_at desc);
create index if not exists whatsapp_logs_correlation_idx on public.whatsapp_logs(correlation_id, created_at) where correlation_id is not null;
create index if not exists whatsapp_logs_error_idx on public.whatsapp_logs(store_id, created_at desc) where success = false;

-- -----------------------------------------------------------------------------
-- Triggers comuns e trilha de status
-- -----------------------------------------------------------------------------

create or replace function app_private.whatsapp_capture_status_change()
returns trigger
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_entity_type text := tg_argv[0];
  v_status_column text := coalesce(nullif(tg_argv[1], ''), 'status');
  v_previous_status text;
  v_new_status text;
begin
  v_new_status := to_jsonb(new)->>v_status_column;
  if tg_op = 'UPDATE' then
    v_previous_status := to_jsonb(old)->>v_status_column;
  end if;
  if tg_op = 'INSERT' or v_previous_status is distinct from v_new_status then
    insert into public.whatsapp_status_history (
      admin_user_id, store_id, entity_type, entity_id, previous_status,
      new_status, source, metadata
    ) values (
      new.admin_user_id, new.store_id, v_entity_type, new.id,
      v_previous_status, v_new_status, 'database', '{}'::jsonb
    );
  end if;
  return new;
end;
$$;

do $$
declare
  v_table text;
begin
  foreach v_table in array array[
    'whatsapp_connections', 'whatsapp_contacts', 'whatsapp_tags',
    'whatsapp_conversations', 'whatsapp_messages', 'whatsapp_templates',
    'whatsapp_campaigns', 'whatsapp_campaign_recipients',
    'whatsapp_send_queue', 'whatsapp_dispatch_limits', 'whatsapp_webhook_events'
  ] loop
    execute format('drop trigger if exists %I on public.%I', v_table || '_set_updated_at', v_table);
    execute format(
      'create trigger %I before update on public.%I for each row execute function app_private.set_updated_at()',
      v_table || '_set_updated_at', v_table
    );
  end loop;
end $$;

drop trigger if exists whatsapp_connection_status_history on public.whatsapp_connections;
create trigger whatsapp_connection_status_history after insert or update of status on public.whatsapp_connections
for each row execute function app_private.whatsapp_capture_status_change('connection', 'status');
drop trigger if exists whatsapp_conversation_status_history on public.whatsapp_conversations;
create trigger whatsapp_conversation_status_history after insert or update of status on public.whatsapp_conversations
for each row execute function app_private.whatsapp_capture_status_change('conversation', 'status');
drop trigger if exists whatsapp_message_status_history on public.whatsapp_messages;
create trigger whatsapp_message_status_history after insert or update of status on public.whatsapp_messages
for each row execute function app_private.whatsapp_capture_status_change('message', 'status');
drop trigger if exists whatsapp_campaign_status_history on public.whatsapp_campaigns;
create trigger whatsapp_campaign_status_history after insert or update of status on public.whatsapp_campaigns
for each row execute function app_private.whatsapp_capture_status_change('campaign', 'status');
drop trigger if exists whatsapp_campaign_recipient_status_history on public.whatsapp_campaign_recipients;
create trigger whatsapp_campaign_recipient_status_history after insert or update of status on public.whatsapp_campaign_recipients
for each row execute function app_private.whatsapp_capture_status_change('campaign_recipient', 'status');
drop trigger if exists whatsapp_queue_status_history on public.whatsapp_send_queue;
create trigger whatsapp_queue_status_history after insert or update of status on public.whatsapp_send_queue
for each row execute function app_private.whatsapp_capture_status_change('queue', 'status');
drop trigger if exists whatsapp_webhook_status_history on public.whatsapp_webhook_events;
create trigger whatsapp_webhook_status_history after insert or update of processing_status on public.whatsapp_webhook_events
for each row execute function app_private.whatsapp_capture_status_change('webhook', 'processing_status');

-- -----------------------------------------------------------------------------
-- Autorizacao central: Admin -> Agencia -> Cliente, sempre dentro do tenant
-- -----------------------------------------------------------------------------

create or replace function app_private.whatsapp_store_allowed(
  p_admin_user_id uuid,
  p_user_id uuid,
  p_user_role public.app_user_role,
  p_user_store_id uuid,
  p_store_id uuid,
  p_configuration_write boolean default false
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
        or (
          coalesce(p_configuration_write, false) = false
          and p_user_role::text = 'store'
          and st.id = p_user_store_id
        )
      )
  );
$$;

create or replace function app_private.whatsapp_normalize_phone(p_value text)
returns text
language plpgsql
immutable
as $$
declare v_digits text := regexp_replace(coalesce(p_value, ''), '[^0-9]', '', 'g');
begin
  if length(v_digits) < 7 or length(v_digits) > 15 then
    raise exception 'Numero de WhatsApp invalido.';
  end if;
  return '+' || v_digits;
end;
$$;

create or replace function app_private.whatsapp_json_size_guard(p_value jsonb, p_limit integer, p_label text)
returns jsonb
language plpgsql
immutable
as $$
begin
  if octet_length(coalesce(p_value, '{}'::jsonb)::text) > p_limit then
    raise exception '% excede o limite permitido.', p_label;
  end if;
  return coalesce(p_value, '{}'::jsonb);
end;
$$;

create or replace function app_private.whatsapp_validate_opt_in(p_payload jsonb)
returns void
language plpgsql
volatile
as $$
declare v_evidence jsonb:=p_payload->'opt_in_evidence';v_at timestamptz;
begin
  if length(btrim(coalesce(p_payload->>'opt_in_source','')))=0 then raise exception 'Informe a origem do consentimento de marketing.'; end if;
  if nullif(p_payload->>'opt_in_at','') is null then raise exception 'Informe a data do consentimento de marketing.'; end if;
  v_at:=(p_payload->>'opt_in_at')::timestamptz;
  if v_at>now()+interval '5 minutes' then raise exception 'A data do consentimento nao pode estar no futuro.'; end if;
  if length(btrim(coalesce(p_payload->>'opt_in_purpose','')))=0 then raise exception 'Informe a finalidade do consentimento de marketing.'; end if;
  if length(btrim(coalesce(p_payload->>'opt_in_text_version','')))=0 then raise exception 'Informe a versao do texto de consentimento.'; end if;
  if jsonb_typeof(v_evidence)<>'object' or v_evidence='{}'::jsonb then raise exception 'Informe uma evidencia estruturada do consentimento.'; end if;
  if length(btrim(coalesce(v_evidence->>'note',v_evidence->>'reference',v_evidence->>'hash','')))=0 then raise exception 'A evidencia deve conter nota, referencia ou hash verificavel.'; end if;
end;
$$;

create or replace function app_private.whatsapp_marketing_consent_active(p_contact public.whatsapp_contacts)
returns boolean
language sql
immutable
as $$
  select coalesce(p_contact.marketing_opt_in,false)
    and p_contact.opt_in_at is not null
    and length(btrim(coalesce(p_contact.opt_in_source,'')))>0
    and length(btrim(coalesce(p_contact.opt_in_purpose,'')))>0
    and length(btrim(coalesce(p_contact.opt_in_text_version,'')))>0
    and jsonb_typeof(p_contact.opt_in_evidence)='object'
    and p_contact.opt_in_evidence<>'{}'::jsonb
    and length(btrim(coalesce(p_contact.opt_in_evidence->>'note',p_contact.opt_in_evidence->>'reference',p_contact.opt_in_evidence->>'hash','')))>0
    and p_contact.opt_in_evidence->>'consented_phone'=p_contact.phone_e164
    and p_contact.opt_out_at is null
    and p_contact.revoked_at is null;
$$;

-- -----------------------------------------------------------------------------
-- RPCs do frontend (nenhuma retorna segredo)
-- -----------------------------------------------------------------------------

create or replace function public.wa_list_connections(
  p_session_token text,
  p_store_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare v_session record; v_result jsonb;
begin
  select * into v_session from app_private.session_user(p_session_token);
  if not app_private.whatsapp_store_allowed(
    v_session.admin_user_id, v_session.user_id, v_session.user_role,
    v_session.user_store_id, p_store_id, false
  ) then raise exception 'Cliente nao encontrado ou sem permissao.'; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', c.id, 'store_id', c.store_id, 'name', c.name,
    'display_phone_number', c.display_phone_number,
    'phone_number_id', c.phone_number_id,
    'business_account_id', c.business_account_id,
    'app_id', c.app_id, 'graph_api_version', c.graph_api_version,
    'webhook_url', c.webhook_url, 'status', c.status,
    'token_expires_at', c.token_expires_at,
    'quality_rating', c.quality_rating,
    'whatsapp_business_manager_messaging_limit', c.public_config->>'whatsapp_business_manager_messaging_limit',
    'last_validated_at', c.last_validated_at,
    'last_connected_at', c.last_connected_at,
    'last_error_code', c.last_error_code,
    'last_error_message', c.last_error_message,
    'has_access_token', (s.connection_id is not null),
    'has_app_secret', (s.connection_id is not null),
    'has_verify_token', (s.connection_id is not null),
    'created_at', c.created_at, 'updated_at', c.updated_at
  ) order by c.created_at desc), '[]'::jsonb)
  into v_result
  from public.whatsapp_connections c
  left join app_private.whatsapp_connection_secrets s on s.connection_id = c.id
  where c.store_id = p_store_id and c.admin_user_id = v_session.admin_user_id;
  return v_result;
end;
$$;

create or replace function public.wa_get_bootstrap(
  p_session_token text,
  p_store_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare v_session record; v_store record;
begin
  select * into v_session from app_private.session_user(p_session_token);
  select st.id, st.name, st.nick into v_store
  from public.stores st
  where st.id = p_store_id
    and app_private.whatsapp_store_allowed(
      v_session.admin_user_id, v_session.user_id, v_session.user_role,
      v_session.user_store_id, st.id, false
    );
  if not found then raise exception 'Cliente nao encontrado ou sem permissao.'; end if;

  return jsonb_build_object(
    'store', jsonb_build_object('id', v_store.id, 'name', v_store.name, 'nick', v_store.nick),
    'permissions', jsonb_build_object(
      'can_configure', v_session.user_role::text in ('admin', 'technician'),
      'can_send', true,
      'can_manage_campaigns', v_session.user_role::text in ('admin', 'technician', 'store')
    ),
    'connections', public.wa_list_connections(p_session_token, p_store_id),
    'counts', jsonb_build_object(
      'open_conversations', (select count(*) from public.whatsapp_conversations c where c.store_id = p_store_id and c.status in ('open', 'pending')),
      'unread_conversations', (select count(*) from public.whatsapp_conversations c where c.store_id = p_store_id and c.unread_count > 0),
      'active_contacts', (select count(*) from public.whatsapp_contacts c where c.store_id = p_store_id and c.is_active),
      'marketing_opt_in_contacts', (select count(*) from public.whatsapp_contacts c where c.store_id=p_store_id and c.is_active and not c.is_blocked and app_private.whatsapp_marketing_consent_active(c)),
      'running_campaigns', (select count(*) from public.whatsapp_campaigns c where c.store_id = p_store_id and c.status in ('scheduled', 'running', 'paused')),
      'approved_templates', (select count(*) from public.whatsapp_templates t where t.store_id = p_store_id and upper(t.status) = 'APPROVED'),
      'failed_queue', (select count(*) from public.whatsapp_send_queue q where q.store_id = p_store_id and q.status = 'failed')
    ),
    'tags', coalesce((select jsonb_agg(to_jsonb(t) - 'admin_user_id' order by t.name) from public.whatsapp_tags t where t.store_id = p_store_id and t.is_active), '[]'::jsonb)
  );
end;
$$;

create or replace function public.wa_list_conversations(
  p_session_token text,
  p_store_id uuid,
  p_search text default null,
  p_status text default null,
  p_unread_only boolean default false,
  p_favorites_only boolean default false,
  p_tag_ids uuid[] default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare v_session record; v_items jsonb; v_total bigint; v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 200); v_offset integer := greatest(coalesce(p_offset, 0), 0);
begin
  select * into v_session from app_private.session_user(p_session_token);
  if not app_private.whatsapp_store_allowed(v_session.admin_user_id, v_session.user_id, v_session.user_role, v_session.user_store_id, p_store_id, false)
  then raise exception 'Cliente nao encontrado ou sem permissao.'; end if;

  with filtered as (
    select c.*, ct.name as contact_name, ct.profile_name, ct.phone_e164,
      ct.profile_picture_url, conn.name as connection_name,
      coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name, 'color', t.color) order by t.name)
        from public.whatsapp_contact_tags x join public.whatsapp_tags t on t.id = x.tag_id where x.contact_id = ct.id), '[]'::jsonb) as tags
    from public.whatsapp_conversations c
    join public.whatsapp_contacts ct on ct.id = c.contact_id and ct.is_active
    join public.whatsapp_connections conn on conn.id = c.connection_id
    where c.store_id = p_store_id
      and c.admin_user_id = v_session.admin_user_id
      and (nullif(btrim(coalesce(p_search, '')), '') is null or ct.name ilike '%' || btrim(p_search) || '%' or ct.profile_name ilike '%' || btrim(p_search) || '%' or (regexp_replace(p_search, '[^0-9+]', '', 'g')<>'' and ct.phone_e164 ilike '%' || regexp_replace(p_search, '[^0-9+]', '', 'g') || '%') or c.last_message_preview ilike '%' || btrim(p_search) || '%')
      and (
        nullif(lower(btrim(coalesce(p_status,''))),'') is null
        or (lower(btrim(p_status))='open' and c.status in ('open','pending'))
        or (lower(btrim(p_status))='closed' and c.status in ('resolved','closed','archived'))
        or (lower(btrim(p_status)) not in ('open','closed') and c.status=lower(btrim(p_status)))
      )
      and (not coalesce(p_unread_only, false) or c.unread_count > 0)
      and (not coalesce(p_favorites_only, false) or c.is_favorite)
      and (p_tag_ids is null or cardinality(p_tag_ids) = 0 or exists (select 1 from public.whatsapp_contact_tags x where x.contact_id = ct.id and x.tag_id = any(p_tag_ids)))
  )
  select count(*) into v_total from filtered;

  with filtered as (
    select c.*, ct.name as contact_name, ct.profile_name, ct.phone_e164,
      ct.profile_picture_url, conn.name as connection_name,
      coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name, 'color', t.color) order by t.name)
        from public.whatsapp_contact_tags x join public.whatsapp_tags t on t.id = x.tag_id where x.contact_id = ct.id), '[]'::jsonb) as tags
    from public.whatsapp_conversations c
    join public.whatsapp_contacts ct on ct.id = c.contact_id and ct.is_active
    join public.whatsapp_connections conn on conn.id = c.connection_id
    where c.store_id = p_store_id and c.admin_user_id = v_session.admin_user_id
      and (nullif(btrim(coalesce(p_search, '')), '') is null or ct.name ilike '%' || btrim(p_search) || '%' or ct.profile_name ilike '%' || btrim(p_search) || '%' or (regexp_replace(p_search, '[^0-9+]', '', 'g')<>'' and ct.phone_e164 ilike '%' || regexp_replace(p_search, '[^0-9+]', '', 'g') || '%') or c.last_message_preview ilike '%' || btrim(p_search) || '%')
      and (
        nullif(lower(btrim(coalesce(p_status,''))),'') is null
        or (lower(btrim(p_status))='open' and c.status in ('open','pending'))
        or (lower(btrim(p_status))='closed' and c.status in ('resolved','closed','archived'))
        or (lower(btrim(p_status)) not in ('open','closed') and c.status=lower(btrim(p_status)))
      )
      and (not coalesce(p_unread_only, false) or c.unread_count > 0)
      and (not coalesce(p_favorites_only, false) or c.is_favorite)
      and (p_tag_ids is null or cardinality(p_tag_ids) = 0 or exists (select 1 from public.whatsapp_contact_tags x where x.contact_id = ct.id and x.tag_id = any(p_tag_ids)))
    order by c.last_message_at desc nulls last, c.updated_at desc
    limit v_limit offset v_offset
  )
  select coalesce(jsonb_agg(to_jsonb(filtered) - 'admin_user_id' order by last_message_at desc nulls last, updated_at desc), '[]'::jsonb) into v_items from filtered;
  return jsonb_build_object('items', v_items, 'total', v_total, 'limit', v_limit, 'offset', v_offset);
end;
$$;

create or replace function public.wa_get_messages(
  p_session_token text,
  p_conversation_id uuid,
  p_before timestamptz default null,
  p_limit integer default 80
)
returns jsonb
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare v_session record; v_conversation record; v_items jsonb; v_limit integer := least(greatest(coalesce(p_limit, 80), 1), 200);
begin
  select * into v_session from app_private.session_user(p_session_token);
  select c.* into v_conversation from public.whatsapp_conversations c
  where c.id = p_conversation_id and c.admin_user_id = v_session.admin_user_id
    and app_private.whatsapp_store_allowed(v_session.admin_user_id, v_session.user_id, v_session.user_role, v_session.user_store_id, c.store_id, false);
  if not found then raise exception 'Conversa nao encontrada ou sem permissao.'; end if;

  with page as (
    select m.*,
      coalesce((select jsonb_agg(to_jsonb(a) - 'admin_user_id' - 'store_id' order by a.created_at) from public.whatsapp_attachments a where a.message_id = m.id), '[]'::jsonb) as attachments
    from public.whatsapp_messages m
    where m.conversation_id = p_conversation_id
      and (p_before is null or m.created_at < p_before)
    order by m.created_at desc, m.id desc limit v_limit
  )
  select coalesce(jsonb_agg(to_jsonb(page) - 'admin_user_id' - 'store_id' order by created_at, id), '[]'::jsonb) into v_items from page;

  update public.whatsapp_conversations set unread_count = 0 where id = p_conversation_id;
  return jsonb_build_object('items', v_items, 'has_more', jsonb_array_length(v_items) = v_limit);
end;
$$;

create or replace function public.wa_upsert_contact(
  p_session_token text,
  p_store_id uuid,
  p_contact_id uuid default null,
  p_payload jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record; v_id uuid; v_phone text; v_tag uuid; v_label text; v_label_id uuid;
  v_current public.whatsapp_contacts%rowtype;
  v_has_opt_in boolean := p_payload ? 'marketing_opt_in' or p_payload ? 'opt_in';
  v_opt_in boolean := coalesce(nullif(coalesce(p_payload->>'marketing_opt_in',p_payload->>'opt_in'),'')::boolean,false);
  v_phone_changed boolean:=false;
begin
  select * into v_session from app_private.session_user(p_session_token);
  if not app_private.whatsapp_store_allowed(v_session.admin_user_id, v_session.user_id, v_session.user_role, v_session.user_store_id, p_store_id, false)
  then raise exception 'Cliente nao encontrado ou sem permissao.'; end if;
  if p_contact_id is not null then
    select * into v_current from public.whatsapp_contacts c where c.id=p_contact_id and c.store_id=p_store_id and c.admin_user_id=v_session.admin_user_id;
    if not found then raise exception 'Contato nao encontrado.'; end if;
  end if;
  v_phone := app_private.whatsapp_normalize_phone(coalesce(p_payload->>'phone',p_payload->>'phone_e164',v_current.phone_e164));
  v_phone_changed:=p_contact_id is not null and v_phone is distinct from v_current.phone_e164;
  if v_phone_changed and exists(
    select 1 from public.whatsapp_send_queue queue
    join public.whatsapp_messages message on message.id=queue.message_id
    where message.contact_id=p_contact_id and queue.status='processing'
  ) then
    raise exception 'Aguarde o envio em processamento terminar antes de trocar o telefone.';
  end if;
  if v_has_opt_in and v_opt_in then perform app_private.whatsapp_validate_opt_in(p_payload); end if;

  if p_contact_id is null then
    insert into public.whatsapp_contacts (
      admin_user_id, store_id, wa_id, phone_e164, name, profile_name, email,
      company, language_code, notes, internal_notes, custom_fields,
      marketing_opt_in,opt_in_source,opt_in_at,opt_in_purpose,opt_in_categories,
      opt_in_text_version,opt_in_evidence,opt_out_at,revoked_at,
      is_favorite, is_blocked,
      created_by, updated_by
    ) values (
      v_session.admin_user_id, p_store_id, nullif(btrim(p_payload->>'wa_id'), ''), v_phone,
      left(btrim(coalesce(p_payload->>'name', '')), 200), left(btrim(coalesce(p_payload->>'profile_name', '')), 200),
      nullif(left(lower(btrim(p_payload->>'email')), 320), ''), nullif(left(btrim(p_payload->>'company'), 200), ''),
      nullif(left(btrim(p_payload->>'language_code'), 20), ''), nullif(left(p_payload->>'notes', 10000), ''),nullif(left(p_payload->>'internal_notes',20000),''),
      app_private.whatsapp_json_size_guard(coalesce(p_payload->'custom_fields', '{}'::jsonb), 65536, 'Campos personalizados'),
      v_opt_in,
      case when v_opt_in then nullif(left(btrim(p_payload->>'opt_in_source'),160),'') else null end,
      case when v_opt_in then (p_payload->>'opt_in_at')::timestamptz else null end,
      case when v_opt_in then nullif(left(btrim(p_payload->>'opt_in_purpose'),500),'') else null end,
      case when v_opt_in then coalesce(array(select jsonb_array_elements_text(coalesce(p_payload->'opt_in_categories','[]'::jsonb))),'{}'::text[]) else '{}'::text[] end,
      case when v_opt_in then nullif(left(btrim(p_payload->>'opt_in_text_version'),160),'') else null end,
      case when v_opt_in then app_private.whatsapp_json_size_guard((p_payload->'opt_in_evidence')||jsonb_build_object('recorded_by',v_session.user_id,'recorded_at',now(),'consented_phone',v_phone),131072,'Evidencia do consentimento') else '{}'::jsonb end,
      case when v_opt_in then null else nullif(p_payload->>'opt_out_at','')::timestamptz end,
      case when v_opt_in then null else nullif(p_payload->>'revoked_at','')::timestamptz end,
      coalesce((p_payload->>'is_favorite')::boolean, false), coalesce((p_payload->>'is_blocked')::boolean, false),
      v_session.user_id, v_session.user_id
    )
    on conflict (store_id, phone_e164) do update set
      wa_id = coalesce(excluded.wa_id, whatsapp_contacts.wa_id), name = excluded.name,
      email = excluded.email, company = excluded.company, language_code = excluded.language_code,
      notes = excluded.notes,internal_notes=excluded.internal_notes, custom_fields = excluded.custom_fields,
      marketing_opt_in=case when v_has_opt_in or p_payload ? 'opt_out_at' or p_payload ? 'revoked_at' then excluded.marketing_opt_in else whatsapp_contacts.marketing_opt_in end,
      opt_in_source=case when v_has_opt_in then excluded.opt_in_source else whatsapp_contacts.opt_in_source end,
      opt_in_at=case when v_has_opt_in then excluded.opt_in_at else whatsapp_contacts.opt_in_at end,
      opt_in_purpose=case when v_has_opt_in then excluded.opt_in_purpose else whatsapp_contacts.opt_in_purpose end,
      opt_in_categories=case when v_has_opt_in then excluded.opt_in_categories else whatsapp_contacts.opt_in_categories end,
      opt_in_text_version=case when v_has_opt_in then excluded.opt_in_text_version else whatsapp_contacts.opt_in_text_version end,
      opt_in_evidence=case when v_has_opt_in then excluded.opt_in_evidence else whatsapp_contacts.opt_in_evidence end,
      opt_out_at=case when v_has_opt_in and v_opt_in then null when v_has_opt_in or p_payload ? 'opt_out_at' then coalesce(excluded.opt_out_at,now()) else whatsapp_contacts.opt_out_at end,
      revoked_at=case when v_has_opt_in and v_opt_in then null when p_payload ? 'revoked_at' then coalesce(excluded.revoked_at,now()) else whatsapp_contacts.revoked_at end,
      is_favorite = excluded.is_favorite, is_blocked = excluded.is_blocked,
      is_active = true, deleted_at = null, updated_by = v_session.user_id
    returning id into v_id;
  else
    update public.whatsapp_contacts set
      wa_id = case when v_phone_changed then null when p_payload ? 'wa_id' then nullif(btrim(p_payload->>'wa_id'), '') else wa_id end,
      phone_e164 = v_phone,
      name = case when p_payload ? 'name' then left(btrim(p_payload->>'name'), 200) else name end,
      profile_name=case when v_phone_changed then '' else profile_name end,
      profile_picture_url=case when v_phone_changed then null else profile_picture_url end,
      email = case when p_payload ? 'email' then nullif(left(lower(btrim(p_payload->>'email')), 320), '') else email end,
      company = case when p_payload ? 'company' then nullif(left(btrim(p_payload->>'company'), 200), '') else company end,
      language_code = case when p_payload ? 'language_code' then nullif(left(btrim(p_payload->>'language_code'), 20), '') else language_code end,
      notes = case when p_payload ? 'notes' then nullif(left(p_payload->>'notes', 10000), '') else notes end,
      internal_notes=case when p_payload ? 'internal_notes' then nullif(left(p_payload->>'internal_notes',20000),'') else internal_notes end,
      custom_fields = case when p_payload ? 'custom_fields' then app_private.whatsapp_json_size_guard(p_payload->'custom_fields', 65536, 'Campos personalizados') else custom_fields end,
      marketing_opt_in=case when p_payload ? 'opt_out_at' or p_payload ? 'revoked_at' then false when v_phone_changed and not (v_has_opt_in and v_opt_in) then false when v_has_opt_in then v_opt_in else marketing_opt_in end,
      opt_in_source=case when v_has_opt_in and v_opt_in then nullif(left(btrim(p_payload->>'opt_in_source'),160),'') when v_has_opt_in then null else opt_in_source end,
      opt_in_at=case when v_has_opt_in and v_opt_in then (p_payload->>'opt_in_at')::timestamptz when v_has_opt_in then null else opt_in_at end,
      opt_in_purpose=case when v_has_opt_in and v_opt_in then nullif(left(btrim(p_payload->>'opt_in_purpose'),500),'') when v_has_opt_in then null else opt_in_purpose end,
      opt_in_categories=case when v_has_opt_in and v_opt_in then coalesce(array(select jsonb_array_elements_text(coalesce(p_payload->'opt_in_categories','[]'::jsonb))),'{}'::text[]) when v_has_opt_in then '{}'::text[] else opt_in_categories end,
      opt_in_text_version=case when v_has_opt_in and v_opt_in then nullif(left(btrim(p_payload->>'opt_in_text_version'),160),'') when v_has_opt_in then null else opt_in_text_version end,
      opt_in_evidence=case when v_has_opt_in and v_opt_in then app_private.whatsapp_json_size_guard((p_payload->'opt_in_evidence')||jsonb_build_object('recorded_by',v_session.user_id,'recorded_at',now(),'consented_phone',v_phone),131072,'Evidencia do consentimento') when v_has_opt_in then '{}'::jsonb else opt_in_evidence end,
      opt_out_at=case when v_has_opt_in and v_opt_in then null when v_phone_changed or v_has_opt_in or p_payload ? 'opt_out_at' then coalesce(nullif(p_payload->>'opt_out_at','')::timestamptz,now()) else opt_out_at end,
      revoked_at=case when v_has_opt_in and v_opt_in then null when v_phone_changed or p_payload ? 'revoked_at' then coalesce(nullif(p_payload->>'revoked_at','')::timestamptz,now()) else revoked_at end,
      is_favorite = case when p_payload ? 'is_favorite' then (p_payload->>'is_favorite')::boolean else is_favorite end,
      is_blocked = case when p_payload ? 'is_blocked' then (p_payload->>'is_blocked')::boolean else is_blocked end,
      updated_by = v_session.user_id
    where id = p_contact_id and store_id = p_store_id and admin_user_id = v_session.admin_user_id
    returning id into v_id;
    if v_id is null then raise exception 'Contato nao encontrado.'; end if;
  end if;

  if p_payload ? 'tag_ids' or p_payload ? 'labels' then
    delete from public.whatsapp_contact_tags where contact_id = v_id;
  end if;
  if p_payload ? 'tag_ids' then
    for v_tag in select value::uuid from jsonb_array_elements_text(coalesce(p_payload->'tag_ids', '[]'::jsonb)) loop
      insert into public.whatsapp_contact_tags(contact_id, tag_id)
      select v_id, t.id from public.whatsapp_tags t where t.id = v_tag and t.store_id = p_store_id and t.is_active
      on conflict do nothing;
    end loop;
  end if;
  if p_payload ? 'labels' then
    for v_label in select btrim(value) from jsonb_array_elements_text(coalesce(p_payload->'labels','[]'::jsonb)) loop
      if length(v_label)=0 then continue; end if;
      insert into public.whatsapp_tags(admin_user_id,store_id,name,color,is_active)
      values(v_session.admin_user_id,p_store_id,left(v_label,80),'#2f80ed',true)
      on conflict(store_id,name) do update set is_active=true returning id into v_label_id;
      insert into public.whatsapp_contact_tags(contact_id,tag_id) values(v_id,v_label_id) on conflict do nothing;
    end loop;
  end if;
  if v_phone_changed then
    update public.whatsapp_conversations set customer_service_window_expires_at=null
    where contact_id=v_id;
    update public.whatsapp_send_queue queue set status='cancelled',completed_at=now(),
      last_error_code='contact_phone_changed',last_error_message='Envio cancelado porque o telefone do contato foi alterado.'
    from public.whatsapp_messages message
    where queue.message_id=message.id and message.contact_id=v_id and queue.status in ('pending','retry');
    update public.whatsapp_messages set status='cancelled',error_code='contact_phone_changed',
      error_message='Envio cancelado porque o telefone do contato foi alterado.'
    where contact_id=v_id and status='queued';
    update public.whatsapp_campaign_recipients recipient set status='cancelled',
      error_code='contact_phone_changed',error_message='Telefone alterado depois da criacao da audiencia.'
    where recipient.contact_id=v_id and recipient.status in ('pending','queued');
    update public.whatsapp_campaigns campaign set
      queued_count=(select count(*) from public.whatsapp_campaign_recipients recipient where recipient.campaign_id=campaign.id and recipient.status in ('queued','processing','sent','delivered','read')),
      cancelled_count=(select count(*) from public.whatsapp_campaign_recipients recipient where recipient.campaign_id=campaign.id and recipient.status='cancelled')
    where exists(
      select 1 from public.whatsapp_campaign_recipients recipient
      where recipient.campaign_id=campaign.id and recipient.contact_id=v_id
    );
    update public.whatsapp_campaigns campaign set status='completed',completed_at=now()
    where campaign.status='running' and exists(
      select 1 from public.whatsapp_campaign_recipients recipient
      where recipient.campaign_id=campaign.id and recipient.contact_id=v_id
    ) and not exists(
      select 1 from public.whatsapp_campaign_recipients recipient
      where recipient.campaign_id=campaign.id and recipient.status in ('pending','queued','processing')
    );
  end if;
  return v_id;
end;
$$;

create or replace function public.wa_delete_contact(p_session_token text, p_contact_id uuid)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);
  update public.whatsapp_contacts c set is_active = false, deleted_at = now(), updated_by = v_session.user_id
  where c.id = p_contact_id and c.admin_user_id = v_session.admin_user_id
    and app_private.whatsapp_store_allowed(v_session.admin_user_id, v_session.user_id, v_session.user_role, v_session.user_store_id, c.store_id, false);
  if not found then raise exception 'Contato nao encontrado ou sem permissao.'; end if;
  update public.whatsapp_conversations set status = 'archived', archived_at = now() where contact_id = p_contact_id;
  return true;
end;
$$;

drop function if exists public.wa_list_campaigns(text,uuid,text,integer,integer);
create or replace function public.wa_list_campaigns(
  p_session_token text, p_store_id uuid, p_status text default null,
  p_limit integer default 50, p_offset integer default 0,
  p_search text default null
)
returns jsonb
language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_session record; v_items jsonb; v_total bigint; v_limit integer := least(greatest(coalesce(p_limit,50),1),200); v_offset integer := greatest(coalesce(p_offset,0),0);
begin
  select * into v_session from app_private.session_user(p_session_token);
  if not app_private.whatsapp_store_allowed(v_session.admin_user_id,v_session.user_id,v_session.user_role,v_session.user_store_id,p_store_id,false)
  then raise exception 'Cliente nao encontrado ou sem permissao.'; end if;
  select count(*) into v_total
  from public.whatsapp_campaigns c
  join public.whatsapp_templates t on t.id=c.template_id
  join public.whatsapp_connections conn on conn.id=c.connection_id
  where c.store_id=p_store_id
    and (nullif(p_status,'') is null or c.status=p_status)
    and (
      nullif(btrim(coalesce(p_search,'')),'') is null
      or c.name ilike '%'||btrim(p_search)||'%'
      or t.name ilike '%'||btrim(p_search)||'%'
      or conn.name ilike '%'||btrim(p_search)||'%'
    );
  with page as (
    select c.*, t.name as template_name, t.language_code as template_language, conn.name as connection_name
    from public.whatsapp_campaigns c
    join public.whatsapp_templates t on t.id=c.template_id
    join public.whatsapp_connections conn on conn.id=c.connection_id
    where c.store_id=p_store_id
      and (nullif(p_status,'') is null or c.status=p_status)
      and (
        nullif(btrim(coalesce(p_search,'')),'') is null
        or c.name ilike '%'||btrim(p_search)||'%'
        or t.name ilike '%'||btrim(p_search)||'%'
        or conn.name ilike '%'||btrim(p_search)||'%'
      )
    order by c.created_at desc limit v_limit offset v_offset
  ) select coalesce(jsonb_agg(to_jsonb(page)-'admin_user_id' order by created_at desc),'[]'::jsonb) into v_items from page;
  return jsonb_build_object('items',v_items,'total',v_total,'limit',v_limit,'offset',v_offset);
end;
$$;

create or replace function public.wa_upsert_campaign(
  p_session_token text, p_store_id uuid, p_campaign_id uuid default null,
  p_payload jsonb default '{}'::jsonb
)
returns uuid
language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_id uuid;
  v_connection uuid:=nullif(p_payload->>'connection_id','')::uuid;
  v_template uuid:=nullif(p_payload->>'template_id','')::uuid;
  v_audience jsonb:=coalesce(p_payload->'audience_filter','{}'::jsonb);
  v_audience_mode text:=lower(coalesce(nullif(p_payload->>'audience_mode',''),nullif(p_payload#>>'{audience_filter,mode}',''),case when p_payload ? 'contact_ids' then 'selected' else 'selected' end));
  v_existing public.whatsapp_campaigns%rowtype;
begin
  select * into v_session from app_private.session_user(p_session_token);
  if not app_private.whatsapp_store_allowed(v_session.admin_user_id,v_session.user_id,v_session.user_role,v_session.user_store_id,p_store_id,false)
  then raise exception 'Cliente nao encontrado ou sem permissao.'; end if;
  if not exists(select 1 from public.whatsapp_connections c where c.id=v_connection and c.store_id=p_store_id) then raise exception 'Conexao invalida.'; end if;
  if not exists(select 1 from public.whatsapp_templates t where t.id=v_template and t.connection_id=v_connection and upper(t.status)='APPROVED') then raise exception 'Escolha um template aprovado.'; end if;
  if length(btrim(coalesce(p_payload->>'name',''))) = 0 then raise exception 'Informe o nome da campanha.'; end if;
  if v_audience_mode not in ('selected','all_opted_in') then raise exception 'Modo de audiencia invalido.'; end if;
  if p_payload ? 'contact_ids' and jsonb_typeof(p_payload->'contact_ids')<>'array' then raise exception 'Lista de contatos invalida.'; end if;
  if v_audience ? 'tag_ids' and jsonb_typeof(v_audience->'tag_ids')<>'array' then raise exception 'Filtro de etiquetas invalido.'; end if;
  if v_audience ? 'exclude_tag_ids' and jsonb_typeof(v_audience->'exclude_tag_ids')<>'array' then raise exception 'Filtro de exclusao de etiquetas invalido.'; end if;
  if v_audience ? 'exclude_contact_ids' and jsonb_typeof(v_audience->'exclude_contact_ids')<>'array' then raise exception 'Filtro de exclusao de contatos invalido.'; end if;
  if jsonb_typeof(coalesce(p_payload->'template_parameters','[]'::jsonb))<>'array' then raise exception 'Parametros do template devem ser uma lista JSON.'; end if;
  v_audience:=app_private.whatsapp_json_size_guard(v_audience||jsonb_build_object('mode',v_audience_mode),65536,'Filtro da audiencia');
  if p_campaign_id is not null then
    select * into v_existing from public.whatsapp_campaigns campaign
    where campaign.id=p_campaign_id and campaign.store_id=p_store_id
      and campaign.admin_user_id=v_session.admin_user_id
      and campaign.status in ('draft','scheduled','paused')
    for update;
    if not found then raise exception 'Campanha nao encontrada ou nao pode mais ser editada.'; end if;
    if v_existing.started_at is not null and (
      v_connection<>v_existing.connection_id
      or v_template<>v_existing.template_id
      or (p_payload ? 'scheduled_at' and nullif(p_payload->>'scheduled_at','')::timestamptz is distinct from v_existing.scheduled_at)
      or coalesce(p_payload->'template_parameters',v_existing.template_parameters)<>v_existing.template_parameters
      or p_payload ? 'contact_ids'
      or p_payload ? 'audience_filter'
      or p_payload ? 'audience_mode'
      or coalesce((p_payload->>'resolve_audience')::boolean,false)
    ) then
      raise exception 'Conexao, template, parametros, agendamento e audiencia ficam imutaveis depois do primeiro envio. Duplique a campanha para altera-los.';
    end if;
  end if;

  if p_campaign_id is null then
    insert into public.whatsapp_campaigns(admin_user_id,store_id,connection_id,template_id,name,status,scheduled_at,messages_per_second,audience_filter,template_parameters,created_by,updated_by)
    values(v_session.admin_user_id,p_store_id,v_connection,v_template,left(btrim(p_payload->>'name'),200),'draft',nullif(p_payload->>'scheduled_at','')::timestamptz,
      least(greatest(coalesce(nullif(p_payload->>'messages_per_second','')::numeric,5),0.1),80),
      v_audience,
      app_private.whatsapp_json_size_guard(coalesce(p_payload->'template_parameters','[]'::jsonb),65536,'Parametros do template'),v_session.user_id,v_session.user_id)
    returning id into v_id;
  else
    update public.whatsapp_campaigns set connection_id=v_connection,template_id=v_template,name=left(btrim(p_payload->>'name'),200),
      scheduled_at=case when p_payload ? 'scheduled_at' then nullif(p_payload->>'scheduled_at','')::timestamptz else scheduled_at end,
      messages_per_second=least(greatest(coalesce(nullif(p_payload->>'messages_per_second','')::numeric,messages_per_second),0.1),80),
      audience_filter=case when p_payload ? 'audience_filter' or p_payload ? 'audience_mode' then v_audience else audience_filter end,
      template_parameters=app_private.whatsapp_json_size_guard(coalesce(p_payload->'template_parameters',template_parameters),65536,'Parametros do template'),updated_by=v_session.user_id
    where id=p_campaign_id and store_id=p_store_id and status in ('draft','scheduled','paused') returning id into v_id;
    if v_id is null then raise exception 'Campanha nao encontrada ou nao pode mais ser editada.'; end if;
  end if;

  if p_payload ? 'contact_ids' or v_audience_mode='all_opted_in' or coalesce((p_payload->>'resolve_audience')::boolean,false) then
    if exists(
      select 1 from public.whatsapp_campaigns campaign
      where campaign.id=v_id and (
        campaign.status not in ('draft','scheduled')
        or campaign.started_at is not null
        or exists(
          select 1 from public.whatsapp_campaign_recipients recipient
          where recipient.campaign_id=campaign.id and recipient.status<>'pending'
        )
      )
    ) then
      raise exception 'A audiencia fica imutavel depois que a campanha inicia. Duplique a campanha para usar outro publico.';
    end if;
    delete from public.whatsapp_campaign_recipients where campaign_id=v_id;
    insert into public.whatsapp_campaign_recipients(admin_user_id,store_id,campaign_id,contact_id)
    select v_session.admin_user_id,p_store_id,v_id,c.id
    from public.whatsapp_contacts c
    where c.store_id=p_store_id and c.is_active and not c.is_blocked
      and app_private.whatsapp_marketing_consent_active(c)
      and (
        v_audience_mode='all_opted_in'
        or c.id in (select value::uuid from jsonb_array_elements_text(coalesce(p_payload->'contact_ids','[]'::jsonb)))
      )
      and (
        nullif(btrim(coalesce(v_audience->>'search','')),'') is null
        or c.name ilike '%'||btrim(v_audience->>'search')||'%'
        or (regexp_replace(v_audience->>'search','[^0-9+]','','g')<>'' and c.phone_e164 ilike '%'||regexp_replace(v_audience->>'search','[^0-9+]','','g')||'%')
        or c.email ilike '%'||btrim(v_audience->>'search')||'%'
      )
      and (not coalesce((v_audience->>'favorites_only')::boolean,false) or c.is_favorite)
      and (
        not (v_audience ? 'tag_ids') or jsonb_array_length(v_audience->'tag_ids')=0
        or exists(
          select 1 from public.whatsapp_contact_tags ct
          where ct.contact_id=c.id and ct.tag_id in (
            select value::uuid from jsonb_array_elements_text(coalesce(v_audience->'tag_ids','[]'::jsonb))
          )
        )
      )
      and (
        not (v_audience ? 'exclude_tag_ids') or jsonb_array_length(v_audience->'exclude_tag_ids')=0
        or not exists(
          select 1 from public.whatsapp_contact_tags ct
          where ct.contact_id=c.id and ct.tag_id in (
            select value::uuid from jsonb_array_elements_text(coalesce(v_audience->'exclude_tag_ids','[]'::jsonb))
          )
        )
      )
      and (
        not (v_audience ? 'exclude_contact_ids') or jsonb_array_length(v_audience->'exclude_contact_ids')=0
        or c.id not in (
          select value::uuid from jsonb_array_elements_text(coalesce(v_audience->'exclude_contact_ids','[]'::jsonb))
        )
      )
    on conflict do nothing;
    update public.whatsapp_campaigns set total_recipients=(select count(*) from public.whatsapp_campaign_recipients r where r.campaign_id=v_id) where id=v_id;
  end if;
  return v_id;
end;
$$;

create or replace function app_private.whatsapp_enqueue_campaign(p_campaign_id uuid, p_actor_user_id uuid default null)
returns integer
language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_campaign record; v_recipient record; v_conversation uuid; v_message uuid; v_count integer := 0; v_key text;v_parameters jsonb;v_capacity integer;
begin
  select c.*,t.name as template_name,t.language_code,t.components into v_campaign
  from public.whatsapp_campaigns c join public.whatsapp_templates t on t.id=c.template_id
  where c.id=p_campaign_id for update;
  if not found then return 0; end if;
  if upper((select status from public.whatsapp_templates where id=v_campaign.template_id)) <> 'APPROVED' then raise exception 'Template nao esta aprovado.'; end if;
  if not exists(select 1 from public.whatsapp_connections where id=v_campaign.connection_id and status in ('connected','token_expiring')) then raise exception 'Conexao da campanha nao esta ativa.'; end if;
  if jsonb_typeof(v_campaign.template_parameters)<>'array' then raise exception 'Parametros da campanha sao invalidos.'; end if;

  update public.whatsapp_campaign_recipients recipient set
    status='cancelled',error_code='marketing_consent_invalid',
    error_message='Contato bloqueado, removido ou sem consentimento valido no momento da materializacao.'
  where recipient.campaign_id=p_campaign_id and recipient.status='pending'
    and not exists(
      select 1 from public.whatsapp_contacts contact
      where contact.id=recipient.contact_id and contact.is_active and not contact.is_blocked
        and app_private.whatsapp_marketing_consent_active(contact)
    );

  select greatest(500-count(*)::integer,0) into v_capacity
  from public.whatsapp_send_queue queue_item
  where queue_item.campaign_id=p_campaign_id
    and queue_item.status in ('pending','retry','processing');

  for v_recipient in
    select r.*,ct.phone_e164 from public.whatsapp_campaign_recipients r join public.whatsapp_contacts ct on ct.id=r.contact_id
    where r.campaign_id=p_campaign_id and r.status='pending' and ct.is_active and not ct.is_blocked
      and app_private.whatsapp_marketing_consent_active(ct)
    order by r.created_at limit least(100,v_capacity) for update of r skip locked
  loop
    insert into public.whatsapp_conversations(admin_user_id,store_id,connection_id,contact_id,status)
    values(v_campaign.admin_user_id,v_campaign.store_id,v_campaign.connection_id,v_recipient.contact_id,'open')
    on conflict(connection_id,contact_id) do update set status=case when whatsapp_conversations.status='archived' then 'open' else whatsapp_conversations.status end
    returning id into v_conversation;
    v_key := 'campaign:'||p_campaign_id::text||':recipient:'||v_recipient.id::text;
    v_parameters:=case when jsonb_typeof(v_recipient.resolved_parameters)='array' and jsonb_array_length(v_recipient.resolved_parameters)>0 then v_recipient.resolved_parameters else v_campaign.template_parameters end;
    insert into public.whatsapp_messages(admin_user_id,store_id,connection_id,conversation_id,contact_id,idempotency_key,direction,message_type,status,template_name,template_language,template_parameters,created_by)
    values(v_campaign.admin_user_id,v_campaign.store_id,v_campaign.connection_id,v_conversation,v_recipient.contact_id,v_key,'outbound','template','queued',v_campaign.template_name,v_campaign.language_code,
      v_parameters,p_actor_user_id)
    on conflict(connection_id,idempotency_key) do update set updated_at=now() returning id into v_message;
    insert into public.whatsapp_send_queue(admin_user_id,store_id,connection_id,message_id,campaign_id,campaign_recipient_id,idempotency_key,payload,status,available_at)
    values(v_campaign.admin_user_id,v_campaign.store_id,v_campaign.connection_id,v_message,p_campaign_id,v_recipient.id,v_key,
      jsonb_build_object('messaging_product','whatsapp','to',regexp_replace(v_recipient.phone_e164,'[^0-9]','','g'),'type','template','biz_opaque_callback_data',v_key,'template',jsonb_build_object('name',v_campaign.template_name,'language',jsonb_build_object('code',v_campaign.language_code),'components',v_parameters)),
      'pending',now()+make_interval(secs=>(v_count/greatest(v_campaign.messages_per_second,0.1))::double precision)) on conflict(connection_id,idempotency_key) do nothing;
    update public.whatsapp_campaign_recipients set status='queued',message_id=v_message,queued_at=coalesce(queued_at,now()),error_code=null,error_message=null where id=v_recipient.id;
    v_count:=v_count+1;
  end loop;
  update public.whatsapp_campaigns campaign set
    status=case when exists(
      select 1 from public.whatsapp_campaign_recipients recipient
      where recipient.campaign_id=p_campaign_id and recipient.status in ('pending','queued','processing')
    ) then 'running' else 'completed' end,
    started_at=coalesce(started_at,now()),paused_at=null,
    completed_at=case when exists(
      select 1 from public.whatsapp_campaign_recipients recipient
      where recipient.campaign_id=p_campaign_id and recipient.status in ('pending','queued','processing')
    ) then null else coalesce(completed_at,now()) end,
    queued_count=(select count(*) from public.whatsapp_campaign_recipients where campaign_id=p_campaign_id and status in ('queued','processing','sent','delivered','read')),
    cancelled_count=(select count(*) from public.whatsapp_campaign_recipients where campaign_id=p_campaign_id and status='cancelled')
  where campaign.id=p_campaign_id;
  return v_count;
end;
$$;

create or replace function public.wa_campaign_action(p_session_token text,p_campaign_id uuid,p_action text)
returns jsonb
language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_session record; v_campaign record; v_count integer:=0; v_action text:=lower(btrim(coalesce(p_action,'')));
begin
  select * into v_session from app_private.session_user(p_session_token);
  select c.* into v_campaign from public.whatsapp_campaigns c where c.id=p_campaign_id and c.admin_user_id=v_session.admin_user_id
    and app_private.whatsapp_store_allowed(v_session.admin_user_id,v_session.user_id,v_session.user_role,v_session.user_store_id,c.store_id,false) for update;
  if not found then raise exception 'Campanha nao encontrada ou sem permissao.'; end if;
  if v_action in ('start','start_now','force_start') then
    if v_campaign.status not in ('draft','scheduled','paused') then
      raise exception 'Campanha nao pode ser iniciada neste estado. Duplique campanhas encerradas ou com falha para preservar o historico.';
    end if;
    if v_campaign.total_recipients=0 then raise exception 'A campanha nao possui destinatarios.'; end if;
    if not exists(select 1 from public.whatsapp_connections where id=v_campaign.connection_id and status in ('connected','token_expiring')) then raise exception 'A conexao da campanha nao esta ativa.'; end if;
    if not exists(select 1 from public.whatsapp_templates where id=v_campaign.template_id and connection_id=v_campaign.connection_id and upper(status)='APPROVED') then raise exception 'O template da campanha nao esta aprovado.'; end if;
    if v_action='start' and v_campaign.scheduled_at is not null and v_campaign.scheduled_at>now() then
      update public.whatsapp_campaigns set status='scheduled',updated_by=v_session.user_id where id=p_campaign_id;
    else
      if v_action in ('start_now','force_start') then
        update public.whatsapp_campaigns set scheduled_at=null,updated_by=v_session.user_id where id=p_campaign_id;
      end if;
      v_count:=app_private.whatsapp_enqueue_campaign(p_campaign_id,v_session.user_id);
    end if;
  elsif v_action='pause' then
    update public.whatsapp_campaigns set status='paused',paused_at=now(),updated_by=v_session.user_id where id=p_campaign_id and status in ('running','scheduled');
    update public.whatsapp_send_queue set status='retry',available_at=greatest(available_at,now()+interval '1 day') where campaign_id=p_campaign_id and status='pending';
  elsif v_action='resume' then
    if v_campaign.status<>'paused' then raise exception 'Somente campanha pausada pode ser retomada.'; end if;
    update public.whatsapp_send_queue set status='pending',available_at=now() where campaign_id=p_campaign_id and status='retry' and attempt_count=0;
    update public.whatsapp_campaigns set status='running',paused_at=null,updated_by=v_session.user_id where id=p_campaign_id;
    v_count:=app_private.whatsapp_enqueue_campaign(p_campaign_id,v_session.user_id);
  elsif v_action='cancel' then
    if v_campaign.status in ('completed','cancelled') then raise exception 'Campanha ja foi encerrada.'; end if;
    update public.whatsapp_campaigns set status='cancelled',cancelled_at=now(),updated_by=v_session.user_id where id=p_campaign_id;
    update public.whatsapp_send_queue set status='cancelled',completed_at=now() where campaign_id=p_campaign_id and status in ('pending','retry');
    update public.whatsapp_campaign_recipients set status='cancelled' where campaign_id=p_campaign_id and status in ('pending','queued');
    update public.whatsapp_campaigns set cancelled_count=(select count(*) from public.whatsapp_campaign_recipients where campaign_id=p_campaign_id and status='cancelled') where id=p_campaign_id;
  else raise exception 'Acao de campanha invalida.'; end if;
  return jsonb_build_object('ok',true,'action',v_action,'queued',v_count,'status',(select status from public.whatsapp_campaigns where id=p_campaign_id));
end;
$$;

create or replace function public.wa_list_templates(p_session_token text,p_store_id uuid,p_connection_id uuid default null,p_status text default null)
returns jsonb language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_session record; v_result jsonb;
begin
  select * into v_session from app_private.session_user(p_session_token);
  if not app_private.whatsapp_store_allowed(v_session.admin_user_id,v_session.user_id,v_session.user_role,v_session.user_store_id,p_store_id,false) then raise exception 'Cliente nao encontrado ou sem permissao.'; end if;
  select coalesce(jsonb_agg(to_jsonb(t)-'admin_user_id' order by t.name,t.language_code),'[]'::jsonb) into v_result from public.whatsapp_templates t
  where t.store_id=p_store_id and (p_connection_id is null or t.connection_id=p_connection_id) and (nullif(p_status,'') is null or upper(t.status)=upper(p_status));
  return v_result;
end;
$$;

create or replace function public.wa_list_webhook_events(p_session_token text,p_store_id uuid,p_search text default null,p_status text default null,p_limit integer default 50,p_offset integer default 0)
returns jsonb language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_session record;v_items jsonb;v_total bigint;v_limit integer:=least(greatest(coalesce(p_limit,50),1),200);v_offset integer:=greatest(coalesce(p_offset,0),0);
begin
  select * into v_session from app_private.session_user(p_session_token);
  if not app_private.whatsapp_store_allowed(v_session.admin_user_id,v_session.user_id,v_session.user_role,v_session.user_store_id,p_store_id,false) then raise exception 'Cliente nao encontrado ou sem permissao.'; end if;
  select count(*) into v_total
  from public.whatsapp_webhook_events e
  where e.store_id=p_store_id and e.admin_user_id=v_session.admin_user_id
    and (nullif(p_status,'') is null or e.processing_status=p_status)
    and (
      nullif(btrim(coalesce(p_search,'')),'') is null
      or e.event_type ilike '%'||btrim(p_search)||'%'
      or e.provider_object ilike '%'||btrim(p_search)||'%'
      or e.provider_message_id ilike '%'||btrim(p_search)||'%'
      or e.event_key ilike '%'||btrim(p_search)||'%'
    );
  with page as(
    select
      e.id,e.store_id,e.connection_id,e.event_key,e.event_type,
      e.provider_object,e.provider_message_id,e.signature_valid,
      e.processing_status,e.processing_attempts,e.received_count,
      e.first_received_at,e.last_received_at,e.processed_at,e.next_attempt_at,
      e.last_error,e.created_at,e.updated_at
    from public.whatsapp_webhook_events e
    where e.store_id=p_store_id and e.admin_user_id=v_session.admin_user_id
      and (nullif(p_status,'') is null or e.processing_status=p_status)
      and (
        nullif(btrim(coalesce(p_search,'')),'') is null
        or e.event_type ilike '%'||btrim(p_search)||'%'
        or e.provider_object ilike '%'||btrim(p_search)||'%'
        or e.provider_message_id ilike '%'||btrim(p_search)||'%'
        or e.event_key ilike '%'||btrim(p_search)||'%'
      )
    order by e.created_at desc limit v_limit offset v_offset
  )
  select coalesce(jsonb_agg(to_jsonb(page) order by created_at desc),'[]'::jsonb) into v_items from page;
  return jsonb_build_object('items',v_items,'total',v_total,'limit',v_limit,'offset',v_offset);
end;
$$;

create or replace function public.wa_get_webhook_event(p_session_token text,p_event_id uuid)
returns jsonb language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_session record;v_result jsonb;
begin
  select * into v_session from app_private.session_user(p_session_token);
  select to_jsonb(e)-'admin_user_id'-'locked_by' into v_result
  from public.whatsapp_webhook_events e
  where e.id=p_event_id and e.admin_user_id=v_session.admin_user_id
    and app_private.whatsapp_store_allowed(
      v_session.admin_user_id,v_session.user_id,v_session.user_role,
      v_session.user_store_id,e.store_id,false
    );
  if v_result is null then raise exception 'Evento nao encontrado ou sem permissao.'; end if;
  return v_result;
end;
$$;

create or replace function public.wa_reprocess_webhook(p_session_token text,p_event_id uuid)
returns boolean language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);
  update public.whatsapp_webhook_events e set processing_status='pending',processing_attempts=0,processed_at=null,next_attempt_at=now(),last_error=null,locked_at=null,locked_by=null
  where e.id=p_event_id and e.admin_user_id=v_session.admin_user_id
    and app_private.whatsapp_store_allowed(v_session.admin_user_id,v_session.user_id,v_session.user_role,v_session.user_store_id,e.store_id,true);
  if not found then raise exception 'Evento nao encontrado ou sem permissao.'; end if;
  return true;
end;
$$;

create or replace function public.wa_list_logs(p_session_token text,p_store_id uuid,p_level text default null,p_category text default null,p_search text default null,p_limit integer default 100,p_offset integer default 0)
returns jsonb language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_session record;v_items jsonb;v_total bigint;v_limit integer:=least(greatest(coalesce(p_limit,100),1),500);v_offset integer:=greatest(coalesce(p_offset,0),0);
begin
  select * into v_session from app_private.session_user(p_session_token);
  if not app_private.whatsapp_store_allowed(v_session.admin_user_id,v_session.user_id,v_session.user_role,v_session.user_store_id,p_store_id,false) then raise exception 'Cliente nao encontrado ou sem permissao.'; end if;
  select count(*) into v_total from public.whatsapp_logs l where l.store_id=p_store_id and (nullif(p_level,'') is null or l.level=p_level) and (nullif(p_category,'') is null or l.category=p_category) and (nullif(btrim(coalesce(p_search,'')),'') is null or l.message ilike '%'||p_search||'%' or l.action ilike '%'||p_search||'%' or l.error_code ilike '%'||p_search||'%' or l.correlation_id ilike '%'||p_search||'%' or l.endpoint ilike '%'||p_search||'%' or l.request_id ilike '%'||p_search||'%');
  with page as(
    select l.id,l.store_id,l.connection_id,l.user_id,l.level,l.category,l.action,
      l.correlation_id,l.request_id,l.http_method,l.endpoint,l.http_status,
      l.latency_ms,l.success,l.error_code,l.message,l.created_at
    from public.whatsapp_logs l
    where l.store_id=p_store_id
      and (nullif(p_level,'') is null or l.level=p_level)
      and (nullif(p_category,'') is null or l.category=p_category)
      and (nullif(btrim(coalesce(p_search,'')),'') is null or l.message ilike '%'||p_search||'%' or l.action ilike '%'||p_search||'%' or l.error_code ilike '%'||p_search||'%' or l.correlation_id ilike '%'||p_search||'%' or l.endpoint ilike '%'||p_search||'%' or l.request_id ilike '%'||p_search||'%')
    order by l.created_at desc limit v_limit offset v_offset
  )
  select coalesce(jsonb_agg(to_jsonb(page) order by created_at desc),'[]'::jsonb) into v_items from page;
  return jsonb_build_object('items',v_items,'total',v_total,'limit',v_limit,'offset',v_offset);
end;
$$;

create or replace function public.wa_get_log(p_session_token text,p_log_id bigint)
returns jsonb language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_session record;v_result jsonb;
begin
  select * into v_session from app_private.session_user(p_session_token);
  select to_jsonb(l)-'admin_user_id' into v_result
  from public.whatsapp_logs l
  where l.id=p_log_id and l.admin_user_id=v_session.admin_user_id
    and app_private.whatsapp_store_allowed(
      v_session.admin_user_id,v_session.user_id,v_session.user_role,
      v_session.user_store_id,l.store_id,false
    );
  if v_result is null then raise exception 'Log nao encontrado ou sem permissao.'; end if;
  return v_result;
end;
$$;

create or replace function public.wa_disconnect_connection(p_session_token text,p_connection_id uuid)
returns boolean language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);
  update public.whatsapp_connections c set status='disconnected',disconnected_at=now(),last_error_code=null,last_error_message=null,updated_by=v_session.user_id
  where c.id=p_connection_id and c.admin_user_id=v_session.admin_user_id
    and app_private.whatsapp_store_allowed(v_session.admin_user_id,v_session.user_id,v_session.user_role,v_session.user_store_id,c.store_id,true);
  if not found then raise exception 'Conexao nao encontrada ou sem permissao.'; end if;
  update public.whatsapp_send_queue set status='retry',available_at=greatest(available_at,now()+interval '1 hour') where connection_id=p_connection_id and status='pending';
  return true;
end;
$$;

-- -----------------------------------------------------------------------------
-- RPCs exclusivas das Edge Functions (service_role)
-- -----------------------------------------------------------------------------

create or replace function public.wa_service_save_connection(
  p_session_token text,
  p_payload jsonb,
  p_encryption_key text
)
returns jsonb
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_connection public.whatsapp_connections%rowtype;
  v_connection_id uuid := nullif(p_payload->>'connection_id', '')::uuid;
  v_store_id uuid := nullif(p_payload->>'store_id', '')::uuid;
  v_existing_secrets jsonb := '{}'::jsonb;
  v_new_secrets jsonb := '{}'::jsonb;
  v_verify_token text;
  v_phone text;
  v_target_waba text;
  v_target_app text;
  v_sibling record;
  v_sibling_secrets jsonb;
begin
  if length(coalesce(p_encryption_key, '')) < 32 then
    raise exception 'Chave de criptografia do WhatsApp ausente ou insegura.';
  end if;
  select * into v_session from app_private.session_user(p_session_token);

  if v_connection_id is not null then
    select * into v_connection from public.whatsapp_connections c
    where c.id = v_connection_id and c.admin_user_id = v_session.admin_user_id;
    if not found then raise exception 'Conexao nao encontrada.'; end if;
    v_store_id := v_connection.store_id;
  end if;
  if not app_private.whatsapp_store_allowed(
    v_session.admin_user_id, v_session.user_id, v_session.user_role,
    v_session.user_store_id, v_store_id, true
  ) then raise exception 'Somente o Admin ou a Agencia responsavel podem configurar esta loja.'; end if;

  if v_connection_id is not null and exists (
    select 1 from app_private.whatsapp_connection_secrets s where s.connection_id = v_connection_id
  ) then
    begin
      select extensions.pgp_sym_decrypt(s.secret_cipher, p_encryption_key)::jsonb
      into v_existing_secrets
      from app_private.whatsapp_connection_secrets s where s.connection_id = v_connection_id;
    exception when others then
      raise exception 'Nao foi possivel decifrar as credenciais atuais. Verifique WHATSAPP_CREDENTIAL_ENCRYPTION_KEY.';
    end;
  end if;

  v_new_secrets := v_existing_secrets || jsonb_strip_nulls(jsonb_build_object(
    'access_token', nullif(btrim(p_payload->>'access_token'), ''),
    'app_secret', nullif(btrim(p_payload->>'app_secret'), ''),
    'verify_token', nullif(btrim(p_payload->>'verify_token'), '')
  ));
  if nullif(v_new_secrets->>'access_token', '') is null
     or nullif(v_new_secrets->>'app_secret', '') is null
     or nullif(v_new_secrets->>'verify_token', '') is null then
    raise exception 'Access Token, App Secret e Verify Token sao obrigatorios.';
  end if;
  if length(v_new_secrets->>'access_token')<20 or length(v_new_secrets->>'access_token')>8192 then raise exception 'Access Token possui tamanho invalido.'; end if;
  if length(v_new_secrets->>'app_secret')<16 or length(v_new_secrets->>'app_secret')>512 then raise exception 'App Secret possui tamanho invalido.'; end if;
  if length(v_new_secrets->>'verify_token')<16 or length(v_new_secrets->>'verify_token')>512 then raise exception 'Verify Token deve possuir entre 16 e 512 caracteres.'; end if;
  v_verify_token := v_new_secrets->>'verify_token';

  if nullif(btrim(coalesce(p_payload->>'phone_number_id', v_connection.phone_number_id)), '') is null then raise exception 'Phone Number ID obrigatorio.'; end if;
  if nullif(btrim(coalesce(p_payload->>'business_account_id', v_connection.business_account_id)), '') is null then raise exception 'Business Account ID obrigatorio.'; end if;
  if length(btrim(coalesce(p_payload->>'app_id', v_connection.app_id, '')))<3 then raise exception 'App ID obrigatorio.'; end if;
  if nullif(btrim(coalesce(p_payload->>'name', v_connection.name)), '') is null then raise exception 'Nome da conexao obrigatorio.'; end if;
  v_target_waba:=btrim(coalesce(nullif(p_payload->>'business_account_id',''),v_connection.business_account_id));
  v_target_app:=btrim(coalesce(nullif(p_payload->>'app_id',''),v_connection.app_id));
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('whatsapp:waba:'||v_target_waba,0));
  for v_sibling in
    select c.id,s.secret_cipher
    from public.whatsapp_connections c
    join app_private.whatsapp_connection_secrets s on s.connection_id=c.id
    where c.business_account_id=v_target_waba
      and c.admin_user_id=v_session.admin_user_id
      and c.app_id=v_target_app
      and (v_connection_id is null or c.id<>v_connection_id)
  loop
    begin
      v_sibling_secrets:=extensions.pgp_sym_decrypt(v_sibling.secret_cipher,p_encryption_key)::jsonb;
    exception when others then
      raise exception 'Nao foi possivel validar as credenciais irmas da conta comercial.';
    end;
    if nullif(v_sibling_secrets->>'app_secret','') is distinct from nullif(v_new_secrets->>'app_secret','') then
      raise exception 'Use o mesmo App Secret em todas as conexoes desta conta comercial.';
    end if;
  end loop;
  v_phone := regexp_replace(coalesce(p_payload->>'display_phone_number', v_connection.display_phone_number, ''), '[^0-9]', '', 'g');

  if v_connection_id is null then
    insert into public.whatsapp_connections (
      admin_user_id, store_id, name, display_phone_number, normalized_phone,
      phone_number_id, business_account_id, app_id, graph_api_version,
      webhook_url, status, token_expires_at, public_config, created_by, updated_by
    ) values (
      v_session.admin_user_id, v_store_id, left(btrim(p_payload->>'name'), 160),
      left(btrim(coalesce(p_payload->>'display_phone_number', '')), 40), v_phone,
      left(btrim(p_payload->>'phone_number_id'), 160), left(btrim(p_payload->>'business_account_id'), 160),
      left(btrim(coalesce(p_payload->>'app_id', '')), 160),
      case when coalesce(p_payload->>'graph_api_version', 'v26.0') ~ '^v[0-9]{2,3}[.][0-9]+$' then coalesce(p_payload->>'graph_api_version', 'v26.0') else 'v26.0' end,
      left(btrim(coalesce(p_payload->>'webhook_url', '')), 2000), 'draft',
      nullif(p_payload->>'token_expires_at', '')::timestamptz,
      app_private.whatsapp_json_size_guard(coalesce(p_payload->'public_config', '{}'::jsonb), 65536, 'Configuracao publica'),
      v_session.user_id, v_session.user_id
    ) returning * into v_connection;
    v_connection_id := v_connection.id;
  else
    update public.whatsapp_connections set
      name = left(btrim(coalesce(nullif(p_payload->>'name', ''), name)), 160),
      display_phone_number = left(btrim(coalesce(p_payload->>'display_phone_number', display_phone_number)), 40),
      normalized_phone = v_phone,
      phone_number_id = left(btrim(coalesce(nullif(p_payload->>'phone_number_id', ''), phone_number_id)), 160),
      business_account_id = left(btrim(coalesce(nullif(p_payload->>'business_account_id', ''), business_account_id)), 160),
      app_id = left(btrim(coalesce(p_payload->>'app_id', app_id)), 160),
      graph_api_version = case when coalesce(p_payload->>'graph_api_version', graph_api_version) ~ '^v[0-9]{2,3}[.][0-9]+$' then coalesce(p_payload->>'graph_api_version', graph_api_version) else graph_api_version end,
      webhook_url = left(btrim(coalesce(p_payload->>'webhook_url', webhook_url)), 2000),
      token_expires_at = case when p_payload ? 'token_expires_at' then nullif(p_payload->>'token_expires_at', '')::timestamptz else token_expires_at end,
      public_config = case when p_payload ? 'public_config' then app_private.whatsapp_json_size_guard(p_payload->'public_config', 65536, 'Configuracao publica') else public_config end,
      status = case
        when status = 'connected'
          and not (p_payload ? 'access_token')
          and not (p_payload ? 'app_secret')
          and not (p_payload ? 'verify_token')
          and coalesce(nullif(btrim(p_payload->>'phone_number_id'), ''), phone_number_id) = phone_number_id
          and coalesce(nullif(btrim(p_payload->>'business_account_id'), ''), business_account_id) = business_account_id
          and coalesce(btrim(p_payload->>'app_id'), app_id) is not distinct from app_id
          and coalesce(p_payload->>'graph_api_version', graph_api_version) = graph_api_version
          and coalesce(v_phone, normalized_phone, '') = coalesce(normalized_phone, '')
          and coalesce(btrim(p_payload->>'webhook_url'), webhook_url, '') = coalesce(webhook_url, '')
        then status
        else 'draft'
      end,
      updated_by = v_session.user_id
    where id = v_connection_id returning * into v_connection;
  end if;

  insert into app_private.whatsapp_connection_secrets as current_secrets (
    connection_id, secret_cipher, verify_token_hash, secret_version, rotated_at
  ) values (
    v_connection_id,
    extensions.pgp_sym_encrypt(v_new_secrets::text, p_encryption_key, 'cipher-algo=aes256,compress-algo=1'),
    encode(extensions.digest(v_verify_token, 'sha256'), 'hex'),
    coalesce((select s.secret_version + 1 from app_private.whatsapp_connection_secrets s where s.connection_id = v_connection_id), 1),
    now()
  ) on conflict (connection_id) do update set
    secret_cipher = excluded.secret_cipher,
    verify_token_hash = excluded.verify_token_hash,
    secret_version = current_secrets.secret_version + 1,
    rotated_at = now();

  insert into public.whatsapp_logs(admin_user_id,store_id,connection_id,user_id,level,category,action,success,message,metadata)
  values(v_session.admin_user_id,v_store_id,v_connection_id,v_session.user_id,'info','credential','save_connection',true,
    'Credenciais do WhatsApp atualizadas com armazenamento cifrado.',jsonb_build_object('secret_fields_updated',jsonb_build_array(
      case when p_payload ? 'access_token' then 'access_token' end,
      case when p_payload ? 'app_secret' then 'app_secret' end,
      case when p_payload ? 'verify_token' then 'verify_token' end
    )));
  return jsonb_build_object('id',v_connection_id,'store_id',v_store_id,'status',v_connection.status,'has_credentials',true);
end;
$$;

create or replace function public.wa_service_connection_runtime(
  p_session_token text, p_connection_id uuid, p_encryption_key text,
  p_configuration_write boolean default false
)
returns jsonb
language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_session record;v_connection record;v_secrets jsonb;
begin
  if length(coalesce(p_encryption_key,''))<32 then raise exception 'Chave de criptografia do WhatsApp ausente.'; end if;
  select * into v_session from app_private.session_user(p_session_token);
  select c.* into v_connection from public.whatsapp_connections c where c.id=p_connection_id and c.admin_user_id=v_session.admin_user_id
    and app_private.whatsapp_store_allowed(v_session.admin_user_id,v_session.user_id,v_session.user_role,v_session.user_store_id,c.store_id,p_configuration_write);
  if not found then raise exception 'Conexao nao encontrada ou sem permissao.'; end if;
  begin
    select extensions.pgp_sym_decrypt(s.secret_cipher,p_encryption_key)::jsonb into v_secrets from app_private.whatsapp_connection_secrets s where s.connection_id=p_connection_id;
  exception when others then raise exception 'Nao foi possivel decifrar as credenciais. Verifique WHATSAPP_CREDENTIAL_ENCRYPTION_KEY.'; end;
  if v_secrets is null then raise exception 'Credenciais da conexao nao encontradas.'; end if;
  return (to_jsonb(v_connection)-'admin_user_id'-'created_by'-'updated_by') || jsonb_build_object(
    'admin_user_id',v_session.admin_user_id,'user_id',v_session.user_id,'user_role',v_session.user_role::text,'secrets',v_secrets
  );
end;
$$;

create or replace function public.wa_service_connection_runtime_by_phone(
  p_phone_number_id text, p_encryption_key text
)
returns jsonb
language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_connection record;v_secrets jsonb;v_sibling record;v_sibling_secrets jsonb;
begin
  if length(coalesce(p_encryption_key,''))<32 then raise exception 'Chave de criptografia do WhatsApp ausente.'; end if;
  select c.* into v_connection from public.whatsapp_connections c where c.phone_number_id=btrim(p_phone_number_id);
  if not found then raise exception 'Conexao do webhook nao encontrada.'; end if;
  begin
    select extensions.pgp_sym_decrypt(s.secret_cipher,p_encryption_key)::jsonb into v_secrets from app_private.whatsapp_connection_secrets s where s.connection_id=v_connection.id;
  exception when others then raise exception 'Nao foi possivel decifrar as credenciais. Verifique WHATSAPP_CREDENTIAL_ENCRYPTION_KEY.'; end;
  if v_secrets is null then raise exception 'Credenciais da conexao nao encontradas.'; end if;
  for v_sibling in
    select c.id,s.secret_cipher
    from public.whatsapp_connections c
    join app_private.whatsapp_connection_secrets s on s.connection_id=c.id
    where c.business_account_id=v_connection.business_account_id
      and c.admin_user_id=v_connection.admin_user_id
      and c.app_id=v_connection.app_id
      and c.id<>v_connection.id
  loop
    begin
      v_sibling_secrets:=extensions.pgp_sym_decrypt(v_sibling.secret_cipher,p_encryption_key)::jsonb;
    exception when others then
      raise exception 'Nao foi possivel validar as credenciais irmas da conta comercial.';
    end;
    if nullif(v_sibling_secrets->>'app_secret','') is distinct from nullif(v_secrets->>'app_secret','') then
      raise exception 'As conexoes desta conta comercial usam App Secrets divergentes.';
    end if;
  end loop;
  return (to_jsonb(v_connection)-'created_by'-'updated_by') || jsonb_build_object('secrets',v_secrets);
end;
$$;

create or replace function public.wa_service_connection_runtime_by_id(
  p_connection_id uuid, p_encryption_key text
)
returns jsonb
language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_connection record;v_secrets jsonb;
begin
  if length(coalesce(p_encryption_key,''))<32 then raise exception 'Chave de criptografia do WhatsApp ausente.'; end if;
  select c.* into v_connection from public.whatsapp_connections c where c.id=p_connection_id;
  if not found then raise exception 'Conexao nao encontrada.'; end if;
  begin
    select extensions.pgp_sym_decrypt(s.secret_cipher,p_encryption_key)::jsonb into v_secrets from app_private.whatsapp_connection_secrets s where s.connection_id=v_connection.id;
  exception when others then raise exception 'Nao foi possivel decifrar as credenciais. Verifique WHATSAPP_CREDENTIAL_ENCRYPTION_KEY.'; end;
  if v_secrets is null then raise exception 'Credenciais da conexao nao encontradas.'; end if;
  return (to_jsonb(v_connection)-'created_by'-'updated_by') || jsonb_build_object('secrets',v_secrets);
end;
$$;

create or replace function public.wa_service_connection_runtime_by_business_account(
  p_business_account_id text, p_encryption_key text
)
returns jsonb
language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_connection record;v_secrets jsonb;v_sibling record;v_sibling_secrets jsonb;
begin
  if length(coalesce(p_encryption_key,''))<32 then raise exception 'Chave de criptografia do WhatsApp ausente.'; end if;
  if exists(
    select 1
    from public.whatsapp_connections c
    where c.business_account_id=btrim(p_business_account_id)
    group by c.business_account_id
    having count(distinct c.admin_user_id)>1
      or count(distinct btrim(c.app_id))>1
      or bool_or(length(btrim(c.app_id))<3)
  ) then
    raise exception 'A conta comercial do webhook possui vinculos inconsistentes entre tenant ou App Meta.';
  end if;
  select c.* into v_connection from public.whatsapp_connections c
  where c.business_account_id=btrim(p_business_account_id)
  order by case c.status when 'connected' then 0 when 'token_expiring' then 1 else 2 end,c.updated_at desc limit 1;
  if not found then raise exception 'Conta comercial do webhook nao encontrada.'; end if;
  begin
    select extensions.pgp_sym_decrypt(s.secret_cipher,p_encryption_key)::jsonb into v_secrets from app_private.whatsapp_connection_secrets s where s.connection_id=v_connection.id;
  exception when others then raise exception 'Nao foi possivel decifrar as credenciais. Verifique WHATSAPP_CREDENTIAL_ENCRYPTION_KEY.'; end;
  if v_secrets is null then raise exception 'Credenciais da conexao nao encontradas.'; end if;
  for v_sibling in
    select c.id,s.secret_cipher
    from public.whatsapp_connections c
    join app_private.whatsapp_connection_secrets s on s.connection_id=c.id
    where c.business_account_id=v_connection.business_account_id
      and c.admin_user_id=v_connection.admin_user_id
      and c.app_id=v_connection.app_id
      and c.id<>v_connection.id
  loop
    begin
      v_sibling_secrets:=extensions.pgp_sym_decrypt(v_sibling.secret_cipher,p_encryption_key)::jsonb;
    exception when others then
      raise exception 'Nao foi possivel validar as credenciais irmas da conta comercial.';
    end;
    if nullif(v_sibling_secrets->>'app_secret','') is distinct from nullif(v_secrets->>'app_secret','') then
      raise exception 'As conexoes desta conta comercial usam App Secrets divergentes.';
    end if;
  end loop;
  return (to_jsonb(v_connection)-'created_by'-'updated_by') || jsonb_build_object('secrets',v_secrets);
end;
$$;

create or replace function public.wa_service_connection_by_verify_token(p_verify_token text)
returns jsonb
language sql security definer
set search_path = app_private, public, extensions
as $$
  select coalesce((
    select jsonb_build_object('id',c.id,'admin_user_id',c.admin_user_id,'store_id',c.store_id,'phone_number_id',c.phone_number_id,'app_id',c.app_id,'status',c.status)
    from app_private.whatsapp_connection_secrets s join public.whatsapp_connections c on c.id=s.connection_id
    where s.verify_token_hash=encode(extensions.digest(coalesce(p_verify_token,''),'sha256'),'hex') limit 1
  ),'null'::jsonb);
$$;

create or replace function public.wa_service_set_connection_status(
  p_connection_id uuid,p_status text,p_error_code text default null,p_error_message text default null,p_metadata jsonb default '{}'::jsonb
)
returns boolean language plpgsql security definer
set search_path = app_private, public, extensions
as $$
begin
  if p_status not in ('draft','validating','connected','token_expiring','disconnected','error') then raise exception 'Status de conexao invalido.'; end if;
  update public.whatsapp_connections set status=p_status,last_error_code=nullif(left(p_error_code,160),''),last_error_message=nullif(left(p_error_message,4000),''),
    last_validated_at=case when p_status in ('connected','error') then now() else last_validated_at end,
    last_connected_at=case when p_status='connected' then now() else last_connected_at end,
    disconnected_at=case when p_status='disconnected' then now() when p_status='connected' then null else disconnected_at end,
    quality_rating=coalesce(nullif(p_metadata->>'quality_rating',''),quality_rating),
    token_expires_at=case when p_metadata ? 'token_expires_at' then nullif(p_metadata->>'token_expires_at','')::timestamptz else token_expires_at end,
    display_phone_number=coalesce(nullif(left(p_metadata->>'display_phone_number',40),''),display_phone_number),
    normalized_phone=case when nullif(p_metadata->>'display_phone_number','') is not null then regexp_replace(p_metadata->>'display_phone_number','[^0-9]','','g') else normalized_phone end,
    public_config=public_config||jsonb_strip_nulls(jsonb_build_object(
      'throughput_level',nullif(p_metadata->>'throughput_level',''),
      'whatsapp_business_manager_messaging_limit',nullif(p_metadata->>'whatsapp_business_manager_messaging_limit',''),
      'verified_name',nullif(p_metadata->>'verified_name',''),
      'provider_status',nullif(p_metadata->>'provider_status',''),
      'code_verification_status',nullif(p_metadata->>'code_verification_status',''),
      'name_status',nullif(p_metadata->>'name_status',''),
      'token_scopes',p_metadata->'token_scopes',
      'business_account_name',nullif(p_metadata->>'business_account_name',''),
      'business_account_review_status',nullif(p_metadata->>'business_account_review_status','')
    ))
  where id=p_connection_id;
  if not found then raise exception 'Conexao nao encontrada.'; end if;
  return true;
end;
$$;

create or replace function public.wa_service_log(p_payload jsonb)
returns bigint language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_id bigint;
begin
  insert into public.whatsapp_logs(admin_user_id,store_id,connection_id,user_id,level,category,action,correlation_id,request_id,http_method,endpoint,http_status,latency_ms,success,error_code,message,metadata)
  values(nullif(p_payload->>'admin_user_id','')::uuid,nullif(p_payload->>'store_id','')::uuid,nullif(p_payload->>'connection_id','')::uuid,nullif(p_payload->>'user_id','')::uuid,
    case when p_payload->>'level' in ('debug','info','warning','error','critical') then p_payload->>'level' else 'info' end,
    case when p_payload->>'category' in ('connection','credential','api','message','media','template','campaign','webhook','queue','security','system') then p_payload->>'category' else 'system' end,
    left(coalesce(nullif(p_payload->>'action',''),'unspecified'),160),nullif(left(p_payload->>'correlation_id',160),''),nullif(left(p_payload->>'request_id',160),''),
    nullif(left(p_payload->>'http_method',16),''),nullif(left(p_payload->>'endpoint',2000),''),nullif(p_payload->>'http_status','')::integer,
    greatest(coalesce(nullif(p_payload->>'latency_ms','')::integer,0),0),coalesce((p_payload->>'success')::boolean,true),nullif(left(p_payload->>'error_code',160),''),
    left(coalesce(p_payload->>'message',''),8000),app_private.whatsapp_json_size_guard(coalesce(p_payload->'metadata','{}'::jsonb),131072,'Metadados de log')) returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.wa_service_log_session(p_session_token text,p_payload jsonb)
returns bigint language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_session record;v_store_id uuid;v_connection_id uuid;v_result bigint;
begin
  select * into v_session from app_private.session_user(p_session_token);
  begin v_connection_id:=nullif(p_payload->>'connection_id','')::uuid;exception when others then v_connection_id:=null;end;
  if v_connection_id is not null then
    select connection.store_id into v_store_id
    from public.whatsapp_connections connection
    where connection.id=v_connection_id and connection.admin_user_id=v_session.admin_user_id
      and app_private.whatsapp_store_allowed(
        v_session.admin_user_id,v_session.user_id,v_session.user_role,
        v_session.user_store_id,connection.store_id,false
      );
    if not found then v_connection_id:=null;v_store_id:=null;end if;
  else
    begin v_store_id:=nullif(p_payload->>'store_id','')::uuid;exception when others then v_store_id:=null;end;
    if v_store_id is not null and not app_private.whatsapp_store_allowed(
      v_session.admin_user_id,v_session.user_id,v_session.user_role,
      v_session.user_store_id,v_store_id,false
    ) then v_store_id:=null; end if;
  end if;
  v_result:=public.wa_service_log(
    (coalesce(p_payload,'{}'::jsonb)-'admin_user_id'-'user_id'-'store_id'-'connection_id')
    ||jsonb_build_object(
      'admin_user_id',v_session.admin_user_id,'user_id',v_session.user_id,
      'store_id',v_store_id,'connection_id',v_connection_id
    )
  );
  return v_result;
end;
$$;

create or replace function public.wa_service_enqueue_message(p_session_token text,p_payload jsonb)
returns jsonb language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_store_id uuid:=nullif(p_payload->>'store_id','')::uuid;
  v_connection record;
  v_contact record;
  v_conversation record;
  v_message uuid;
  v_queue uuid;
  v_queue_status text;
  v_key text;
  v_type text:=coalesce(nullif(p_payload->>'type',''),'text');
  v_input_provider jsonb:=coalesce(p_payload->'provider_payload','{}'::jsonb);
  v_provider_payload jsonb;
  v_text text:=coalesce(p_payload->>'text',p_payload#>>'{provider_payload,text,body}');
  v_template_name text:=coalesce(p_payload->>'template_name',p_payload#>>'{provider_payload,template,name}');
  v_template_language text:=coalesce(p_payload->>'template_language',p_payload#>>'{provider_payload,template,language,code}','pt_BR');
  v_reply_to text:=coalesce(p_payload->>'reply_to_provider_message_id',p_payload#>>'{provider_payload,context,message_id}');
begin
  select * into v_session from app_private.session_user(p_session_token);
  if not app_private.whatsapp_store_allowed(v_session.admin_user_id,v_session.user_id,v_session.user_role,v_session.user_store_id,v_store_id,false) then raise exception 'Cliente nao encontrado ou sem permissao.'; end if;
  select * into v_connection from public.whatsapp_connections c where c.id=nullif(p_payload->>'connection_id','')::uuid and c.store_id=v_store_id and c.status in ('connected','token_expiring');
  if not found then raise exception 'Conexao nao esta ativa.'; end if;
  if v_type not in ('text','image','document','audio','video','sticker','location','contacts','interactive','reaction','template') then raise exception 'Tipo de mensagem invalido.'; end if;

  if nullif(p_payload->>'conversation_id','') is not null then
    select c.* into v_conversation from public.whatsapp_conversations c where c.id=(p_payload->>'conversation_id')::uuid and c.connection_id=v_connection.id;
    if not found then raise exception 'Conversa nao encontrada.'; end if;
    select * into v_contact from public.whatsapp_contacts where id=v_conversation.contact_id and is_active and not is_blocked;
  elsif nullif(p_payload->>'contact_id','') is not null then
    select * into v_contact from public.whatsapp_contacts where id=(p_payload->>'contact_id')::uuid and store_id=v_store_id and is_active and not is_blocked;
  elsif nullif(p_payload->>'to','') is not null then
    insert into public.whatsapp_contacts(admin_user_id,store_id,phone_e164,name,created_by,updated_by)
    values(v_session.admin_user_id,v_store_id,app_private.whatsapp_normalize_phone(p_payload->>'to'),left(btrim(coalesce(p_payload->>'contact_name','')),200),v_session.user_id,v_session.user_id)
    on conflict(store_id,phone_e164) do update set is_active=true,deleted_at=null returning * into v_contact;
  end if;
  if v_contact.id is null or not v_contact.is_active or v_contact.is_blocked then raise exception 'Contato invalido, bloqueado ou removido.'; end if;
  if v_conversation.id is null then
    insert into public.whatsapp_conversations(admin_user_id,store_id,connection_id,contact_id,status)
    values(v_session.admin_user_id,v_store_id,v_connection.id,v_contact.id,'open')
    on conflict(connection_id,contact_id) do update set status=case when whatsapp_conversations.status='archived' then 'open' else whatsapp_conversations.status end returning * into v_conversation;
  end if;
  if v_type<>'template' and (v_conversation.customer_service_window_expires_at is null or v_conversation.customer_service_window_expires_at<=now()) then
    raise exception 'A janela de atendimento de 24 horas esta fechada. Use um template aprovado.';
  end if;
  if v_type='template'
     and (v_conversation.customer_service_window_expires_at is null or v_conversation.customer_service_window_expires_at<=now())
     and (
       not v_contact.marketing_opt_in or v_contact.opt_in_at is null
       or length(btrim(coalesce(v_contact.opt_in_source,'')))=0
       or length(btrim(coalesce(v_contact.opt_in_purpose,'')))=0
       or length(btrim(coalesce(v_contact.opt_in_text_version,'')))=0
       or jsonb_typeof(v_contact.opt_in_evidence)<>'object'
       or v_contact.opt_in_evidence='{}'::jsonb
       or length(btrim(coalesce(v_contact.opt_in_evidence->>'note',v_contact.opt_in_evidence->>'reference',v_contact.opt_in_evidence->>'hash','')))=0
       or v_contact.opt_in_evidence->>'consented_phone'<>v_contact.phone_e164
       or v_contact.opt_out_at is not null or v_contact.revoked_at is not null
     ) then
    raise exception 'O contato nao possui consentimento ativo para uma conversa iniciada pela empresa.';
  end if;
  if v_type='template' and not exists(
    select 1 from public.whatsapp_templates t where t.connection_id=v_connection.id
      and t.name=v_template_name and upper(t.status)='APPROVED'
      and (nullif(v_template_language,'') is null or t.language_code=v_template_language)
  ) then raise exception 'Template inexistente, nao aprovado ou pertencente a outra conexao.'; end if;
  v_key:=coalesce(nullif(left(p_payload->>'idempotency_key',300),''),'direct:'||v_connection.id::text||':'||gen_random_uuid()::text);
  -- Campos criticos sao reconstruidos no servidor. O cliente nunca pode trocar
  -- destinatario ou tipo injetando um provider_payload arbitrario.
  v_provider_payload:=jsonb_build_object(
    'messaging_product','whatsapp','recipient_type','individual',
    'to',regexp_replace(v_contact.phone_e164,'[^0-9]','','g'),'type',v_type
  ) || case
    when v_type='text' then jsonb_build_object('text',jsonb_build_object(
      'preview_url',coalesce(nullif(p_payload->>'preview_url','')::boolean,coalesce((v_input_provider#>>'{text,preview_url}')::boolean,false)),
      'body',left(coalesce(v_text,''),4096)
    ))
    when v_type='template' then jsonb_build_object('template',jsonb_build_object(
      'name',v_template_name,'language',jsonb_build_object('code',v_template_language),
      'components',coalesce(p_payload->'template_parameters',v_input_provider#>'{template,components}','[]'::jsonb)
    ))
    when p_payload ? v_type then jsonb_build_object(v_type,p_payload->v_type)
    when v_input_provider ? v_type then jsonb_build_object(v_type,v_input_provider->v_type)
    else '{}'::jsonb
  end;
  if nullif(v_reply_to,'') is not null then
    v_provider_payload:=v_provider_payload||jsonb_build_object('context',jsonb_build_object('message_id',left(v_reply_to,300)));
  end if;
  -- A Meta devolve este identificador nos webhooks de status. Ele permite
  -- reconciliar um POST aceito mesmo se a confirmacao local falhar depois.
  v_provider_payload:=v_provider_payload||jsonb_build_object('biz_opaque_callback_data',v_key);
  v_provider_payload:=app_private.whatsapp_json_size_guard(v_provider_payload,262144,'Payload da mensagem');
  if v_type='text' and length(btrim(coalesce(v_text,'')))=0 then raise exception 'Digite a mensagem.'; end if;
  if v_type='template' and length(btrim(coalesce(v_template_name,'')))=0 then raise exception 'Escolha um template aprovado.'; end if;
  if v_type='contacts' and jsonb_typeof(v_provider_payload->v_type)<>'array' then raise exception 'Lista de contatos da mensagem invalida.'; end if;
  if v_type not in ('text','template','contacts') and jsonb_typeof(v_provider_payload->v_type)<>'object' then raise exception 'Conteudo da mensagem ausente ou invalido.'; end if;
  insert into public.whatsapp_messages(admin_user_id,store_id,connection_id,conversation_id,contact_id,idempotency_key,direction,message_type,status,text_body,reply_to_provider_message_id,template_name,template_language,template_parameters,provider_payload,created_by)
  values(v_session.admin_user_id,v_store_id,v_connection.id,v_conversation.id,v_contact.id,v_key,'outbound',v_type,'queued',nullif(left(v_text,65536),''),nullif(left(v_reply_to,300),''),nullif(left(v_template_name,512),''),nullif(left(v_template_language,20),''),coalesce(p_payload->'template_parameters',v_input_provider#>'{template,components}','[]'::jsonb),v_provider_payload,v_session.user_id)
  on conflict(connection_id,idempotency_key) do nothing returning id into v_message;
  if v_message is null then
    select m.id into v_message from public.whatsapp_messages m
    where m.connection_id=v_connection.id and m.idempotency_key=v_key
      and m.store_id=v_store_id and m.contact_id=v_contact.id
      and m.conversation_id=v_conversation.id and m.message_type=v_type
      and (m.provider_payload-'provider_response'-'last_status_webhook')=v_provider_payload;
    if v_message is null then
      raise exception 'A chave de idempotencia ja foi usada com outro destinatario ou conteudo.';
    end if;
  end if;
  if v_type in ('image','document','audio','video','sticker') and nullif(v_provider_payload#>>array[v_type,'id'],'') is not null then
    insert into public.whatsapp_attachments(admin_user_id,store_id,message_id,provider_media_id,original_filename,mime_type,file_size,sha256,caption,media_status)
    values(v_session.admin_user_id,v_store_id,v_message,v_provider_payload#>>array[v_type,'id'],nullif(left(coalesce(p_payload->>'filename',v_provider_payload#>>array[v_type,'filename']),500),''),nullif(left(p_payload->>'mime_type',255),''),nullif(p_payload->>'file_size','')::bigint,nullif(left(p_payload->>'sha256',128),''),nullif(left(v_provider_payload#>>array[v_type,'caption'],4096),''),'remote')
    on conflict(message_id,provider_media_id) where provider_media_id is not null do nothing;
  end if;
  insert into public.whatsapp_send_queue(admin_user_id,store_id,connection_id,message_id,idempotency_key,payload,priority)
  values(v_session.admin_user_id,v_store_id,v_connection.id,v_message,v_key,v_provider_payload,coalesce(nullif(p_payload->>'priority','')::smallint,100))
  on conflict(connection_id,idempotency_key) do nothing returning id,status into v_queue,v_queue_status;
  if v_queue is null then
    select q.id,q.status into v_queue,v_queue_status from public.whatsapp_send_queue q
    where q.connection_id=v_connection.id and q.idempotency_key=v_key
      and q.store_id=v_store_id and q.message_id=v_message
      and q.payload=v_provider_payload;
    if v_queue is null then
      raise exception 'A chave de idempotencia da fila ja foi usada com outro conteudo.';
    end if;
  end if;
  return jsonb_build_object('message_id',v_message,'queue_id',v_queue,'conversation_id',v_conversation.id,'status',coalesce(v_queue_status,'queued'),'idempotency_key',v_key);
end;
$$;

create or replace function public.wa_service_start_due_campaigns(p_limit integer default 2)
returns integer language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_campaign record;v_count integer:=0;
begin
  update public.whatsapp_campaigns campaign set status='failed',completed_at=now(),last_error='A conexao ficou indisponivel antes do horario agendado.'
  where campaign.status='scheduled' and campaign.scheduled_at<=now()
    and not exists(
      select 1 from public.whatsapp_connections connection
      where connection.id=campaign.connection_id and connection.status in ('connected','token_expiring')
    );
  update public.whatsapp_campaigns campaign set status='failed',completed_at=now(),last_error='O template deixou de estar aprovado antes do horario agendado.'
  where campaign.status='scheduled' and campaign.scheduled_at<=now()
    and not exists(
      select 1 from public.whatsapp_templates template
      where template.id=campaign.template_id and template.connection_id=campaign.connection_id and upper(template.status)='APPROVED'
    );
  for v_campaign in
    select campaign.id
    from public.whatsapp_campaigns campaign
    join public.whatsapp_connections connection
      on connection.id=campaign.connection_id and connection.status in ('connected','token_expiring')
    join public.whatsapp_templates template
      on template.id=campaign.template_id and template.connection_id=campaign.connection_id and upper(template.status)='APPROVED'
    where campaign.status='scheduled' and campaign.scheduled_at<=now()
    order by campaign.scheduled_at
    limit least(greatest(coalesce(p_limit,2),1),8)
    for update of campaign skip locked
  loop
    begin
      perform app_private.whatsapp_enqueue_campaign(v_campaign.id,null);
      v_count:=v_count+1;
    exception when others then
      update public.whatsapp_campaigns set status='failed',completed_at=now(),last_error=left(sqlerrm,4000)
      where id=v_campaign.id;
    end;
  end loop;
  return v_count;
end;
$$;

create or replace function public.wa_service_fill_running_campaigns(p_limit integer default 2)
returns integer language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_campaign record;v_count integer:=0;
begin
  for v_campaign in
    select campaign.id
    from public.whatsapp_campaigns campaign
    where campaign.status='running' and exists(
      select 1 from public.whatsapp_campaign_recipients recipient
      where recipient.campaign_id=campaign.id and recipient.status='pending'
    )
    and (
      select count(*)
      from public.whatsapp_send_queue queue_item
      where queue_item.campaign_id=campaign.id
        and queue_item.status in ('pending','retry','processing')
    )<500
    order by campaign.started_at nulls first,campaign.id
    limit least(greatest(coalesce(p_limit,2),1),8)
    for update of campaign skip locked
  loop
    begin
      v_count:=v_count+app_private.whatsapp_enqueue_campaign(v_campaign.id,null);
    exception when others then
      update public.whatsapp_campaigns set status='failed',completed_at=now(),last_error=left(sqlerrm,4000)
      where id=v_campaign.id;
    end;
  end loop;
  return v_count;
end;
$$;

create or replace function public.wa_service_refresh_connection_health()
returns jsonb language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_expiring integer;v_expired integer;
begin
  update public.whatsapp_connections set status='token_expiring',last_error_code=null,last_error_message='O Access Token expira em menos de 7 dias.'
  where status='connected' and token_expires_at is not null and token_expires_at>now() and token_expires_at<=now()+interval '7 days';
  get diagnostics v_expiring=row_count;
  update public.whatsapp_connections set status='error',last_error_code='access_token_expired',last_error_message='O Access Token expirou. Atualize o token para reconectar.'
  where status in ('connected','token_expiring') and token_expires_at is not null and token_expires_at<=now();
  get diagnostics v_expired=row_count;
  update public.whatsapp_connections set status='connected',last_error_code=null,last_error_message=null
  where status='token_expiring' and (token_expires_at is null or token_expires_at>now()+interval '7 days');
  return jsonb_build_object('expiring',v_expiring,'expired',v_expired);
end;
$$;

create or replace function public.wa_service_claim_queue(p_worker_id text,p_limit integer default 25)
returns jsonb language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare
  v_result jsonb:='[]'::jsonb;
  v_candidate record;
  v_claimed jsonb;
  v_pair_key text;
  v_connection_next timestamptz;
  v_pair_next timestamptz;
  v_pair_in_flight uuid;
  v_pair_lease_expires timestamptz;
  v_dispatch_at timestamptz;
  v_now timestamptz;
  v_effective_rate numeric;
  v_count integer:=0;
  v_limit integer:=least(greatest(coalesce(p_limit,25),1),100);
  v_affected_campaigns uuid[]:='{}'::uuid[];
begin
  perform public.wa_service_refresh_connection_health();
  perform public.wa_service_start_due_campaigns(2);
  perform public.wa_service_fill_running_campaigns(2);
  update public.whatsapp_send_queue set status='retry',locked_at=null,locked_by=null,available_at=now(),last_error_message='Lock expirado; item devolvido a fila.'
  where status='processing' and locked_at<now()-interval '10 minutes';
  update public.whatsapp_dispatch_limits d set in_flight_queue_id=null,lease_expires_at=null
  where d.in_flight_queue_id is not null and (
    d.lease_expires_at<=now() or not exists(select 1 from public.whatsapp_send_queue q where q.id=d.in_flight_queue_id and q.status='processing')
  );
  with cancelled as(
    update public.whatsapp_send_queue q set status='cancelled',completed_at=now(),last_error_code='marketing_consent_revoked',last_error_message='Envio cancelado porque o consentimento de marketing nao esta ativo.'
    from public.whatsapp_campaign_recipients r join public.whatsapp_contacts ct on ct.id=r.contact_id
    where q.campaign_recipient_id=r.id and q.status in ('pending','retry')
      and (
        not ct.is_active or ct.is_blocked
        or not app_private.whatsapp_marketing_consent_active(ct)
        or regexp_replace(ct.phone_e164,'[^0-9]','','g')<>regexp_replace(coalesce(q.payload->>'to',''),'[^0-9]','','g')
      )
    returning q.campaign_id
  ) select coalesce(array_agg(distinct campaign_id) filter(where campaign_id is not null),'{}'::uuid[]) into v_affected_campaigns from cancelled;
  update public.whatsapp_messages m set status='cancelled',error_code='marketing_consent_revoked',error_message='Envio cancelado porque o consentimento de marketing nao esta ativo.'
  from public.whatsapp_send_queue q where q.message_id=m.id and q.status='cancelled' and q.last_error_code='marketing_consent_revoked' and m.status in ('queued','processing');
  update public.whatsapp_campaign_recipients r set status='cancelled',error_code='marketing_consent_revoked',error_message='Consentimento de marketing ausente ou revogado.'
  from public.whatsapp_send_queue q where q.campaign_recipient_id=r.id and q.status='cancelled' and q.last_error_code='marketing_consent_revoked' and r.status in ('pending','queued','processing');
  update public.whatsapp_campaigns campaign set
    queued_count=(select count(*) from public.whatsapp_campaign_recipients recipient where recipient.campaign_id=campaign.id and recipient.status in ('queued','processing','sent','delivered','read')),
    sent_count=(select count(*) from public.whatsapp_campaign_recipients recipient where recipient.campaign_id=campaign.id and recipient.status in ('sent','delivered','read')),
    delivered_count=(select count(*) from public.whatsapp_campaign_recipients recipient where recipient.campaign_id=campaign.id and recipient.status in ('delivered','read')),
    read_count=(select count(*) from public.whatsapp_campaign_recipients recipient where recipient.campaign_id=campaign.id and recipient.status='read'),
    failed_count=(select count(*) from public.whatsapp_campaign_recipients recipient where recipient.campaign_id=campaign.id and recipient.status='failed'),
    cancelled_count=(select count(*) from public.whatsapp_campaign_recipients recipient where recipient.campaign_id=campaign.id and recipient.status='cancelled')
  where campaign.status='running' and campaign.id=any(v_affected_campaigns);
  update public.whatsapp_campaigns campaign set status='completed',completed_at=now()
  where campaign.status='running' and campaign.id=any(v_affected_campaigns)
    and not exists(
      select 1 from public.whatsapp_campaign_recipients recipient
      where recipient.campaign_id=campaign.id and recipient.status in ('pending','queued','processing')
    );
  update public.whatsapp_campaigns cp set status='paused',paused_at=now(),last_error='Template deixou de estar aprovado; campanha pausada automaticamente.'
  where cp.status='running' and not exists(select 1 from public.whatsapp_templates t where t.id=cp.template_id and t.connection_id=cp.connection_id and upper(t.status)='APPROVED');
  for v_candidate in
    select q.*,
      cp.messages_per_second as campaign_rate,
      case
        when coalesce(c.public_config->>'max_messages_per_second','') ~ '^[0-9]+([.][0-9]+)?$'
          then (c.public_config->>'max_messages_per_second')::numeric
        else 20::numeric
      end as connection_rate
    from public.whatsapp_send_queue q
    join public.whatsapp_connections c on c.id=q.connection_id
    left join public.whatsapp_campaigns cp on cp.id=q.campaign_id
    where q.status in ('pending','retry') and q.available_at<=now() and q.attempt_count<q.max_attempts
      and c.status in ('connected','token_expiring') and (q.campaign_id is null or cp.status='running')
      and (q.campaign_id is null or exists(select 1 from public.whatsapp_templates t where t.id=cp.template_id and t.connection_id=q.connection_id and upper(t.status)='APPROVED'))
      and (q.campaign_recipient_id is null or exists(
        select 1 from public.whatsapp_campaign_recipients cr join public.whatsapp_contacts ct on ct.id=cr.contact_id
        where cr.id=q.campaign_recipient_id and ct.is_active and not ct.is_blocked and app_private.whatsapp_marketing_consent_active(ct)
      ))
      and not exists(
        select 1 from public.whatsapp_send_queue earlier
        where earlier.connection_id=q.connection_id
          and regexp_replace(coalesce(earlier.payload->>'to',''),'[^0-9]','','g')=regexp_replace(coalesce(q.payload->>'to',''),'[^0-9]','','g')
          and earlier.status in ('pending','retry','processing')
          and (earlier.created_at,earlier.id)<(q.created_at,q.id)
      )
    order by q.priority,q.available_at,q.created_at
    limit v_limit*20
    for update of q skip locked
  loop
    exit when v_count>=v_limit;
    v_pair_key:=coalesce(nullif(regexp_replace(coalesce(v_candidate.payload->>'to',''),'[^0-9]','','g'),''),'queue:'||v_candidate.id::text);
    v_effective_rate:=least(greatest(coalesce(v_candidate.campaign_rate,v_candidate.connection_rate,20),0.1),greatest(coalesce(v_candidate.connection_rate,20),0.1),80);
    insert into public.whatsapp_dispatch_limits(connection_id,scope_key,admin_user_id,store_id,next_available_at)
    values(v_candidate.connection_id,'__connection__',v_candidate.admin_user_id,v_candidate.store_id,clock_timestamp()) on conflict do nothing;
    insert into public.whatsapp_dispatch_limits(connection_id,scope_key,admin_user_id,store_id,next_available_at)
    values(v_candidate.connection_id,v_pair_key,v_candidate.admin_user_id,v_candidate.store_id,clock_timestamp()) on conflict do nothing;
    select next_available_at into v_connection_next from public.whatsapp_dispatch_limits where connection_id=v_candidate.connection_id and scope_key='__connection__' for update;
    select next_available_at,in_flight_queue_id,lease_expires_at into v_pair_next,v_pair_in_flight,v_pair_lease_expires from public.whatsapp_dispatch_limits where connection_id=v_candidate.connection_id and scope_key=v_pair_key for update;
    v_now:=clock_timestamp();
    if v_pair_in_flight is not null and v_pair_in_flight<>v_candidate.id and coalesce(v_pair_lease_expires,v_now)>v_now then continue; end if;
    v_dispatch_at:=greatest(v_now,v_connection_next,v_pair_next);
    -- A Edge Function nao deve ficar aberta esperando uma fila distante.
    -- O cron seguinte reivindica os slots que estiverem alem deste horizonte.
    if v_dispatch_at>v_now+interval '12 seconds' then continue; end if;
    update public.whatsapp_dispatch_limits set next_available_at=v_dispatch_at+make_interval(secs=>(1/v_effective_rate)::double precision)
    where connection_id=v_candidate.connection_id and scope_key='__connection__';
    update public.whatsapp_dispatch_limits set next_available_at=v_dispatch_at+interval '6 seconds',in_flight_queue_id=v_candidate.id,lease_expires_at=v_dispatch_at+interval '10 minutes'
    where connection_id=v_candidate.connection_id and scope_key=v_pair_key;
    v_claimed:=null;
    update public.whatsapp_send_queue q set status='processing',locked_at=now(),locked_by=left(p_worker_id,160),attempt_count=q.attempt_count+1,reserved_dispatch_at=v_dispatch_at
    where q.id=v_candidate.id and q.status in ('pending','retry') returning to_jsonb(q) into v_claimed;
    if v_claimed is not null then
      v_result:=v_result||(v_claimed||jsonb_build_object('messages_per_second',v_effective_rate,'dispatch_at',v_dispatch_at));
      v_count:=v_count+1;
    end if;
  end loop;
  update public.whatsapp_messages m set status='processing' from public.whatsapp_send_queue q where q.message_id=m.id and q.locked_by=left(p_worker_id,160) and q.status='processing';
  update public.whatsapp_campaign_recipients r set status='processing' from public.whatsapp_send_queue q where q.campaign_recipient_id=r.id and q.locked_by=left(p_worker_id,160) and q.status='processing';
  return v_result;
end;
$$;

create or replace function public.wa_service_release_queue_claim(
  p_queue_id uuid,p_worker_id text,p_available_at timestamptz default now(),p_reason text default null
)
returns boolean language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_queue record;
begin
  select * into v_queue
  from public.whatsapp_send_queue
  where id=p_queue_id and status='processing' and locked_by=left(p_worker_id,160)
  for update;
  if not found then return false; end if;
  update public.whatsapp_send_queue set
    status='retry',available_at=greatest(coalesce(p_available_at,now()),now()),
    locked_at=null,locked_by=null,reserved_dispatch_at=null,
    attempt_count=greatest(attempt_count-1,0),
    last_error_message=nullif(left(p_reason,4000),'')
  where id=p_queue_id;
  update public.whatsapp_messages set status='queued'
  where id=v_queue.message_id and status='processing';
  update public.whatsapp_campaign_recipients set status='queued'
  where id=v_queue.campaign_recipient_id and status='processing';
  update public.whatsapp_dispatch_limits set in_flight_queue_id=null,lease_expires_at=null
  where connection_id=v_queue.connection_id
    and scope_key=coalesce(nullif(regexp_replace(coalesce(v_queue.payload->>'to',''),'[^0-9]','','g'),''),'queue:'||v_queue.id::text)
    and in_flight_queue_id=v_queue.id;
  return true;
end;
$$;

create or replace function public.wa_service_prepare_queue_send(p_queue_id uuid,p_worker_id text)
returns jsonb language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_queue record;v_reason text;v_terminal boolean:=false;
begin
  select q.*,conn.status as connection_status,cp.status as campaign_status,
    case when q.campaign_recipient_id is null then true else coalesce((
      ct.is_active and not ct.is_blocked and app_private.whatsapp_marketing_consent_active(ct)
      and regexp_replace(ct.phone_e164,'[^0-9]','','g')=regexp_replace(coalesce(q.payload->>'to',''),'[^0-9]','','g')
    ),false) end as recipient_valid,
    case
      when q.campaign_id is not null then upper(coalesce(t.status,''))='APPROVED'
      when direct_message.message_type='template' then exists(
        select 1 from public.whatsapp_templates direct_template
        where direct_template.connection_id=q.connection_id
          and direct_template.name=direct_message.template_name
          and direct_template.language_code=direct_message.template_language
          and upper(direct_template.status)='APPROVED'
      )
      else true
    end as template_valid,
    case
      when q.campaign_id is not null then true
      else coalesce(
        direct_contact.is_active and not direct_contact.is_blocked
        and regexp_replace(direct_contact.phone_e164,'[^0-9]','','g')=regexp_replace(coalesce(q.payload->>'to',''),'[^0-9]','','g')
        and (
          direct_conversation.customer_service_window_expires_at>now()
          or (
            direct_message.message_type='template'
            and app_private.whatsapp_marketing_consent_active(direct_contact)
          )
        ),
        false
      )
    end as direct_message_valid
  into v_queue
  from public.whatsapp_send_queue q
  join public.whatsapp_connections conn on conn.id=q.connection_id
  left join public.whatsapp_campaigns cp on cp.id=q.campaign_id
  left join public.whatsapp_templates t on t.id=cp.template_id and t.connection_id=q.connection_id
  left join public.whatsapp_campaign_recipients cr on cr.id=q.campaign_recipient_id
  left join public.whatsapp_contacts ct on ct.id=cr.contact_id
  left join public.whatsapp_messages direct_message on direct_message.id=q.message_id
  left join public.whatsapp_conversations direct_conversation on direct_conversation.id=direct_message.conversation_id
  left join public.whatsapp_contacts direct_contact on direct_contact.id=direct_message.contact_id
  where q.id=p_queue_id
  for update of q;
  if not found or v_queue.status<>'processing' or v_queue.locked_by is distinct from left(p_worker_id,160) then
    return jsonb_build_object('ready',false,'status','claim_lost','reason','O item nao pertence mais a este worker.');
  end if;
  if v_queue.connection_status not in ('connected','token_expiring') then
    perform public.wa_service_release_queue_claim(p_queue_id,p_worker_id,now()+interval '1 minute','Conexao indisponivel antes do envio.');
    return jsonb_build_object('ready',false,'status','retry','reason','connection_unavailable');
  end if;
  if v_queue.campaign_id is null and not v_queue.direct_message_valid then
    v_reason:='Contato bloqueado, removido ou fora da janela permitida antes do envio.';v_terminal:=true;
  elsif v_queue.campaign_id is not null and coalesce(v_queue.campaign_status,'missing')<>'running' then
    if v_queue.campaign_status in ('cancelled','completed','failed') then
      v_reason:='Campanha encerrada antes do envio.';v_terminal:=true;
    else
      perform public.wa_service_release_queue_claim(p_queue_id,p_worker_id,now()+interval '1 minute','Campanha pausada antes do envio.');
      return jsonb_build_object('ready',false,'status','retry','reason','campaign_not_running');
    end if;
  elsif not v_queue.recipient_valid then
    v_reason:='Consentimento de marketing ausente ou revogado antes do envio.';v_terminal:=true;
  elsif not v_queue.template_valid then
    if v_queue.campaign_id is null then
      v_reason:='Template deixou de estar aprovado antes do envio.';v_terminal:=true;
    else
      update public.whatsapp_campaigns set status='paused',paused_at=now(),last_error='Template deixou de estar aprovado; campanha pausada automaticamente.'
      where id=v_queue.campaign_id and status='running';
      perform public.wa_service_release_queue_claim(p_queue_id,p_worker_id,now()+interval '5 minutes','Template nao aprovado antes do envio.');
      return jsonb_build_object('ready',false,'status','retry','reason','template_not_approved');
    end if;
  end if;
  if v_terminal then
    update public.whatsapp_send_queue set status='cancelled',completed_at=now(),locked_at=null,locked_by=null,last_error_code='send_cancelled',last_error_message=v_reason where id=p_queue_id;
    update public.whatsapp_messages set status='cancelled',error_code='send_cancelled',error_message=v_reason where id=v_queue.message_id and status in ('queued','processing');
    update public.whatsapp_campaign_recipients set status='cancelled',error_code='send_cancelled',error_message=v_reason where id=v_queue.campaign_recipient_id and status in ('pending','queued','processing');
    update public.whatsapp_campaigns set cancelled_count=(select count(*) from public.whatsapp_campaign_recipients where campaign_id=v_queue.campaign_id and status='cancelled') where id=v_queue.campaign_id;
    update public.whatsapp_dispatch_limits set in_flight_queue_id=null,lease_expires_at=null
    where connection_id=v_queue.connection_id
      and scope_key=coalesce(nullif(regexp_replace(coalesce(v_queue.payload->>'to',''),'[^0-9]','','g'),''),'queue:'||v_queue.id::text)
      and in_flight_queue_id=v_queue.id;
    return jsonb_build_object('ready',false,'status','cancelled','reason',v_reason);
  end if;
  update public.whatsapp_send_queue set locked_at=now() where id=p_queue_id;
  return jsonb_build_object('ready',true,'status','processing');
end;
$$;

create or replace function public.wa_service_finish_queue(
  p_queue_id uuid,p_success boolean,p_provider_message_id text default null,
  p_provider_response jsonb default '{}'::jsonb,p_http_status integer default null,
  p_error_code text default null,p_error_message text default null,
  p_retry_at timestamptz default null,p_terminal boolean default false
)
returns jsonb language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_queue record;v_new_status text;v_campaign_status text;
begin
  select * into v_queue from public.whatsapp_send_queue where id=p_queue_id for update;
  if not found then raise exception 'Item da fila nao encontrado.'; end if;
  if p_success then v_new_status:='sent';
  elsif not coalesce(p_terminal,false) and v_queue.attempt_count<v_queue.max_attempts then v_new_status:='retry';
  else v_new_status:='failed'; end if;
  update public.whatsapp_send_queue set status=v_new_status,provider_message_id=coalesce(nullif(p_provider_message_id,''),provider_message_id),provider_response=coalesce(p_provider_response,'{}'::jsonb),last_http_status=p_http_status,last_error_code=nullif(left(p_error_code,160),''),last_error_message=nullif(left(p_error_message,4000),''),available_at=case when v_new_status='retry' then coalesce(p_retry_at,now()+make_interval(secs=>least(21600,power(2,least(v_queue.attempt_count,12))::integer*5))) else available_at end,locked_at=null,locked_by=null,completed_at=case when v_new_status in ('sent','failed') then now() else null end where id=p_queue_id;
  if v_queue.message_id is not null then
    update public.whatsapp_messages set status=case when p_success then 'sent' when v_new_status='failed' then 'failed' else 'queued' end,provider_message_id=coalesce(nullif(p_provider_message_id,''),provider_message_id),provider_payload=case when p_success then provider_payload||jsonb_build_object('provider_response',coalesce(p_provider_response,'{}'::jsonb)) else provider_payload end,error_code=nullif(left(p_error_code,160),''),error_message=nullif(left(p_error_message,4000),''),sent_at=case when p_success then coalesce(sent_at,now()) else sent_at end,failed_at=case when v_new_status='failed' then now() else failed_at end where id=v_queue.message_id;
    if p_success then
      update public.whatsapp_conversations c set last_message_id=m.id,last_message_preview=left(coalesce(m.text_body,'Template: '||coalesce(m.template_name,m.message_type)),500),last_message_direction='outbound',last_message_at=coalesce(m.sent_at,now()) from public.whatsapp_messages m where m.id=v_queue.message_id and c.id=m.conversation_id;
    end if;
  end if;
  if v_queue.campaign_recipient_id is not null then
    update public.whatsapp_campaign_recipients set status=case when p_success then 'sent' when v_new_status='failed' then 'failed' else 'queued' end,sent_at=case when p_success then coalesce(sent_at,now()) else sent_at end,failed_at=case when v_new_status='failed' then now() else failed_at end,error_code=nullif(left(p_error_code,160),''),error_message=nullif(left(p_error_message,4000),'') where id=v_queue.campaign_recipient_id;
  end if;
  if v_queue.campaign_id is not null then
    update public.whatsapp_campaigns c set queued_count=(select count(*) from public.whatsapp_campaign_recipients r where r.campaign_id=c.id and r.status in ('queued','processing','sent','delivered','read')),sent_count=(select count(*) from public.whatsapp_campaign_recipients r where r.campaign_id=c.id and r.status in ('sent','delivered','read')),delivered_count=(select count(*) from public.whatsapp_campaign_recipients r where r.campaign_id=c.id and r.status in ('delivered','read')),read_count=(select count(*) from public.whatsapp_campaign_recipients r where r.campaign_id=c.id and r.status='read'),failed_count=(select count(*) from public.whatsapp_campaign_recipients r where r.campaign_id=c.id and r.status='failed'),cancelled_count=(select count(*) from public.whatsapp_campaign_recipients r where r.campaign_id=c.id and r.status='cancelled') where c.id=v_queue.campaign_id;
    if not exists(select 1 from public.whatsapp_campaign_recipients r where r.campaign_id=v_queue.campaign_id and r.status in ('pending','queued','processing')) then
      update public.whatsapp_campaigns set status='completed',completed_at=now() where id=v_queue.campaign_id and status='running';
    end if;
    select status into v_campaign_status from public.whatsapp_campaigns where id=v_queue.campaign_id;
  end if;
  update public.whatsapp_dispatch_limits set in_flight_queue_id=null,lease_expires_at=null
  where connection_id=v_queue.connection_id
    and scope_key=coalesce(nullif(regexp_replace(coalesce(v_queue.payload->>'to',''),'[^0-9]','','g'),''),'queue:'||v_queue.id::text)
    and in_flight_queue_id=v_queue.id;
  return jsonb_build_object('ok',true,'queue_status',v_new_status,'campaign_status',v_campaign_status);
end;
$$;

-- Finalizacao cercada pelo lease. Um worker antigo nao pode sobrescrever o
-- resultado de outro depois que seu lock expirou e o item foi reivindicado de
-- novo. Mantemos wa_service_finish_queue como primitiva interna para preservar
-- compatibilidade, mas o worker oficial usa exclusivamente esta funcao.
create or replace function public.wa_service_finish_queue_claim(
  p_queue_id uuid,p_worker_id text,p_success boolean,p_provider_message_id text default null,
  p_provider_response jsonb default '{}'::jsonb,p_http_status integer default null,
  p_error_code text default null,p_error_message text default null,
  p_retry_at timestamptz default null,p_terminal boolean default false
)
returns jsonb language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_owned boolean;
begin
  select true into v_owned
  from public.whatsapp_send_queue q
  where q.id=p_queue_id and q.status='processing' and q.locked_by=left(p_worker_id,160)
  for update;
  if not coalesce(v_owned,false) then
    return jsonb_build_object('ok',false,'queue_status','claim_lost');
  end if;
  return public.wa_service_finish_queue(
    p_queue_id,p_success,p_provider_message_id,p_provider_response,p_http_status,
    p_error_code,p_error_message,p_retry_at,p_terminal
  );
end;
$$;

-- Quarentena terminal para o raro caso em que a Meta aceita o POST, mas a
-- confirmacao transacional perde o lease ou a resposta local do banco. Nunca
-- reenviamos automaticamente uma mensagem potencialmente entregue.
create or replace function public.wa_service_quarantine_accepted_queue(
  p_queue_id uuid,p_provider_message_id text default null,
  p_provider_response jsonb default '{}'::jsonb,p_reason text default null
)
returns jsonb language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_queue record;v_message record;
begin
  select * into v_queue from public.whatsapp_send_queue where id=p_queue_id for update;
  if not found then return jsonb_build_object('ok',false,'queue_status','missing'); end if;
  if v_queue.status in ('sent','failed','cancelled') then
    return jsonb_build_object('ok',false,'queue_status',v_queue.status);
  end if;
  update public.whatsapp_send_queue set
    status='sent_unconfirmed',
    provider_message_id=coalesce(nullif(p_provider_message_id,''),provider_message_id),
    provider_response=app_private.whatsapp_json_size_guard(coalesce(p_provider_response,'{}'::jsonb),262144,'Resposta da Meta'),
    last_http_status=200,last_error_code='accepted_confirmation_pending',
    last_error_message=coalesce(nullif(left(p_reason,4000),''),'A Meta aceitou o POST, mas a confirmacao local ficou pendente.'),
    locked_at=null,locked_by=null,completed_at=now()
  where id=p_queue_id;
  if v_queue.message_id is not null then
    update public.whatsapp_messages set
      status='sent',provider_message_id=coalesce(nullif(p_provider_message_id,''),provider_message_id),
      provider_payload=provider_payload||jsonb_build_object('provider_response',coalesce(p_provider_response,'{}'::jsonb),'local_confirmation','pending'),
      sent_at=coalesce(sent_at,now()),error_code='accepted_confirmation_pending',
      error_message=coalesce(nullif(left(p_reason,4000),''),'Aguardando reconciliacao do webhook.')
    where id=v_queue.message_id returning * into v_message;
    update public.whatsapp_conversations conversation set
      last_message_id=v_message.id,
      last_message_preview=left(coalesce(v_message.text_body,'Template: '||coalesce(v_message.template_name,v_message.message_type)),500),
      last_message_direction='outbound',last_message_at=coalesce(v_message.sent_at,now())
    where conversation.id=v_message.conversation_id;
  end if;
  if v_queue.campaign_recipient_id is not null then
    update public.whatsapp_campaign_recipients set status='sent',sent_at=coalesce(sent_at,now()),
      error_code='accepted_confirmation_pending',error_message='Aguardando reconciliacao do webhook.'
    where id=v_queue.campaign_recipient_id;
    update public.whatsapp_campaigns campaign set
      sent_count=(select count(*) from public.whatsapp_campaign_recipients recipient where recipient.campaign_id=campaign.id and recipient.status in ('sent','delivered','read')),
      delivered_count=(select count(*) from public.whatsapp_campaign_recipients recipient where recipient.campaign_id=campaign.id and recipient.status in ('delivered','read')),
      read_count=(select count(*) from public.whatsapp_campaign_recipients recipient where recipient.campaign_id=campaign.id and recipient.status='read'),
      failed_count=(select count(*) from public.whatsapp_campaign_recipients recipient where recipient.campaign_id=campaign.id and recipient.status='failed')
    where campaign.id=v_queue.campaign_id;
  end if;
  update public.whatsapp_dispatch_limits set in_flight_queue_id=null,lease_expires_at=null
  where connection_id=v_queue.connection_id and in_flight_queue_id=v_queue.id;
  return jsonb_build_object('ok',true,'queue_status','sent_unconfirmed');
end;
$$;

create or replace function public.wa_service_record_webhook(
  p_connection_id uuid,p_event_key text,p_event_type text,p_provider_object text,
  p_provider_message_id text,p_headers jsonb,p_payload jsonb
)
returns jsonb language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_connection record;v_id uuid;v_is_new boolean:=false;
begin
  select * into v_connection from public.whatsapp_connections where id=p_connection_id;
  if not found then raise exception 'Conexao do webhook nao encontrada.'; end if;
  select id into v_id from public.whatsapp_webhook_events where connection_id=p_connection_id and event_key=left(p_event_key,500) for update;
  if found then
    update public.whatsapp_webhook_events set received_count=received_count+1,last_received_at=now() where id=v_id;
  else
    begin
      insert into public.whatsapp_webhook_events(admin_user_id,store_id,connection_id,event_key,event_type,provider_object,provider_message_id,signature_valid,headers,payload)
      values(v_connection.admin_user_id,v_connection.store_id,p_connection_id,left(p_event_key,500),left(coalesce(p_event_type,'unknown'),160),nullif(left(p_provider_object,160),''),nullif(left(p_provider_message_id,500),''),true,
        app_private.whatsapp_json_size_guard(coalesce(p_headers,'{}'::jsonb),32768,'Cabecalhos do webhook'),app_private.whatsapp_json_size_guard(p_payload,3145728,'Payload do webhook')) returning id into v_id;
      v_is_new:=true;
    exception when unique_violation then
      select id into v_id from public.whatsapp_webhook_events where connection_id=p_connection_id and event_key=left(p_event_key,500);
      update public.whatsapp_webhook_events set received_count=received_count+1,last_received_at=now() where id=v_id;
    end;
  end if;
  return jsonb_build_object('id',v_id,'is_new',v_is_new);
end;
$$;

create or replace function public.wa_service_get_webhook(p_session_token text,p_event_id uuid)
returns jsonb language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_session record;v_event record;
begin
  select * into v_session from app_private.session_user(p_session_token);
  select e.* into v_event from public.whatsapp_webhook_events e where e.id=p_event_id and e.admin_user_id=v_session.admin_user_id
    and app_private.whatsapp_store_allowed(v_session.admin_user_id,v_session.user_id,v_session.user_role,v_session.user_store_id,e.store_id,false);
  if not found then raise exception 'Evento nao encontrado ou sem permissao.'; end if;
  return to_jsonb(v_event)-'admin_user_id';
end;
$$;

create or replace function public.wa_service_mark_webhook(p_event_id uuid,p_status text,p_error text default null)
returns boolean language plpgsql security definer
set search_path = app_private, public, extensions
as $$
begin
  if p_status not in ('pending','processing','processed','failed','ignored') then raise exception 'Status de webhook invalido.'; end if;
  update public.whatsapp_webhook_events set processing_status=p_status,processed_at=case when p_status in ('processed','ignored') then now() else processed_at end,last_error=nullif(left(p_error,8000),''),next_attempt_at=case when p_status='failed' then now()+make_interval(secs=>least(21600,power(2,least(processing_attempts+1,12))::integer*5)) else next_attempt_at end,locked_at=case when p_status in ('processed','ignored','failed','pending') then null else locked_at end,locked_by=case when p_status in ('processed','ignored','failed','pending') then null else locked_by end where id=p_event_id;
  return found;
end;
$$;

create or replace function public.wa_service_claim_webhooks(p_worker_id text,p_limit integer default 20)
returns jsonb language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_result jsonb;
begin
  update public.whatsapp_webhook_events set processing_status='failed',locked_at=null,locked_by=null,next_attempt_at=now(),last_error='Lease expirado; evento devolvido a fila.'
  where processing_status='processing' and locked_at<now()-interval '10 minutes';
  with candidates as(
    select e.id from public.whatsapp_webhook_events e
    where e.processing_status in ('pending','failed') and e.next_attempt_at<=now() and e.processing_attempts<20
    order by e.next_attempt_at,e.created_at limit least(greatest(coalesce(p_limit,20),1),100) for update skip locked
  ),claimed as(
    update public.whatsapp_webhook_events e set processing_status='processing',processing_attempts=e.processing_attempts+1,locked_at=now(),locked_by=left(p_worker_id,160)
    from candidates c where e.id=c.id returning e.id,e.connection_id,e.event_type,e.payload,e.processing_attempts,e.admin_user_id,e.store_id
  ) select coalesce(jsonb_agg(to_jsonb(claimed) order by id),'[]'::jsonb) into v_result from claimed;
  return v_result;
end;
$$;

create or replace function public.wa_service_apply_template_webhook(p_connection_id uuid,p_payload jsonb)
returns jsonb language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_status text:=upper(coalesce(nullif(p_payload->>'event',''),nullif(p_payload->>'status','')));v_count integer;
begin
  update public.whatsapp_templates set
    status=case when v_status is null then status else left(v_status,40) end,
    rejection_reason=case when v_status='REJECTED' then nullif(left(coalesce(p_payload->>'reason',p_payload->>'rejection_reason'),2000),'') else rejection_reason end,
    last_synced_at=now(),
    quality_score=(case when jsonb_typeof(quality_score)='object' then quality_score else jsonb_build_object('score',quality_score) end)||jsonb_strip_nulls(jsonb_build_object(
      'event',p_payload->>'event','quality_score',p_payload->'quality_score',
      'previous_quality_score',p_payload->'previous_quality_score',
      'new_quality_score',p_payload->'new_quality_score'
    ))
  where connection_id in (
    select sibling.id
    from public.whatsapp_connections sibling
    join public.whatsapp_connections source
      on source.id=p_connection_id
      and sibling.business_account_id=source.business_account_id
      and sibling.admin_user_id=source.admin_user_id
      and sibling.app_id=source.app_id
  ) and (
    (nullif(p_payload->>'message_template_id','') is not null and provider_template_id=p_payload->>'message_template_id')
    or (nullif(p_payload->>'message_template_name','') is not null and name=p_payload->>'message_template_name' and (nullif(p_payload->>'message_template_language','') is null or language_code=p_payload->>'message_template_language'))
  );
  get diagnostics v_count=row_count;
  return jsonb_build_object('updated',v_count,'status',v_status,'quality_only',v_status is null);
end;
$$;

create or replace function public.wa_service_upsert_inbound_message(p_connection_id uuid,p_contact jsonb,p_message jsonb)
returns jsonb language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_connection record;v_contact record;v_conversation record;v_message_id uuid;v_sent_at timestamptz;v_inserted integer;v_type text:=coalesce(nullif(p_message->>'type',''),'unknown');v_media jsonb:=p_message->'media';
begin
  select * into v_connection from public.whatsapp_connections where id=p_connection_id;
  if not found then raise exception 'Conexao nao encontrada.'; end if;
  if v_type not in ('text','image','document','audio','video','sticker','location','contacts','interactive','reaction','template','unknown') then v_type:='unknown'; end if;
  v_sent_at:=coalesce(nullif(p_message->>'sent_at','')::timestamptz,now());
  insert into public.whatsapp_contacts(admin_user_id,store_id,wa_id,phone_e164,name,profile_name,last_seen_at)
  values(v_connection.admin_user_id,v_connection.store_id,nullif(p_contact->>'wa_id',''),app_private.whatsapp_normalize_phone(coalesce(p_contact->>'phone',p_contact->>'wa_id')),
    left(btrim(coalesce(p_contact->>'name',p_contact->>'profile_name','')),200),left(btrim(coalesce(p_contact->>'profile_name','')),200),v_sent_at)
  on conflict(store_id,phone_e164) do update set wa_id=coalesce(excluded.wa_id,whatsapp_contacts.wa_id),profile_name=coalesce(nullif(excluded.profile_name,''),whatsapp_contacts.profile_name),name=case when whatsapp_contacts.name='' then excluded.name else whatsapp_contacts.name end,last_seen_at=greatest(coalesce(whatsapp_contacts.last_seen_at,excluded.last_seen_at),excluded.last_seen_at),is_active=true,deleted_at=null returning * into v_contact;
  insert into public.whatsapp_conversations(admin_user_id,store_id,connection_id,contact_id,status,customer_service_window_expires_at)
  values(v_connection.admin_user_id,v_connection.store_id,p_connection_id,v_contact.id,'open',v_sent_at+interval '24 hours')
  on conflict(connection_id,contact_id) do update set status=case when whatsapp_conversations.status in ('resolved','archived') then 'open' else whatsapp_conversations.status end,customer_service_window_expires_at=greatest(coalesce(whatsapp_conversations.customer_service_window_expires_at,excluded.customer_service_window_expires_at),excluded.customer_service_window_expires_at) returning * into v_conversation;
  insert into public.whatsapp_messages(admin_user_id,store_id,connection_id,conversation_id,contact_id,provider_message_id,idempotency_key,direction,message_type,status,text_body,reply_to_provider_message_id,provider_payload,received_at,created_at)
  values(v_connection.admin_user_id,v_connection.store_id,p_connection_id,v_conversation.id,v_contact.id,nullif(p_message->>'provider_message_id',''),'inbound:'||p_connection_id::text||':'||coalesce(nullif(p_message->>'provider_message_id',''),encode(extensions.digest(p_message::text,'sha256'),'hex')),'inbound',v_type,'received',nullif(p_message->>'text',''),nullif(p_message->>'reply_to_provider_message_id',''),p_message,v_sent_at,v_sent_at)
  on conflict(connection_id,idempotency_key) do nothing returning id into v_message_id;
  get diagnostics v_inserted = row_count;
  if v_inserted=0 then select id into v_message_id from public.whatsapp_messages where connection_id=p_connection_id and idempotency_key='inbound:'||p_connection_id::text||':'||coalesce(nullif(p_message->>'provider_message_id',''),encode(extensions.digest(p_message::text,'sha256'),'hex')); end if;
  if v_inserted>0 then
    update public.whatsapp_conversations set unread_count=unread_count+1,last_message_id=v_message_id,last_message_preview=left(coalesce(p_message->>'text','['||v_type||']'),500),last_message_direction='inbound',last_message_at=v_sent_at where id=v_conversation.id;
    if jsonb_typeof(v_media)='object' and nullif(v_media->>'id','') is not null then
      insert into public.whatsapp_attachments(admin_user_id,store_id,message_id,provider_media_id,original_filename,mime_type,sha256,caption,media_status)
      values(v_connection.admin_user_id,v_connection.store_id,v_message_id,v_media->>'id',nullif(v_media->>'filename',''),nullif(v_media->>'mime_type',''),nullif(v_media->>'sha256',''),nullif(v_media->>'caption',''),'remote')
      on conflict(message_id,provider_media_id) where provider_media_id is not null do nothing;
    end if;
  end if;
  return jsonb_build_object('message_id',v_message_id,'conversation_id',v_conversation.id,'contact_id',v_contact.id,'inserted',v_inserted>0);
end;
$$;

create or replace function public.wa_service_update_message_status(p_connection_id uuid,p_status_payload jsonb)
returns jsonb language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare
  v_message record;
  v_status text:=lower(coalesce(p_status_payload->>'status',''));
  v_at timestamptz:=coalesce(nullif(p_status_payload->>'timestamp','')::timestamptz,now());
  v_recipient uuid;
  v_callback_key text:=nullif(left(coalesce(p_status_payload->>'biz_opaque_callback_data',p_status_payload#>>'{raw,biz_opaque_callback_data}'),300),'');
  v_queue record;
begin
  if v_status not in ('sent','delivered','read','failed') then return jsonb_build_object('updated',false,'ignored',true); end if;
  select * into v_message from public.whatsapp_messages where connection_id=p_connection_id and provider_message_id=p_status_payload->>'provider_message_id' for update;
  if not found and v_callback_key is not null then
    select * into v_message from public.whatsapp_messages
    where connection_id=p_connection_id and idempotency_key=v_callback_key
    for update;
    if found and exists(
      select 1 from public.whatsapp_messages provider_conflict
      where provider_conflict.connection_id=p_connection_id
        and provider_conflict.provider_message_id=p_status_payload->>'provider_message_id'
        and provider_conflict.id<>v_message.id
    ) then
      return jsonb_build_object('updated',false,'provider_id_conflict',true);
    elsif found then
      update public.whatsapp_messages
      set provider_message_id=p_status_payload->>'provider_message_id'
      where id=v_message.id;
      v_message.provider_message_id:=p_status_payload->>'provider_message_id';
    end if;
  end if;
  if not found then return jsonb_build_object('updated',false,'missing',true); end if;
  if (
    v_status <> 'failed'
    and (case v_status when 'sent' then 1 when 'delivered' then 2 when 'read' then 3 else 0 end)
      < (case v_message.status when 'sent' then 1 when 'delivered' then 2 when 'read' then 3 else 0 end)
  ) or (v_status='failed' and v_message.status in ('delivered','read')) then
    return jsonb_build_object('updated',false,'stale',true,'message_id',v_message.id,'current_status',v_message.status);
  end if;
  update public.whatsapp_messages set status=v_status,sent_at=case when v_status='sent' then coalesce(sent_at,v_at) else sent_at end,delivered_at=case when v_status in ('delivered','read') then coalesce(delivered_at,v_at) else delivered_at end,read_at=case when v_status='read' then coalesce(read_at,v_at) else read_at end,failed_at=case when v_status='failed' then coalesce(failed_at,v_at) else failed_at end,error_code=case when v_status='failed' then nullif(p_status_payload->>'error_code','') else error_code end,error_message=case when v_status='failed' then nullif(left(p_status_payload->>'error_message',4000),'') else error_message end,provider_payload=provider_payload||jsonb_build_object('last_status_webhook',p_status_payload) where id=v_message.id;
  select * into v_queue from public.whatsapp_send_queue
  where message_id=v_message.id and status in ('pending','retry','processing','sent_unconfirmed')
  order by created_at desc limit 1 for update;
  if found then
    update public.whatsapp_send_queue set
      status=case when v_status='failed' then 'failed' else 'sent' end,
      provider_message_id=coalesce(nullif(p_status_payload->>'provider_message_id',''),provider_message_id),
      last_error_code=case when v_status='failed' then nullif(p_status_payload->>'error_code','') else null end,
      last_error_message=case when v_status='failed' then nullif(left(p_status_payload->>'error_message',4000),'') else null end,
      locked_at=null,locked_by=null,completed_at=coalesce(completed_at,v_at)
    where id=v_queue.id;
    update public.whatsapp_dispatch_limits set in_flight_queue_id=null,lease_expires_at=null
    where connection_id=v_queue.connection_id and in_flight_queue_id=v_queue.id;
  end if;
  select r.id into v_recipient from public.whatsapp_campaign_recipients r where r.message_id=v_message.id;
  if v_recipient is not null then
    update public.whatsapp_campaign_recipients set status=v_status,sent_at=case when v_status='sent' then coalesce(sent_at,v_at) else sent_at end,delivered_at=case when v_status in ('delivered','read') then coalesce(delivered_at,v_at) else delivered_at end,read_at=case when v_status='read' then coalesce(read_at,v_at) else read_at end,failed_at=case when v_status='failed' then coalesce(failed_at,v_at) else failed_at end,error_code=case when v_status='failed' then nullif(p_status_payload->>'error_code','') else error_code end,error_message=case when v_status='failed' then nullif(left(p_status_payload->>'error_message',4000),'') else error_message end where id=v_recipient;
    update public.whatsapp_campaigns c set sent_count=(select count(*) from public.whatsapp_campaign_recipients r where r.campaign_id=c.id and r.status in ('sent','delivered','read')),delivered_count=(select count(*) from public.whatsapp_campaign_recipients r where r.campaign_id=c.id and r.status in ('delivered','read')),read_count=(select count(*) from public.whatsapp_campaign_recipients r where r.campaign_id=c.id and r.status='read'),failed_count=(select count(*) from public.whatsapp_campaign_recipients r where r.campaign_id=c.id and r.status='failed') where c.id=(select campaign_id from public.whatsapp_campaign_recipients where id=v_recipient);
  end if;
  return jsonb_build_object('updated',true,'message_id',v_message.id,'status',v_status);
end;
$$;

create or replace function public.wa_service_upsert_templates(p_connection_id uuid,p_templates jsonb)
returns integer language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_connection record;v_template jsonb;v_count integer:=0;v_sync_started timestamptz:=clock_timestamp();
begin
  select * into v_connection from public.whatsapp_connections where id=p_connection_id;
  if not found then raise exception 'Conexao nao encontrada.'; end if;
  if jsonb_typeof(coalesce(p_templates,'[]'::jsonb))<>'array' then raise exception 'Lista de templates invalida.'; end if;
  for v_template in select value from jsonb_array_elements(p_templates) loop
    if nullif(v_template->>'name','') is null or nullif(v_template->>'language','') is null then continue; end if;
    insert into public.whatsapp_templates(admin_user_id,store_id,connection_id,provider_template_id,name,language_code,category,status,parameter_format,components,quality_score,rejection_reason,last_synced_at)
    values(v_connection.admin_user_id,v_connection.store_id,p_connection_id,nullif(v_template->>'id',''),left(v_template->>'name',512),left(v_template->>'language',20),left(coalesce(v_template->>'category','UTILITY'),40),left(coalesce(v_template->>'status','PENDING'),40),nullif(left(v_template->>'parameter_format',40),''),coalesce(v_template->'components','[]'::jsonb),case when jsonb_typeof(v_template->'quality_score')='object' then v_template->'quality_score' when v_template ? 'quality_score' then jsonb_build_object('score',v_template->'quality_score') else '{}'::jsonb end,nullif(left(v_template->>'rejected_reason',2000),''),v_sync_started)
    on conflict(connection_id,name,language_code) do update set provider_template_id=coalesce(excluded.provider_template_id,whatsapp_templates.provider_template_id),category=excluded.category,status=excluded.status,parameter_format=excluded.parameter_format,components=excluded.components,quality_score=excluded.quality_score,rejection_reason=excluded.rejection_reason,last_synced_at=excluded.last_synced_at;
    v_count:=v_count+1;
  end loop;
  update public.whatsapp_templates set status='DELETED',last_synced_at=v_sync_started
  where connection_id=p_connection_id and last_synced_at is not null and last_synced_at<v_sync_started
    and status<>'DELETED';
  return v_count;
end;
$$;

create or replace function public.wa_service_template_for_edit(p_session_token text,p_template_id uuid)
returns jsonb language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_session record;v_template record;
begin
  select * into v_session from app_private.session_user(p_session_token);
  select t.* into v_template from public.whatsapp_templates t where t.id=p_template_id and t.admin_user_id=v_session.admin_user_id
    and app_private.whatsapp_store_allowed(v_session.admin_user_id,v_session.user_id,v_session.user_role,v_session.user_store_id,t.store_id,true);
  if not found then raise exception 'Template nao encontrado ou sem permissao.'; end if;
  if nullif(v_template.provider_template_id,'') is null then raise exception 'Template ainda nao possui identificador da Meta; sincronize antes de editar.'; end if;
  return jsonb_build_object('id',v_template.id,'connection_id',v_template.connection_id,'provider_template_id',v_template.provider_template_id,'name',v_template.name,'language_code',v_template.language_code,'status',v_template.status);
end;
$$;

create or replace function public.wa_service_attachment_runtime(p_session_token text,p_attachment_id uuid)
returns jsonb language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_session record;v_attachment record;
begin
  select * into v_session from app_private.session_user(p_session_token);
  select a.*,m.connection_id into v_attachment
  from public.whatsapp_attachments a join public.whatsapp_messages m on m.id=a.message_id
  where a.id=p_attachment_id and a.admin_user_id=v_session.admin_user_id
    and app_private.whatsapp_store_allowed(v_session.admin_user_id,v_session.user_id,v_session.user_role,v_session.user_store_id,a.store_id,false);
  if not found then raise exception 'Anexo nao encontrado ou sem permissao.'; end if;
  if nullif(v_attachment.provider_media_id,'') is null then raise exception 'Anexo sem identificador de midia da Meta.'; end if;
  return jsonb_build_object('id',v_attachment.id,'connection_id',v_attachment.connection_id,'provider_media_id',v_attachment.provider_media_id,'original_filename',v_attachment.original_filename,'mime_type',v_attachment.mime_type,'file_size',v_attachment.file_size,'sha256',v_attachment.sha256);
end;
$$;

create or replace function public.wa_list_contacts(
  p_session_token text,p_store_id uuid,p_search text default null,
  p_tag_ids uuid[] default null,p_active_only boolean default true,
  p_limit integer default 50,p_offset integer default 0
)
returns jsonb language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_session record;v_items jsonb;v_total bigint;v_limit integer:=least(greatest(coalesce(p_limit,50),1),200);v_offset integer:=greatest(coalesce(p_offset,0),0);
begin
  select * into v_session from app_private.session_user(p_session_token);
  if not app_private.whatsapp_store_allowed(v_session.admin_user_id,v_session.user_id,v_session.user_role,v_session.user_store_id,p_store_id,false) then raise exception 'Cliente nao encontrado ou sem permissao.'; end if;
  with filtered as(
    select c.* from public.whatsapp_contacts c where c.store_id=p_store_id and c.admin_user_id=v_session.admin_user_id
      and (not coalesce(p_active_only,true) or c.is_active)
      and (nullif(btrim(coalesce(p_search,'')),'') is null or c.name ilike '%'||btrim(p_search)||'%' or c.profile_name ilike '%'||btrim(p_search)||'%' or (regexp_replace(p_search,'[^0-9+]','','g')<>'' and c.phone_e164 ilike '%'||regexp_replace(p_search,'[^0-9+]','','g')||'%') or c.email ilike '%'||btrim(p_search)||'%' or exists(select 1 from public.whatsapp_contact_tags search_ct join public.whatsapp_tags search_tag on search_tag.id=search_ct.tag_id where search_ct.contact_id=c.id and search_tag.name ilike '%'||btrim(p_search)||'%'))
      and (p_tag_ids is null or cardinality(p_tag_ids)=0 or exists(select 1 from public.whatsapp_contact_tags ct where ct.contact_id=c.id and ct.tag_id=any(p_tag_ids)))
  ) select count(*) into v_total from filtered;
  with page as(
    select c.*,
      app_private.whatsapp_marketing_consent_active(c) as marketing_consent_active,
      coalesce((select jsonb_agg(jsonb_build_object('id',t.id,'name',t.name,'color',t.color) order by t.name) from public.whatsapp_contact_tags ct join public.whatsapp_tags t on t.id=ct.tag_id where ct.contact_id=c.id),'[]'::jsonb) as tags,
      (select count(*) from public.whatsapp_conversations cv where cv.contact_id=c.id) as conversations_count,
      (select max(cv.last_message_at) from public.whatsapp_conversations cv where cv.contact_id=c.id) as last_message_at
    from public.whatsapp_contacts c where c.store_id=p_store_id and c.admin_user_id=v_session.admin_user_id
      and (not coalesce(p_active_only,true) or c.is_active)
      and (nullif(btrim(coalesce(p_search,'')),'') is null or c.name ilike '%'||btrim(p_search)||'%' or c.profile_name ilike '%'||btrim(p_search)||'%' or (regexp_replace(p_search,'[^0-9+]','','g')<>'' and c.phone_e164 ilike '%'||regexp_replace(p_search,'[^0-9+]','','g')||'%') or c.email ilike '%'||btrim(p_search)||'%' or exists(select 1 from public.whatsapp_contact_tags search_ct join public.whatsapp_tags search_tag on search_tag.id=search_ct.tag_id where search_ct.contact_id=c.id and search_tag.name ilike '%'||btrim(p_search)||'%'))
      and (p_tag_ids is null or cardinality(p_tag_ids)=0 or exists(select 1 from public.whatsapp_contact_tags ct where ct.contact_id=c.id and ct.tag_id=any(p_tag_ids)))
    order by c.is_favorite desc,c.updated_at desc limit v_limit offset v_offset
  ) select coalesce(jsonb_agg(to_jsonb(page)-'admin_user_id' order by is_favorite desc,updated_at desc),'[]'::jsonb) into v_items from page;
  return jsonb_build_object('items',v_items,'total',v_total,'limit',v_limit,'offset',v_offset);
end;
$$;

create or replace function public.wa_update_conversation(
  p_session_token text,p_conversation_id uuid,p_payload jsonb default '{}'::jsonb
)
returns jsonb language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_session record;v_conversation record;v_status text;
begin
  select * into v_session from app_private.session_user(p_session_token);
  select c.* into v_conversation from public.whatsapp_conversations c where c.id=p_conversation_id and c.admin_user_id=v_session.admin_user_id
    and app_private.whatsapp_store_allowed(v_session.admin_user_id,v_session.user_id,v_session.user_role,v_session.user_store_id,c.store_id,false) for update;
  if not found then raise exception 'Conversa nao encontrada ou sem permissao.'; end if;
  v_status:=case when p_payload ? 'status' then lower(p_payload->>'status') else v_conversation.status end;
  if v_status not in ('open','pending','resolved','archived') then raise exception 'Status de conversa invalido.'; end if;
  if p_payload ? 'assigned_user_id' and nullif(p_payload->>'assigned_user_id','') is not null and not exists(
    select 1
    from public.app_users u
    join public.stores st on st.id=v_conversation.store_id
    where u.id=(p_payload->>'assigned_user_id')::uuid and u.is_active
      and (
        u.id=v_session.admin_user_id
        or u.id=st.technician_user_id
        or (u.role::text='store' and u.store_id=v_conversation.store_id and u.admin_user_id=v_session.admin_user_id)
      )
  ) then raise exception 'Responsavel invalido.'; end if;
  update public.whatsapp_conversations set status=v_status,
    is_favorite=case when p_payload ? 'is_favorite' then (p_payload->>'is_favorite')::boolean else is_favorite end,
    unread_count=case when coalesce((p_payload->>'mark_read')::boolean,false) then 0 else unread_count end,
    assigned_user_id=case when p_payload ? 'assigned_user_id' then nullif(p_payload->>'assigned_user_id','')::uuid else assigned_user_id end,
    assigned_at=case when p_payload ? 'assigned_user_id' then case when nullif(p_payload->>'assigned_user_id','') is null then null else now() end else assigned_at end,
    resolved_at=case when v_status='resolved' then coalesce(resolved_at,now()) when status='resolved' and v_status<>'resolved' then null else resolved_at end,
    archived_at=case when v_status='archived' then coalesce(archived_at,now()) when status='archived' and v_status<>'archived' then null else archived_at end
  where id=p_conversation_id returning * into v_conversation;
  return to_jsonb(v_conversation)-'admin_user_id';
end;
$$;

create or replace function public.wa_get_campaign_report(
  p_session_token text,p_campaign_id uuid,p_limit integer default 200,p_offset integer default 0
)
returns jsonb language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_session record;v_campaign record;v_items jsonb;v_total bigint;v_limit integer:=least(greatest(coalesce(p_limit,200),1),1000);v_offset integer:=greatest(coalesce(p_offset,0),0);
begin
  select * into v_session from app_private.session_user(p_session_token);
  select c.*,t.name as template_name,t.language_code as template_language,conn.name as connection_name into v_campaign
  from public.whatsapp_campaigns c join public.whatsapp_templates t on t.id=c.template_id join public.whatsapp_connections conn on conn.id=c.connection_id
  where c.id=p_campaign_id and c.admin_user_id=v_session.admin_user_id
    and app_private.whatsapp_store_allowed(v_session.admin_user_id,v_session.user_id,v_session.user_role,v_session.user_store_id,c.store_id,false);
  if not found then raise exception 'Campanha nao encontrada ou sem permissao.'; end if;
  select count(*) into v_total from public.whatsapp_campaign_recipients where campaign_id=p_campaign_id;
  with page as(
    select r.id,r.contact_id,ct.name as contact_name,ct.phone_e164,r.status,r.queued_at,r.sent_at,r.delivered_at,r.read_at,r.failed_at,r.error_code,r.error_message,r.message_id
    from public.whatsapp_campaign_recipients r join public.whatsapp_contacts ct on ct.id=r.contact_id
    where r.campaign_id=p_campaign_id order by r.created_at,r.id limit v_limit offset v_offset
  ) select coalesce(jsonb_agg(to_jsonb(page) order by contact_name,phone_e164),'[]'::jsonb) into v_items from page;
  return jsonb_build_object(
    'campaign',to_jsonb(v_campaign)-'admin_user_id'-'created_by'-'updated_by',
    'summary',jsonb_build_object('total',v_total,'pending',(select count(*) from public.whatsapp_campaign_recipients where campaign_id=p_campaign_id and status='pending'),'queued',(select count(*) from public.whatsapp_campaign_recipients where campaign_id=p_campaign_id and status in ('queued','processing')),'sent',(select count(*) from public.whatsapp_campaign_recipients where campaign_id=p_campaign_id and status='sent'),'delivered',(select count(*) from public.whatsapp_campaign_recipients where campaign_id=p_campaign_id and status='delivered'),'read',(select count(*) from public.whatsapp_campaign_recipients where campaign_id=p_campaign_id and status='read'),'failed',(select count(*) from public.whatsapp_campaign_recipients where campaign_id=p_campaign_id and status='failed'),'cancelled',(select count(*) from public.whatsapp_campaign_recipients where campaign_id=p_campaign_id and status='cancelled')),
    'recipients',v_items,'total',v_total,'limit',v_limit,'offset',v_offset
  );
end;
$$;

create or replace function public.wa_service_import_contacts(p_session_token text,p_store_id uuid,p_contacts jsonb)
returns jsonb language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_session record;v_item jsonb;v_phone text;v_total integer:=0;v_imported integer:=0;v_updated integer:=0;v_failed integer:=0;v_existing uuid;v_contact_id uuid;v_label text;v_label_id uuid;v_item_opt_in boolean;v_errors jsonb:='[]'::jsonb;
begin
  select * into v_session from app_private.session_user(p_session_token);
  if not app_private.whatsapp_store_allowed(v_session.admin_user_id,v_session.user_id,v_session.user_role,v_session.user_store_id,p_store_id,false) then raise exception 'Cliente nao encontrado ou sem permissao.'; end if;
  if jsonb_typeof(coalesce(p_contacts,'[]'::jsonb))<>'array' then raise exception 'Lista de contatos invalida.'; end if;
  if jsonb_array_length(p_contacts)>5000 then raise exception 'Importe no maximo 5.000 contatos por lote.'; end if;
  for v_item in select value from jsonb_array_elements(p_contacts) loop
    v_total:=v_total+1;
    begin
      v_phone:=app_private.whatsapp_normalize_phone(coalesce(v_item->>'phone',v_item->>'phone_e164'));
      select id into v_existing from public.whatsapp_contacts where store_id=p_store_id and phone_e164=v_phone;
      v_item_opt_in:=coalesce(nullif(coalesce(v_item->>'marketing_opt_in',v_item->>'opt_in'),'')::boolean,false);
      if v_item_opt_in then perform app_private.whatsapp_validate_opt_in(v_item); end if;
      insert into public.whatsapp_contacts(admin_user_id,store_id,wa_id,phone_e164,name,email,company,language_code,notes,internal_notes,custom_fields,marketing_opt_in,opt_in_source,opt_in_at,opt_in_purpose,opt_in_categories,opt_in_text_version,opt_in_evidence,opt_out_at,revoked_at,is_active,deleted_at,created_by,updated_by)
      values(v_session.admin_user_id,p_store_id,nullif(v_item->>'wa_id',''),v_phone,left(btrim(coalesce(v_item->>'name','')),200),nullif(left(lower(btrim(v_item->>'email')),320),''),nullif(left(btrim(v_item->>'company'),200),''),nullif(left(btrim(v_item->>'language_code'),20),''),nullif(left(v_item->>'notes',10000),''),nullif(left(v_item->>'internal_notes',20000),''),app_private.whatsapp_json_size_guard(coalesce(v_item->'custom_fields','{}'::jsonb),65536,'Campos personalizados'),v_item_opt_in,case when v_item_opt_in then nullif(left(btrim(v_item->>'opt_in_source'),160),'') end,case when v_item_opt_in then (v_item->>'opt_in_at')::timestamptz end,case when v_item_opt_in then nullif(left(btrim(v_item->>'opt_in_purpose'),500),'') end,case when v_item_opt_in then coalesce(array(select jsonb_array_elements_text(coalesce(v_item->'opt_in_categories','[]'::jsonb))),'{}'::text[]) else '{}'::text[] end,case when v_item_opt_in then nullif(left(btrim(v_item->>'opt_in_text_version'),160),'') end,case when v_item_opt_in then app_private.whatsapp_json_size_guard((v_item->'opt_in_evidence')||jsonb_build_object('imported_by',v_session.user_id,'imported_at',now(),'consented_phone',v_phone),131072,'Evidencia do consentimento') else '{}'::jsonb end,case when v_item_opt_in then null else nullif(v_item->>'opt_out_at','')::timestamptz end,case when v_item_opt_in then null else nullif(v_item->>'revoked_at','')::timestamptz end,true,null,v_session.user_id,v_session.user_id)
      on conflict(store_id,phone_e164) do update set name=case when excluded.name<>'' then excluded.name else whatsapp_contacts.name end,email=coalesce(excluded.email,whatsapp_contacts.email),company=coalesce(excluded.company,whatsapp_contacts.company),language_code=coalesce(excluded.language_code,whatsapp_contacts.language_code),notes=coalesce(excluded.notes,whatsapp_contacts.notes),internal_notes=coalesce(excluded.internal_notes,whatsapp_contacts.internal_notes),custom_fields=whatsapp_contacts.custom_fields||excluded.custom_fields,
        marketing_opt_in=case when v_item ? 'marketing_opt_in' or v_item ? 'opt_in' then excluded.marketing_opt_in when v_item ? 'opt_out_at' or v_item ? 'revoked_at' then false else whatsapp_contacts.marketing_opt_in end,
        opt_in_source=case when v_item ? 'marketing_opt_in' or v_item ? 'opt_in' then excluded.opt_in_source else whatsapp_contacts.opt_in_source end,
        opt_in_at=case when v_item ? 'marketing_opt_in' or v_item ? 'opt_in' then excluded.opt_in_at else whatsapp_contacts.opt_in_at end,
        opt_in_purpose=case when v_item ? 'marketing_opt_in' or v_item ? 'opt_in' then excluded.opt_in_purpose else whatsapp_contacts.opt_in_purpose end,
        opt_in_categories=case when v_item ? 'marketing_opt_in' or v_item ? 'opt_in' then excluded.opt_in_categories else whatsapp_contacts.opt_in_categories end,
        opt_in_text_version=case when v_item ? 'marketing_opt_in' or v_item ? 'opt_in' then excluded.opt_in_text_version else whatsapp_contacts.opt_in_text_version end,
        opt_in_evidence=case when v_item ? 'marketing_opt_in' or v_item ? 'opt_in' then excluded.opt_in_evidence else whatsapp_contacts.opt_in_evidence end,
        opt_out_at=case when v_item_opt_in then null when v_item ? 'marketing_opt_in' or v_item ? 'opt_in' or v_item ? 'opt_out_at' then coalesce(excluded.opt_out_at,now()) else whatsapp_contacts.opt_out_at end,
        revoked_at=case when v_item_opt_in then null when v_item ? 'revoked_at' then coalesce(excluded.revoked_at,now()) else whatsapp_contacts.revoked_at end,
        is_active=true,deleted_at=null,updated_by=v_session.user_id returning id into v_contact_id;
      if v_item ? 'labels' then
        delete from public.whatsapp_contact_tags where contact_id=v_contact_id;
        for v_label in select btrim(value) from jsonb_array_elements_text(coalesce(v_item->'labels','[]'::jsonb)) loop
          if length(v_label)=0 then continue; end if;
          insert into public.whatsapp_tags(admin_user_id,store_id,name,color,is_active) values(v_session.admin_user_id,p_store_id,left(v_label,80),'#2f80ed',true)
          on conflict(store_id,name) do update set is_active=true returning id into v_label_id;
          insert into public.whatsapp_contact_tags(contact_id,tag_id) values(v_contact_id,v_label_id) on conflict do nothing;
        end loop;
      end if;
      if v_existing is null then v_imported:=v_imported+1;else v_updated:=v_updated+1;end if;
    exception when others then
      v_failed:=v_failed+1;
      if jsonb_array_length(v_errors)<100 then v_errors:=v_errors||jsonb_build_array(jsonb_build_object('row',v_total,'phone',coalesce(v_item->>'phone',v_item->>'phone_e164'),'error',sqlerrm));end if;
    end;
  end loop;
  return jsonb_build_object('total',v_total,'imported',v_imported,'updated',v_updated,'failed',v_failed,'errors',v_errors,'errors_truncated',v_failed>jsonb_array_length(v_errors));
end;
$$;

-- -----------------------------------------------------------------------------
-- RLS, permissoes e publicacao no PostgREST
-- -----------------------------------------------------------------------------

do $$
declare v_table text;
begin
  foreach v_table in array array[
    'whatsapp_connections','whatsapp_contacts','whatsapp_tags','whatsapp_contact_tags',
    'whatsapp_conversations','whatsapp_messages','whatsapp_attachments','whatsapp_templates',
    'whatsapp_campaigns','whatsapp_campaign_recipients','whatsapp_send_queue','whatsapp_dispatch_limits',
    'whatsapp_webhook_events','whatsapp_status_history','whatsapp_logs'
  ] loop
    execute format('alter table public.%I enable row level security',v_table);
    execute format('revoke all on table public.%I from public, anon, authenticated',v_table);
    execute format('grant select, insert, update, delete on table public.%I to service_role',v_table);
  end loop;
end $$;

revoke all on table app_private.whatsapp_connection_secrets from public, anon, authenticated;
grant select,insert,update,delete on table app_private.whatsapp_connection_secrets to service_role;

revoke all on function public.wa_list_connections(text,uuid) from public;
revoke all on function public.wa_get_bootstrap(text,uuid) from public;
revoke all on function public.wa_list_conversations(text,uuid,text,text,boolean,boolean,uuid[],integer,integer) from public;
revoke all on function public.wa_get_messages(text,uuid,timestamptz,integer) from public;
revoke all on function public.wa_upsert_contact(text,uuid,uuid,jsonb) from public;
revoke all on function public.wa_delete_contact(text,uuid) from public;
revoke all on function public.wa_list_campaigns(text,uuid,text,integer,integer,text) from public;
revoke all on function public.wa_upsert_campaign(text,uuid,uuid,jsonb) from public;
revoke all on function public.wa_campaign_action(text,uuid,text) from public;
revoke all on function public.wa_list_templates(text,uuid,uuid,text) from public;
revoke all on function public.wa_list_webhook_events(text,uuid,text,text,integer,integer) from public;
revoke all on function public.wa_get_webhook_event(text,uuid) from public;
revoke all on function public.wa_reprocess_webhook(text,uuid) from public;
revoke all on function public.wa_list_logs(text,uuid,text,text,text,integer,integer) from public;
revoke all on function public.wa_get_log(text,bigint) from public;
revoke all on function public.wa_disconnect_connection(text,uuid) from public;
revoke all on function public.wa_list_contacts(text,uuid,text,uuid[],boolean,integer,integer) from public;
revoke all on function public.wa_update_conversation(text,uuid,jsonb) from public;
revoke all on function public.wa_get_campaign_report(text,uuid,integer,integer) from public;

grant execute on function public.wa_list_connections(text,uuid) to anon,authenticated,service_role;
grant execute on function public.wa_get_bootstrap(text,uuid) to anon,authenticated,service_role;
grant execute on function public.wa_list_conversations(text,uuid,text,text,boolean,boolean,uuid[],integer,integer) to anon,authenticated,service_role;
grant execute on function public.wa_get_messages(text,uuid,timestamptz,integer) to anon,authenticated,service_role;
grant execute on function public.wa_upsert_contact(text,uuid,uuid,jsonb) to anon,authenticated,service_role;
grant execute on function public.wa_delete_contact(text,uuid) to anon,authenticated,service_role;
grant execute on function public.wa_list_campaigns(text,uuid,text,integer,integer,text) to anon,authenticated,service_role;
grant execute on function public.wa_upsert_campaign(text,uuid,uuid,jsonb) to anon,authenticated,service_role;
grant execute on function public.wa_campaign_action(text,uuid,text) to anon,authenticated,service_role;
grant execute on function public.wa_list_templates(text,uuid,uuid,text) to anon,authenticated,service_role;
grant execute on function public.wa_list_webhook_events(text,uuid,text,text,integer,integer) to anon,authenticated,service_role;
grant execute on function public.wa_get_webhook_event(text,uuid) to anon,authenticated,service_role;
grant execute on function public.wa_reprocess_webhook(text,uuid) to anon,authenticated,service_role;
grant execute on function public.wa_list_logs(text,uuid,text,text,text,integer,integer) to anon,authenticated,service_role;
grant execute on function public.wa_get_log(text,bigint) to anon,authenticated,service_role;
grant execute on function public.wa_disconnect_connection(text,uuid) to anon,authenticated,service_role;
grant execute on function public.wa_list_contacts(text,uuid,text,uuid[],boolean,integer,integer) to anon,authenticated,service_role;
grant execute on function public.wa_update_conversation(text,uuid,jsonb) to anon,authenticated,service_role;
grant execute on function public.wa_get_campaign_report(text,uuid,integer,integer) to anon,authenticated,service_role;

revoke all on function public.wa_service_save_connection(text,jsonb,text) from public,anon,authenticated;
revoke all on function public.wa_service_connection_runtime(text,uuid,text,boolean) from public,anon,authenticated;
revoke all on function public.wa_service_connection_runtime_by_phone(text,text) from public,anon,authenticated;
revoke all on function public.wa_service_connection_runtime_by_id(uuid,text) from public,anon,authenticated;
revoke all on function public.wa_service_connection_runtime_by_business_account(text,text) from public,anon,authenticated;
revoke all on function public.wa_service_connection_by_verify_token(text) from public,anon,authenticated;
revoke all on function public.wa_service_set_connection_status(uuid,text,text,text,jsonb) from public,anon,authenticated;
revoke all on function public.wa_service_log(jsonb) from public,anon,authenticated;
revoke all on function public.wa_service_log_session(text,jsonb) from public,anon,authenticated;
revoke all on function public.wa_service_enqueue_message(text,jsonb) from public,anon,authenticated;
revoke all on function public.wa_service_start_due_campaigns(integer) from public,anon,authenticated;
revoke all on function public.wa_service_fill_running_campaigns(integer) from public,anon,authenticated;
revoke all on function public.wa_service_refresh_connection_health() from public,anon,authenticated;
revoke all on function public.wa_service_claim_queue(text,integer) from public,anon,authenticated;
revoke all on function public.wa_service_release_queue_claim(uuid,text,timestamptz,text) from public,anon,authenticated;
revoke all on function public.wa_service_prepare_queue_send(uuid,text) from public,anon,authenticated;
revoke all on function public.wa_service_finish_queue(uuid,boolean,text,jsonb,integer,text,text,timestamptz,boolean) from public,anon,authenticated;
revoke all on function public.wa_service_finish_queue(uuid,boolean,text,jsonb,integer,text,text,timestamptz,boolean) from service_role;
revoke all on function public.wa_service_finish_queue_claim(uuid,text,boolean,text,jsonb,integer,text,text,timestamptz,boolean) from public,anon,authenticated;
revoke all on function public.wa_service_quarantine_accepted_queue(uuid,text,jsonb,text) from public,anon,authenticated;
revoke all on function public.wa_service_record_webhook(uuid,text,text,text,text,jsonb,jsonb) from public,anon,authenticated;
revoke all on function public.wa_service_get_webhook(text,uuid) from public,anon,authenticated;
revoke all on function public.wa_service_mark_webhook(uuid,text,text) from public,anon,authenticated;
revoke all on function public.wa_service_claim_webhooks(text,integer) from public,anon,authenticated;
revoke all on function public.wa_service_apply_template_webhook(uuid,jsonb) from public,anon,authenticated;
revoke all on function public.wa_service_upsert_inbound_message(uuid,jsonb,jsonb) from public,anon,authenticated;
revoke all on function public.wa_service_update_message_status(uuid,jsonb) from public,anon,authenticated;
revoke all on function public.wa_service_upsert_templates(uuid,jsonb) from public,anon,authenticated;
revoke all on function public.wa_service_import_contacts(text,uuid,jsonb) from public,anon,authenticated;
revoke all on function public.wa_service_template_for_edit(text,uuid) from public,anon,authenticated;
revoke all on function public.wa_service_attachment_runtime(text,uuid) from public,anon,authenticated;

grant execute on function public.wa_service_save_connection(text,jsonb,text) to service_role;
grant execute on function public.wa_service_connection_runtime(text,uuid,text,boolean) to service_role;
grant execute on function public.wa_service_connection_runtime_by_phone(text,text) to service_role;
grant execute on function public.wa_service_connection_runtime_by_id(uuid,text) to service_role;
grant execute on function public.wa_service_connection_runtime_by_business_account(text,text) to service_role;
grant execute on function public.wa_service_connection_by_verify_token(text) to service_role;
grant execute on function public.wa_service_set_connection_status(uuid,text,text,text,jsonb) to service_role;
grant execute on function public.wa_service_log(jsonb) to service_role;
grant execute on function public.wa_service_log_session(text,jsonb) to service_role;
grant execute on function public.wa_service_enqueue_message(text,jsonb) to service_role;
grant execute on function public.wa_service_start_due_campaigns(integer) to service_role;
grant execute on function public.wa_service_fill_running_campaigns(integer) to service_role;
grant execute on function public.wa_service_refresh_connection_health() to service_role;
grant execute on function public.wa_service_claim_queue(text,integer) to service_role;
grant execute on function public.wa_service_release_queue_claim(uuid,text,timestamptz,text) to service_role;
grant execute on function public.wa_service_prepare_queue_send(uuid,text) to service_role;
grant execute on function public.wa_service_finish_queue_claim(uuid,text,boolean,text,jsonb,integer,text,text,timestamptz,boolean) to service_role;
grant execute on function public.wa_service_quarantine_accepted_queue(uuid,text,jsonb,text) to service_role;
grant execute on function public.wa_service_record_webhook(uuid,text,text,text,text,jsonb,jsonb) to service_role;
grant execute on function public.wa_service_get_webhook(text,uuid) to service_role;
grant execute on function public.wa_service_mark_webhook(uuid,text,text) to service_role;
grant execute on function public.wa_service_claim_webhooks(text,integer) to service_role;
grant execute on function public.wa_service_apply_template_webhook(uuid,jsonb) to service_role;
grant execute on function public.wa_service_upsert_inbound_message(uuid,jsonb,jsonb) to service_role;
grant execute on function public.wa_service_update_message_status(uuid,jsonb) to service_role;
grant execute on function public.wa_service_upsert_templates(uuid,jsonb) to service_role;
grant execute on function public.wa_service_import_contacts(text,uuid,jsonb) to service_role;
grant execute on function public.wa_service_template_for_edit(text,uuid) to service_role;
grant execute on function public.wa_service_attachment_runtime(text,uuid) to service_role;

-- Funcoes internas nao ficam invocaveis por PostgREST, mesmo que o schema
-- app_private ja possua USAGE por compatibilidade com modulos antigos.
revoke all on function app_private.whatsapp_capture_status_change() from public,anon,authenticated;
revoke all on function app_private.whatsapp_store_allowed(uuid,uuid,public.app_user_role,uuid,uuid,boolean) from public,anon,authenticated;
revoke all on function app_private.whatsapp_normalize_phone(text) from public,anon,authenticated;
revoke all on function app_private.whatsapp_json_size_guard(jsonb,integer,text) from public,anon,authenticated;
revoke all on function app_private.whatsapp_validate_opt_in(jsonb) from public,anon,authenticated;
revoke all on function app_private.whatsapp_marketing_consent_active(public.whatsapp_contacts) from public,anon,authenticated;
revoke all on function app_private.whatsapp_enqueue_campaign(uuid,uuid) from public,anon,authenticated;
revoke all on function app_private.whatsapp_guard_waba_ownership() from public,anon,authenticated;
grant execute on function app_private.whatsapp_capture_status_change() to service_role;
grant execute on function app_private.whatsapp_store_allowed(uuid,uuid,public.app_user_role,uuid,uuid,boolean) to service_role;
grant execute on function app_private.whatsapp_normalize_phone(text) to service_role;
grant execute on function app_private.whatsapp_json_size_guard(jsonb,integer,text) to service_role;
grant execute on function app_private.whatsapp_validate_opt_in(jsonb) to service_role;
grant execute on function app_private.whatsapp_marketing_consent_active(public.whatsapp_contacts) to service_role;
grant execute on function app_private.whatsapp_enqueue_campaign(uuid,uuid) to service_role;

commit;
notify pgrst, 'reload schema';

-- Verificacao rapida apos executar:
-- select to_regprocedure('public.wa_get_bootstrap(text,uuid)'),
--        to_regprocedure('public.wa_service_claim_queue(text,integer)'),
--        to_regclass('public.whatsapp_messages');
