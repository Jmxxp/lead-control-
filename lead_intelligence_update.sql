-- Inteligencia comercial nativa, historico de lifecycle e auditoria da IA.
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
      'lead_created',
      'contacted',
      'qualified',
      'scheduled',
      'visited',
      'purchased',
      'lost',
      'reopened'
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
alter table public.ai_usage enable row level security;

drop trigger if exists lead_intelligence_set_updated_at on public.lead_intelligence;
create trigger lead_intelligence_set_updated_at
before update on public.lead_intelligence
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
  case
    when l.bought = 'Sim' then coalesce(l.updated_at, l.created_at)
    else null
  end
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
  insert into public.lead_intelligence (
    lead_id, admin_user_id, store_id, lifecycle_status
  ) values (
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
      new.admin_user_id,
      new.store_id,
      new.id,
      'lead_created',
      coalesce(new.created_at, v_event_at),
      new.created_by,
      jsonb_build_object('channel', new.channel, 'campaign', new.campaign)
    );
  end if;

  if new.scheduled = 'Sim'
     and (tg_op = 'INSERT' or old.scheduled is distinct from 'Sim') then
    insert into public.lead_events (
      admin_user_id, store_id, lead_id, event_type, event_at, actor_user_id, metadata
    ) values (
      new.admin_user_id,
      new.store_id,
      new.id,
      'scheduled',
      v_event_at,
      new.updated_by,
      jsonb_build_object(
        'visit_date', new.scheduled_visit_date,
        'visit_time', new.scheduled_visit_time
      )
    );

    update public.lead_intelligence
    set lifecycle_status = case
      when lifecycle_status in ('won', 'lost') then lifecycle_status
      else 'scheduled'
    end
    where lead_id = new.id;
  end if;

  if new.visited = 'Sim'
     and (tg_op = 'INSERT' or old.visited is distinct from 'Sim') then
    insert into public.lead_events (
      admin_user_id, store_id, lead_id, event_type, event_at, actor_user_id
    ) values (
      new.admin_user_id, new.store_id, new.id, 'visited', v_event_at, new.updated_by
    );

    update public.lead_intelligence
    set lifecycle_status = case
      when lifecycle_status in ('won', 'lost') then lifecycle_status
      else 'visited'
    end
    where lead_id = new.id;
  end if;

  if new.bought = 'Sim'
     and (tg_op = 'INSERT' or old.bought is distinct from 'Sim') then
    insert into public.lead_events (
      admin_user_id, store_id, lead_id, event_type, event_at, actor_user_id, metadata
    ) values (
      new.admin_user_id,
      new.store_id,
      new.id,
      'purchased',
      v_event_at,
      new.updated_by,
      jsonb_build_object('value', new.purchase_amount, 'order_id', new.service_order)
    );

    update public.lead_intelligence
    set lifecycle_status = 'won',
        purchased_at = coalesce(purchased_at, v_event_at)
    where lead_id = new.id;
  end if;

  return new;
end;
$$;

drop trigger if exists leads_capture_lifecycle on public.leads;
create trigger leads_capture_lifecycle
after insert or update of
  store_id,
  scheduled,
  scheduled_visit_date,
  scheduled_visit_time,
  visited,
  bought,
  purchase_amount,
  service_order
on public.leads
for each row execute function app_private.capture_lead_lifecycle();

-- O tipo de retorno foi reduzido aos campos comerciais. DROP e necessario
-- quando este arquivo substitui uma versao antiga que ainda expunha tracking.
drop function if exists public.lc_list_lead_intelligence(text);
drop function if exists app_private.rpc_list_lead_intelligence(text);

create function app_private.rpc_list_lead_intelligence(p_session_token text)
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
  returning_customer boolean
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session
  from app_private.session_user(p_session_token);

  return query
  select
    li.lead_id,
    li.lifecycle_status,
    li.qualified,
    li.loss_reason,
    li.owner_name,
    li.email,
    li.first_response_at,
    li.qualified_at,
    li.lost_at,
    li.purchased_at,
    li.returning_customer
  from public.lead_intelligence li
  join public.stores st on st.id = li.store_id
  where li.admin_user_id = v_session.admin_user_id
    and (
      v_session.user_role::text = 'admin'
      or (
        v_session.user_role::text = 'technician'
        and st.technician_user_id = v_session.user_id
      )
      or (
        v_session.user_role::text = 'store'
        and li.store_id = v_session.user_store_id
      )
    );
end;
$$;

create function public.lc_list_lead_intelligence(p_session_token text)
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
  returning_customer boolean
)
language sql
security invoker
as $$
  select * from app_private.rpc_list_lead_intelligence(p_session_token);
