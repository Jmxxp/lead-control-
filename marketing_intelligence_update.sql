-- Inteligencia comercial, atribuicao e integracoes de marketing.
-- Rode depois de agency_store_configuration_editor_update.sql e
-- central_ai_configuration_update.sql.

begin;

set search_path = public, extensions;

create table if not exists public.lead_intelligence (
  lead_id uuid primary key references public.leads(id) on delete cascade,
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
  store_id uuid not null,
  lifecycle_status text not null default 'new',
  qualified boolean not null default false,
  loss_reason text,
  owner_name text,
  email text,
  first_response_at timestamptz,
  qualified_at timestamptz,
  lost_at timestamptz,
  purchased_at timestamptz,
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
  external_lead_id text,
  marketing_consent boolean not null default false,
  consent_at timestamptz,
  returning_customer boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint lead_intelligence_status_check
    check (lifecycle_status in ('new', 'contacted', 'qualified', 'scheduled', 'visited', 'won', 'lost')),
  constraint lead_intelligence_store_admin_fk
    foreign key (store_id, admin_user_id)
    references public.stores(id, admin_user_id)
    on delete cascade
);

create index if not exists lead_intelligence_store_status_idx
  on public.lead_intelligence (store_id, lifecycle_status, updated_at desc);

create table if not exists public.lead_events (
  id uuid primary key default gen_random_uuid(),
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
  store_id uuid not null,
  lead_id uuid not null references public.leads(id) on delete cascade,
  event_type text not null,
  event_at timestamptz not null default now(),
  actor_user_id uuid references public.app_users(id) on delete set null,
  source text not null default 'app',
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint lead_events_type_check check (
    event_type in (
      'lead_created', 'contacted', 'qualified', 'scheduled', 'visited',
      'purchased', 'lost', 'reopened', 'attribution_updated'
    )
  ),
  constraint lead_events_store_admin_fk
    foreign key (store_id, admin_user_id)
    references public.stores(id, admin_user_id)
    on delete cascade
);

create index if not exists lead_events_store_date_idx
  on public.lead_events (store_id, event_at desc);
create index if not exists lead_events_lead_date_idx
  on public.lead_events (lead_id, event_at desc);

create table if not exists public.ad_daily_metrics (
  id uuid primary key default gen_random_uuid(),
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
  store_id uuid not null,
  metric_date date not null,
  platform text not null,
  account_external_id text not null default '',
  campaign_external_id text not null default '',
  campaign_name text not null default '',
  adset_external_id text not null default '',
  adset_name text not null default '',
  ad_external_id text not null default '',
  ad_name text not null default '',
  creative_external_id text not null default '',
  spend numeric(14,2) not null default 0 check (spend >= 0),
  impressions bigint not null default 0 check (impressions >= 0),
  reach bigint not null default 0 check (reach >= 0),
  clicks bigint not null default 0 check (clicks >= 0),
  platform_leads bigint not null default 0 check (platform_leads >= 0),
  platform_conversions bigint not null default 0 check (platform_conversions >= 0),
  currency text not null default 'BRL',
  source text not null default 'manual',
  raw_metrics jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint ad_daily_metrics_platform_check check (platform in ('meta', 'google', 'other')),
  constraint ad_daily_metrics_store_admin_fk
    foreign key (store_id, admin_user_id)
    references public.stores(id, admin_user_id)
    on delete cascade,
  constraint ad_daily_metrics_unique_row unique (
    store_id, metric_date, platform, account_external_id,
    campaign_external_id, adset_external_id, ad_external_id
  )
);

create index if not exists ad_daily_metrics_store_date_idx
  on public.ad_daily_metrics (store_id, metric_date desc);

