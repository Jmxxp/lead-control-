-- Jornada e atribuicao de marketing | Meta Ads + Google Ads
-- Migracao incremental, aditiva e autocontida para um banco Lead Control.
-- Nao substitui marketing_intelligence_update.sql e nao depende dele.
-- Execute uma vez no SQL Editor. O arquivo pode ser reaplicado com seguranca.

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
     or to_regprocedure('app_private.session_user(text)') is null then
    raise exception 'Instale primeiro o database.sql base do Lead Control.';
  end if;
end $$;

create or replace function app_private.ma_set_updated_at()
returns trigger language plpgsql
set search_path = app_private, public, extensions
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create or replace function app_private.ma_json_guard(
  p_value jsonb, p_max_bytes integer, p_label text
)
returns jsonb language plpgsql immutable
set search_path = app_private, public, extensions
as $$
declare v_value jsonb := coalesce(p_value, '{}'::jsonb);
begin
  if jsonb_typeof(v_value) <> 'object' then
    raise exception '% deve ser um objeto JSON.', coalesce(p_label, 'Payload');
  end if;
  if octet_length(v_value::text) > greatest(coalesce(p_max_bytes, 65536), 128) then
    raise exception '% excede o tamanho permitido.', coalesce(p_label, 'Payload');
  end if;
  return v_value;
end;
$$;

create or replace function app_private.ma_store_allowed(
  p_admin_user_id uuid,
  p_user_id uuid,
  p_user_role public.app_user_role,
  p_user_store_id uuid,
  p_store_id uuid,
  p_configuration_write boolean default false
)
returns boolean language sql stable security definer
set search_path = app_private, public, extensions
as $$
  select exists (
    select 1
    from public.stores st
    where st.id = p_store_id
      and st.admin_user_id = p_admin_user_id
      and st.is_active
      and (
        p_user_role::text = 'admin'
        or (
          p_user_role::text = 'technician'
          and st.technician_user_id = p_user_id
        )
        or (
          not p_configuration_write
          and p_user_role::text = 'store'
          and st.id = p_user_store_id
        )
      )
  );
$$;

create table if not exists public.marketing_attribution_connections (
  id uuid primary key default gen_random_uuid(),
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
  store_id uuid not null,
  provider text not null,
  name text not null,
  status text not null default 'draft',
  account_external_id text not null default '',
  account_name text,
  api_version text not null default '',
  token_expires_at timestamptz,
  public_config jsonb not null default '{}'::jsonb,
  last_validated_at timestamptz,
  last_sync_at timestamptz,
  last_error_code text,
  last_error_message text,
  created_by uuid references public.app_users(id) on delete set null,
  updated_by uuid references public.app_users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint ma_connections_provider_check check (provider in ('meta', 'google')),
  constraint ma_connections_status_check check (
    status in ('draft', 'validating', 'active', 'token_expiring', 'error', 'disconnected')
  ),
  constraint ma_connections_store_admin_fk foreign key (store_id, admin_user_id)
    references public.stores(id, admin_user_id) on delete cascade,
  constraint ma_connections_store_provider_key unique (store_id, provider)
);

create table if not exists app_private.marketing_attribution_connection_secrets (
  connection_id uuid primary key references public.marketing_attribution_connections(id) on delete cascade,
  secret_cipher bytea not null,
  secret_version integer not null default 1,
  rotated_at timestamptz not null default now()
);

create table if not exists public.marketing_tracking_sources (
  id uuid primary key default gen_random_uuid(),
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
  store_id uuid not null,
  name text not null default 'Site principal',
  token_hash text not null unique,
  token_prefix text not null,
  allowed_origins text[] not null default '{}',
  is_active boolean not null default true,
  last_used_at timestamptz,
  created_by uuid references public.app_users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint ma_tracking_sources_store_admin_fk foreign key (store_id, admin_user_id)
    references public.stores(id, admin_user_id) on delete cascade
);

create index if not exists ma_tracking_sources_store_idx
  on public.marketing_tracking_sources(store_id, is_active);

create table if not exists public.marketing_touchpoints (
  id uuid primary key default gen_random_uuid(),
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
  store_id uuid not null,
  tracking_source_id uuid references public.marketing_tracking_sources(id) on delete set null,
  lead_id uuid references public.leads(id) on delete set null,
  anonymous_id text,
  session_id text,
  event_name text not null default 'page_view',
  occurred_at timestamptz not null default now(),
  provider text,
  utm_source text,
  utm_medium text,
  utm_campaign text,
  utm_content text,
  utm_term text,
  campaign_external_id text,
  adset_external_id text,
  ad_external_id text,
  creative_external_id text,
  gclid text,
  gbraid text,
  wbraid text,
  fbclid text,
  fbc text,
  fbp text,
  landing_page_url text,
  referrer_url text,
  marketing_consent boolean not null default false,
  consent_at timestamptz,
  consent_version text,
  consent_source text,
  ip_hash text,
  user_agent_hash text,
  idempotency_key text not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint ma_touchpoints_provider_check check (provider is null or provider in ('meta', 'google', 'direct', 'organic', 'other')),
  constraint ma_touchpoints_store_admin_fk foreign key (store_id, admin_user_id)
    references public.stores(id, admin_user_id) on delete cascade,
  constraint ma_touchpoints_store_idempotency_key unique (store_id, idempotency_key)
);

create index if not exists ma_touchpoints_store_date_idx
  on public.marketing_touchpoints(store_id, occurred_at desc);
create index if not exists ma_touchpoints_lead_date_idx
  on public.marketing_touchpoints(lead_id, occurred_at) where lead_id is not null;
create index if not exists ma_touchpoints_anonymous_idx
  on public.marketing_touchpoints(store_id, anonymous_id, occurred_at desc)
  where anonymous_id is not null;
create index if not exists ma_touchpoints_gclid_idx
  on public.marketing_touchpoints(store_id, gclid) where gclid is not null;
create index if not exists ma_touchpoints_fbclid_idx
  on public.marketing_touchpoints(store_id, fbclid) where fbclid is not null;

create table if not exists public.marketing_attribution_events (
  id uuid primary key default gen_random_uuid(),
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
  store_id uuid not null,
  lead_id uuid not null references public.leads(id) on delete cascade,
  event_type text not null,
  event_at timestamptz not null default now(),
  value numeric(14,2),
  currency text not null default 'BRL',
  actor_user_id uuid references public.app_users(id) on delete set null,
  source text not null default 'app',
  idempotency_key text not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint ma_events_type_check check (
    event_type in ('lead_created', 'contacted', 'qualified', 'scheduled', 'visited', 'purchased', 'lost', 'reopened')
  ),
  constraint ma_events_store_admin_fk foreign key (store_id, admin_user_id)
    references public.stores(id, admin_user_id) on delete cascade,
  constraint ma_events_store_idempotency_key unique (store_id, idempotency_key)
);

create index if not exists ma_events_store_date_idx
  on public.marketing_attribution_events(store_id, event_at desc);
create index if not exists ma_events_lead_date_idx
  on public.marketing_attribution_events(lead_id, event_at);

create table if not exists public.marketing_ad_metrics (
  id uuid primary key default gen_random_uuid(),
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
  store_id uuid not null,
  connection_id uuid not null references public.marketing_attribution_connections(id) on delete cascade,
  metric_date date not null,
  provider text not null,
  account_external_id text not null default '',
  campaign_external_id text not null default '',
  campaign_name text not null default '',
  adset_external_id text not null default '',
  adset_name text not null default '',
  ad_external_id text not null default '',
  ad_name text not null default '',
  creative_external_id text not null default '',
  spend numeric(18,4) not null default 0,
  impressions bigint not null default 0,
  reach bigint not null default 0,
  clicks bigint not null default 0,
  platform_leads numeric(18,4) not null default 0,
  platform_conversions numeric(18,4) not null default 0,
  conversion_value numeric(18,4) not null default 0,
  currency text not null default 'BRL',
  raw_metrics jsonb not null default '{}'::jsonb,
  sync_run_id uuid,
  synced_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint ma_ad_metrics_provider_check check (provider in ('meta', 'google')),
  constraint ma_ad_metrics_nonnegative_check check (
    spend >= 0 and impressions >= 0 and reach >= 0 and clicks >= 0
    and platform_leads >= 0 and platform_conversions >= 0 and conversion_value >= 0
  ),
  constraint ma_ad_metrics_store_admin_fk foreign key (store_id, admin_user_id)
    references public.stores(id, admin_user_id) on delete cascade,
  constraint ma_ad_metrics_unique_row unique (
    connection_id, metric_date, campaign_external_id, adset_external_id, ad_external_id
  )
);

alter table public.marketing_ad_metrics
  add column if not exists sync_run_id uuid;

create index if not exists ma_ad_metrics_store_date_idx
  on public.marketing_ad_metrics(store_id, metric_date desc);
create index if not exists ma_ad_metrics_campaign_idx
  on public.marketing_ad_metrics(store_id, provider, campaign_external_id, metric_date desc);

create table if not exists public.marketing_sync_queue (
  id uuid primary key default gen_random_uuid(),
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
  store_id uuid not null,
  connection_id uuid not null references public.marketing_attribution_connections(id) on delete cascade,
  provider text not null,
  start_date date not null,
  end_date date not null,
  status text not null default 'pending',
  priority smallint not null default 100,
  attempt_count integer not null default 0,
  max_attempts integer not null default 6,
  available_at timestamptz not null default now(),
  locked_at timestamptz,
  locked_by text,
  completed_at timestamptz,
  last_error_code text,
  last_error_message text,
  requested_by uuid references public.app_users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint ma_sync_queue_provider_check check (provider in ('meta', 'google')),
  constraint ma_sync_queue_status_check check (status in ('pending', 'processing', 'retry', 'completed', 'failed', 'cancelled')),
  constraint ma_sync_queue_range_check check (start_date <= end_date and end_date - start_date <= 400),
  constraint ma_sync_queue_store_admin_fk foreign key (store_id, admin_user_id)
    references public.stores(id, admin_user_id) on delete cascade
);

create index if not exists ma_sync_queue_claim_idx
  on public.marketing_sync_queue(status, available_at, priority, created_at);

create table if not exists public.marketing_sync_runs (
  id uuid primary key default gen_random_uuid(),
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
  store_id uuid not null,
  connection_id uuid not null references public.marketing_attribution_connections(id) on delete cascade,
  queue_id uuid references public.marketing_sync_queue(id) on delete set null,
  provider text not null,
  start_date date not null,
  end_date date not null,
  status text not null default 'running',
  rows_received integer not null default 0,
  rows_upserted integer not null default 0,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  error_code text,
  error_message text,
  provider_metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint ma_sync_runs_provider_check check (provider in ('meta', 'google')),
  constraint ma_sync_runs_status_check check (status in ('running', 'completed', 'failed')),
  constraint ma_sync_runs_store_admin_fk foreign key (store_id, admin_user_id)
    references public.stores(id, admin_user_id) on delete cascade
);

create index if not exists ma_sync_runs_store_date_idx
  on public.marketing_sync_runs(store_id, started_at desc);

create table if not exists public.marketing_offline_conversion_queue (
  id uuid primary key default gen_random_uuid(),
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
  store_id uuid not null,
  connection_id uuid not null references public.marketing_attribution_connections(id) on delete cascade,
  lead_id uuid not null references public.leads(id) on delete cascade,
  provider text not null,
  event_name text not null,
  event_at timestamptz not null,
  event_id text not null,
  payload jsonb not null default '{}'::jsonb,
  status text not null default 'pending',
  attempt_count integer not null default 0,
  max_attempts integer not null default 8,
  available_at timestamptz not null default now(),
  locked_at timestamptz,
  locked_by text,
  sent_at timestamptz,
  diagnostic_attempt_count integer not null default 0,
  next_diagnostic_at timestamptz,
  confirmed_at timestamptz,
  provider_receipt jsonb,
  last_error_code text,
  last_error_message text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint ma_conversion_provider_check check (provider in ('meta', 'google')),
  constraint ma_conversion_status_check check (status in ('pending', 'processing', 'retry', 'submitted', 'sent', 'partial', 'failed', 'skipped')),
  constraint ma_conversion_diagnostic_attempt_check check (diagnostic_attempt_count >= 0),
  constraint ma_conversion_store_admin_fk foreign key (store_id, admin_user_id)
    references public.stores(id, admin_user_id) on delete cascade,
  constraint ma_conversion_connection_event_key unique (connection_id, event_id)
);

-- CREATE TABLE IF NOT EXISTS nao acrescenta colunas quando uma versao anterior
-- desta migracao ja foi executada. Estes ALTERs mantem a reaplicacao segura.
alter table public.marketing_offline_conversion_queue
  add column if not exists diagnostic_attempt_count integer not null default 0,
  add column if not exists next_diagnostic_at timestamptz,
  add column if not exists confirmed_at timestamptz;
alter table public.marketing_offline_conversion_queue
  drop constraint if exists ma_conversion_status_check;
alter table public.marketing_offline_conversion_queue
  add constraint ma_conversion_status_check
  check (status in ('pending', 'processing', 'retry', 'submitted', 'sent', 'partial', 'failed', 'skipped'));
alter table public.marketing_offline_conversion_queue
  drop constraint if exists ma_conversion_diagnostic_attempt_check;
alter table public.marketing_offline_conversion_queue
  add constraint ma_conversion_diagnostic_attempt_check
  check (diagnostic_attempt_count >= 0);

create index if not exists ma_conversion_claim_idx
  on public.marketing_offline_conversion_queue(status, available_at, created_at);

create index if not exists ma_conversion_diagnostic_claim_idx
  on public.marketing_offline_conversion_queue(next_diagnostic_at, created_at)
  where status = 'submitted';

create table if not exists public.marketing_attribution_logs (
  id bigint generated always as identity primary key,
  admin_user_id uuid references public.app_users(id) on delete cascade,
  store_id uuid references public.stores(id) on delete cascade,
  connection_id uuid references public.marketing_attribution_connections(id) on delete set null,
  user_id uuid references public.app_users(id) on delete set null,
  level text not null default 'info',
  category text not null default 'system',
  action text not null default 'unknown',
  success boolean not null default true,
  correlation_id text,
  latency_ms integer,
  http_status integer,
  error_code text,
  message text not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint ma_logs_level_check check (level in ('debug', 'info', 'warning', 'error', 'critical'))
);

