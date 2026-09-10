-- Relatorio diario por Web Push, configurado por loja e por agencia.
--
-- Os endpoints e as chaves de Push ficam no schema privado. A aplicacao usa
-- apenas RPCs autenticados pela sessao propria; o worker recebe entregas por
-- RPCs exclusivos do service_role. O agendamento e calculado no fuso escolhido
-- para continuar correto em mudancas de horario civil.

begin;

set local lock_timeout = '10s';
set local statement_timeout = '5min';

create table if not exists app_private.web_push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.app_users(id) on delete cascade,
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  content_encoding text not null default 'aes128gcm',
  expiration_time bigint,
  device_metadata jsonb not null default '{}'::jsonb,
  revoked_at timestamptz,
  last_seen_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint web_push_subscriptions_endpoint_check
    check (length(endpoint) between 12 and 4096 and endpoint ~ '^https://'),
  constraint web_push_subscriptions_key_check
    check (length(p256dh) between 20 and 512 and length(auth) between 8 and 256),
  constraint web_push_subscriptions_encoding_check
    check (content_encoding in ('aes128gcm', 'aesgcm')),
  constraint web_push_subscriptions_device_check
    check (jsonb_typeof(device_metadata) = 'object')
);

alter table app_private.web_push_subscriptions enable row level security;
revoke all on table app_private.web_push_subscriptions
  from public, anon, authenticated, service_role;

create index if not exists web_push_subscriptions_active_user_idx
  on app_private.web_push_subscriptions (user_id, last_seen_at desc)
  where revoked_at is null;

create table if not exists app_private.daily_report_settings (
  store_id uuid not null,
  agency_user_id uuid not null references public.app_users(id) on delete cascade,
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
  enabled boolean not null default false,
  report_time time without time zone not null default time '18:00',
  time_zone text not null default 'America/Sao_Paulo',
  next_run_at timestamptz,
  updated_by uuid references public.app_users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (store_id, agency_user_id),
  constraint daily_report_settings_store_admin_fk
    foreign key (store_id, admin_user_id)
    references public.stores(id, admin_user_id)
    on delete cascade,
  constraint daily_report_settings_enabled_run_check
    check (not enabled or next_run_at is not null)
);

alter table app_private.daily_report_settings enable row level security;
revoke all on table app_private.daily_report_settings
  from public, anon, authenticated, service_role;

create index if not exists daily_report_settings_due_idx
  on app_private.daily_report_settings (next_run_at, store_id, agency_user_id)
  where enabled = true;

create table if not exists app_private.daily_report_deliveries (
  id uuid primary key default gen_random_uuid(),
  store_id uuid not null,
  agency_user_id uuid not null,
  subscription_id uuid not null
    references app_private.web_push_subscriptions(id) on delete cascade,
  report_local_date date not null,
  payload_snapshot jsonb not null,
  status text not null default 'pending',
  attempts smallint not null default 0,
  next_attempt_at timestamptz not null default now(),
  locked_at timestamptz,
  sent_at timestamptz,
  last_http_status integer,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint daily_report_deliveries_setting_fk
    foreign key (store_id, agency_user_id)
    references app_private.daily_report_settings(store_id, agency_user_id)
    on delete cascade,
  constraint daily_report_deliveries_once
    unique (store_id, agency_user_id, subscription_id, report_local_date),
  constraint daily_report_deliveries_payload_check
    check (jsonb_typeof(payload_snapshot) = 'object'),
  constraint daily_report_deliveries_status_check
    check (status in ('pending', 'processing', 'sent', 'failed', 'dead')),
  constraint daily_report_deliveries_attempts_check
    check (attempts between 0 and 6)
);

alter table app_private.daily_report_deliveries enable row level security;
revoke all on table app_private.daily_report_deliveries
  from public, anon, authenticated, service_role;

create index if not exists daily_report_deliveries_retry_idx
  on app_private.daily_report_deliveries (next_attempt_at, created_at)
  where status in ('pending', 'failed', 'processing') and attempts < 3;