create table if not exists public.store_marketing_targets (
  store_id uuid primary key,
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
  monthly_budget numeric(14,2) check (monthly_budget is null or monthly_budget >= 0),
  lead_goal integer check (lead_goal is null or lead_goal >= 0),
  qualified_goal integer check (qualified_goal is null or qualified_goal >= 0),
  sales_goal integer check (sales_goal is null or sales_goal >= 0),
  revenue_goal numeric(14,2) check (revenue_goal is null or revenue_goal >= 0),
  target_cpl numeric(14,2) check (target_cpl is null or target_cpl >= 0),
  target_cac numeric(14,2) check (target_cac is null or target_cac >= 0),
  target_roas numeric(10,2) check (target_roas is null or target_roas >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint store_marketing_targets_store_admin_fk
    foreign key (store_id, admin_user_id)
    references public.stores(id, admin_user_id)
    on delete cascade
);

create table if not exists public.marketing_connections (
  id uuid primary key default gen_random_uuid(),
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
  store_id uuid not null,
  provider text not null,
  status text not null default 'disconnected',
  account_external_id text,
  account_name text,
  public_config jsonb not null default '{}'::jsonb,
  secret_config jsonb not null default '{}'::jsonb,
  last_sync_at timestamptz,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint marketing_connections_provider_check check (provider in ('meta', 'google')),
  constraint marketing_connections_status_check check (status in ('disconnected', 'pending', 'active', 'error')),
  constraint marketing_connections_store_admin_fk
    foreign key (store_id, admin_user_id)
    references public.stores(id, admin_user_id)
    on delete cascade,
  constraint marketing_connections_store_provider_key unique (store_id, provider)
);

create table if not exists public.marketing_conversion_queue (
  id uuid primary key default gen_random_uuid(),
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
  store_id uuid not null,
  lead_id uuid not null references public.leads(id) on delete cascade,
  provider text not null,
  event_name text not null,
  event_at timestamptz not null,
  payload jsonb not null default '{}'::jsonb,
  status text not null default 'pending',
  attempt_count integer not null default 0,
  next_attempt_at timestamptz not null default now(),
  processed_at timestamptz,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint marketing_conversion_queue_provider_check check (provider in ('meta', 'google')),
  constraint marketing_conversion_queue_status_check check (status in ('pending', 'processing', 'sent', 'failed')),
  constraint marketing_conversion_queue_unique_event unique (lead_id, provider, event_name, event_at),
  constraint marketing_conversion_queue_store_admin_fk
    foreign key (store_id, admin_user_id)
    references public.stores(id, admin_user_id)
    on delete cascade
);

create index if not exists marketing_conversion_queue_status_idx
  on public.marketing_conversion_queue (status, next_attempt_at);

create table if not exists public.ai_usage (
  id uuid primary key default gen_random_uuid(),
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
  user_id uuid references public.app_users(id) on delete set null,
  store_id uuid references public.stores(id) on delete set null,
  provider text not null,
  model text not null,
  request_kind text not null default 'chat',
  input_tokens integer,
  output_tokens integer,
  latency_ms integer,
  status text not null default 'success',
  created_at timestamptz not null default now()
);

create index if not exists ai_usage_admin_date_idx
  on public.ai_usage (admin_user_id, created_at desc);

alter table public.lead_intelligence enable row level security;
alter table public.lead_events enable row level security;
alter table public.ad_daily_metrics enable row level security;
alter table public.store_marketing_targets enable row level security;
alter table public.marketing_connections enable row level security;
alter table public.marketing_conversion_queue enable row level security;
alter table public.ai_usage enable row level security;

drop trigger if exists lead_intelligence_set_updated_at on public.lead_intelligence;
create trigger lead_intelligence_set_updated_at
before update on public.lead_intelligence
for each row execute function app_private.set_updated_at();

drop trigger if exists ad_daily_metrics_set_updated_at on public.ad_daily_metrics;
create trigger ad_daily_metrics_set_updated_at
before update on public.ad_daily_metrics
for each row execute function app_private.set_updated_at();

drop trigger if exists store_marketing_targets_set_updated_at on public.store_marketing_targets;
create trigger store_marketing_targets_set_updated_at
before update on public.store_marketing_targets
for each row execute function app_private.set_updated_at();

drop trigger if exists marketing_connections_set_updated_at on public.marketing_connections;
create trigger marketing_connections_set_updated_at
before update on public.marketing_connections
for each row execute function app_private.set_updated_at();

drop trigger if exists marketing_conversion_queue_set_updated_at on public.marketing_conversion_queue;
create trigger marketing_conversion_queue_set_updated_at
before update on public.marketing_conversion_queue
for each row execute function app_private.set_updated_at();

insert into public.lead_intelligence (
  lead_id, admin_user_id, store_id, lifecycle_status, qualified, purchased_at
)
select
  l.id,
  l.admin_user_id,
  l.store_id,
  case
    when l.bought = 'Sim' then 'won'
    when l.visited = 'Sim' then 'visited'
    when l.scheduled = 'Sim' then 'scheduled'
    else 'new'
  end,
  false,
  case when l.bought = 'Sim' then coalesce(l.updated_at, l.created_at) else null end
from public.leads l
on conflict (lead_id) do nothing;

create or replace function app_private.capture_lead_lifecycle()
returns trigger
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_event_at timestamptz := now();
begin
  insert into public.lead_intelligence (lead_id, admin_user_id, store_id, lifecycle_status)
  values (
    new.id,
    new.admin_user_id,
    new.store_id,
    case
      when new.bought = 'Sim' then 'won'
      when new.visited = 'Sim' then 'visited'
      when new.scheduled = 'Sim' then 'scheduled'
      else 'new'
    end
  )
  on conflict (lead_id) do update
  set store_id = excluded.store_id,
      admin_user_id = excluded.admin_user_id;

  if tg_op = 'INSERT' then
    insert into public.lead_events (
      admin_user_id, store_id, lead_id, event_type, event_at, actor_user_id, metadata
    ) values (
      new.admin_user_id, new.store_id, new.id, 'lead_created', coalesce(new.created_at, v_event_at),
      new.created_by, jsonb_build_object('channel', new.channel, 'campaign', new.campaign)
    );
  end if;

  if new.scheduled = 'Sim' and (tg_op = 'INSERT' or old.scheduled is distinct from 'Sim') then
    insert into public.lead_events (admin_user_id, store_id, lead_id, event_type, event_at, actor_user_id, metadata)
    values (
      new.admin_user_id, new.store_id, new.id, 'scheduled', v_event_at, new.updated_by,
      jsonb_build_object('visit_date', new.scheduled_visit_date, 'visit_time', new.scheduled_visit_time)
    );
    update public.lead_intelligence
    set lifecycle_status = case when lifecycle_status in ('won', 'lost') then lifecycle_status else 'scheduled' end
    where lead_id = new.id;
  end if;

  if new.visited = 'Sim' and (tg_op = 'INSERT' or old.visited is distinct from 'Sim') then
    insert into public.lead_events (admin_user_id, store_id, lead_id, event_type, event_at, actor_user_id)
    values (new.admin_user_id, new.store_id, new.id, 'visited', v_event_at, new.updated_by);
    update public.lead_intelligence
    set lifecycle_status = case when lifecycle_status in ('won', 'lost') then lifecycle_status else 'visited' end
    where lead_id = new.id;
  end if;

  if new.bought = 'Sim' and (tg_op = 'INSERT' or old.bought is distinct from 'Sim') then
    insert into public.lead_events (admin_user_id, store_id, lead_id, event_type, event_at, actor_user_id, metadata)
    values (
      new.admin_user_id, new.store_id, new.id, 'purchased', v_event_at, new.updated_by,
      jsonb_build_object('value', new.purchase_amount, 'order_id', new.service_order)
    );
    update public.lead_intelligence
    set lifecycle_status = 'won', purchased_at = coalesce(purchased_at, v_event_at)
    where lead_id = new.id;

    insert into public.marketing_conversion_queue (
      admin_user_id, store_id, lead_id, provider, event_name, event_at, payload
    )
    select
      new.admin_user_id,
      new.store_id,
      new.id,
      c.provider,
      'Purchase',
      v_event_at,
      jsonb_build_object(
        'value', new.purchase_amount,
        'currency', 'BRL',
        'order_id', new.service_order,
        'phone', new.phone,
        'email', li.email,
        'gclid', li.gclid,
        'gbraid', li.gbraid,
        'wbraid', li.wbraid,
        'fbc', li.fbc,
        'fbp', li.fbp,
        'marketing_consent', li.marketing_consent
      )
    from public.marketing_connections c
    join public.lead_intelligence li on li.lead_id = new.id
    where c.store_id = new.store_id
      and c.status = 'active'
    on conflict (lead_id, provider, event_name, event_at) do nothing;
  end if;

  return new;
end;
$$;

drop trigger if exists leads_capture_lifecycle on public.leads;
create trigger leads_capture_lifecycle
after insert or update of store_id, scheduled, scheduled_visit_date, scheduled_visit_time, visited, bought, purchase_amount, service_order
on public.leads
for each row execute function app_private.capture_lead_lifecycle();

create or replace function app_private.rpc_list_lead_intelligence(p_session_token text)
returns table (
  lead_id uuid,
  lifecycle_status text,
  qualified boolean,
  loss_reason text,
  owner_name text,
  email text,
  first_response_at timestamptz,
  qualified_at timestamptz,
  lost_at timestamptz,
  purchased_at timestamptz,
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
  external_lead_id text,
  marketing_consent boolean,
  consent_at timestamptz,
  returning_customer boolean
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);

  return query
  select
    li.lead_id, li.lifecycle_status, li.qualified, li.loss_reason, li.owner_name, li.email,
    li.first_response_at, li.qualified_at, li.lost_at, li.purchased_at,
    li.utm_source, li.utm_medium, li.utm_campaign, li.utm_content, li.utm_term,
    li.campaign_external_id, li.adset_external_id, li.ad_external_id, li.creative_external_id,
    li.gclid, li.gbraid, li.wbraid, li.fbclid, li.fbc, li.fbp,
    li.landing_page_url, li.external_lead_id, li.marketing_consent, li.consent_at,
    li.returning_customer
  from public.lead_intelligence li
  join public.stores st on st.id = li.store_id
  where li.admin_user_id = v_session.admin_user_id
    and (
      v_session.user_role::text = 'admin'
      or (v_session.user_role::text = 'technician' and st.technician_user_id = v_session.user_id)
      or (v_session.user_role::text = 'store' and li.store_id = v_session.user_store_id)
    );
end;
$$;

create or replace function public.lc_list_lead_intelligence(p_session_token text)
returns table (
  lead_id uuid,
  lifecycle_status text,
  qualified boolean,
  loss_reason text,
  owner_name text,
  email text,
  first_response_at timestamptz,
  qualified_at timestamptz,
  lost_at timestamptz,
  purchased_at timestamptz,
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
  external_lead_id text,
  marketing_consent boolean,
  consent_at timestamptz,
  returning_customer boolean
)
language sql
security invoker
as $$ select * from app_private.rpc_list_lead_intelligence(p_session_token); $$;

create or replace function app_private.rpc_save_lead_intelligence(
  p_session_token text,
  p_lead_id uuid,
  p_payload jsonb default '{}'::jsonb
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_lead record;
  v_before record;
  v_status text;
  v_qualified boolean;
  v_loss_reason text;
begin
  select * into v_session from app_private.session_user(p_session_token);
  select l.* into v_lead
  from public.leads l
  join public.stores st on st.id = l.store_id
  where l.id = p_lead_id
    and l.admin_user_id = v_session.admin_user_id
    and (
      v_session.user_role::text = 'admin'
      or (v_session.user_role::text = 'technician' and st.technician_user_id = v_session.user_id)
      or (v_session.user_role::text = 'store' and l.store_id = v_session.user_store_id)
    );
  if not found then raise exception 'Lead nao encontrado ou sem permissao.'; end if;

  insert into public.lead_intelligence (lead_id, admin_user_id, store_id)
  values (v_lead.id, v_lead.admin_user_id, v_lead.store_id)
  on conflict (lead_id) do nothing;

  select * into v_before from public.lead_intelligence where lead_id = p_lead_id;
  v_status := coalesce(nullif(btrim(p_payload->>'lifecycle_status'), ''), v_before.lifecycle_status);
  if v_status not in ('new', 'contacted', 'qualified', 'scheduled', 'visited', 'won', 'lost') then
    raise exception 'Etapa comercial invalida.';
  end if;
  v_qualified := case
    when p_payload ? 'qualified' then lower(coalesce(p_payload->>'qualified', 'false')) in ('true', '1', 'sim')
    else v_before.qualified
  end;
  v_loss_reason := case
    when p_payload ? 'loss_reason' then nullif(btrim(p_payload->>'loss_reason'), '')
    else v_before.loss_reason
  end;
  if v_status = 'lost' and v_loss_reason is null then
    raise exception 'Informe o motivo da perda.';
  end if;

  update public.lead_intelligence
  set
    lifecycle_status = v_status,
    qualified = v_qualified,
    loss_reason = case when v_status = 'lost' then v_loss_reason else null end,
    owner_name = case when p_payload ? 'owner_name' then nullif(left(btrim(p_payload->>'owner_name'), 160), '') else owner_name end,
    email = case when p_payload ? 'email' then nullif(left(lower(btrim(p_payload->>'email')), 320), '') else email end,
    first_response_at = case when p_payload ? 'first_response_at' then nullif(p_payload->>'first_response_at', '')::timestamptz else first_response_at end,
    qualified_at = case when v_qualified then coalesce(qualified_at, now()) else null end,
    lost_at = case when v_status = 'lost' then coalesce(lost_at, now()) else null end,
    purchased_at = case when v_status = 'won' then coalesce(purchased_at, now()) else purchased_at end,
    utm_source = case when p_payload ? 'utm_source' then nullif(left(btrim(p_payload->>'utm_source'), 500), '') else utm_source end,
    utm_medium = case when p_payload ? 'utm_medium' then nullif(left(btrim(p_payload->>'utm_medium'), 500), '') else utm_medium end,
    utm_campaign = case when p_payload ? 'utm_campaign' then nullif(left(btrim(p_payload->>'utm_campaign'), 500), '') else utm_campaign end,
    utm_content = case when p_payload ? 'utm_content' then nullif(left(btrim(p_payload->>'utm_content'), 500), '') else utm_content end,
    utm_term = case when p_payload ? 'utm_term' then nullif(left(btrim(p_payload->>'utm_term'), 500), '') else utm_term end,
    campaign_external_id = case when p_payload ? 'campaign_external_id' then nullif(left(btrim(p_payload->>'campaign_external_id'), 500), '') else campaign_external_id end,
    adset_external_id = case when p_payload ? 'adset_external_id' then nullif(left(btrim(p_payload->>'adset_external_id'), 500), '') else adset_external_id end,
    ad_external_id = case when p_payload ? 'ad_external_id' then nullif(left(btrim(p_payload->>'ad_external_id'), 500), '') else ad_external_id end,
    creative_external_id = case when p_payload ? 'creative_external_id' then nullif(left(btrim(p_payload->>'creative_external_id'), 500), '') else creative_external_id end,
    gclid = case when p_payload ? 'gclid' then nullif(left(btrim(p_payload->>'gclid'), 500), '') else gclid end,
    gbraid = case when p_payload ? 'gbraid' then nullif(left(btrim(p_payload->>'gbraid'), 500), '') else gbraid end,
    wbraid = case when p_payload ? 'wbraid' then nullif(left(btrim(p_payload->>'wbraid'), 500), '') else wbraid end,
    fbclid = case when p_payload ? 'fbclid' then nullif(left(btrim(p_payload->>'fbclid'), 500), '') else fbclid end,
    fbc = case when p_payload ? 'fbc' then nullif(left(btrim(p_payload->>'fbc'), 500), '') else fbc end,
    fbp = case when p_payload ? 'fbp' then nullif(left(btrim(p_payload->>'fbp'), 500), '') else fbp end,
    landing_page_url = case when p_payload ? 'landing_page_url' then nullif(left(btrim(p_payload->>'landing_page_url'), 2000), '') else landing_page_url end,
    external_lead_id = case when p_payload ? 'external_lead_id' then nullif(left(btrim(p_payload->>'external_lead_id'), 500), '') else external_lead_id end,
    marketing_consent = case when p_payload ? 'marketing_consent' then lower(coalesce(p_payload->>'marketing_consent', 'false')) in ('true', '1', 'sim') else marketing_consent end,
    consent_at = case
      when p_payload ? 'marketing_consent' and lower(coalesce(p_payload->>'marketing_consent', 'false')) in ('true', '1', 'sim') then coalesce(consent_at, now())
      when p_payload ? 'marketing_consent' then null
      else consent_at
    end,
    returning_customer = case when p_payload ? 'returning_customer' then lower(coalesce(p_payload->>'returning_customer', 'false')) in ('true', '1', 'sim') else returning_customer end
  where lead_id = p_lead_id;

  if v_qualified and not v_before.qualified then
    insert into public.lead_events (admin_user_id, store_id, lead_id, event_type, actor_user_id)
    values (v_lead.admin_user_id, v_lead.store_id, v_lead.id, 'qualified', v_session.user_id);
  end if;
  if v_status = 'lost' and v_before.lifecycle_status is distinct from 'lost' then
    insert into public.lead_events (admin_user_id, store_id, lead_id, event_type, actor_user_id, metadata)
    values (v_lead.admin_user_id, v_lead.store_id, v_lead.id, 'lost', v_session.user_id, jsonb_build_object('reason', v_loss_reason));
  elsif v_before.lifecycle_status = 'lost' and v_status <> 'lost' then
    insert into public.lead_events (admin_user_id, store_id, lead_id, event_type, actor_user_id)
    values (v_lead.admin_user_id, v_lead.store_id, v_lead.id, 'reopened', v_session.user_id);
  end if;

  if (p_payload ? 'utm_source') or (p_payload ? 'gclid') or (p_payload ? 'fbclid') or (p_payload ? 'ad_external_id') then
    insert into public.lead_events (admin_user_id, store_id, lead_id, event_type, actor_user_id)
    values (v_lead.admin_user_id, v_lead.store_id, v_lead.id, 'attribution_updated', v_session.user_id);
  end if;
  return true;
end;
$$;

create or replace function public.lc_save_lead_intelligence(
  p_session_token text,
  p_lead_id uuid,
  p_payload jsonb default '{}'::jsonb
)
returns boolean
language sql
security invoker
as $$ select app_private.rpc_save_lead_intelligence(p_session_token, p_lead_id, p_payload); $$;

create or replace function public.lc_upsert_lead_with_intelligence(
  p_session_token text,
  p_lead_id uuid,
  p_name text,
  p_phone text,
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
declare v_lead_id uuid;
begin
  v_lead_id := public.lc_upsert_lead(
    p_session_token, p_lead_id, p_name, p_phone, p_channel, p_campaign,
    p_conversation_start, p_conclusion, p_scheduled, p_scheduled_visit_date,
    p_scheduled_visit_time, p_visited, p_bought, p_purchase_amount,
    p_service_order, p_notes, p_custom_values, p_store_id, p_contact_date
  );
  perform app_private.rpc_save_lead_intelligence(p_session_token, v_lead_id, p_intelligence);
  return v_lead_id;
end;
$$;

create or replace function app_private.rpc_list_ad_daily_metrics(
  p_session_token text,
  p_store_id uuid default null,
  p_start_date date default null,
  p_end_date date default null
)
returns setof public.ad_daily_metrics
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);
  return query
  select m.*
  from public.ad_daily_metrics m
  join public.stores st on st.id = m.store_id
  where m.admin_user_id = v_session.admin_user_id
    and (p_store_id is null or m.store_id = p_store_id)
    and (p_start_date is null or m.metric_date >= p_start_date)
    and (p_end_date is null or m.metric_date <= p_end_date)
    and (
      v_session.user_role::text = 'admin'
      or (v_session.user_role::text = 'technician' and st.technician_user_id = v_session.user_id)
      or (v_session.user_role::text = 'store' and m.store_id = v_session.user_store_id)
    )
  order by m.metric_date desc, m.platform, m.campaign_name;
end;
$$;

create or replace function public.lc_list_ad_daily_metrics(
  p_session_token text,
  p_store_id uuid default null,
  p_start_date date default null,
  p_end_date date default null
)
returns setof public.ad_daily_metrics
language sql
security invoker
as $$ select * from app_private.rpc_list_ad_daily_metrics(p_session_token, p_store_id, p_start_date, p_end_date); $$;

create or replace function app_private.rpc_upsert_ad_daily_metric(
  p_session_token text,
  p_payload jsonb
)
returns uuid
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_store_id uuid := nullif(p_payload->>'store_id', '')::uuid;
  v_id uuid;
begin
  select * into v_session from app_private.session_user(p_session_token);
  if v_session.user_role::text not in ('admin', 'technician') then
    raise exception 'Somente admin ou empresa podem editar investimento.';
  end if;
  if not exists (
    select 1 from public.stores st
    where st.id = v_store_id and st.admin_user_id = v_session.admin_user_id and st.is_active
      and (v_session.user_role::text = 'admin' or st.technician_user_id = v_session.user_id)
  ) then raise exception 'Loja nao encontrada ou sem permissao.'; end if;

  insert into public.ad_daily_metrics (
    admin_user_id, store_id, metric_date, platform, account_external_id,
    campaign_external_id, campaign_name, adset_external_id, adset_name,
    ad_external_id, ad_name, creative_external_id, spend, impressions, reach,
    clicks, platform_leads, platform_conversions, currency, source
  ) values (
    v_session.admin_user_id, v_store_id, (p_payload->>'metric_date')::date,
    case when lower(p_payload->>'platform') in ('meta', 'google') then lower(p_payload->>'platform') else 'other' end,
    coalesce(p_payload->>'account_external_id', ''),
    coalesce(nullif(p_payload->>'campaign_external_id', ''), nullif(p_payload->>'campaign_name', ''), ''),
    coalesce(p_payload->>'campaign_name', ''),
    coalesce(p_payload->>'adset_external_id', ''), coalesce(p_payload->>'adset_name', ''),
    coalesce(p_payload->>'ad_external_id', ''), coalesce(p_payload->>'ad_name', ''), coalesce(p_payload->>'creative_external_id', ''),
    greatest(coalesce(nullif(p_payload->>'spend', '')::numeric, 0), 0),
    greatest(coalesce(nullif(p_payload->>'impressions', '')::bigint, 0), 0),
    greatest(coalesce(nullif(p_payload->>'reach', '')::bigint, 0), 0),
    greatest(coalesce(nullif(p_payload->>'clicks', '')::bigint, 0), 0),
    greatest(coalesce(nullif(p_payload->>'platform_leads', '')::bigint, 0), 0),
    greatest(coalesce(nullif(p_payload->>'platform_conversions', '')::bigint, 0), 0),
    upper(coalesce(nullif(p_payload->>'currency', ''), 'BRL')), 'manual'
  )
  on conflict (store_id, metric_date, platform, account_external_id, campaign_external_id, adset_external_id, ad_external_id)
  do update set
    campaign_name = excluded.campaign_name, adset_name = excluded.adset_name, ad_name = excluded.ad_name,
    creative_external_id = excluded.creative_external_id, spend = excluded.spend,
    impressions = excluded.impressions, reach = excluded.reach, clicks = excluded.clicks,
    platform_leads = excluded.platform_leads, platform_conversions = excluded.platform_conversions,
    currency = excluded.currency, source = 'manual'
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.lc_upsert_ad_daily_metric(p_session_token text, p_payload jsonb)
returns uuid language sql security invoker
as $$ select app_private.rpc_upsert_ad_daily_metric(p_session_token, p_payload); $$;

create or replace function app_private.rpc_list_marketing_targets(p_session_token text)
returns setof public.store_marketing_targets
language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);
  return query
  select t.* from public.store_marketing_targets t
  join public.stores st on st.id = t.store_id
  where t.admin_user_id = v_session.admin_user_id
    and (
      v_session.user_role::text = 'admin'
      or (v_session.user_role::text = 'technician' and st.technician_user_id = v_session.user_id)
      or (v_session.user_role::text = 'store' and t.store_id = v_session.user_store_id)
    );
end;
$$;

create or replace function public.lc_list_marketing_targets(p_session_token text)
returns setof public.store_marketing_targets language sql security invoker
as $$ select * from app_private.rpc_list_marketing_targets(p_session_token); $$;

create or replace function app_private.rpc_save_marketing_targets(
  p_session_token text, p_store_id uuid, p_payload jsonb
)
returns boolean
language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);
  if v_session.user_role::text not in ('admin', 'technician') then
    raise exception 'Somente admin ou empresa podem editar metas.';
  end if;
  if not exists (
    select 1 from public.stores st where st.id = p_store_id
      and st.admin_user_id = v_session.admin_user_id and st.is_active
      and (v_session.user_role::text = 'admin' or st.technician_user_id = v_session.user_id)
  ) then raise exception 'Loja nao encontrada ou sem permissao.'; end if;

  insert into public.store_marketing_targets (
    store_id, admin_user_id, monthly_budget, lead_goal, qualified_goal,
    sales_goal, revenue_goal, target_cpl, target_cac, target_roas
  ) values (
    p_store_id, v_session.admin_user_id,
    nullif(p_payload->>'monthly_budget', '')::numeric,
    nullif(p_payload->>'lead_goal', '')::integer,
    nullif(p_payload->>'qualified_goal', '')::integer,
    nullif(p_payload->>'sales_goal', '')::integer,
    nullif(p_payload->>'revenue_goal', '')::numeric,
    nullif(p_payload->>'target_cpl', '')::numeric,
    nullif(p_payload->>'target_cac', '')::numeric,
    nullif(p_payload->>'target_roas', '')::numeric
  )
  on conflict (store_id) do update set
    monthly_budget = excluded.monthly_budget, lead_goal = excluded.lead_goal,
    qualified_goal = excluded.qualified_goal, sales_goal = excluded.sales_goal,
    revenue_goal = excluded.revenue_goal, target_cpl = excluded.target_cpl,
    target_cac = excluded.target_cac, target_roas = excluded.target_roas;
  return true;