create index if not exists ma_logs_store_date_idx
  on public.marketing_attribution_logs(store_id, created_at desc);
create index if not exists ma_logs_correlation_idx
  on public.marketing_attribution_logs(correlation_id) where correlation_id is not null;

create table if not exists app_private.marketing_oauth_states (
  state_hash text primary key,
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
  user_id uuid not null references public.app_users(id) on delete cascade,
  store_id uuid not null references public.stores(id) on delete cascade,
  connection_id uuid not null references public.marketing_attribution_connections(id) on delete cascade,
  provider text not null default 'google',
  redirect_after text not null,
  expires_at timestamptz not null,
  consumed_at timestamptz,
  created_at timestamptz not null default now(),
  constraint ma_oauth_provider_check check (provider = 'google')
);

create table if not exists app_private.marketing_maintenance_state (
  task_key text primary key,
  last_run_at timestamptz,
  metadata jsonb not null default '{}'::jsonb
);

do $$
declare v_table text;
begin
  foreach v_table in array array[
    'marketing_attribution_connections', 'marketing_tracking_sources',
    'marketing_touchpoints', 'marketing_attribution_events',
    'marketing_ad_metrics', 'marketing_sync_queue', 'marketing_sync_runs',
    'marketing_offline_conversion_queue', 'marketing_attribution_logs'
  ] loop
    execute format('alter table public.%I enable row level security', v_table);
    execute format('revoke all on table public.%I from public, anon, authenticated', v_table);
  end loop;
end $$;

revoke all on table app_private.marketing_attribution_connection_secrets from public, anon, authenticated;
revoke all on table app_private.marketing_oauth_states from public, anon, authenticated;
revoke all on table app_private.marketing_maintenance_state from public, anon, authenticated;

drop trigger if exists ma_connections_updated_at on public.marketing_attribution_connections;
create trigger ma_connections_updated_at before update on public.marketing_attribution_connections
for each row execute function app_private.ma_set_updated_at();
drop trigger if exists ma_tracking_sources_updated_at on public.marketing_tracking_sources;
create trigger ma_tracking_sources_updated_at before update on public.marketing_tracking_sources
for each row execute function app_private.ma_set_updated_at();
drop trigger if exists ma_ad_metrics_updated_at on public.marketing_ad_metrics;
create trigger ma_ad_metrics_updated_at before update on public.marketing_ad_metrics
for each row execute function app_private.ma_set_updated_at();
drop trigger if exists ma_sync_queue_updated_at on public.marketing_sync_queue;
create trigger ma_sync_queue_updated_at before update on public.marketing_sync_queue
for each row execute function app_private.ma_set_updated_at();
drop trigger if exists ma_conversion_updated_at on public.marketing_offline_conversion_queue;
create trigger ma_conversion_updated_at before update on public.marketing_offline_conversion_queue
for each row execute function app_private.ma_set_updated_at();

-- ---------------------------------------------------------------------------
-- Contrato autenticado consumido pelo frontend
-- ---------------------------------------------------------------------------

create or replace function public.ma_list_connections(
  p_session_token text,
  p_store_id uuid
)
returns jsonb language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_session record; v_result jsonb;
begin
  select * into v_session from app_private.session_user(p_session_token);
  if not app_private.ma_store_allowed(
    v_session.admin_user_id, v_session.user_id, v_session.user_role,
    v_session.user_store_id, p_store_id, false
  ) then raise exception 'Cliente nao encontrado ou sem permissao.'; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', c.id,
    'store_id', c.store_id,
    'provider', c.provider,
    'name', c.name,
    'status', c.status,
    'account_external_id', c.account_external_id,
    'account_name', c.account_name,
    'api_version', c.api_version,
    'token_expires_at', c.token_expires_at,
    'public_config', c.public_config,
    'last_validated_at', c.last_validated_at,
    'last_sync_at', c.last_sync_at,
    'last_error_code', c.last_error_code,
    'last_error_message', c.last_error_message,
    'has_credentials', (s.connection_id is not null),
    'can_configure', v_session.user_role::text in ('admin', 'technician'),
    'created_at', c.created_at,
    'updated_at', c.updated_at
  ) order by c.provider), '[]'::jsonb)
  into v_result
  from public.marketing_attribution_connections c
  left join app_private.marketing_attribution_connection_secrets s
    on s.connection_id = c.id
  where c.store_id = p_store_id
    and c.admin_user_id = v_session.admin_user_id;
  return v_result;
end;
$$;

create or replace function public.ma_get_tracker_config(
  p_session_token text,
  p_store_id uuid
)
returns jsonb language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_session record; v_store record; v_sources jsonb;
begin
  select * into v_session from app_private.session_user(p_session_token);
  if not app_private.ma_store_allowed(
    v_session.admin_user_id, v_session.user_id, v_session.user_role,
    v_session.user_store_id, p_store_id, false
  ) then raise exception 'Cliente nao encontrado ou sem permissao.'; end if;
  select st.id, st.name, st.nick into v_store from public.stores st where st.id=p_store_id;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', s.id, 'name', s.name, 'token_prefix', s.token_prefix,
    'allowed_origins', s.allowed_origins, 'is_active', s.is_active,
    'last_used_at', s.last_used_at, 'created_at', s.created_at
  ) order by s.created_at), '[]'::jsonb)
  into v_sources
  from public.marketing_tracking_sources s
  where s.store_id=p_store_id and s.admin_user_id=v_session.admin_user_id;
  return jsonb_build_object(
    'store', jsonb_build_object('id',v_store.id,'name',v_store.name,'nick',v_store.nick),
    'sources', v_sources,
    'can_configure', v_session.user_role::text in ('admin','technician'),
    'capture_action', 'capture-touchpoint',
    'notice', 'O token completo aparece apenas ao criar ou rotacionar. Instale-o somente em dominios autorizados.'
  );
end;
$$;

create or replace function public.ma_rotate_tracker_token(
  p_session_token text,
  p_store_id uuid,
  p_source_id uuid default null,
  p_name text default 'Site principal',
  p_allowed_origins text[] default '{}'
)
returns jsonb language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_source public.marketing_tracking_sources%rowtype;
  v_token text := encode(extensions.gen_random_bytes(32), 'hex');
  v_origin text;
  v_origins text[] := '{}'::text[];
begin
  select * into v_session from app_private.session_user(p_session_token);
  if not app_private.ma_store_allowed(
    v_session.admin_user_id, v_session.user_id, v_session.user_role,
    v_session.user_store_id, p_store_id, true
  ) then raise exception 'Somente o Admin ou a Agencia responsavel podem configurar o rastreamento.'; end if;
  foreach v_origin in array coalesce(p_allowed_origins, '{}'::text[]) loop
    v_origin := lower(rtrim(btrim(v_origin), '/'));
    if v_origin !~ '^https?://[a-z0-9.-]+(?::[0-9]{1,5})?$' then
      raise exception 'Origem nao permitida: %', v_origin;
    end if;
    if not v_origin = any(v_origins) then v_origins := array_append(v_origins, v_origin); end if;
  end loop;
  if p_source_id is null then
    insert into public.marketing_tracking_sources(
      admin_user_id,store_id,name,token_hash,token_prefix,allowed_origins,created_by
    ) values (
      v_session.admin_user_id,p_store_id,left(coalesce(nullif(btrim(p_name),''),'Site principal'),120),
      encode(extensions.digest(v_token,'sha256'),'hex'),left(v_token,12),v_origins,v_session.user_id
    ) returning * into v_source;
  else
    update public.marketing_tracking_sources set
      token_hash=encode(extensions.digest(v_token,'sha256'),'hex'),
      token_prefix=left(v_token,12),
      name=left(coalesce(nullif(btrim(p_name),''),name),120),
      allowed_origins=v_origins,
      is_active=true
    where id=p_source_id and store_id=p_store_id and admin_user_id=v_session.admin_user_id
    returning * into v_source;
    if not found then raise exception 'Fonte de rastreamento nao encontrada.'; end if;
  end if;
  insert into public.marketing_attribution_logs(
    admin_user_id,store_id,user_id,level,category,action,success,message,metadata
  ) values (
    v_session.admin_user_id,p_store_id,v_session.user_id,'info','tracker','rotate_token',true,
    'Token do rastreador criado ou rotacionado.',jsonb_build_object('source_id',v_source.id,'token_prefix',v_source.token_prefix)
  );
  return jsonb_build_object(
    'source_id',v_source.id,'tracking_token',v_token,'tracker_token',v_token,'public_token',v_token,'token_prefix',v_source.token_prefix,
    'allowed_origins',v_source.allowed_origins,
    'warning','Copie agora. O token completo nao podera ser consultado novamente.'
  );
end;
$$;

create or replace function app_private.ma_enqueue_event_conversions(
  p_event_id uuid,
  p_metadata jsonb default '{}'::jsonb
)
returns integer language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare
  v_event public.marketing_attribution_events%rowtype;
  v_lead public.leads%rowtype;
  v_touch public.marketing_touchpoints%rowtype;
  v_consent boolean := false;
  v_count integer := 0;
begin
  select * into v_event from public.marketing_attribution_events where id=p_event_id;
  if not found then return 0; end if;
  select * into v_lead from public.leads where id=v_event.lead_id;
  if not found then return 0; end if;
  select * into v_touch
  from public.marketing_touchpoints t
  where t.lead_id=v_event.lead_id and t.marketing_consent
    and t.occurred_at<=v_event.event_at+interval '5 minutes'
  order by t.occurred_at desc limit 1;
  v_consent := found or lower(coalesce(p_metadata->>'marketing_consent','false')) in ('true','1','sim','yes');
  if not v_consent then return 0; end if;

  insert into public.marketing_offline_conversion_queue(
    admin_user_id,store_id,connection_id,lead_id,provider,event_name,event_at,event_id,payload
  )
  select
    v_event.admin_user_id,v_event.store_id,c.id,v_event.lead_id,c.provider,
    v_event.event_type,v_event.event_at,'ma:'||v_event.id::text||':'||c.provider,
    jsonb_strip_nulls(jsonb_build_object(
      'value',coalesce(v_event.value,0),
      'currency',coalesce(nullif(v_event.currency,''),'BRL'),
      'order_id',coalesce(nullif(p_metadata->>'order_id',''),v_lead.service_order,v_event.lead_id::text),
      'phone',v_lead.phone,
      'email',nullif(lower(btrim(p_metadata->>'email')),''),
      'external_id',v_event.lead_id::text,
      'gclid',v_touch.gclid,'gbraid',v_touch.gbraid,'wbraid',v_touch.wbraid,
      'fbclid',v_touch.fbclid,'fbc',v_touch.fbc,'fbp',v_touch.fbp,
      'marketing_consent',true,
      'consent_at',coalesce(v_touch.consent_at,nullif(p_metadata->>'consent_at','')::timestamptz),
      'consent_version',coalesce(v_touch.consent_version,p_metadata->>'consent_version'),
      'action_source','physical_store','event_source','IN_STORE'
    ))
  from public.marketing_attribution_connections c
  where c.store_id=v_event.store_id and c.admin_user_id=v_event.admin_user_id
    and c.status in ('active','token_expiring')
    and coalesce(c.public_config->'conversion_events','["purchased"]'::jsonb) ? v_event.event_type
  on conflict(connection_id,event_id) do nothing;
  get diagnostics v_count=row_count;
  return v_count;
end;
$$;

create or replace function public.ma_record_event(
  p_session_token text,
  p_store_id uuid,
  p_lead_id uuid,
  p_event_type text,
  p_payload jsonb default '{}'::jsonb
)
returns jsonb language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record; v_event_id uuid;
  v_event_type text:=lower(btrim(coalesce(p_event_type,'')));
  v_idempotency text; v_attached integer:=0; v_queued integer:=0;
begin
  select * into v_session from app_private.session_user(p_session_token);
  if not app_private.ma_store_allowed(
    v_session.admin_user_id,v_session.user_id,v_session.user_role,
    v_session.user_store_id,p_store_id,false
  ) then raise exception 'Cliente nao encontrado ou sem permissao.'; end if;
  perform 1 from public.leads
  where id=p_lead_id and store_id=p_store_id and admin_user_id=v_session.admin_user_id;
  if not found then raise exception 'Lead nao encontrado nesta loja.'; end if;
  if v_event_type not in ('lead_created','contacted','qualified','scheduled','visited','purchased','lost','reopened') then
    raise exception 'Evento de jornada invalido.';
  end if;
  p_payload:=app_private.ma_json_guard(coalesce(p_payload,'{}'::jsonb),65536,'Evento de jornada');
  if nullif(btrim(p_payload->>'anonymous_id'),'') is not null then
    update public.marketing_touchpoints set lead_id=p_lead_id
    where store_id=p_store_id and lead_id is null
      and anonymous_id=left(btrim(p_payload->>'anonymous_id'),200)
      and occurred_at>=now()-interval '90 days';
    get diagnostics v_attached=row_count;
  end if;
  v_idempotency:=coalesce(nullif(left(btrim(p_payload->>'idempotency_key'),200),''),
    'event:'||p_lead_id::text||':'||v_event_type||':'||coalesce(p_payload->>'event_at',clock_timestamp()::text));
  insert into public.marketing_attribution_events(
    admin_user_id,store_id,lead_id,event_type,event_at,value,currency,actor_user_id,source,idempotency_key,metadata
  ) values (
    v_session.admin_user_id,p_store_id,p_lead_id,v_event_type,
    coalesce(nullif(p_payload->>'event_at','')::timestamptz,now()),
    nullif(p_payload->>'value','')::numeric,
    upper(left(coalesce(nullif(p_payload->>'currency',''),'BRL'),3)),
    v_session.user_id,'app',v_idempotency,p_payload-'idempotency_key'
  ) on conflict(store_id,idempotency_key) do update set metadata=excluded.metadata
  returning id into v_event_id;
  v_queued:=app_private.ma_enqueue_event_conversions(v_event_id,p_payload);
  return jsonb_build_object('event_id',v_event_id,'touchpoints_attached',v_attached,'conversions_queued',v_queued);