create or replace function app_private.daily_report_valid_time_zone(
  p_time_zone text
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from pg_catalog.pg_timezone_names timezone_name
    where timezone_name.name = p_time_zone
  );
$$;

create or replace function app_private.daily_report_next_run(
  p_report_time time without time zone,
  p_time_zone text,
  p_after timestamptz default now()
)
returns timestamptz
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_local_after timestamp without time zone;
  v_candidate timestamptz;
begin
  if p_report_time is null
     or p_after is null
     or not app_private.daily_report_valid_time_zone(p_time_zone) then
    raise exception 'Horario ou fuso do relatorio diario invalido.';
  end if;

  v_local_after := pg_catalog.timezone(p_time_zone, p_after);
  v_candidate := (v_local_after::date + p_report_time) at time zone p_time_zone;

  if v_candidate <= p_after then
    v_candidate := ((v_local_after::date + 1) + p_report_time)
      at time zone p_time_zone;
  end if;

  return v_candidate;
end;
$$;

create or replace function app_private.daily_report_store_allowed(
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
set search_path = ''
as $$
  select exists (
    select 1
    from public.stores store_record
    where store_record.id = p_store_id
      and store_record.admin_user_id = p_admin_user_id
      and store_record.is_active = true
      and (
        p_user_role::text = 'admin'
        or (
          p_user_role::text = 'store'
          and p_user_store_id = store_record.id
        )
        or (
          p_user_role::text = 'technician'
          and app_private.technician_can_access_store(
            p_admin_user_id,
            p_user_id,
            store_record.id
          )
        )
      )
  );
$$;

create or replace function app_private.build_daily_report_payload(
  p_store_id uuid,
  p_admin_user_id uuid,
  p_report_local_date date,
  p_time_zone text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_store_name text;
  v_day_start timestamptz;
  v_day_end timestamptz;
  v_revenue_cents bigint := 0;
  v_prospections bigint := 0;
  v_converted bigint := 0;
  v_conversion_rate numeric := 0;
begin
  if not app_private.daily_report_valid_time_zone(p_time_zone) then
    raise exception 'Fuso do relatorio diario invalido.';
  end if;

  select store_record.name
  into v_store_name
  from public.stores store_record
  where store_record.id = p_store_id
    and store_record.admin_user_id = p_admin_user_id
    and store_record.is_active = true;

  if not found then
    raise exception 'Loja do relatorio diario nao encontrada.';
  end if;

  v_day_start := p_report_local_date::timestamp at time zone p_time_zone;
  v_day_end := (p_report_local_date + 1)::timestamp at time zone p_time_zone;

  -- Esta e a mesma fonte contabil usada nas metas do Bom Dia Vendedor.
  select coalesce(pg_catalog.sum(
    pg_catalog.round(attendance.purchase_value * 100)::bigint
  ), 0)::bigint
  into v_revenue_cents
  from public.attendances attendance
  where attendance.store_id = p_store_id
    and attendance.admin_user_id = p_admin_user_id
    and attendance.tag = 'purchase'
    and attendance.purchase_value > 0
    and attendance.attended_at >= v_day_start
    and attendance.attended_at < v_day_end;

  -- Conversao usa uma unica coorte: prospectados no dia e, dentre eles,
  -- quantos ja possuem compra. Assim nunca mistura denominadores de dias
  -- diferentes nem pode ultrapassar 100%.
  select
    pg_catalog.count(*)::bigint,
    pg_catalog.count(*) filter (
      where prospection.purchased_at is not null
    )::bigint
  into v_prospections, v_converted
  from public.prospections prospection
  where prospection.store_id = p_store_id
    and prospection.admin_user_id = p_admin_user_id
    and prospection.created_at >= v_day_start
    and prospection.created_at < v_day_end;

  if v_prospections > 0 then
    v_conversion_rate := pg_catalog.round(
      (v_converted::numeric / v_prospections::numeric) * 100,
      1
    );
  end if;

  return pg_catalog.jsonb_build_object(
    'store_id', p_store_id,
    'store_name', v_store_name,
    'report_date', p_report_local_date,
    'time_zone', p_time_zone,
    'revenue_cents', v_revenue_cents,
    'prospections', v_prospections,
    'converted_prospections', v_converted,
    'conversion_rate', v_conversion_rate,
    'url', './?module=attendances'
  );
end;
$$;

create or replace function public.lc_get_push_public_key_v1(
  p_session_token text
)
returns table(public_key text)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_session record;
begin
  select * into v_session
  from app_private.session_user(p_session_token);

  return query
  select secret.decrypted_secret
  from vault.decrypted_secrets secret
  where secret.name = 'daily_report_vapid_public_key'
    and nullif(secret.decrypted_secret, '') is not null
  limit 1;
end;
$$;

create or replace function public.lc_register_push_subscription_v1(
  p_session_token text,
  p_subscription jsonb
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_session record;
  v_endpoint text;
  v_p256dh text;
  v_auth text;
  v_encoding text;
  v_expiration_time bigint;
  v_device jsonb;
  v_subscription_id uuid;
begin
  select * into v_session
  from app_private.session_user(p_session_token);

  if pg_catalog.jsonb_typeof(p_subscription) <> 'object' then
    raise exception 'Assinatura de notificacao invalida.';
  end if;

  v_endpoint := nullif(left(btrim(p_subscription->>'endpoint'), 4096), '');
  v_p256dh := nullif(left(btrim(p_subscription#>>'{keys,p256dh}'), 512), '');
  v_auth := nullif(left(btrim(p_subscription#>>'{keys,auth}'), 256), '');
  v_encoding := coalesce(
    nullif(left(btrim(p_subscription->>'content_encoding'), 20), ''),
    'aes128gcm'
  );
  v_device := case
    when pg_catalog.jsonb_typeof(p_subscription->'device') = 'object'
      then p_subscription->'device'
    else '{}'::jsonb
  end;

  if coalesce(p_subscription->>'expiration_time', '') ~ '^[0-9]+$' then
    v_expiration_time := (p_subscription->>'expiration_time')::bigint;
  end if;

  if v_endpoint is null
     or v_endpoint !~ '^https://'
     or v_p256dh is null
     or v_auth is null
     or v_encoding not in ('aes128gcm', 'aesgcm') then
    raise exception 'Assinatura de notificacao incompleta ou invalida.';
  end if;

  insert into app_private.web_push_subscriptions (
    user_id,
    admin_user_id,
    endpoint,
    p256dh,
    auth,
    content_encoding,
    expiration_time,
    device_metadata,
    revoked_at,
    last_seen_at,
    updated_at
  ) values (
    v_session.user_id,
    v_session.admin_user_id,
    v_endpoint,
    v_p256dh,
    v_auth,
    v_encoding,
    v_expiration_time,
    v_device,
    null,
    now(),
    now()
  )
  on conflict (endpoint) do update
  set user_id = excluded.user_id,
      admin_user_id = excluded.admin_user_id,
      p256dh = excluded.p256dh,
      auth = excluded.auth,
      content_encoding = excluded.content_encoding,
      expiration_time = excluded.expiration_time,
      device_metadata = excluded.device_metadata,
      revoked_at = null,
      last_seen_at = now(),
      updated_at = now()
  returning id into v_subscription_id;

  return pg_catalog.jsonb_build_object(
    'success', true,
    'subscription_id', v_subscription_id
  );
end;
$$;

create or replace function public.lc_unregister_push_subscription_v1(
  p_session_token text,
  p_endpoint text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_session record;
  v_count integer;
begin
  select * into v_session
  from app_private.session_user(p_session_token);

  update app_private.web_push_subscriptions subscription
  set revoked_at = now(),
      updated_at = now()
  where subscription.user_id = v_session.user_id
    and subscription.endpoint = nullif(left(btrim(p_endpoint), 4096), '')
    and subscription.revoked_at is null;

  get diagnostics v_count = row_count;
  return pg_catalog.jsonb_build_object('success', true, 'revoked', v_count);
end;
$$;

create or replace function public.lc_get_daily_report_settings_v1(
  p_session_token text,
  p_store_id uuid
)
returns table(
  store_id uuid,
  store_name text,
  agency_user_id uuid,
  agency_name text,
  enabled boolean,
  report_time time without time zone,
  time_zone text,
  has_active_subscription boolean,
  next_run_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_session record;
begin
  select * into v_session
  from app_private.session_user(p_session_token);

  if not app_private.daily_report_store_allowed(
    v_session.admin_user_id,
    v_session.user_id,
    v_session.user_role,
    v_session.user_store_id,
    p_store_id
  ) then
    raise exception 'Loja nao encontrada ou sem permissao para notificacoes.';
  end if;

  return query
  select
    store_record.id,
    store_record.name,
    agency.id,
    agency.full_name,
    coalesce(setting.enabled, false),
    coalesce(setting.report_time, time '18:00'),
    coalesce(setting.time_zone, 'America/Sao_Paulo'),
    exists (
      select 1
      from app_private.web_push_subscriptions subscription
      where subscription.user_id = agency.id
        and subscription.revoked_at is null
    ),
    setting.next_run_at
  from public.stores store_record
  join app_private.store_agency_accesses access
    on access.store_id = store_record.id
   and access.admin_user_id = store_record.admin_user_id
   and access.is_active = true
  join public.app_users agency
    on agency.id = access.agency_user_id
   and agency.admin_user_id = access.admin_user_id
   and agency.role::text = 'technician'
   and agency.is_active = true
  left join app_private.daily_report_settings setting
    on setting.store_id = access.store_id
   and setting.agency_user_id = access.agency_user_id
  where store_record.id = p_store_id
    and store_record.admin_user_id = v_session.admin_user_id
    and store_record.is_active = true
    and (
      v_session.user_role::text <> 'technician'
      or agency.id = v_session.user_id
    )
  order by agency.full_name, agency.id;
end;
$$;

create or replace function public.lc_save_daily_report_setting_v1(
  p_session_token text,
  p_store_id uuid,
  p_agency_user_id uuid,
  p_enabled boolean,
  p_report_time time without time zone,
  p_time_zone text
)
returns table(
  store_id uuid,
  agency_user_id uuid,
  enabled boolean,
  report_time time without time zone,
  time_zone text,
  has_active_subscription boolean,
  next_run_at timestamptz
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_session record;
  v_admin_user_id uuid;
  v_next_run_at timestamptz;
begin
  select * into v_session
  from app_private.session_user(p_session_token);

  if not app_private.daily_report_store_allowed(
    v_session.admin_user_id,
    v_session.user_id,
    v_session.user_role,
    v_session.user_store_id,
    p_store_id
  ) then
    raise exception 'Loja nao encontrada ou sem permissao para notificacoes.';
  end if;

  if v_session.user_role::text = 'technician'
     and p_agency_user_id is distinct from v_session.user_id then
    raise exception 'A agencia pode alterar somente o proprio relatorio.';
  end if;

  select access.admin_user_id
  into v_admin_user_id
  from app_private.store_agency_accesses access
  join public.app_users agency
    on agency.id = access.agency_user_id
   and agency.admin_user_id = access.admin_user_id
   and agency.role::text = 'technician'
   and agency.is_active = true
  where access.store_id = p_store_id
    and access.admin_user_id = v_session.admin_user_id
    and access.agency_user_id = p_agency_user_id
    and access.is_active = true;

  if not found then
    raise exception 'Agencia nao encontrada ou sem acesso ativo a esta loja.';
  end if;

  if p_enabled is null or p_report_time is null then
    raise exception 'Status e horario do relatorio sao obrigatorios.';
  end if;

  if not app_private.daily_report_valid_time_zone(p_time_zone) then
    raise exception 'Fuso do relatorio diario invalido.';
  end if;

  v_next_run_at := case
    when p_enabled then app_private.daily_report_next_run(
      p_report_time,
      p_time_zone,
      now()
    )
    else null
  end;

  insert into app_private.daily_report_settings (
    store_id,
    agency_user_id,
    admin_user_id,
    enabled,
    report_time,
    time_zone,
    next_run_at,
    updated_by,
    updated_at
  ) values (
    p_store_id,
    p_agency_user_id,
    v_admin_user_id,
    p_enabled,
    p_report_time,
    p_time_zone,
    v_next_run_at,
    v_session.user_id,
    now()
  )
  on conflict (store_id, agency_user_id) do update
  set admin_user_id = excluded.admin_user_id,
      enabled = excluded.enabled,
      report_time = excluded.report_time,
      time_zone = excluded.time_zone,
      next_run_at = excluded.next_run_at,
      updated_by = excluded.updated_by,
      updated_at = now();

  return query
  select
    setting.store_id,
    setting.agency_user_id,
    setting.enabled,
    setting.report_time,
    setting.time_zone,
    exists (
      select 1
      from app_private.web_push_subscriptions subscription
      where subscription.user_id = setting.agency_user_id
        and subscription.revoked_at is null
    ),
    setting.next_run_at
  from app_private.daily_report_settings setting
  where setting.store_id = p_store_id
    and setting.agency_user_id = p_agency_user_id;
end;
$$;

create or replace function public.lc_claim_daily_report_deliveries_v1(
  p_limit integer default 50
)
returns table(
  delivery_id uuid,
  endpoint text,
  p256dh text,
  auth text,
  content_encoding text,
  payload jsonb,
  attempt integer
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_setting record;
  v_report_date date;
  v_payload jsonb;
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 200));
begin
  update app_private.daily_report_deliveries delivery
  set status = 'failed',
      locked_at = null,
      next_attempt_at = now(),
      last_error = 'Tempo limite do processamento anterior excedido.',
      updated_at = now()
  where delivery.status = 'processing'
    and delivery.locked_at < now() - interval '10 minutes'
    and delivery.attempts < 3;

  for v_setting in
    select setting.*
    from app_private.daily_report_settings setting
    where setting.enabled = true
      and setting.next_run_at <= now()
    order by setting.next_run_at, setting.store_id, setting.agency_user_id
    for update skip locked
    limit v_limit
  loop
    v_report_date := pg_catalog.timezone(
      v_setting.time_zone,
      v_setting.next_run_at
    )::date;
    v_payload := app_private.build_daily_report_payload(
      v_setting.store_id,
      v_setting.admin_user_id,
      v_report_date,
      v_setting.time_zone
    );

    insert into app_private.daily_report_deliveries (
      store_id,
      agency_user_id,
      subscription_id,
      report_local_date,
      payload_snapshot
    )
    select
      v_setting.store_id,
      v_setting.agency_user_id,
      subscription.id,
      v_report_date,
      v_payload
    from app_private.web_push_subscriptions subscription
    where subscription.user_id = v_setting.agency_user_id
      and subscription.admin_user_id = v_setting.admin_user_id
      and subscription.revoked_at is null
    on conflict (
      store_id,
      agency_user_id,
      subscription_id,
      report_local_date
    ) do nothing;

    update app_private.daily_report_settings setting
    set next_run_at = app_private.daily_report_next_run(
          v_setting.report_time,
          v_setting.time_zone,
          v_setting.next_run_at + interval '1 second'
        ),
        updated_at = now()
    where setting.store_id = v_setting.store_id
      and setting.agency_user_id = v_setting.agency_user_id;
  end loop;

  return query
  with claimable as (
    select delivery.id
    from app_private.daily_report_deliveries delivery
    join app_private.daily_report_settings setting
      on setting.store_id = delivery.store_id
     and setting.agency_user_id = delivery.agency_user_id
     and setting.enabled = true
    join app_private.web_push_subscriptions subscription
      on subscription.id = delivery.subscription_id
     and subscription.revoked_at is null
    where delivery.status in ('pending', 'failed')
      and delivery.attempts < 3
      and delivery.next_attempt_at <= now()
    order by delivery.next_attempt_at, delivery.created_at, delivery.id
    for update of delivery skip locked
    limit v_limit
  ), claimed as (
    update app_private.daily_report_deliveries delivery
    set status = 'processing',
        attempts = delivery.attempts + 1,
        locked_at = now(),
        updated_at = now()
    from claimable
    where delivery.id = claimable.id
    returning delivery.*
  )
  select
    claimed.id,
    subscription.endpoint,
    subscription.p256dh,
    subscription.auth,
    subscription.content_encoding,
    claimed.payload_snapshot,
    claimed.attempts::integer
  from claimed
  join app_private.web_push_subscriptions subscription
    on subscription.id = claimed.subscription_id
  order by claimed.created_at, claimed.id;
end;
$$;

create or replace function public.lc_complete_daily_report_delivery_v1(
  p_delivery_id uuid,
  p_succeeded boolean,
  p_permanent_failure boolean default false,
  p_http_status integer default null,
  p_error text default null
)
returns boolean
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_subscription_id uuid;
  v_attempts integer;
begin
  select delivery.subscription_id, delivery.attempts
  into v_subscription_id, v_attempts
  from app_private.daily_report_deliveries delivery
  where delivery.id = p_delivery_id
    and delivery.status = 'processing'
  for update;

  if not found then
    return false;
  end if;

  update app_private.daily_report_deliveries delivery
  set status = case
        when p_succeeded then 'sent'
        when p_permanent_failure or v_attempts >= 3 then 'dead'
        else 'failed'
      end,
      sent_at = case when p_succeeded then now() else null end,
      locked_at = null,
      next_attempt_at = case
        when p_succeeded or p_permanent_failure or v_attempts >= 3 then now()
        else now() + pg_catalog.make_interval(
          mins => case v_attempts when 1 then 2 when 2 then 10 else 30 end
        )
      end,
      last_http_status = p_http_status,
      last_error = case
        when p_succeeded then null
        else left(coalesce(nullif(btrim(p_error), ''), 'Falha no envio Web Push.'), 500)
      end,
      updated_at = now()
  where delivery.id = p_delivery_id;

  if p_permanent_failure then
    update app_private.web_push_subscriptions subscription
    set revoked_at = coalesce(subscription.revoked_at, now()),
        updated_at = now()
    where subscription.id = v_subscription_id;
  end if;

  return true;
end;
$$;

revoke all on function app_private.daily_report_valid_time_zone(text)
  from public, anon, authenticated, service_role;
revoke all on function app_private.daily_report_next_run(time, text, timestamptz)
  from public, anon, authenticated, service_role;
revoke all on function app_private.daily_report_store_allowed(
  uuid, uuid, public.app_user_role, uuid, uuid
) from public, anon, authenticated, service_role;
revoke all on function app_private.build_daily_report_payload(
  uuid, uuid, date, text
) from public, anon, authenticated, service_role;

revoke all on function public.lc_get_push_public_key_v1(text)
  from public, anon, authenticated, service_role;
grant execute on function public.lc_get_push_public_key_v1(text)
  to anon, authenticated, service_role;

revoke all on function public.lc_register_push_subscription_v1(text, jsonb)
  from public, anon, authenticated, service_role;
grant execute on function public.lc_register_push_subscription_v1(text, jsonb)
  to anon, authenticated, service_role;

revoke all on function public.lc_unregister_push_subscription_v1(text, text)
  from public, anon, authenticated, service_role;
grant execute on function public.lc_unregister_push_subscription_v1(text, text)
  to anon, authenticated, service_role;

revoke all on function public.lc_get_daily_report_settings_v1(text, uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.lc_get_daily_report_settings_v1(text, uuid)
  to anon, authenticated, service_role;

revoke all on function public.lc_save_daily_report_setting_v1(
  text, uuid, uuid, boolean, time, text
) from public, anon, authenticated, service_role;
grant execute on function public.lc_save_daily_report_setting_v1(
  text, uuid, uuid, boolean, time, text
) to anon, authenticated, service_role;

revoke all on function public.lc_claim_daily_report_deliveries_v1(integer)
  from public, anon, authenticated, service_role;
grant execute on function public.lc_claim_daily_report_deliveries_v1(integer)
  to service_role;

revoke all on function public.lc_complete_daily_report_delivery_v1(
  uuid, boolean, boolean, integer, text
) from public, anon, authenticated, service_role;
grant execute on function public.lc_complete_daily_report_delivery_v1(
  uuid, boolean, boolean, integer, text
) to service_role;

comment on table app_private.web_push_subscriptions is
  'Assinaturas Web Push privadas dos aparelhos que optaram por receber relatorios.';
comment on table app_private.daily_report_settings is
  'Agenda independente de relatorio para cada vinculo loja-agencia.';
comment on table app_private.daily_report_deliveries is
  'Outbox idempotente e auditavel dos relatorios diarios enviados por Web Push.';
comment on function public.lc_get_daily_report_settings_v1(text, uuid) is
  'Lista a agenda de cada agencia ativa na loja, limitada pelo escopo da sessao.';
comment on function public.lc_claim_daily_report_deliveries_v1(integer) is
  'Materializa agendamentos vencidos e bloqueia um lote de entregas para o worker.';

-- A URL e o segredo sao lidos do Vault somente no instante de cada execucao.
-- Eles sao provisionados fora da migracao para nunca entrarem no Git.
select cron.unschedule('daily-report-push-every-minute')
where exists (
  select 1
  from cron.job scheduled_job
  where scheduled_job.jobname = 'daily-report-push-every-minute'
);

select cron.schedule(
  'daily-report-push-every-minute',
  '* * * * *',
  $cron$
    select net.http_post(
      url := (
        select secret.decrypted_secret
        from vault.decrypted_secrets secret
        where secret.name = 'daily_report_function_url'
        limit 1
      ),
      headers := pg_catalog.jsonb_build_object(
        'Content-Type', 'application/json',
        'x-cron-secret', (
          select secret.decrypted_secret
          from vault.decrypted_secrets secret
          where secret.name = 'daily_report_cron_secret'
          limit 1
        )
      ),
      body := '{"source":"pg_cron"}'::jsonb,
      timeout_milliseconds := 50000
    );
  $cron$
);

do $qa$
begin
  if pg_catalog.has_table_privilege(
       'anon',
       'app_private.web_push_subscriptions',
       'SELECT'
     )
     or pg_catalog.has_table_privilege(
       'authenticated',
       'app_private.web_push_subscriptions',
       'SELECT'
     ) then
    raise exception 'QA Push: tabela privada exposta para cliente.';
  end if;

  if pg_catalog.has_function_privilege(
       'anon',
       'public.lc_claim_daily_report_deliveries_v1(integer)',
       'EXECUTE'
     )
     or pg_catalog.has_function_privilege(
       'authenticated',
       'public.lc_claim_daily_report_deliveries_v1(integer)',
       'EXECUTE'
     )
     or not pg_catalog.has_function_privilege(
       'service_role',
       'public.lc_claim_daily_report_deliveries_v1(integer)',
       'EXECUTE'
     ) then
    raise exception 'QA Push: ACL do worker esta incorreta.';
  end if;

  if app_private.daily_report_next_run(
       time '18:00',
       'America/Sao_Paulo',
       timestamptz '2026-09-09 22:00:00+00'
     ) <> timestamptz '2026-09-10 21:00:00+00' then
    raise exception 'QA Push: calculo do proximo horario local esta incorreto.';
  end if;
end;
$qa$;

notify pgrst, 'reload schema';

commit;