end;
$$;

create or replace function public.lc_save_marketing_targets(
  p_session_token text, p_store_id uuid, p_payload jsonb
)
returns boolean language sql security invoker
as $$ select app_private.rpc_save_marketing_targets(p_session_token, p_store_id, p_payload); $$;

create or replace function app_private.rpc_list_marketing_connections(p_session_token text, p_store_id uuid)
returns table (
  provider text, status text, account_external_id text, account_name text,
  last_sync_at timestamptz, last_error text
)
language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);
  if not exists (
    select 1 from public.stores st where st.id = p_store_id
      and st.admin_user_id = v_session.admin_user_id
      and (
        v_session.user_role::text = 'admin'
        or (v_session.user_role::text = 'technician' and st.technician_user_id = v_session.user_id)
        or (v_session.user_role::text = 'store' and st.id = v_session.user_store_id)
      )
  ) then raise exception 'Loja nao encontrada ou sem permissao.'; end if;
  return query
  select c.provider, c.status, c.account_external_id, c.account_name, c.last_sync_at, c.last_error
  from public.marketing_connections c where c.store_id = p_store_id;
end;
$$;

create or replace function public.lc_list_marketing_connections(p_session_token text, p_store_id uuid)
returns table (
  provider text, status text, account_external_id text, account_name text,
  last_sync_at timestamptz, last_error text
)
language sql security invoker
as $$ select * from app_private.rpc_list_marketing_connections(p_session_token, p_store_id); $$;