end;
$$;

create or replace function app_private.ma_capture_lead_lifecycle()
returns trigger language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_event_id uuid;
begin
  if tg_op='INSERT' then
    insert into public.marketing_attribution_events(
      admin_user_id,store_id,lead_id,event_type,event_at,actor_user_id,source,idempotency_key,metadata
    ) values (
      new.admin_user_id,new.store_id,new.id,'lead_created',coalesce(new.created_at,now()),new.created_by,
      'lead_trigger','lead_created:'||new.id::text,
      jsonb_strip_nulls(jsonb_build_object('channel',new.channel,'campaign',new.campaign))
    ) on conflict(store_id,idempotency_key) do nothing;
  end if;
  if new.scheduled='Sim' and (tg_op='INSERT' or old.scheduled is distinct from 'Sim') then
    insert into public.marketing_attribution_events(
      admin_user_id,store_id,lead_id,event_type,event_at,actor_user_id,source,idempotency_key,metadata
    ) values (
      new.admin_user_id,new.store_id,new.id,'scheduled',now(),new.updated_by,'lead_trigger',
      'scheduled:'||new.id::text,
      jsonb_strip_nulls(jsonb_build_object('visit_date',new.scheduled_visit_date,'visit_time',new.scheduled_visit_time))
    ) on conflict(store_id,idempotency_key) do nothing returning id into v_event_id;
    if v_event_id is not null then perform app_private.ma_enqueue_event_conversions(v_event_id,'{}'); end if;
  end if;
  v_event_id:=null;
  if new.visited='Sim' and (tg_op='INSERT' or old.visited is distinct from 'Sim') then
    insert into public.marketing_attribution_events(
      admin_user_id,store_id,lead_id,event_type,event_at,actor_user_id,source,idempotency_key
    ) values (
      new.admin_user_id,new.store_id,new.id,'visited',now(),new.updated_by,'lead_trigger','visited:'||new.id::text
    ) on conflict(store_id,idempotency_key) do nothing returning id into v_event_id;
    if v_event_id is not null then perform app_private.ma_enqueue_event_conversions(v_event_id,'{}'); end if;
  end if;
  v_event_id:=null;
  if new.bought='Sim' and (tg_op='INSERT' or old.bought is distinct from 'Sim') then
    insert into public.marketing_attribution_events(
      admin_user_id,store_id,lead_id,event_type,event_at,value,currency,actor_user_id,source,idempotency_key,metadata
    ) values (
      new.admin_user_id,new.store_id,new.id,'purchased',now(),new.purchase_amount,'BRL',new.updated_by,
      'lead_trigger','purchased:'||new.id::text,
      jsonb_strip_nulls(jsonb_build_object('order_id',new.service_order))
    ) on conflict(store_id,idempotency_key) do nothing returning id into v_event_id;
    if v_event_id is not null then
      perform app_private.ma_enqueue_event_conversions(v_event_id,jsonb_strip_nulls(jsonb_build_object('order_id',new.service_order)));
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists ma_leads_capture_lifecycle on public.leads;
create trigger ma_leads_capture_lifecycle
after insert or update of scheduled,scheduled_visit_date,scheduled_visit_time,visited,bought,purchase_amount,service_order
on public.leads for each row execute function app_private.ma_capture_lead_lifecycle();

-- Compatibilidade opcional com marketing_intelligence_update.sql. A tabela
-- lead_intelligence pode nao existir; por isso o trigger e instalado de forma
-- condicional sem tornar esta migration dependente da antiga.
create or replace function app_private.ma_capture_lead_intelligence()
returns trigger language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_event_id uuid;v_event_type text;v_event_at timestamptz;v_key text;v_metadata jsonb;
begin
  if new.qualified and (tg_op='INSERT' or not coalesce(old.qualified,false)) then
    v_event_type:='qualified';v_event_at:=coalesce(new.qualified_at,now());v_key:='qualified:'||new.lead_id::text;
  elsif new.lifecycle_status='contacted' and (tg_op='INSERT' or old.lifecycle_status is distinct from 'contacted') then
    v_event_type:='contacted';v_event_at:=coalesce(new.first_response_at,now());v_key:='contacted:'||new.lead_id::text;
  elsif new.lifecycle_status='lost' and (tg_op='INSERT' or old.lifecycle_status is distinct from 'lost') then
    v_event_type:='lost';v_event_at:=coalesce(new.lost_at,now());v_key:='lost:'||new.lead_id::text;
  elsif tg_op='UPDATE' and old.lifecycle_status='lost' and new.lifecycle_status<>'lost' then
    v_event_type:='reopened';v_event_at:=now();v_key:='reopened:'||new.lead_id::text||':'||extract(epoch from clock_timestamp())::bigint;
  else return new; end if;
  v_metadata:=jsonb_strip_nulls(jsonb_build_object('owner_name',new.owner_name,'loss_reason',new.loss_reason,'source','lead_intelligence'));
  insert into public.marketing_attribution_events(
    admin_user_id,store_id,lead_id,event_type,event_at,actor_user_id,source,idempotency_key,metadata
  ) values (
    new.admin_user_id,new.store_id,new.lead_id,v_event_type,v_event_at,null,'lead_intelligence_trigger',v_key,v_metadata
  ) on conflict(store_id,idempotency_key) do update set metadata=excluded.metadata returning id into v_event_id;
  if v_event_type='qualified' then perform app_private.ma_enqueue_event_conversions(v_event_id,v_metadata); end if;
  return new;
end;
$$;

do $$
begin
  if to_regclass('public.lead_intelligence') is not null then
    execute 'drop trigger if exists ma_lead_intelligence_lifecycle on public.lead_intelligence';
    execute 'create trigger ma_lead_intelligence_lifecycle after insert or update of lifecycle_status,qualified,qualified_at,lost_at on public.lead_intelligence for each row execute function app_private.ma_capture_lead_intelligence()';
    execute $backfill$
      insert into public.marketing_attribution_events(
        admin_user_id,store_id,lead_id,event_type,event_at,source,idempotency_key,metadata
      )
      select li.admin_user_id,li.store_id,li.lead_id,'qualified',coalesce(li.qualified_at,li.updated_at,now()),
        'migration','qualified:'||li.lead_id::text,
        jsonb_strip_nulls(jsonb_build_object('owner_name',li.owner_name,'source','lead_intelligence'))
      from public.lead_intelligence li where li.qualified
      on conflict(store_id,idempotency_key) do nothing
    $backfill$;
  end if;
end $$;

insert into public.marketing_attribution_events(
  admin_user_id,store_id,lead_id,event_type,event_at,value,currency,actor_user_id,source,idempotency_key,metadata
)
select l.admin_user_id,l.store_id,l.id,'lead_created',l.created_at,null,'BRL',l.created_by,
  'migration','lead_created:'||l.id::text,
  jsonb_strip_nulls(jsonb_build_object('channel',l.channel,'campaign',l.campaign))
from public.leads l
on conflict(store_id,idempotency_key) do nothing;

insert into public.marketing_attribution_events(
  admin_user_id,store_id,lead_id,event_type,event_at,value,currency,actor_user_id,source,idempotency_key,metadata
)
select l.admin_user_id,l.store_id,l.id,'purchased',coalesce(l.updated_at,l.created_at),l.purchase_amount,'BRL',l.updated_by,
  'migration','purchased:'||l.id::text,
  jsonb_strip_nulls(jsonb_build_object('order_id',l.service_order))
from public.leads l where l.bought='Sim'
on conflict(store_id,idempotency_key) do nothing;

create or replace function public.ma_get_dashboard(
  p_session_token text,
  p_store_id uuid,
  p_start_date date default null,
  p_end_date date default null
)
returns jsonb language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_start date:=coalesce(p_start_date,date_trunc('month',current_date)::date);
  v_end date:=coalesce(p_end_date,current_date);
  v_spend numeric:=0; v_impressions bigint:=0; v_reach bigint:=0; v_clicks bigint:=0;
  v_platform_conversions numeric:=0; v_platform_value numeric:=0;
  v_leads bigint:=0; v_qualified bigint:=0; v_visited bigint:=0; v_purchases bigint:=0;
  v_revenue numeric:=0; v_attributed bigint:=0;
  v_by_provider jsonb; v_campaigns jsonb; v_series jsonb; v_connections jsonb;
  v_click_id_count bigint:=0; v_utm_count bigint:=0;
begin
  select * into v_session from app_private.session_user(p_session_token);
  if not app_private.ma_store_allowed(
    v_session.admin_user_id,v_session.user_id,v_session.user_role,
    v_session.user_store_id,p_store_id,false
  ) then raise exception 'Cliente nao encontrado ou sem permissao.'; end if;
  if v_start>v_end or v_end-v_start>730 then raise exception 'Periodo invalido ou superior a 730 dias.'; end if;

  select coalesce(sum(spend),0),coalesce(sum(impressions),0),coalesce(sum(reach),0),coalesce(sum(clicks),0),
    coalesce(sum(platform_conversions),0),coalesce(sum(conversion_value),0)
  into v_spend,v_impressions,v_reach,v_clicks,v_platform_conversions,v_platform_value
  from public.marketing_ad_metrics
  where store_id=p_store_id and metric_date between v_start and v_end;

  select count(*) into v_leads from public.leads
  where store_id=p_store_id and created_at>=v_start::timestamptz and created_at<(v_end+1)::timestamptz;
  select
    count(distinct lead_id) filter(where event_type='qualified'),
    count(distinct lead_id) filter(where event_type='visited'),
    count(distinct lead_id) filter(where event_type='purchased'),
    coalesce(sum(value) filter(where event_type='purchased'),0)
  into v_qualified,v_visited,v_purchases,v_revenue
  from public.marketing_attribution_events
  where store_id=p_store_id and event_at>=v_start::timestamptz and event_at<(v_end+1)::timestamptz;
  select count(distinct t.lead_id),
    count(distinct t.lead_id) filter(where coalesce(t.gclid,t.gbraid,t.wbraid,t.fbclid) is not null),
    count(distinct t.lead_id) filter(where coalesce(t.utm_source,t.utm_campaign) is not null)
  into v_attributed,v_click_id_count,v_utm_count
  from public.marketing_touchpoints t
  join public.leads l on l.id=t.lead_id
  where t.store_id=p_store_id and l.created_at>=v_start::timestamptz and l.created_at<(v_end+1)::timestamptz;

  with providers(provider) as (values('meta'::text),('google'::text)),
  metric as (
    select provider,sum(spend) spend,sum(impressions) impressions,sum(clicks) clicks,
      sum(platform_conversions) platform_conversions,sum(conversion_value) platform_value
    from public.marketing_ad_metrics where store_id=p_store_id and metric_date between v_start and v_end
    group by provider
  ), selected_touch as (
    select distinct on(t.lead_id) t.*,l.created_at as lead_created_at
    from public.marketing_touchpoints t join public.leads l on l.id=t.lead_id
    where t.store_id=p_store_id and l.created_at>=v_start::timestamptz and l.created_at<(v_end+1)::timestamptz
    order by t.lead_id,t.occurred_at desc,t.id desc
  ), attributed as (
    select coalesce(t.provider,case when t.gclid is not null or t.gbraid is not null or t.wbraid is not null then 'google' when t.fbclid is not null or t.fbc is not null then 'meta' end) provider,
      count(*) leads
    from selected_touch t
    group by 1
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'provider',p.provider,'spend',coalesce(m.spend,0),'impressions',coalesce(m.impressions,0),
    'clicks',coalesce(m.clicks,0),'platform_conversions',coalesce(m.platform_conversions,0),
    'platform_conversion_value',coalesce(m.platform_value,0),'attributed_leads',coalesce(a.leads,0),
    'cpl',case when coalesce(a.leads,0)>0 then round(m.spend/a.leads,2) end
  ) order by p.provider),'[]'::jsonb) into v_by_provider
  from providers p left join metric m on m.provider=p.provider left join attributed a on a.provider=p.provider;

  with metric as (
    select provider,campaign_external_id,max(campaign_name) campaign_name,
      sum(spend) spend,sum(impressions) impressions,sum(clicks) clicks,
      sum(platform_conversions) platform_conversions,sum(conversion_value) platform_value
    from public.marketing_ad_metrics
    where store_id=p_store_id and metric_date between v_start and v_end
    group by provider,campaign_external_id
  ), selected_touch as (
    select distinct on(t.lead_id) t.*
    from public.marketing_touchpoints t join public.leads l on l.id=t.lead_id
    where t.store_id=p_store_id and l.created_at>=v_start::timestamptz and l.created_at<(v_end+1)::timestamptz
    order by t.lead_id,t.occurred_at desc,t.id desc
  ), attributed as (
    select coalesce(t.provider,case when coalesce(t.gclid,t.gbraid,t.wbraid) is not null then 'google' when coalesce(t.fbclid,t.fbc) is not null then 'meta' else 'other' end) provider,
      coalesce(t.campaign_external_id,t.utm_campaign,'') campaign_external_id,
      count(*) leads
    from selected_touch t
    group by 1,2
  ), combined as (
    select coalesce(m.provider,a.provider) provider,
      coalesce(m.campaign_external_id,a.campaign_external_id) campaign_external_id,
      coalesce(nullif(m.campaign_name,''),nullif(a.campaign_external_id,''),'Sem campanha') campaign_name,
      coalesce(m.spend,0) spend,coalesce(m.impressions,0) impressions,coalesce(m.clicks,0) clicks,
      coalesce(m.platform_conversions,0) platform_conversions,coalesce(m.platform_value,0) platform_value,
      coalesce(a.leads,0) leads
    from metric m full join attributed a on a.provider=m.provider and a.campaign_external_id=m.campaign_external_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'provider',provider,'campaign_external_id',campaign_external_id,'campaign_name',campaign_name,
    'spend',spend,'impressions',impressions,'clicks',clicks,'attributed_leads',leads,
    'platform_conversions',platform_conversions,'platform_conversion_value',platform_value,
    'cpl',case when leads>0 then round(spend/leads,2) end,
    'ctr',case when impressions>0 then round((clicks::numeric/impressions)*100,2) end
  ) order by spend desc),'[]'::jsonb) into v_campaigns from (select * from combined order by spend desc limit 100) ranked;

  with days as (select generate_series(v_start,v_end,interval '1 day')::date metric_day),
  metric as (
    select metric_date metric_day,sum(spend) spend,sum(impressions) impressions,sum(clicks) clicks
    from public.marketing_ad_metrics where store_id=p_store_id and metric_date between v_start and v_end group by metric_date
  ), lead_count as (
    select created_at::date metric_day,count(*) leads from public.leads
    where store_id=p_store_id and created_at>=v_start::timestamptz and created_at<(v_end+1)::timestamptz group by created_at::date
  ), event_count as (
    select event_at::date metric_day,count(distinct lead_id) filter(where event_type='qualified') qualified,
      count(distinct lead_id) filter(where event_type='purchased') purchases,
      coalesce(sum(value) filter(where event_type='purchased'),0) revenue
    from public.marketing_attribution_events
    where store_id=p_store_id and event_at>=v_start::timestamptz and event_at<(v_end+1)::timestamptz group by event_at::date
  )
  select jsonb_agg(jsonb_build_object(
    'date',d.metric_day,'spend',coalesce(m.spend,0),'impressions',coalesce(m.impressions,0),
    'clicks',coalesce(m.clicks,0),'leads',coalesce(l.leads,0),'qualified',coalesce(e.qualified,0),
    'purchases',coalesce(e.purchases,0),'revenue',coalesce(e.revenue,0)
  ) order by d.metric_day) into v_series
  from days d left join metric m on m.metric_day=d.metric_day left join lead_count l on l.metric_day=d.metric_day left join event_count e on e.metric_day=d.metric_day;

  v_connections:=public.ma_list_connections(p_session_token,p_store_id);
  return jsonb_build_object(
    'store_id',p_store_id,'period',jsonb_build_object('start_date',v_start,'end_date',v_end),
    'summary',jsonb_build_object(
      'spend',v_spend,'impressions',v_impressions,'reach',v_reach,'clicks',v_clicks,'leads',v_leads,
      'attributed_leads',v_attributed,'qualified',v_qualified,'visited',v_visited,
      'purchases',v_purchases,'revenue',v_revenue,'platform_conversions',v_platform_conversions,
      'platform_conversion_value',v_platform_value,
      'ctr',case when v_impressions>0 then round((v_clicks::numeric/v_impressions)*100,2) end,
      'cpc',case when v_clicks>0 then round(v_spend/v_clicks,2) end,
      'cpl',case when v_leads>0 then round(v_spend/v_leads,2) end,
      'cost_per_qualified',case when v_qualified>0 then round(v_spend/v_qualified,2) end,
      'cac',case when v_purchases>0 then round(v_spend/v_purchases,2) end,
      'roas',case when v_spend>0 then round(v_revenue/v_spend,2) end,
      'lead_to_sale_rate',case when v_leads>0 then round((v_purchases::numeric/v_leads)*100,2) end
    ),
    'funnel',jsonb_build_array(
      jsonb_build_object('stage','leads','value',v_leads),
      jsonb_build_object('stage','qualified','value',v_qualified),
      jsonb_build_object('stage','visited','value',v_visited),
      jsonb_build_object('stage','purchased','value',v_purchases)
    ),
    'data_quality',jsonb_build_object(
      'attributed_leads',v_attributed,'click_id_leads',v_click_id_count,'utm_leads',v_utm_count,
      'attribution_rate',case when v_leads>0 then round((v_attributed::numeric/v_leads)*100,2) else 0 end
    ),
    'by_provider',v_by_provider,'campaigns',v_campaigns,'series',coalesce(v_series,'[]'::jsonb),
    'connections',v_connections,
    'last_sync_at',(select max(c.last_sync_at) from public.marketing_attribution_connections c where c.store_id=p_store_id)
  );