$$;

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
  select * into v_session
  from app_private.session_user(p_session_token);

  select l.* into v_lead
  from public.leads l
  join public.stores st on st.id = l.store_id
  where l.id = p_lead_id
    and l.admin_user_id = v_session.admin_user_id
    and (
      v_session.user_role::text = 'admin'
      or (
        v_session.user_role::text = 'technician'
        and st.technician_user_id = v_session.user_id
      )
      or (
        v_session.user_role::text = 'store'
        and l.store_id = v_session.user_store_id
      )
    );

  if not found then
    raise exception 'Lead nao encontrado ou sem permissao.';
  end if;

  insert into public.lead_intelligence (lead_id, admin_user_id, store_id)
  values (v_lead.id, v_lead.admin_user_id, v_lead.store_id)
  on conflict (lead_id) do nothing;

  select * into v_before
  from public.lead_intelligence
  where lead_id = p_lead_id;

  v_status := coalesce(
    nullif(btrim(p_payload->>'lifecycle_status'), ''),
    v_before.lifecycle_status
  );

  if v_status not in ('new', 'contacted', 'qualified', 'scheduled', 'visited', 'won', 'lost') then
    raise exception 'Etapa comercial invalida.';
  end if;

  v_qualified := case
    when p_payload ? 'qualified'
      then lower(coalesce(p_payload->>'qualified', 'false')) in ('true', '1', 'sim')
    else v_before.qualified
  end;

  v_loss_reason := case
    when p_payload ? 'loss_reason'
      then nullif(btrim(p_payload->>'loss_reason'), '')
    else v_before.loss_reason
  end;

  if v_status = 'lost' and v_loss_reason is null then
    raise exception 'Informe o motivo da perda.';
  end if;

  update public.lead_intelligence
  set lifecycle_status = v_status,
      qualified = v_qualified,
      loss_reason = case when v_status = 'lost' then v_loss_reason else null end,
      owner_name = case
        when p_payload ? 'owner_name'
          then nullif(left(btrim(p_payload->>'owner_name'), 160), '')
        else owner_name
      end,
      email = case
        when p_payload ? 'email'
          then nullif(left(lower(btrim(p_payload->>'email')), 320), '')
        else email
      end,
      first_response_at = case
        when p_payload ? 'first_response_at'
          then nullif(p_payload->>'first_response_at', '')::timestamptz
        else first_response_at
      end,
      qualified_at = case
        when v_qualified then coalesce(qualified_at, now())
        else null
      end,
      lost_at = case
        when v_status = 'lost' then coalesce(lost_at, now())
        else null
      end,
      purchased_at = case
        when v_status = 'won' then coalesce(purchased_at, now())
        else purchased_at
      end,
      returning_customer = case
        when p_payload ? 'returning_customer'
          then lower(coalesce(p_payload->>'returning_customer', 'false')) in ('true', '1', 'sim')
        else returning_customer
      end
  where lead_id = p_lead_id;

  if v_qualified and not v_before.qualified then
    insert into public.lead_events (
      admin_user_id, store_id, lead_id, event_type, actor_user_id
    ) values (
      v_lead.admin_user_id, v_lead.store_id, v_lead.id, 'qualified', v_session.user_id
    );
  end if;

  if v_status = 'lost' and v_before.lifecycle_status is distinct from 'lost' then
    insert into public.lead_events (
      admin_user_id, store_id, lead_id, event_type, actor_user_id, metadata
    ) values (
      v_lead.admin_user_id,
      v_lead.store_id,
      v_lead.id,
      'lost',
      v_session.user_id,
      jsonb_build_object('reason', v_loss_reason)
    );
  elsif v_before.lifecycle_status = 'lost' and v_status <> 'lost' then
    insert into public.lead_events (
      admin_user_id, store_id, lead_id, event_type, actor_user_id
    ) values (
      v_lead.admin_user_id, v_lead.store_id, v_lead.id, 'reopened', v_session.user_id
    );
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
as $$
  select app_private.rpc_save_lead_intelligence(
    p_session_token,
    p_lead_id,
    p_payload
  );
$$;

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
declare
  v_lead_id uuid;
begin
  v_lead_id := public.lc_upsert_lead(
    p_session_token,
    p_lead_id,
    p_name,
    p_phone,
    p_channel,
    p_campaign,
    p_conversation_start,
    p_conclusion,
    p_scheduled,
    p_scheduled_visit_date,
    p_scheduled_visit_time,
    p_visited,
    p_bought,
    p_purchase_amount,
    p_service_order,
    p_notes,
    p_custom_values,
    p_store_id,
    p_contact_date
  );

  perform app_private.rpc_save_lead_intelligence(
    p_session_token,
    v_lead_id,
    p_intelligence
  );
  return v_lead_id;
end;
$$;