-- A chave da IA deixa de ser devolvida ao navegador. A assinatura e mantida
-- para compatibilidade com o frontend existente.
create or replace function app_private.rpc_get_ai_settings(p_session_token text)
returns table (
  provider text, model text, api_key text, system_prompt text,
  has_api_key boolean, updated_at timestamptz
)
language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);
  if v_session.user_role::text not in ('admin', 'technician') then
    raise exception 'A IA esta disponivel somente para admin e empresas B2B.';
  end if;
  return query
  select
    coalesce(s.provider, 'deepseek'), coalesce(s.model, 'deepseek-chat'), ''::text,
    coalesce(nullif(btrim(s.system_prompt), ''),
      'Voce e uma IA especialista em analise comercial. Use somente os dados agregados da loja selecionada, sinalize amostras pequenas e priorize acoes mensuraveis.'),
    coalesce(length(btrim(s.api_key)) > 0, false), s.updated_at
  from (select 1) seed
  left join public.ai_settings s on s.admin_user_id = v_session.admin_user_id;
end;
$$;

create or replace function public.lc_ai_runtime_config(p_session_token text)
returns table (
  admin_user_id uuid, user_id uuid, user_role text, provider text,
  model text, api_key text, system_prompt text
)
language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);
  if v_session.user_role::text not in ('admin', 'technician') then
    raise exception 'A IA esta disponivel somente para admin e empresas B2B.';
  end if;
  if (select count(*) from public.ai_usage u where u.admin_user_id = v_session.admin_user_id and u.created_at > now() - interval '1 hour') >= 120 then
    raise exception 'Limite temporario de analises atingido. Tente novamente em alguns minutos.';
  end if;
  return query
  select v_session.admin_user_id, v_session.user_id, v_session.user_role::text,
    s.provider, s.model, s.api_key,
    coalesce(nullif(btrim(s.system_prompt), ''),
      'Voce e uma IA especialista em analise comercial. Use somente os dados agregados da loja selecionada, sinalize amostras pequenas e priorize acoes mensuraveis.')
  from public.ai_settings s
  where s.admin_user_id = v_session.admin_user_id and length(btrim(s.api_key)) > 0;
  if not found then raise exception 'A IA ainda nao foi configurada pelo administrador.'; end if;