end;
$$;

create or replace function public.ma_list_journey(
  p_session_token text,
  p_store_id uuid,
  p_lead_id uuid default null,
  p_start_date date default null,
  p_end_date date default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record; v_items jsonb; v_total bigint; v_unmatched bigint;
  v_limit integer:=least(greatest(coalesce(p_limit,50),1),100);
  v_offset integer:=greatest(coalesce(p_offset,0),0);
  v_start date:=coalesce(p_start_date,current_date-interval '30 days');
  v_end date:=coalesce(p_end_date,current_date);
begin
  select * into v_session from app_private.session_user(p_session_token);
  if not app_private.ma_store_allowed(v_session.admin_user_id,v_session.user_id,v_session.user_role,v_session.user_store_id,p_store_id,false)
  then raise exception 'Cliente nao encontrado ou sem permissao.'; end if;
  if v_start>v_end or v_end-v_start>730 then raise exception 'Periodo invalido ou superior a 730 dias.'; end if;
  select count(*) into v_total from public.leads l
  where l.store_id=p_store_id and (p_lead_id is null or l.id=p_lead_id)
    and l.created_at>=v_start::timestamptz and l.created_at<(v_end+1)::timestamptz;
  with page as (
    select l.* from public.leads l
    where l.store_id=p_store_id and (p_lead_id is null or l.id=p_lead_id)
      and l.created_at>=v_start::timestamptz and l.created_at<(v_end+1)::timestamptz
    order by l.created_at desc limit v_limit offset v_offset
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'lead_id',p.id,
    'lead_name',p.name,
    'name',p.name,
    'provider',coalesce((select t.provider from public.marketing_touchpoints t where t.lead_id=p.id order by t.occurred_at desc,t.id desc limit 1),'direct'),
    'platform',coalesce((select t.provider from public.marketing_touchpoints t where t.lead_id=p.id order by t.occurred_at desc,t.id desc limit 1),'direct'),
    'utm_source',(select t.utm_source from public.marketing_touchpoints t where t.lead_id=p.id order by t.occurred_at desc,t.id desc limit 1),
    'utm_campaign',(select t.utm_campaign from public.marketing_touchpoints t where t.lead_id=p.id order by t.occurred_at desc,t.id desc limit 1),
    'campaign_name',coalesce(
      (select t.utm_campaign from public.marketing_touchpoints t where t.lead_id=p.id order by t.occurred_at desc,t.id desc limit 1),
      p.campaign
    ),
    'first_touch_at',(select min(t.occurred_at) from public.marketing_touchpoints t where t.lead_id=p.id),
    'touchpoint_at',(select max(t.occurred_at) from public.marketing_touchpoints t where t.lead_id=p.id),
    'lead_created_at',p.created_at,
    'created_at',p.created_at,
    'qualified_at',(select min(e.event_at) from public.marketing_attribution_events e where e.lead_id=p.id and e.event_type='qualified'),
    'qualified',exists(select 1 from public.marketing_attribution_events e where e.lead_id=p.id and e.event_type='qualified'),
    'purchased_at',(select min(e.event_at) from public.marketing_attribution_events e where e.lead_id=p.id and e.event_type='purchased'),
    'purchased',(p.bought='Sim' or exists(select 1 from public.marketing_attribution_events e where e.lead_id=p.id and e.event_type='purchased')),
    'lead',jsonb_build_object(
      'id',p.id,'name',p.name,'phone',p.phone,'channel',p.channel,'campaign',p.campaign,
      'scheduled',p.scheduled,'visited',p.visited,'bought',p.bought,
      'purchase_amount',p.purchase_amount,'created_at',p.created_at,'updated_at',p.updated_at
    ),
    'touchpoints',coalesce((select jsonb_agg(jsonb_build_object(
      'id',t.id,'event_name',t.event_name,'occurred_at',t.occurred_at,'provider',t.provider,
      'utm_source',t.utm_source,'utm_medium',t.utm_medium,'utm_campaign',t.utm_campaign,
      'utm_content',t.utm_content,'utm_term',t.utm_term,
      'campaign_external_id',t.campaign_external_id,'adset_external_id',t.adset_external_id,
      'ad_external_id',t.ad_external_id,'creative_external_id',t.creative_external_id,
      'has_gclid',(t.gclid is not null),'has_gbraid',(t.gbraid is not null),'has_wbraid',(t.wbraid is not null),
      'has_fbclid',(t.fbclid is not null),'landing_page_url',t.landing_page_url,
      'referrer_url',t.referrer_url,'marketing_consent',t.marketing_consent,
      'consent_at',t.consent_at,'metadata',t.metadata
    ) order by t.occurred_at) from public.marketing_touchpoints t where t.lead_id=p.id),'[]'::jsonb),
    'events',coalesce((select jsonb_agg(jsonb_build_object(
      'id',e.id,'event_type',e.event_type,'event_at',e.event_at,'value',e.value,
      'currency',e.currency,'source',e.source,'metadata',e.metadata
    ) order by e.event_at) from public.marketing_attribution_events e where e.lead_id=p.id),'[]'::jsonb)
  ) order by p.created_at desc),'[]'::jsonb) into v_items from page p;
  select count(*) into v_unmatched from public.marketing_touchpoints t
  where t.store_id=p_store_id and t.lead_id is null
    and t.occurred_at>=v_start::timestamptz and t.occurred_at<(v_end+1)::timestamptz;
  return jsonb_build_object('items',v_items,'total',v_total,'limit',v_limit,'offset',v_offset,'unmatched_touchpoints',v_unmatched);
end;
$$;

create or replace function public.ma_list_sync_runs(
  p_session_token text,p_store_id uuid,p_limit integer default 50,p_offset integer default 0
)
returns jsonb language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_session record;v_items jsonb;v_total bigint;v_limit integer:=least(greatest(coalesce(p_limit,50),1),200);v_offset integer:=greatest(coalesce(p_offset,0),0);
begin
  select * into v_session from app_private.session_user(p_session_token);
  if not app_private.ma_store_allowed(v_session.admin_user_id,v_session.user_id,v_session.user_role,v_session.user_store_id,p_store_id,false)
  then raise exception 'Cliente nao encontrado ou sem permissao.'; end if;
  select count(*) into v_total from public.marketing_sync_runs where store_id=p_store_id;
  select coalesce(jsonb_agg(to_jsonb(r)-'admin_user_id' order by r.started_at desc),'[]'::jsonb) into v_items
  from (select * from public.marketing_sync_runs where store_id=p_store_id order by started_at desc limit v_limit offset v_offset) r;
  return jsonb_build_object('items',v_items,'total',v_total,'limit',v_limit,'offset',v_offset);
end;
$$;

create or replace function public.ma_disconnect_connection(
  p_session_token text,p_connection_id uuid,p_purge_credentials boolean default false
)
returns boolean language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_session record;v_connection public.marketing_attribution_connections%rowtype;
begin
  select * into v_session from app_private.session_user(p_session_token);
  select * into v_connection from public.marketing_attribution_connections where id=p_connection_id and admin_user_id=v_session.admin_user_id;
  if not found or not app_private.ma_store_allowed(v_session.admin_user_id,v_session.user_id,v_session.user_role,v_session.user_store_id,v_connection.store_id,true)
  then raise exception 'Conexao nao encontrada ou sem permissao.'; end if;
  update public.marketing_attribution_connections set status='disconnected',last_error_code=null,last_error_message=null,updated_by=v_session.user_id where id=p_connection_id;
  update public.marketing_sync_queue set status='cancelled',completed_at=now(),last_error_message='Conexao desconectada.'
    where connection_id=p_connection_id and status in ('pending','retry');
  update public.marketing_offline_conversion_queue set status='skipped',last_error_code='connection_disconnected',last_error_message='Conexao desconectada.'
    where connection_id=p_connection_id and status in ('pending','retry');
  if coalesce(p_purge_credentials,false) then
    delete from app_private.marketing_attribution_connection_secrets where connection_id=p_connection_id;
  end if;
  return true;
end;
$$;

create or replace function public.ma_schedule_sync(
  p_session_token text,p_store_id uuid,p_provider text default null,
  p_start_date date default null,p_end_date date default null
)
returns jsonb language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;v_connection record;v_start date:=coalesce(p_start_date,current_date-interval '30 days');
  v_end date:=coalesce(p_end_date,current_date);v_job_id uuid;v_jobs jsonb:='[]'::jsonb;
  v_chunk_start date;v_chunk_end date;
begin
  select * into v_session from app_private.session_user(p_session_token);
  if not app_private.ma_store_allowed(v_session.admin_user_id,v_session.user_id,v_session.user_role,v_session.user_store_id,p_store_id,true)
  then raise exception 'Somente o Admin ou a Agencia responsavel podem sincronizar esta loja.'; end if;
  if v_start>v_end or v_end-v_start>730 then raise exception 'Periodo invalido ou superior a 730 dias.'; end if;
  if p_provider is not null and lower(p_provider) not in ('meta','google') then raise exception 'Provedor invalido.'; end if;
  for v_connection in select * from public.marketing_attribution_connections c
    where c.store_id=p_store_id and c.admin_user_id=v_session.admin_user_id
      and c.status in ('active','token_expiring') and (p_provider is null or c.provider=lower(p_provider))
  loop
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('ma:sync:'||v_connection.id::text,0));
    v_chunk_start:=v_start;
    while v_chunk_start<=v_end loop
      -- A fila e os clientes de API aceitam no maximo 400 dias de
      -- diferenca. Periodos analiticos de ate 730 dias sao divididos no
      -- servidor sem exigir chamadas adicionais do navegador.
      v_chunk_end:=least(v_chunk_start+400,v_end);
      select q.id into v_job_id from public.marketing_sync_queue q
      where q.connection_id=v_connection.id and q.status in ('pending','processing','retry')
        and q.start_date=v_chunk_start and q.end_date=v_chunk_end order by q.created_at desc limit 1;
      if v_job_id is null then
        insert into public.marketing_sync_queue(
          admin_user_id,store_id,connection_id,provider,start_date,end_date,requested_by
        ) values (
          v_session.admin_user_id,p_store_id,v_connection.id,v_connection.provider,
          v_chunk_start,v_chunk_end,v_session.user_id
        ) returning id into v_job_id;
      end if;
      v_jobs:=v_jobs||jsonb_build_array(jsonb_build_object(
        'job_id',v_job_id,'connection_id',v_connection.id,'provider',v_connection.provider,
        'start_date',v_chunk_start,'end_date',v_chunk_end
      ));
      v_job_id:=null;
      v_chunk_start:=v_chunk_end+1;
    end loop;
  end loop;
  if jsonb_array_length(v_jobs)=0 then raise exception 'Nenhum conector ativo para sincronizar.'; end if;
  return jsonb_build_object('jobs',v_jobs,'start_date',v_start,'end_date',v_end);
