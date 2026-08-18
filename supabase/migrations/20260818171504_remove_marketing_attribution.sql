-- Remove o modulo de atribuicao/importacao de Meta Ads e Google Ads.
-- Preserva a inteligencia comercial nativa, o historico de lifecycle e a IA.

begin;

set local lock_timeout = '10s';
set local statement_timeout = '120s';
set local search_path = public, extensions;

-- O cron nao apaga o historico ao ser desagendado. Guardamos o jobid para
-- remover somente as execucoes dos jobs exclusivos deste modulo.
do $migration$
declare
  v_job_id bigint;
begin
  if to_regclass('cron.job') is not null then
    for v_job_id in
      execute $query$
        select jobid
        from cron.job
        where jobname in ('marketing-worker-30-seconds', 'marketing-worker-2-minutes')
      $query$
    loop
      perform cron.unschedule(v_job_id);

      if to_regclass('cron.job_run_details') is not null then
        execute 'delete from cron.job_run_details where jobid = $1'
          using v_job_id;
      end if;
    end loop;
  end if;
end;
$migration$;

-- Impede novas escritas de atribuicao antes de desmontar as dependencias.
drop trigger if exists ma_leads_capture_lifecycle on public.leads;
drop trigger if exists ma_lead_intelligence_lifecycle on public.lead_intelligence;

-- RPCs publicas legadas precisam sair antes das funcoes privadas/tipos de tabela.
drop function if exists public.lc_list_ad_daily_metrics(text, uuid, date, date);
drop function if exists public.lc_upsert_ad_daily_metric(text, jsonb);
drop function if exists public.lc_list_marketing_targets(text);
drop function if exists public.lc_save_marketing_targets(text, uuid, jsonb);
drop function if exists public.lc_list_marketing_connections(text, uuid);
drop function if exists public.lc_marketing_connection_runtime(text, uuid, text);

drop function if exists app_private.rpc_list_ad_daily_metrics(text, uuid, date, date);
drop function if exists app_private.rpc_upsert_ad_daily_metric(text, jsonb);
drop function if exists app_private.rpc_list_marketing_targets(text);
drop function if exists app_private.rpc_save_marketing_targets(text, uuid, jsonb);
drop function if exists app_private.rpc_list_marketing_connections(text, uuid);

-- O prefixo ma_ pertence exclusivamente ao modulo seguro de atribuicao. O
-- CASCADE fica restrito a essas rotinas e remove apenas triggers dependentes.
do $migration$
declare
  v_signature text;
begin
  for v_signature in
    select p.oid::regprocedure::text
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('public', 'app_private')
      and left(p.proname, 3) = 'ma_'
    order by n.nspname, p.proname, p.oid
  loop
    execute format('drop function if exists %s cascade', v_signature);
  end loop;
end;
$migration$;

-- Reescreve o lifecycle nativo sem fila de conversao, click IDs ou consentimento
-- de marketing. Canais e campanhas do proprio negocio continuam no evento.
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
  )
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

-- A lista muda de tipo de retorno, portanto as duas assinaturas precisam ser
-- recriadas. Permanecem somente os campos de operacao comercial propria.
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

-- O wrapper manteve a assinatura; CREATE OR REPLACE preserva consumidores.
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

-- Remove apenas eventos derivados da antiga atribuicao. O historico comercial
-- (criacao, contato, qualificacao, visita, compra, perda e reabertura) permanece.
delete from public.lead_events
where event_type = 'attribution_updated';

alter table public.lead_events
  drop constraint if exists lead_events_type_check;

alter table public.lead_events
  add constraint lead_events_type_check check (
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
  );

-- Colunas de rastreamento externo. Sem CASCADE: uma dependencia inesperada
-- deve abortar a migration em vez de remover codigo de outro dominio.
alter table public.lead_intelligence
  drop column if exists utm_source,
  drop column if exists utm_medium,
  drop column if exists utm_campaign,
  drop column if exists utm_content,
  drop column if exists utm_term,
  drop column if exists campaign_external_id,
  drop column if exists adset_external_id,
  drop column if exists ad_external_id,
  drop column if exists creative_external_id,
  drop column if exists gclid,
  drop column if exists gbraid,
  drop column if exists wbraid,
  drop column if exists fbclid,
  drop column if exists fbc,
  drop column if exists fbp,
  drop column if exists landing_page_url,
  drop column if exists external_lead_id,
  drop column if exists marketing_consent,
  drop column if exists consent_at;

-- Tabelas seguras de atribuicao, em ordem inversa de dependencia.
drop table if exists app_private.marketing_oauth_states;
drop table if exists app_private.marketing_attribution_connection_secrets;
drop table if exists public.marketing_offline_conversion_queue;
drop table if exists public.marketing_ad_metrics;
drop table if exists public.marketing_sync_runs;
drop table if exists public.marketing_sync_queue;
drop table if exists public.marketing_touchpoints;
drop table if exists public.marketing_tracking_sources;
drop table if exists public.marketing_attribution_events;
drop table if exists public.marketing_attribution_logs;
drop table if exists app_private.marketing_maintenance_state;
drop table if exists public.marketing_attribution_connections;

-- Estrutura legada/manual de Meta Ads e Google Ads.
drop table if exists public.marketing_conversion_queue;
drop table if exists public.marketing_connections;
drop table if exists public.store_marketing_targets;
drop table if exists public.ad_daily_metrics;

-- Segredos Vault usados somente para disparar o worker. Os segredos das Edge
-- Functions sao gerenciados fora do Postgres e constam no runbook de remocao.
do $migration$
begin
  if to_regclass('vault.secrets') is not null then
    execute $query$
      delete from vault.secrets
      where name in ('marketing_project_url', 'marketing_worker_secret')
    $query$;
  end if;
end;
$migration$;

revoke all on table public.lead_intelligence from public, anon, authenticated;
revoke all on table public.lead_events from public, anon, authenticated;

revoke execute on function app_private.rpc_list_lead_intelligence(text) from public;
revoke execute on function app_private.rpc_save_lead_intelligence(text, uuid, jsonb) from public;
revoke execute on function public.lc_list_lead_intelligence(text) from public;
revoke execute on function public.lc_save_lead_intelligence(text, uuid, jsonb) from public;

grant execute on function app_private.rpc_list_lead_intelligence(text) to anon, authenticated;
grant execute on function app_private.rpc_save_lead_intelligence(text, uuid, jsonb) to anon, authenticated;
grant execute on function public.lc_list_lead_intelligence(text) to anon, authenticated;
grant execute on function public.lc_save_lead_intelligence(text, uuid, jsonb) to anon, authenticated;

notify pgrst, 'reload schema';

commit;