end;
$$;

create or replace function public.lc_log_ai_usage(
  p_admin_user_id uuid, p_user_id uuid, p_store_id uuid, p_provider text,
  p_model text, p_request_kind text, p_input_tokens integer,
  p_output_tokens integer, p_latency_ms integer, p_status text
)
returns boolean
language plpgsql security definer
set search_path = app_private, public, extensions
as $$
begin
  insert into public.ai_usage (
    admin_user_id, user_id, store_id, provider, model, request_kind,
    input_tokens, output_tokens, latency_ms, status
  ) values (
    p_admin_user_id, p_user_id, p_store_id, left(p_provider, 40), left(p_model, 160),
    left(coalesce(p_request_kind, 'chat'), 40), p_input_tokens, p_output_tokens,
    p_latency_ms, left(coalesce(p_status, 'success'), 40)
  );
  return true;
end;
$$;

create or replace function public.lc_marketing_connection_runtime(
  p_session_token text, p_store_id uuid, p_provider text
)
returns table (
  admin_user_id uuid, user_id uuid, provider text, account_external_id text,
  public_config jsonb, secret_config jsonb
)
language plpgsql security definer
set search_path = app_private, public, extensions
as $$
declare v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);
  if not exists (
    select 1 from public.stores st where st.id = p_store_id
      and st.admin_user_id = v_session.admin_user_id
      and (
        v_session.user_role::text = 'admin'
        or (v_session.user_role::text = 'technician' and st.technician_user_id = v_session.user_id)
        or (v_session.user_role::text = 'store' and st.id = v_session.user_store_id)
      )
  ) then raise exception 'Loja nao encontrada ou sem permissao.'; end if;
  return query
  select v_session.admin_user_id, v_session.user_id, c.provider,
    c.account_external_id, c.public_config, c.secret_config
  from public.marketing_connections c
  where c.store_id = p_store_id and c.provider = lower(p_provider) and c.status = 'active';