end;
$$;

-- ---------------------------------------------------------------------------
-- RPCs exclusivas das Edge Functions (service_role)
-- ---------------------------------------------------------------------------

create or replace function public.ma_service_save_connection(
  p_session_token text,p_payload jsonb,p_encryption_key text
)
returns jsonb language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;v_connection public.marketing_attribution_connections%rowtype;
  v_connection_id uuid:=nullif(p_payload->>'connection_id','')::uuid;
  v_store_id uuid:=nullif(p_payload->>'store_id','')::uuid;
  v_provider text:=lower(btrim(coalesce(p_payload->>'provider','')));
  v_existing jsonb:='{}'::jsonb;v_secrets jsonb:='{}'::jsonb;v_public jsonb:='{}'::jsonb;
  v_account text;v_version text;v_name text;
begin
  if length(coalesce(p_encryption_key,''))<32 then raise exception 'MARKETING_CREDENTIALS_KEY ausente ou insegura.'; end if;
  p_payload:=app_private.ma_json_guard(coalesce(p_payload,'{}'::jsonb),131072,'Configuracao do conector');
  select * into v_session from app_private.session_user(p_session_token);
  if v_connection_id is not null then
    select * into v_connection from public.marketing_attribution_connections
    where id=v_connection_id and admin_user_id=v_session.admin_user_id;
    if not found then raise exception 'Conexao nao encontrada.'; end if;
    v_store_id:=v_connection.store_id;v_provider:=v_connection.provider;
  end if;
  if v_provider not in ('meta','google') then raise exception 'Provedor deve ser meta ou google.'; end if;
  if not app_private.ma_store_allowed(v_session.admin_user_id,v_session.user_id,v_session.user_role,v_session.user_store_id,v_store_id,true)
  then raise exception 'Somente o Admin ou a Agencia responsavel podem configurar esta loja.'; end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('ma:connection:'||v_store_id::text||':'||v_provider,0)
  );

  -- O frontend pode atualizar por loja+provedor sem conhecer o UUID. Resolva
  -- a conexao antes de validar/mesclar segredos para preservar credenciais
  -- omitidas no formulario.
  if v_connection_id is null then
    select * into v_connection from public.marketing_attribution_connections
    where store_id=v_store_id and provider=v_provider and admin_user_id=v_session.admin_user_id;
    if found then v_connection_id:=v_connection.id; end if;
  end if;

  if v_connection_id is not null and exists(select 1 from app_private.marketing_attribution_connection_secrets where connection_id=v_connection_id) then
    begin
      select extensions.pgp_sym_decrypt(secret_cipher,p_encryption_key)::jsonb into v_existing
      from app_private.marketing_attribution_connection_secrets where connection_id=v_connection_id;
    exception when others then
      raise exception 'Nao foi possivel decifrar as credenciais. Verifique MARKETING_CREDENTIALS_KEY.';
    end;
  end if;

  if v_provider='meta' then
    v_account:=regexp_replace(coalesce(nullif(p_payload->>'ad_account_id',''),nullif(p_payload->>'account_external_id',''),v_connection.account_external_id,''),'[^0-9]','','g');
    if v_account='' then raise exception 'Ad Account ID da Meta obrigatorio.'; end if;
    v_version:=coalesce(nullif(p_payload->>'api_version',''),nullif(v_connection.api_version,''),'v26.0');
    if v_version !~ '^v[0-9]{2,3}([.][0-9]+)?$' then raise exception 'Versao da API Meta invalida.'; end if;
    v_public:=coalesce(v_connection.public_config,'{}'::jsonb)
      || app_private.ma_json_guard(coalesce(p_payload->'public_config','{}'::jsonb),65536,'Configuracao publica')
      || jsonb_strip_nulls(jsonb_build_object(
        'ad_account_id',v_account,
        'dataset_id',nullif(btrim(coalesce(p_payload->>'dataset_id',p_payload->>'pixel_id')),''),
        'conversion_events',coalesce(p_payload->'conversion_events',p_payload->'public_config'->'conversion_events')
      ));
    if nullif(btrim(coalesce(v_public->>'dataset_id',v_public->>'pixel_id','')),'') is null then
      raise exception 'Dataset ID ou Pixel ID da Meta obrigatorio para a Conversions API.';
    end if;
    v_secrets:=v_existing||jsonb_strip_nulls(jsonb_build_object(
      'access_token',nullif(btrim(p_payload->>'access_token'),''),
      'test_event_code',nullif(btrim(p_payload->>'test_event_code'),''),
      'app_id',nullif(btrim(p_payload->>'app_id'),''),
      'app_secret',nullif(btrim(p_payload->>'app_secret'),'')
    ));
    if length(coalesce(v_secrets->>'access_token',''))<20 then raise exception 'Access Token de longa duracao ou System User Token da Meta obrigatorio.'; end if;
  else
    v_account:=regexp_replace(coalesce(nullif(p_payload->>'customer_id',''),nullif(p_payload->>'account_external_id',''),v_connection.account_external_id,''),'[^0-9]','','g');
    if v_account='' then raise exception 'Customer ID do Google Ads obrigatorio.'; end if;
    v_version:=coalesce(nullif(p_payload->>'api_version',''),nullif(v_connection.api_version,''),'v25');
    if v_version !~ '^v[0-9]{2,3}$' then raise exception 'Versao da Google Ads API invalida.'; end if;
    v_public:=coalesce(v_connection.public_config,'{}'::jsonb)
      || app_private.ma_json_guard(coalesce(p_payload->'public_config','{}'::jsonb),65536,'Configuracao publica')
      || jsonb_strip_nulls(jsonb_build_object(
        'customer_id',v_account,
        'login_customer_id',nullif(regexp_replace(coalesce(p_payload->>'login_customer_id',''),'[^0-9]','','g'),''),
        'conversion_action_id',nullif(btrim(p_payload->>'conversion_action_id'),''),
        'conversion_events',coalesce(p_payload->'conversion_events',p_payload->'public_config'->'conversion_events')
      ));
    if nullif(btrim(coalesce(v_public->>'conversion_action_id','')),'') is null then
      raise exception 'Conversion Action ID do Google obrigatorio para conversoes offline.';
    end if;
    v_secrets:=v_existing||jsonb_strip_nulls(jsonb_build_object(
      'developer_token',nullif(btrim(p_payload->>'developer_token'),''),
      'client_id',nullif(btrim(p_payload->>'client_id'),''),
      'client_secret',nullif(btrim(p_payload->>'client_secret'),''),
      'refresh_token',nullif(btrim(p_payload->>'refresh_token'),''),
      'access_token',nullif(btrim(p_payload->>'access_token'),''),
      'access_token_expires_at',nullif(btrim(p_payload->>'access_token_expires_at'),'')
    ));
    if length(coalesce(v_secrets->>'developer_token',''))<10 then raise exception 'Developer Token do Google Ads obrigatorio.'; end if;
    if length(coalesce(v_secrets->>'client_id',''))<10 or length(coalesce(v_secrets->>'client_secret',''))<8 then
      raise exception 'Client ID e Client Secret OAuth do Google obrigatorios.';
    end if;
  end if;
  v_public:=v_public
    -'access_token'-'refresh_token'-'developer_token'-'client_secret'
    -'app_secret'-'test_event_code'-'credentials';
  v_name:=left(coalesce(nullif(btrim(p_payload->>'name'),''),nullif(v_connection.name,''),case when v_provider='meta' then 'Meta Ads' else 'Google Ads' end),160);
  if octet_length(v_secrets::text)>32768 then raise exception 'Credenciais excedem o tamanho permitido.'; end if;
  if v_connection_id is null then
    insert into public.marketing_attribution_connections(
      admin_user_id,store_id,provider,name,status,account_external_id,api_version,token_expires_at,public_config,created_by,updated_by
    ) values (
      v_session.admin_user_id,v_store_id,v_provider,v_name,'draft',v_account,v_version,
      nullif(p_payload->>'token_expires_at','')::timestamptz,v_public,v_session.user_id,v_session.user_id
    ) on conflict(store_id,provider) do update set
      name=excluded.name,account_external_id=excluded.account_external_id,api_version=excluded.api_version,
      public_config=excluded.public_config,status='draft',updated_by=excluded.updated_by
    returning * into v_connection;
    v_connection_id:=v_connection.id;
  else
    update public.marketing_attribution_connections set
      name=v_name,account_external_id=v_account,api_version=v_version,public_config=v_public,
      token_expires_at=case when p_payload?'token_expires_at' then nullif(p_payload->>'token_expires_at','')::timestamptz else token_expires_at end,
      status='draft',last_error_code=null,last_error_message=null,updated_by=v_session.user_id
    where id=v_connection_id returning * into v_connection;
  end if;
  insert into app_private.marketing_attribution_connection_secrets as current_secrets(
    connection_id,secret_cipher,secret_version,rotated_at
  ) values (
    v_connection_id,extensions.pgp_sym_encrypt(v_secrets::text,p_encryption_key,'cipher-algo=aes256,compress-algo=1'),1,now()
  ) on conflict(connection_id) do update set
    secret_cipher=excluded.secret_cipher,secret_version=current_secrets.secret_version+1,rotated_at=now();
  return jsonb_build_object(
    'id',v_connection_id,'store_id',v_store_id,'provider',v_provider,'status','draft',
    'account_external_id',v_account,'name',v_name,'api_version',v_version,'public_config',v_public,'has_credentials',true
  );
end;
$$;

create or replace function public.ma_service_connection_runtime(
  p_session_token text,p_connection_id uuid,p_encryption_key text,p_configuration_write boolean default false
)
returns jsonb language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_session record;v_connection public.marketing_attribution_connections%rowtype;v_secrets jsonb;
begin
  if length(coalesce(p_encryption_key,''))<32 then raise exception 'MARKETING_CREDENTIALS_KEY ausente.'; end if;
  select * into v_session from app_private.session_user(p_session_token);
  select * into v_connection from public.marketing_attribution_connections where id=p_connection_id and admin_user_id=v_session.admin_user_id;
  if not found or not app_private.ma_store_allowed(v_session.admin_user_id,v_session.user_id,v_session.user_role,v_session.user_store_id,v_connection.store_id,p_configuration_write)
  then raise exception 'Conexao nao encontrada ou sem permissao.'; end if;
  begin
    select extensions.pgp_sym_decrypt(secret_cipher,p_encryption_key)::jsonb into v_secrets
    from app_private.marketing_attribution_connection_secrets where connection_id=p_connection_id;
  exception when others then raise exception 'Nao foi possivel decifrar as credenciais.'; end;
  if v_secrets is null then raise exception 'Credenciais ainda nao configuradas.'; end if;
  return to_jsonb(v_connection)-'created_by'-'updated_by'||jsonb_build_object('secrets',v_secrets);
end;
$$;

create or replace function public.ma_service_connection_runtime_by_id(
  p_connection_id uuid,p_encryption_key text
)
returns jsonb language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_connection public.marketing_attribution_connections%rowtype;v_secrets jsonb;
begin
  if length(coalesce(p_encryption_key,''))<32 then raise exception 'MARKETING_CREDENTIALS_KEY ausente.'; end if;
  select * into v_connection from public.marketing_attribution_connections where id=p_connection_id;
  if not found then raise exception 'Conexao nao encontrada.'; end if;
  begin
    select extensions.pgp_sym_decrypt(secret_cipher,p_encryption_key)::jsonb into v_secrets
    from app_private.marketing_attribution_connection_secrets where connection_id=p_connection_id;
  exception when others then raise exception 'Nao foi possivel decifrar as credenciais.'; end;
  if v_secrets is null then raise exception 'Credenciais ainda nao configuradas.'; end if;
  return to_jsonb(v_connection)-'created_by'-'updated_by'||jsonb_build_object('secrets',v_secrets);
end;
$$;

create or replace function public.ma_service_update_connection_secrets(
  p_connection_id uuid,p_encryption_key text,p_patch jsonb
)
returns boolean language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_existing jsonb;v_new jsonb;
begin
  if length(coalesce(p_encryption_key,''))<32 then raise exception 'MARKETING_CREDENTIALS_KEY ausente.'; end if;
  p_patch:=app_private.ma_json_guard(coalesce(p_patch,'{}'::jsonb),32768,'Atualizacao de credencial');
  begin
    select extensions.pgp_sym_decrypt(secret_cipher,p_encryption_key)::jsonb into v_existing
    from app_private.marketing_attribution_connection_secrets where connection_id=p_connection_id for update;
  exception when others then raise exception 'Nao foi possivel decifrar as credenciais.'; end;
  if v_existing is null then raise exception 'Credenciais nao encontradas.'; end if;
  v_new:=v_existing||p_patch;
  update app_private.marketing_attribution_connection_secrets set
    secret_cipher=extensions.pgp_sym_encrypt(v_new::text,p_encryption_key,'cipher-algo=aes256,compress-algo=1'),
    secret_version=secret_version+1,rotated_at=now()
  where connection_id=p_connection_id;
  if p_patch?'access_token_expires_at' then
    update public.marketing_attribution_connections set token_expires_at=nullif(p_patch->>'access_token_expires_at','')::timestamptz where id=p_connection_id;
  end if;
  return true;
end;
$$;