-- A chave da IA nunca e devolvida ao navegador. A assinatura fica compativel
-- com o editor central existente.
create or replace function app_private.rpc_get_ai_settings(p_session_token text)
returns table (
  provider text,
  model text,
  api_key text,
  system_prompt text,
  has_api_key boolean,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session
  from app_private.session_user(p_session_token);

  if v_session.user_role::text not in ('admin', 'technician') then
    raise exception 'A IA esta disponivel somente para admin e empresas B2B.';
  end if;

  return query
  select
    coalesce(s.provider, 'deepseek'),
    coalesce(s.model, 'deepseek-chat'),
    ''::text,
    coalesce(
      nullif(btrim(s.system_prompt), ''),
      'Voce e uma IA especialista em analise comercial. Use somente os dados agregados da loja selecionada, sinalize amostras pequenas e priorize acoes mensuraveis.'
    ),
    coalesce(length(btrim(s.api_key)) > 0, false),
    s.updated_at
  from (select 1) seed
  left join public.ai_settings s
    on s.admin_user_id = v_session.admin_user_id;
end;
$$;

create or replace function public.lc_ai_runtime_config(p_session_token text)
returns table (
  admin_user_id uuid,
  user_id uuid,
  user_role text,
  provider text,
  model text,
  api_key text,
  system_prompt text
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session
  from app_private.session_user(p_session_token);

  if v_session.user_role::text not in ('admin', 'technician') then
    raise exception 'A IA esta disponivel somente para admin e empresas B2B.';
  end if;

  if (
    select count(*)
    from public.ai_usage u
    where u.admin_user_id = v_session.admin_user_id
      and u.created_at > now() - interval '1 hour'
  ) >= 120 then
    raise exception 'Limite temporario de analises atingido. Tente novamente em alguns minutos.';
  end if;

  return query
  select
    v_session.admin_user_id,
    v_session.user_id,
    v_session.user_role::text,
    s.provider,
    s.model,
    s.api_key,
    coalesce(
      nullif(btrim(s.system_prompt), ''),
      'Voce e uma IA especialista em analise comercial. Use somente os dados agregados da loja selecionada, sinalize amostras pequenas e priorize acoes mensuraveis.'
    )
  from public.ai_settings s
  where s.admin_user_id = v_session.admin_user_id
    and length(btrim(s.api_key)) > 0;

  if not found then
    raise exception 'A IA ainda nao foi configurada pelo administrador.';
  end if;
end;
$$;

create or replace function public.lc_log_ai_usage(
  p_admin_user_id uuid,
  p_user_id uuid,
  p_store_id uuid,
  p_provider text,
  p_model text,
  p_request_kind text,
  p_input_tokens integer,
  p_output_tokens integer,
  p_latency_ms integer,
  p_status text
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
begin
  insert into public.ai_usage (
    admin_user_id,
    user_id,
    store_id,
    provider,
    model,
    request_kind,
    input_tokens,
    output_tokens,
    latency_ms,
    status
  ) values (
    p_admin_user_id,
    p_user_id,
    p_store_id,
    left(p_provider, 40),
    left(p_model, 160),
    left(coalesce(p_request_kind, 'chat'), 40),
    p_input_tokens,
    p_output_tokens,
    p_latency_ms,
    left(coalesce(p_status, 'success'), 40)
  );
  return true;
end;
$$;

revoke all on table public.lead_intelligence from public, anon, authenticated;
revoke all on table public.lead_events from public, anon, authenticated;
revoke all on table public.ai_usage from public, anon, authenticated;

revoke execute on function app_private.rpc_list_lead_intelligence(text) from public;
revoke execute on function app_private.rpc_save_lead_intelligence(text, uuid, jsonb) from public;
revoke execute on function public.lc_list_lead_intelligence(text) from public;
revoke execute on function public.lc_save_lead_intelligence(text, uuid, jsonb) from public;
revoke execute on function public.lc_upsert_lead_with_intelligence(text, uuid, text, text, text, text, text, text, text, date, time, text, text, numeric, text, text, jsonb, uuid, date, jsonb) from public;
revoke execute on function public.lc_ai_runtime_config(text) from public, anon, authenticated;
revoke execute on function public.lc_log_ai_usage(uuid, uuid, uuid, text, text, text, integer, integer, integer, text) from public, anon, authenticated;

grant execute on function app_private.rpc_list_lead_intelligence(text) to anon, authenticated;
grant execute on function app_private.rpc_save_lead_intelligence(text, uuid, jsonb) to anon, authenticated;
grant execute on function public.lc_list_lead_intelligence(text) to anon, authenticated;
grant execute on function public.lc_save_lead_intelligence(text, uuid, jsonb) to anon, authenticated;
grant execute on function public.lc_upsert_lead_with_intelligence(text, uuid, text, text, text, text, text, text, text, date, time, text, text, numeric, text, text, jsonb, uuid, date, jsonb) to anon, authenticated;
grant execute on function public.lc_ai_runtime_config(text) to service_role;
grant execute on function public.lc_log_ai_usage(uuid, uuid, uuid, text, text, text, integer, integer, integer, text) to service_role;

notify pgrst, 'reload schema';

commit;