end;
$$;

revoke all on table public.lead_intelligence from public, anon, authenticated;
revoke all on table public.lead_events from public, anon, authenticated;
revoke all on table public.ad_daily_metrics from public, anon, authenticated;
revoke all on table public.store_marketing_targets from public, anon, authenticated;
revoke all on table public.marketing_connections from public, anon, authenticated;
revoke all on table public.marketing_conversion_queue from public, anon, authenticated;
revoke all on table public.ai_usage from public, anon, authenticated;

revoke execute on function app_private.rpc_list_lead_intelligence(text) from public;
revoke execute on function app_private.rpc_save_lead_intelligence(text, uuid, jsonb) from public;
revoke execute on function app_private.rpc_list_ad_daily_metrics(text, uuid, date, date) from public;
revoke execute on function app_private.rpc_upsert_ad_daily_metric(text, jsonb) from public;
revoke execute on function app_private.rpc_list_marketing_targets(text) from public;
revoke execute on function app_private.rpc_save_marketing_targets(text, uuid, jsonb) from public;
revoke execute on function app_private.rpc_list_marketing_connections(text, uuid) from public;

revoke execute on function public.lc_list_lead_intelligence(text) from public;
revoke execute on function public.lc_save_lead_intelligence(text, uuid, jsonb) from public;
revoke execute on function public.lc_upsert_lead_with_intelligence(text, uuid, text, text, text, text, text, text, text, date, time, text, text, numeric, text, text, jsonb, uuid, date, jsonb) from public;
revoke execute on function public.lc_list_ad_daily_metrics(text, uuid, date, date) from public;
revoke execute on function public.lc_upsert_ad_daily_metric(text, jsonb) from public;
revoke execute on function public.lc_list_marketing_targets(text) from public;
revoke execute on function public.lc_save_marketing_targets(text, uuid, jsonb) from public;
revoke execute on function public.lc_list_marketing_connections(text, uuid) from public;