create or replace function public.ma_service_set_connection_status(
  p_connection_id uuid,p_status text,p_error_code text default null,p_error_message text default null,p_metadata jsonb default '{}'
)
returns boolean language plpgsql security definer
set search_path = app_private, public, extensions
as $$
begin
  if p_status not in ('draft','validating','active','token_expiring','error','disconnected') then raise exception 'Status de conexao invalido.'; end if;
  p_metadata:=app_private.ma_json_guard(coalesce(p_metadata,'{}'::jsonb),32768,'Metadados da conexao');
  update public.marketing_attribution_connections set
    status=p_status,last_error_code=nullif(left(p_error_code,160),''),last_error_message=nullif(left(p_error_message,4000),''),
    account_name=coalesce(nullif(left(p_metadata->>'account_name',240),''),account_name),
    account_external_id=coalesce(nullif(regexp_replace(p_metadata->>'account_id','[^0-9]','','g'),''),account_external_id),
    token_expires_at=case when p_metadata?'token_expires_at' then nullif(p_metadata->>'token_expires_at','')::timestamptz else token_expires_at end,
    last_validated_at=case when p_status in ('active','token_expiring') then now() else last_validated_at end
  where id=p_connection_id;
  if not found then raise exception 'Conexao nao encontrada.'; end if;
  return true;
end;
$$;

create or replace function public.ma_service_create_oauth_state(
  p_session_token text,p_connection_id uuid,p_state_hash text,p_redirect_after text
)
returns boolean language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_session record;v_connection public.marketing_attribution_connections%rowtype;
begin
  select * into v_session from app_private.session_user(p_session_token);
  select * into v_connection from public.marketing_attribution_connections where id=p_connection_id and provider='google' and admin_user_id=v_session.admin_user_id;
  if not found or not app_private.ma_store_allowed(v_session.admin_user_id,v_session.user_id,v_session.user_role,v_session.user_store_id,v_connection.store_id,true)
  then raise exception 'Conexao Google nao encontrada ou sem permissao.'; end if;
  delete from app_private.marketing_oauth_states where expires_at<now() or consumed_at is not null;
  insert into app_private.marketing_oauth_states(
    state_hash,admin_user_id,user_id,store_id,connection_id,provider,redirect_after,expires_at
  ) values (
    p_state_hash,v_session.admin_user_id,v_session.user_id,v_connection.store_id,p_connection_id,'google',left(p_redirect_after,2000),now()+interval '10 minutes'
  );
  return true;
end;
$$;

create or replace function public.ma_service_consume_oauth_state(p_state_hash text)
returns jsonb language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_state app_private.marketing_oauth_states%rowtype;
begin
  select * into v_state from app_private.marketing_oauth_states
  where state_hash=p_state_hash and consumed_at is null and expires_at>now() for update;
  if not found then raise exception 'Estado OAuth invalido, expirado ou ja utilizado.'; end if;
  update app_private.marketing_oauth_states set consumed_at=now() where state_hash=p_state_hash;
  return jsonb_build_object(
    'connection_id',v_state.connection_id,'store_id',v_state.store_id,
    'redirect_after',v_state.redirect_after,'admin_user_id',v_state.admin_user_id,'user_id',v_state.user_id
  );
end;
$$;

create or replace function public.ma_service_log(p_payload jsonb)
returns boolean language plpgsql security definer
set search_path = app_private, public, extensions
as $$
begin
  p_payload:=app_private.ma_json_guard(coalesce(p_payload,'{}'::jsonb),65536,'Log');
  insert into public.marketing_attribution_logs(
    admin_user_id,store_id,connection_id,user_id,level,category,action,success,
    correlation_id,latency_ms,http_status,error_code,message,metadata
  ) values (
    nullif(p_payload->>'admin_user_id','')::uuid,nullif(p_payload->>'store_id','')::uuid,
    nullif(p_payload->>'connection_id','')::uuid,nullif(p_payload->>'user_id','')::uuid,
    case when p_payload->>'level' in ('debug','info','warning','error','critical') then p_payload->>'level' else 'info' end,
    left(coalesce(nullif(p_payload->>'category',''),'system'),80),left(coalesce(nullif(p_payload->>'action',''),'unknown'),120),
    lower(coalesce(p_payload->>'success','true')) in ('true','1','yes','sim'),left(p_payload->>'correlation_id',160),
    nullif(p_payload->>'latency_ms','')::integer,nullif(p_payload->>'http_status','')::integer,left(p_payload->>'error_code',160),
    left(coalesce(nullif(p_payload->>'message',''),'Evento do modulo de marketing.'),4000),
    app_private.ma_json_guard(coalesce(p_payload->'metadata','{}'::jsonb),32768,'Metadados do log')
  );
  return true;
exception when foreign_key_violation then
  insert into public.marketing_attribution_logs(level,category,action,success,error_code,message,metadata)
  values('warning','security','invalid_log_scope',false,'invalid_scope','Um log tentou usar um escopo inexistente.','{}');
  return false;
end;
$$;

create or replace function public.ma_service_log_session(p_session_token text,p_payload jsonb)
returns boolean language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_session record;v_store_id uuid:=nullif(p_payload->>'store_id','')::uuid;v_connection_id uuid:=nullif(p_payload->>'connection_id','')::uuid;
begin
  select * into v_session from app_private.session_user(p_session_token);
  if v_store_id is not null and not app_private.ma_store_allowed(v_session.admin_user_id,v_session.user_id,v_session.user_role,v_session.user_store_id,v_store_id,false)
  then v_store_id:=null;v_connection_id:=null; end if;
  if v_connection_id is not null and not exists(select 1 from public.marketing_attribution_connections where id=v_connection_id and store_id=v_store_id and admin_user_id=v_session.admin_user_id)
  then v_connection_id:=null; end if;
  return public.ma_service_log((p_payload-'admin_user_id'-'user_id'-'store_id'-'connection_id')||jsonb_build_object(
    'admin_user_id',v_session.admin_user_id,'user_id',v_session.user_id,'store_id',v_store_id,'connection_id',v_connection_id
  ));
end;
$$;

create index if not exists ma_touchpoints_source_rate_idx
  on public.marketing_touchpoints(tracking_source_id,created_at desc);

create or replace function public.ma_service_capture_touchpoint(
  p_tracking_token text,p_origin text,p_payload jsonb,p_ip_hash text default null,p_user_agent_hash text default null
)
returns jsonb language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare
  v_source public.marketing_tracking_sources%rowtype;v_id uuid;v_consent boolean;
  v_origin text:=lower(rtrim(btrim(coalesce(p_origin,'')),'/'));v_provider text;v_occurred timestamptz;
  v_event_name text;v_idempotency text;v_landing text;v_referrer text;v_metadata jsonb;
begin
  if length(coalesce(p_tracking_token,''))<32 then raise exception 'Token de rastreamento invalido.' using errcode='28000'; end if;
  select * into v_source from public.marketing_tracking_sources
  where token_hash=encode(extensions.digest(p_tracking_token,'sha256'),'hex') and is_active;
  if not found then raise exception 'Token de rastreamento invalido ou desativado.' using errcode='28000'; end if;
  if cardinality(v_source.allowed_origins)=0 then raise exception 'Configure ao menos um dominio autorizado antes de rastrear.'; end if;
  if v_origin='' or not v_origin=any(v_source.allowed_origins) then raise exception 'Dominio nao autorizado para este rastreador.' using errcode='28000'; end if;
  if (select count(*) from public.marketing_touchpoints where tracking_source_id=v_source.id and created_at>now()-interval '1 minute')>=600 then
    raise exception 'Limite temporario do rastreador atingido. Tente novamente.';
  end if;
  p_payload:=app_private.ma_json_guard(coalesce(p_payload,'{}'::jsonb),65536,'Touchpoint');
  v_consent:=lower(coalesce(p_payload->>'marketing_consent',p_payload->'consent'->>'granted','false')) in ('true','1','yes','sim');
  v_event_name:=lower(regexp_replace(left(coalesce(nullif(btrim(p_payload->>'event_name'),''),'page_view'),80),'[^a-zA-Z0-9_.-]','_','g'));
  v_idempotency:=left(coalesce(nullif(btrim(p_payload->>'idempotency_key'),''),extensions.gen_random_uuid()::text),200);
  begin v_occurred:=nullif(p_payload->>'occurred_at','')::timestamptz; exception when others then v_occurred:=now(); end;
  if v_occurred is null or v_occurred<now()-interval '90 days' or v_occurred>now()+interval '1 day' then v_occurred:=now(); end if;
  v_provider:=lower(coalesce(nullif(p_payload->>'provider',''),
    case when coalesce(p_payload->>'gclid',p_payload->>'gbraid',p_payload->>'wbraid') is not null then 'google'
         when coalesce(p_payload->>'fbclid',p_payload->>'fbc',p_payload->>'fbp') is not null then 'meta'
         when lower(coalesce(p_payload->>'utm_medium','')) in ('organic','seo') then 'organic'
         when nullif(p_payload->>'utm_source','') is null then 'direct' else 'other' end));
  if v_provider not in ('meta','google','direct','organic','other') then v_provider:='other'; end if;
  v_landing:=nullif(left(btrim(p_payload->>'landing_page_url'),2000),'');
  v_referrer:=nullif(left(btrim(p_payload->>'referrer_url'),2000),'');
  if v_landing is not null and v_landing !~ '^https?://' then v_landing:=null; end if;
  if v_referrer is not null and v_referrer !~ '^https?://' then v_referrer:=null; end if;
  v_metadata:=app_private.ma_json_guard(coalesce(p_payload->'metadata','{}'::jsonb),16384,'Metadados do touchpoint');

  insert into public.marketing_touchpoints(
    admin_user_id,store_id,tracking_source_id,anonymous_id,session_id,event_name,occurred_at,provider,
    utm_source,utm_medium,utm_campaign,utm_content,utm_term,
    campaign_external_id,adset_external_id,ad_external_id,creative_external_id,
    gclid,gbraid,wbraid,fbclid,fbc,fbp,landing_page_url,referrer_url,
    marketing_consent,consent_at,consent_version,consent_source,ip_hash,user_agent_hash,idempotency_key,metadata
  ) values (
    v_source.admin_user_id,v_source.store_id,v_source.id,
    case when v_consent then nullif(left(btrim(p_payload->>'anonymous_id'),200),'') end,
    case when v_consent then nullif(left(btrim(p_payload->>'session_id'),200),'') end,
    v_event_name,v_occurred,v_provider,
    case when v_consent then nullif(left(btrim(p_payload->>'utm_source'),300),'') end,
    case when v_consent then nullif(left(btrim(p_payload->>'utm_medium'),300),'') end,
    case when v_consent then nullif(left(btrim(p_payload->>'utm_campaign'),500),'') end,
    case when v_consent then nullif(left(btrim(p_payload->>'utm_content'),500),'') end,
    case when v_consent then nullif(left(btrim(p_payload->>'utm_term'),500),'') end,
    case when v_consent then nullif(left(btrim(p_payload->>'campaign_external_id'),300),'') end,
    case when v_consent then nullif(left(btrim(p_payload->>'adset_external_id'),300),'') end,
    case when v_consent then nullif(left(btrim(p_payload->>'ad_external_id'),300),'') end,
    case when v_consent then nullif(left(btrim(p_payload->>'creative_external_id'),300),'') end,
    case when v_consent then nullif(left(btrim(p_payload->>'gclid'),1000),'') end,
    case when v_consent then nullif(left(btrim(p_payload->>'gbraid'),1000),'') end,
    case when v_consent then nullif(left(btrim(p_payload->>'wbraid'),1000),'') end,
    case when v_consent then nullif(left(btrim(p_payload->>'fbclid'),1000),'') end,
    case when v_consent then nullif(left(btrim(p_payload->>'fbc'),1000),'') end,
    case when v_consent then nullif(left(btrim(p_payload->>'fbp'),1000),'') end,
    case when v_consent then v_landing end,case when v_consent then v_referrer end,
    v_consent,case when v_consent then coalesce(nullif(p_payload->>'consent_at','')::timestamptz,now()) end,
    case when v_consent then nullif(left(btrim(coalesce(p_payload->>'consent_version','v1')),80),'') end,
    case when v_consent then nullif(left(btrim(coalesce(p_payload->>'consent_source','site')),80),'') end,
    case when v_consent then nullif(left(p_ip_hash,128),'') end,
    case when v_consent then nullif(left(p_user_agent_hash,128),'') end,
    v_idempotency,case when v_consent then v_metadata else '{}'::jsonb end
  ) on conflict(store_id,idempotency_key) do update set occurred_at=excluded.occurred_at
  returning id into v_id;
  update public.marketing_tracking_sources set last_used_at=now() where id=v_source.id;
  return jsonb_build_object('touchpoint_id',v_id,'store_id',v_source.store_id,'consent_recorded',v_consent);
end;
$$;

create or replace function public.ma_service_schedule_due_syncs()
returns integer language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_connection record;v_count integer:=0;v_start date;
begin
  if not pg_catalog.pg_try_advisory_xact_lock(pg_catalog.hashtextextended('marketing:auto-sync',0)) then return 0; end if;
  for v_connection in
    select c.* from public.marketing_attribution_connections c
    where c.status in ('active','token_expiring')
      and (c.last_sync_at is null or c.last_sync_at<now()-interval '6 hours')
      and not exists(
        select 1 from public.marketing_sync_queue q
        where q.connection_id=c.id and q.status in ('pending','processing','retry')
      )
      and not exists(
        select 1 from public.marketing_sync_queue recent
        where recent.connection_id=c.id and recent.created_at>now()-interval '6 hours'
      )
    order by c.last_sync_at nulls first,c.created_at
    limit 100
    for update of c skip locked
  loop
    v_start:=case when v_connection.last_sync_at is null then current_date-90 else current_date-7 end;
    insert into public.marketing_sync_queue(
      admin_user_id,store_id,connection_id,provider,start_date,end_date,priority,requested_by
    ) values (
      v_connection.admin_user_id,v_connection.store_id,v_connection.id,v_connection.provider,
      v_start,current_date,case when v_connection.last_sync_at is null then 50 else 100 end,null
    );
    v_count:=v_count+1;
  end loop;
  return v_count;