revoke execute on function public.lc_ai_runtime_config(text) from public, anon, authenticated;
revoke execute on function public.lc_log_ai_usage(uuid, uuid, uuid, text, text, text, integer, integer, integer, text) from public, anon, authenticated;
revoke execute on function public.lc_marketing_connection_runtime(text, uuid, text) from public, anon, authenticated;

grant execute on function public.lc_list_lead_intelligence(text) to anon, authenticated;
grant execute on function public.lc_save_lead_intelligence(text, uuid, jsonb) to anon, authenticated;
grant execute on function public.lc_upsert_lead_with_intelligence(text, uuid, text, text, text, text, text, text, text, date, time, text, text, numeric, text, text, jsonb, uuid, date, jsonb) to anon, authenticated;
grant execute on function public.lc_list_ad_daily_metrics(text, uuid, date, date) to anon, authenticated;
grant execute on function public.lc_upsert_ad_daily_metric(text, jsonb) to anon, authenticated;
grant execute on function public.lc_list_marketing_targets(text) to anon, authenticated;
grant execute on function public.lc_save_marketing_targets(text, uuid, jsonb) to anon, authenticated;
grant execute on function public.lc_list_marketing_connections(text, uuid) to anon, authenticated;

grant execute on function app_private.rpc_list_lead_intelligence(text) to anon, authenticated;
grant execute on function app_private.rpc_save_lead_intelligence(text, uuid, jsonb) to anon, authenticated;
grant execute on function app_private.rpc_list_ad_daily_metrics(text, uuid, date, date) to anon, authenticated;
grant execute on function app_private.rpc_upsert_ad_daily_metric(text, jsonb) to anon, authenticated;
grant execute on function app_private.rpc_list_marketing_targets(text) to anon, authenticated;
grant execute on function app_private.rpc_save_marketing_targets(text, uuid, jsonb) to anon, authenticated;
grant execute on function app_private.rpc_list_marketing_connections(text, uuid) to anon, authenticated;

grant execute on function public.lc_ai_runtime_config(text) to service_role;
grant execute on function public.lc_log_ai_usage(uuid, uuid, uuid, text, text, text, integer, integer, integer, text) to service_role;
grant execute on function public.lc_marketing_connection_runtime(text, uuid, text) to service_role;

commit;

notify pgrst, 'reload schema';