end;
$$;

create or replace function public.ma_service_claim_sync(p_worker_id text,p_limit integer default 2)
returns jsonb language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_candidate record;v_run_id uuid;v_items jsonb:='[]'::jsonb;v_limit integer:=least(greatest(coalesce(p_limit,2),1),10);
begin
  update public.marketing_sync_queue set
    status=case when attempt_count>=max_attempts then 'failed' else 'retry' end,
    locked_at=null,locked_by=null,available_at=now(),
    completed_at=case when attempt_count>=max_attempts then now() else null end,
    last_error_code='lease_expired',
    last_error_message=case when attempt_count>=max_attempts
      then 'Lease expirou na ultima tentativa; sincronizacao encerrada.'
      else 'Lease expirado; sincronizacao devolvida a fila.' end
  where status='processing' and locked_at<now()-interval '15 minutes';
  update public.marketing_sync_runs r set status='failed',finished_at=now(),error_code='lease_expired',
    error_message='Lease expirou e a sincronizacao nao pode continuar.'
  from public.marketing_sync_queue q
  where r.queue_id=q.id and r.status='running' and q.status in ('retry','failed') and q.last_error_code='lease_expired';
  for v_candidate in
    select q.* from public.marketing_sync_queue q
    join public.marketing_attribution_connections c on c.id=q.connection_id
    where q.status in ('pending','retry') and q.available_at<=now() and q.attempt_count<q.max_attempts
      and c.status in ('active','token_expiring')
    order by q.priority,q.available_at,q.created_at limit v_limit
    for update of q skip locked
  loop
    update public.marketing_sync_queue set status='processing',locked_at=now(),locked_by=left(p_worker_id,200),attempt_count=attempt_count+1
    where id=v_candidate.id;
    insert into public.marketing_sync_runs(
      admin_user_id,store_id,connection_id,queue_id,provider,start_date,end_date,status
    ) values (
      v_candidate.admin_user_id,v_candidate.store_id,v_candidate.connection_id,v_candidate.id,
      v_candidate.provider,v_candidate.start_date,v_candidate.end_date,'running'
    ) returning id into v_run_id;
    v_items:=v_items||jsonb_build_array(jsonb_build_object(
      'id',v_candidate.id,'connection_id',v_candidate.connection_id,'admin_user_id',v_candidate.admin_user_id,
      'store_id',v_candidate.store_id,'provider',v_candidate.provider,'start_date',v_candidate.start_date,
      'end_date',v_candidate.end_date,'attempt_count',v_candidate.attempt_count+1,
      'max_attempts',v_candidate.max_attempts,'sync_run_id',v_run_id
    ));
  end loop;
  return v_items;
end;
$$;

create or replace function public.ma_service_upsert_metrics(
  p_connection_id uuid,p_sync_run_id uuid,p_metrics jsonb
)
returns integer language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare
  v_connection public.marketing_attribution_connections%rowtype;
  v_run public.marketing_sync_runs%rowtype;
  v_row jsonb;v_count integer:=0;v_date date;
begin
  if jsonb_typeof(coalesce(p_metrics,'[]'::jsonb))<>'array' then raise exception 'Metricas devem ser uma lista JSON.'; end if;
  if jsonb_array_length(p_metrics)>15000 then raise exception 'Lote de metricas excede 15000 linhas.'; end if;
  select * into v_connection from public.marketing_attribution_connections where id=p_connection_id;
  if not found then raise exception 'Conexao nao encontrada.'; end if;
  select * into v_run from public.marketing_sync_runs
  where id=p_sync_run_id and connection_id=p_connection_id and status='running';
  if not found then raise exception 'Execucao de sincronizacao invalida.'; end if;
  for v_row in select value from jsonb_array_elements(p_metrics) loop
    begin v_date:=(v_row->>'metric_date')::date; exception when others then continue; end;
    if v_date<v_run.start_date or v_date>v_run.end_date then continue; end if;
    insert into public.marketing_ad_metrics(
      admin_user_id,store_id,connection_id,metric_date,provider,account_external_id,
      campaign_external_id,campaign_name,adset_external_id,adset_name,ad_external_id,ad_name,creative_external_id,
      spend,impressions,reach,clicks,platform_leads,platform_conversions,conversion_value,currency,raw_metrics,sync_run_id,synced_at
    ) values (
      v_connection.admin_user_id,v_connection.store_id,v_connection.id,v_date,v_connection.provider,
      left(coalesce(v_row->>'account_external_id',v_connection.account_external_id,''),300),
      left(coalesce(v_row->>'campaign_external_id',''),300),left(coalesce(v_row->>'campaign_name',''),500),
      left(coalesce(v_row->>'adset_external_id',''),300),left(coalesce(v_row->>'adset_name',''),500),
      left(coalesce(v_row->>'ad_external_id',''),300),left(coalesce(v_row->>'ad_name',''),500),
      left(coalesce(v_row->>'creative_external_id',''),300),
      greatest(coalesce(nullif(v_row->>'spend','')::numeric,0),0),greatest(coalesce(nullif(v_row->>'impressions','')::bigint,0),0),
      greatest(coalesce(nullif(v_row->>'reach','')::bigint,0),0),greatest(coalesce(nullif(v_row->>'clicks','')::bigint,0),0),
      greatest(coalesce(nullif(v_row->>'platform_leads','')::numeric,0),0),greatest(coalesce(nullif(v_row->>'platform_conversions','')::numeric,0),0),
      greatest(coalesce(nullif(v_row->>'conversion_value','')::numeric,0),0),upper(left(coalesce(nullif(v_row->>'currency',''),'BRL'),3)),
      app_private.ma_json_guard(coalesce(v_row->'raw_metrics','{}'::jsonb),65536,'Metricas brutas'),p_sync_run_id,now()
    ) on conflict(connection_id,metric_date,campaign_external_id,adset_external_id,ad_external_id) do update set
      campaign_name=excluded.campaign_name,adset_name=excluded.adset_name,ad_name=excluded.ad_name,
      creative_external_id=excluded.creative_external_id,spend=excluded.spend,impressions=excluded.impressions,
      reach=excluded.reach,clicks=excluded.clicks,platform_leads=excluded.platform_leads,
      platform_conversions=excluded.platform_conversions,conversion_value=excluded.conversion_value,
      currency=excluded.currency,raw_metrics=excluded.raw_metrics,
      sync_run_id=excluded.sync_run_id,synced_at=now();
    v_count:=v_count+1;
  end loop;
  return v_count;
end;
$$;

create or replace function public.ma_service_finish_sync(
  p_queue_id uuid,p_worker_id text,p_success boolean,p_rows_received integer default 0,p_rows_upserted integer default 0,
  p_provider_metadata jsonb default '{}',p_error_code text default null,p_error_message text default null,p_retryable boolean default false
)
returns jsonb language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare
  v_queue public.marketing_sync_queue%rowtype;
  v_status text;v_retry timestamptz;v_sync_run_id uuid;v_stale_removed integer:=0;
begin
  select * into v_queue from public.marketing_sync_queue where id=p_queue_id for update;
  if not found then return jsonb_build_object('ok',false,'status','missing'); end if;
  if v_queue.status<>'processing' or v_queue.locked_by is distinct from left(p_worker_id,200) then return jsonb_build_object('ok',false,'status','claim_lost'); end if;
  if p_success then v_status:='completed';v_retry:=null;
  elsif p_retryable and v_queue.attempt_count<v_queue.max_attempts then
    v_status:='retry';v_retry:=now()+least(interval '6 hours',make_interval(secs=>power(2,least(v_queue.attempt_count,10))::integer*60));
  else v_status:='failed';v_retry:=null; end if;
  select id into v_sync_run_id from public.marketing_sync_runs
  where queue_id=p_queue_id and status='running'
  order by started_at desc limit 1 for update;
  if p_success and v_sync_run_id is not null then
    -- So depois de a API e todos os upserts concluirem removemos linhas que
    -- nao reapareceram no snapshot. Assim campanhas apagadas/renomeadas nao
    -- deixam custos antigos duplicando o dashboard, e uma falha nao apaga o
    -- ultimo snapshot valido.
    delete from public.marketing_ad_metrics
    where connection_id=v_queue.connection_id
      and metric_date between v_queue.start_date and v_queue.end_date
      and sync_run_id is distinct from v_sync_run_id;
    get diagnostics v_stale_removed=row_count;
  end if;
  update public.marketing_sync_queue set status=v_status,available_at=coalesce(v_retry,available_at),locked_at=null,locked_by=null,
    completed_at=case when v_status in ('completed','failed') then now() end,last_error_code=left(p_error_code,160),last_error_message=left(p_error_message,4000)
  where id=p_queue_id;
  update public.marketing_sync_runs set status=case when p_success then 'completed' else 'failed' end,
    rows_received=greatest(coalesce(p_rows_received,0),0),rows_upserted=greatest(coalesce(p_rows_upserted,0),0),finished_at=now(),
    error_code=left(p_error_code,160),error_message=left(p_error_message,4000),
    provider_metadata=app_private.ma_json_guard(coalesce(p_provider_metadata,'{}'::jsonb),65536,'Metadados do provedor')
      ||jsonb_build_object('stale_rows_removed',v_stale_removed)
  where queue_id=p_queue_id and status='running';
  update public.marketing_attribution_connections set
    last_sync_at=case when p_success then now() else last_sync_at end,
    last_error_code=case when p_success then null else left(p_error_code,160) end,
    last_error_message=case when p_success then null else left(p_error_message,4000) end,
    status=case
      when p_success and status in ('error','validating') then 'active'
      when not p_success and not p_retryable then 'error'
      else status
    end
  where id=v_queue.connection_id;
  return jsonb_build_object('ok',true,'status',v_status,'retry_at',v_retry);
end;
$$;

create or replace function public.ma_service_claim_conversions(p_worker_id text,p_limit integer default 25)
returns jsonb language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_candidate record;v_items jsonb:='[]'::jsonb;v_limit integer:=least(greatest(coalesce(p_limit,25),1),100);v_lead record;
begin
  update public.marketing_offline_conversion_queue set
    status=case when attempt_count>=max_attempts then 'failed' else 'retry' end,
    locked_at=null,locked_by=null,available_at=now(),
    last_error_code='lease_expired',
    last_error_message=case when attempt_count>=max_attempts
      then 'Lease expirou na ultima tentativa; conversao encerrada.'
      else 'Lease expirado; conversao devolvida a fila.' end
  where status='processing' and locked_at<now()-interval '10 minutes';
  for v_candidate in
    select q.* from public.marketing_offline_conversion_queue q
    join public.marketing_attribution_connections c on c.id=q.connection_id
    where q.status in ('pending','retry') and q.available_at<=now() and q.attempt_count<q.max_attempts
      and c.status in ('active','token_expiring')
    order by q.available_at,q.created_at limit v_limit for update of q skip locked
  loop
    select l.phone into v_lead from public.leads l where l.id=v_candidate.lead_id;
    update public.marketing_offline_conversion_queue set status='processing',locked_at=now(),locked_by=left(p_worker_id,200),attempt_count=attempt_count+1
    where id=v_candidate.id;
    v_items:=v_items||jsonb_build_array(jsonb_build_object(
      'id',v_candidate.id,'connection_id',v_candidate.connection_id,'admin_user_id',v_candidate.admin_user_id,
      'store_id',v_candidate.store_id,'provider',v_candidate.provider,'lead_id',v_candidate.lead_id,
      'event_name',v_candidate.event_name,'event_at',v_candidate.event_at,'event_id',v_candidate.event_id,
      'attempt_count',v_candidate.attempt_count+1,'max_attempts',v_candidate.max_attempts,
      'payload',v_candidate.payload||jsonb_build_object('phone',coalesce(v_candidate.payload->>'phone',v_lead.phone))
    ));
  end loop;
  return v_items;
end;
$$;

create or replace function public.ma_service_finish_conversion(
  p_queue_id uuid,p_worker_id text,p_success boolean,p_provider_receipt jsonb default null,
  p_error_code text default null,p_error_message text default null,p_retryable boolean default false,p_skip boolean default false
)
returns jsonb language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_queue public.marketing_offline_conversion_queue%rowtype;v_status text;v_retry timestamptz;
begin
  select * into v_queue from public.marketing_offline_conversion_queue where id=p_queue_id for update;
  if not found then return jsonb_build_object('ok',false,'status','missing'); end if;
  if v_queue.status<>'processing' or v_queue.locked_by is distinct from left(p_worker_id,200) then return jsonb_build_object('ok',false,'status','claim_lost'); end if;
  if p_success then
    v_status:=case when v_queue.provider='google' and nullif(p_provider_receipt->>'requestId','') is not null then 'submitted' else 'sent' end;
    v_retry:=null;
  elsif p_skip then v_status:='skipped';v_retry:=null;
  elsif p_retryable and v_queue.attempt_count<v_queue.max_attempts then
    v_status:='retry';v_retry:=now()+least(interval '12 hours',make_interval(secs=>power(2,least(v_queue.attempt_count,10))::integer*60));
  else v_status:='failed';v_retry:=null; end if;
  update public.marketing_offline_conversion_queue set
    status=v_status,available_at=coalesce(v_retry,available_at),locked_at=null,locked_by=null,
    sent_at=case when p_success then coalesce(sent_at,now()) else sent_at end,
    next_diagnostic_at=case when v_status='submitted' then now()+interval '30 minutes' else null end,
    confirmed_at=case when v_status in ('sent','failed','skipped') then now() else confirmed_at end,
    provider_receipt=case when p_provider_receipt is null then provider_receipt else app_private.ma_json_guard(p_provider_receipt,65536,'Recibo do provedor') end,
    last_error_code=left(p_error_code,160),last_error_message=left(p_error_message,4000)
  where id=p_queue_id;
  return jsonb_build_object('ok',true,'status',v_status,'retry_at',v_retry);
end;
$$;

create or replace function public.ma_service_claim_conversion_diagnostics(
  p_worker_id text,p_limit integer default 5
)
returns jsonb language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare
  v_candidate record;
  v_items jsonb:='[]'::jsonb;
  v_limit integer:=least(greatest(coalesce(p_limit,5),1),10);
begin
  -- Uma Edge Function interrompida nao pode manter o receipt bloqueado.
  update public.marketing_offline_conversion_queue set
    locked_at=null,locked_by=null,
    next_diagnostic_at=least(coalesce(next_diagnostic_at,now()),now()),
    last_error_code='diagnostic_lease_expired',
    last_error_message='Lease de diagnostico expirado; receipt devolvido para reconciliacao.'
  where status='submitted' and locked_at<now()-interval '10 minutes';

  -- A documentacao do Data Manager recomenda polling por no maximo 24 h.
  -- Depois disso o aceite HTTP nao pode ser considerado uma conversao final.
  update public.marketing_offline_conversion_queue set
    status='failed',confirmed_at=now(),next_diagnostic_at=null,
    locked_at=null,locked_by=null,
    last_error_code='google_diagnostic_timeout',
    last_error_message='O Google nao confirmou o processamento da conversao em 24 horas.'
  where status='submitted'
    and locked_at is null
    and coalesce(sent_at,created_at)<=now()-interval '24 hours';

  for v_candidate in
    select q.*
    from public.marketing_offline_conversion_queue q
    join public.marketing_attribution_connections c on c.id=q.connection_id
    where q.status='submitted'
      and q.provider='google'
      and q.locked_at is null
      and q.next_diagnostic_at<=now()
      and q.diagnostic_attempt_count<25
      and nullif(q.provider_receipt->>'requestId','') is not null
      and c.status in ('active','token_expiring','error')
    order by q.next_diagnostic_at,q.created_at
    limit v_limit for update of q skip locked
  loop
    update public.marketing_offline_conversion_queue set
      locked_at=now(),locked_by=left(p_worker_id,200),
      diagnostic_attempt_count=diagnostic_attempt_count+1
    where id=v_candidate.id;
    v_items:=v_items||jsonb_build_array(jsonb_build_object(
      'id',v_candidate.id,
      'connection_id',v_candidate.connection_id,
      'admin_user_id',v_candidate.admin_user_id,
      'store_id',v_candidate.store_id,
      'provider','google',
      'event_id',v_candidate.event_id,
      'request_id',v_candidate.provider_receipt->>'requestId',
      'diagnostic_attempt_count',v_candidate.diagnostic_attempt_count+1,
      'submitted_at',coalesce(v_candidate.sent_at,v_candidate.created_at)
    ));
  end loop;
  return v_items;
end;
$$;

create or replace function public.ma_service_finish_conversion_diagnostic(
  p_queue_id uuid,
  p_worker_id text,
  p_status text,
  p_provider_receipt jsonb default '{}'::jsonb,
  p_error_code text default null,
  p_error_message text default null
)
returns jsonb language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare
  v_queue public.marketing_offline_conversion_queue%rowtype;
  v_status text:=lower(coalesce(p_status,''));
  v_queue_status text;
  v_next timestamptz;
  v_receipt jsonb;
begin
  if v_status not in ('processing','success','partial','failed') then
    raise exception 'Status de diagnostico invalido.';
  end if;
  select * into v_queue
  from public.marketing_offline_conversion_queue
  where id=p_queue_id for update;
  if not found then return jsonb_build_object('ok',false,'status','missing'); end if;
  if v_queue.status<>'submitted'
     or v_queue.provider<>'google'
     or v_queue.locked_by is distinct from left(p_worker_id,200) then
    return jsonb_build_object('ok',false,'status','claim_lost');
  end if;

  v_receipt:=app_private.ma_json_guard(coalesce(p_provider_receipt,'{}'::jsonb),65536,'Diagnostico do provedor');
  if v_status='processing' then
    v_queue_status:='submitted';
    -- Primeiro poll: 30 min. Depois: 30 min * 1,3^tentativa,
    -- limitado a 60 min e com pequeno jitter para evitar efeito manada.
    v_next:=now()+make_interval(secs=>(
      least(3600,ceil(1800*power(1.3,least(v_queue.diagnostic_attempt_count,20)))::integer)
      +floor(random()*120)::integer
    ));
  elsif v_status='success' then
    v_queue_status:='sent';
    v_next:=null;
  elsif v_status='partial' then
    v_queue_status:='partial';
    v_next:=null;
  else
    v_queue_status:='failed';
    v_next:=null;
  end if;

  update public.marketing_offline_conversion_queue set
    status=v_queue_status,
    next_diagnostic_at=v_next,
    locked_at=null,locked_by=null,
    confirmed_at=case when v_status='processing' then confirmed_at else now() end,
    provider_receipt=coalesce(provider_receipt,'{}'::jsonb)||jsonb_build_object(
      'diagnostic',v_receipt,
      'diagnosticStatus',v_status,
      'diagnosticCheckedAt',now()
    ),
    last_error_code=case
      when v_status='success' then null
      when v_status='partial' then left(coalesce(p_error_code,'google_partial_success'),160)
      when v_status='failed' then left(coalesce(p_error_code,'google_conversion_failed'),160)
      else left(p_error_code,160)
    end,
    last_error_message=case
      when v_status='success' then null
      else left(p_error_message,4000)
    end
  where id=p_queue_id;
  return jsonb_build_object('ok',true,'status',v_queue_status,'diagnostic_status',v_status,'next_diagnostic_at',v_next);
end;
$$;

create or replace function public.ma_service_run_retention()
returns jsonb language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_last timestamptz;v_touchpoints integer:=0;v_events integer:=0;v_metrics integer:=0;v_logs integer:=0;v_queue integer:=0;
begin
  if not pg_catalog.pg_try_advisory_xact_lock(pg_catalog.hashtextextended('marketing:retention',0)) then
    return jsonb_build_object('executed',false,'reason','lock_busy');
  end if;
  insert into app_private.marketing_maintenance_state(task_key,last_run_at) values('retention',null) on conflict do nothing;
  select last_run_at into v_last from app_private.marketing_maintenance_state where task_key='retention' for update;
  if v_last is not null and v_last>now()-interval '20 hours' then
    return jsonb_build_object('executed',false,'reason','recently_executed','last_run_at',v_last);
  end if;
  delete from public.marketing_touchpoints where occurred_at<now()-interval '730 days';get diagnostics v_touchpoints=row_count;
  delete from public.marketing_attribution_events where event_at<now()-interval '730 days';get diagnostics v_events=row_count;
  delete from public.marketing_ad_metrics where metric_date<current_date-730;get diagnostics v_metrics=row_count;
  delete from public.marketing_attribution_logs where created_at<now()-interval '365 days';get diagnostics v_logs=row_count;
  delete from public.marketing_offline_conversion_queue where status in ('submitted','sent','partial','failed','skipped') and created_at<now()-interval '730 days';get diagnostics v_queue=row_count;
  delete from public.marketing_sync_queue where status in ('completed','failed','cancelled') and created_at<now()-interval '730 days';
  delete from public.marketing_sync_runs where created_at<now()-interval '730 days';
  delete from app_private.marketing_oauth_states where expires_at<now() or consumed_at<now()-interval '1 day';
  update app_private.marketing_maintenance_state set last_run_at=now(),metadata=jsonb_build_object(
    'touchpoints',v_touchpoints,'events',v_events,'metrics',v_metrics,'logs',v_logs,'conversion_jobs',v_queue
  ) where task_key='retention';
  return jsonb_build_object('executed',true,'touchpoints',v_touchpoints,'events',v_events,'metrics',v_metrics,'logs',v_logs,'conversion_jobs',v_queue);
end;
$$;

-- Permissoes: todo o modulo passa pela Edge Function. O navegador nao executa
-- estas RPCs diretamente; runtime, cifras, claims e dados ficam no service_role.
revoke all on function app_private.ma_set_updated_at() from public,anon,authenticated;
revoke all on function app_private.ma_json_guard(jsonb,integer,text) from public,anon,authenticated;
revoke all on function app_private.ma_store_allowed(uuid,uuid,public.app_user_role,uuid,uuid,boolean) from public,anon,authenticated;
revoke all on function app_private.ma_enqueue_event_conversions(uuid,jsonb) from public,anon,authenticated;
revoke all on function app_private.ma_capture_lead_intelligence() from public,anon,authenticated;

revoke all on function public.ma_list_connections(text,uuid) from public,anon,authenticated;
revoke all on function public.ma_get_tracker_config(text,uuid) from public,anon,authenticated;
revoke all on function public.ma_rotate_tracker_token(text,uuid,uuid,text,text[]) from public,anon,authenticated;
revoke all on function public.ma_record_event(text,uuid,uuid,text,jsonb) from public,anon,authenticated;
revoke all on function public.ma_get_dashboard(text,uuid,date,date) from public,anon,authenticated;
revoke all on function public.ma_list_journey(text,uuid,uuid,date,date,integer,integer) from public,anon,authenticated;
revoke all on function public.ma_list_sync_runs(text,uuid,integer,integer) from public,anon,authenticated;
revoke all on function public.ma_disconnect_connection(text,uuid,boolean) from public,anon,authenticated;
revoke all on function public.ma_schedule_sync(text,uuid,text,date,date) from public,anon,authenticated;

grant execute on function public.ma_list_connections(text,uuid) to service_role;
grant execute on function public.ma_get_tracker_config(text,uuid) to service_role;
grant execute on function public.ma_rotate_tracker_token(text,uuid,uuid,text,text[]) to service_role;
grant execute on function public.ma_record_event(text,uuid,uuid,text,jsonb) to service_role;
grant execute on function public.ma_get_dashboard(text,uuid,date,date) to service_role;
grant execute on function public.ma_list_journey(text,uuid,uuid,date,date,integer,integer) to service_role;
grant execute on function public.ma_list_sync_runs(text,uuid,integer,integer) to service_role;
grant execute on function public.ma_disconnect_connection(text,uuid,boolean) to service_role;
grant execute on function public.ma_schedule_sync(text,uuid,text,date,date) to service_role;

revoke all on function public.ma_service_save_connection(text,jsonb,text) from public,anon,authenticated;
revoke all on function public.ma_service_connection_runtime(text,uuid,text,boolean) from public,anon,authenticated;
revoke all on function public.ma_service_connection_runtime_by_id(uuid,text) from public,anon,authenticated;
revoke all on function public.ma_service_update_connection_secrets(uuid,text,jsonb) from public,anon,authenticated;
revoke all on function public.ma_service_set_connection_status(uuid,text,text,text,jsonb) from public,anon,authenticated;
revoke all on function public.ma_service_create_oauth_state(text,uuid,text,text) from public,anon,authenticated;
revoke all on function public.ma_service_consume_oauth_state(text) from public,anon,authenticated;
revoke all on function public.ma_service_log(jsonb) from public,anon,authenticated;
revoke all on function public.ma_service_log_session(text,jsonb) from public,anon,authenticated;
revoke all on function public.ma_service_capture_touchpoint(text,text,jsonb,text,text) from public,anon,authenticated;
revoke all on function public.ma_service_schedule_due_syncs() from public,anon,authenticated;
revoke all on function public.ma_service_claim_sync(text,integer) from public,anon,authenticated;
revoke all on function public.ma_service_upsert_metrics(uuid,uuid,jsonb) from public,anon,authenticated;
revoke all on function public.ma_service_finish_sync(uuid,text,boolean,integer,integer,jsonb,text,text,boolean) from public,anon,authenticated;
revoke all on function public.ma_service_claim_conversions(text,integer) from public,anon,authenticated;
revoke all on function public.ma_service_finish_conversion(uuid,text,boolean,jsonb,text,text,boolean,boolean) from public,anon,authenticated;
revoke all on function public.ma_service_claim_conversion_diagnostics(text,integer) from public,anon,authenticated;
revoke all on function public.ma_service_finish_conversion_diagnostic(uuid,text,text,jsonb,text,text) from public,anon,authenticated;
revoke all on function public.ma_service_run_retention() from public,anon,authenticated;

grant execute on function public.ma_service_save_connection(text,jsonb,text) to service_role;
grant execute on function public.ma_service_connection_runtime(text,uuid,text,boolean) to service_role;
grant execute on function public.ma_service_connection_runtime_by_id(uuid,text) to service_role;
grant execute on function public.ma_service_update_connection_secrets(uuid,text,jsonb) to service_role;
grant execute on function public.ma_service_set_connection_status(uuid,text,text,text,jsonb) to service_role;
grant execute on function public.ma_service_create_oauth_state(text,uuid,text,text) to service_role;
grant execute on function public.ma_service_consume_oauth_state(text) to service_role;
grant execute on function public.ma_service_log(jsonb) to service_role;
grant execute on function public.ma_service_log_session(text,jsonb) to service_role;
grant execute on function public.ma_service_capture_touchpoint(text,text,jsonb,text,text) to service_role;
grant execute on function public.ma_service_schedule_due_syncs() to service_role;
grant execute on function public.ma_service_claim_sync(text,integer) to service_role;
grant execute on function public.ma_service_upsert_metrics(uuid,uuid,jsonb) to service_role;
grant execute on function public.ma_service_finish_sync(uuid,text,boolean,integer,integer,jsonb,text,text,boolean) to service_role;
grant execute on function public.ma_service_claim_conversions(text,integer) to service_role;
grant execute on function public.ma_service_finish_conversion(uuid,text,boolean,jsonb,text,text,boolean,boolean) to service_role;
grant execute on function public.ma_service_claim_conversion_diagnostics(text,integer) to service_role;
grant execute on function public.ma_service_finish_conversion_diagnostic(uuid,text,text,jsonb,text,text) to service_role;
grant execute on function public.ma_service_run_retention() to service_role;

commit;

-- Verificacao opcional apos executar:
-- select
--   to_regprocedure('public.ma_get_dashboard(text,uuid,date,date)') as dashboard,
--   to_regprocedure('public.ma_service_claim_sync(text,integer)') as sync_worker,
--   to_regprocedure('public.ma_service_claim_conversions(text,integer)') as conversion_worker,
--   to_regprocedure('public.ma_service_claim_conversion_diagnostics(text,integer)') as conversion_diagnostics;
