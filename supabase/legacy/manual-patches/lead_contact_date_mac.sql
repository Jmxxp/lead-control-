-- SQL pronto para colar no Supabase SQL Editor.
-- Adiciona e salva a data do contato do lead.

set search_path = public, extensions;

alter table public.leads add column if not exists contact_date date;

update public.leads
set contact_date = coalesce(contact_date, (timezone('America/Sao_Paulo', created_at))::date, (timezone('America/Sao_Paulo', now()))::date)
where contact_date is null;

alter table public.leads alter column contact_date set default ((timezone('America/Sao_Paulo', now()))::date);
alter table public.leads alter column contact_date set not null;

create index if not exists leads_admin_contact_date_idx on public.leads (admin_user_id, contact_date desc, created_at desc);
create index if not exists leads_store_contact_date_idx on public.leads (store_id, contact_date desc, created_at desc);

create or replace function app_private.rpc_set_lead_contact_date(p_session_token text, p_lead_id uuid, p_contact_date date default null)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);

  update public.leads
  set
    contact_date = coalesce(p_contact_date, contact_date, (timezone('America/Sao_Paulo', now()))::date),
    updated_by = v_session.user_id
  where id = p_lead_id
    and admin_user_id = v_session.admin_user_id
    and (v_session.user_role::text = 'admin' or store_id = v_session.user_store_id);

  if not found then
    raise exception 'Lead nao encontrado ou sem permissao.';
  end if;

  return true;
end;
$$;

create or replace function app_private.rpc_list_leads_contact_date(p_session_token text)
returns table (
  id uuid,
  store_id uuid,
  store_name text,
  name text,
  phone text,
  contact_date date,
  channel text,
  campaign text,
  conversation_start text,
  conclusion text,
  scheduled text,
  scheduled_visit_date date,
  scheduled_visit_time time,
  visited text,
  bought text,
  purchase_amount numeric,
  service_order text,
  notes text,
  inspected boolean,
  custom_values jsonb,
  created_at timestamptz,
  updated_at timestamptz
)
language sql
security definer
set search_path = app_private, public, extensions
as $$
  select
    r.id,
    r.store_id,
    r.store_name,
    r.name,
    r.phone,
    l.contact_date,
    r.channel,
    r.campaign,
    r.conversation_start,
    r.conclusion,
    r.scheduled,
    r.scheduled_visit_date,
    r.scheduled_visit_time,
    r.visited,
    r.bought,
    r.purchase_amount,
    r.service_order,
    r.notes,
    r.inspected,
    r.custom_values,
    r.created_at,
    r.updated_at
  from app_private.rpc_list_leads(p_session_token) r
  join public.leads l on l.id = r.id;
$$;

drop function if exists public.lc_list_leads(text);

create or replace function public.lc_list_leads(p_session_token text)
returns table (
  id uuid,
  store_id uuid,
  store_name text,
  name text,
  phone text,
  contact_date date,
  channel text,
  campaign text,
  conversation_start text,
  conclusion text,
  scheduled text,
  scheduled_visit_date date,
  scheduled_visit_time time,
  visited text,
  bought text,
  purchase_amount numeric,
  service_order text,
  notes text,
  inspected boolean,
  custom_values jsonb,
  created_at timestamptz,
  updated_at timestamptz
)
language sql
security invoker
as $$
  select * from app_private.rpc_list_leads_contact_date(p_session_token);
$$;

drop function if exists public.lc_upsert_lead(text, uuid, text, text, text, text, text, text, text, text, uuid);
drop function if exists public.lc_upsert_lead(text, uuid, text, text, text, text, text, text, text, text, numeric, text, uuid);
drop function if exists public.lc_upsert_lead(text, uuid, text, text, text, text, text, text, text, text, numeric, text, text, uuid);
drop function if exists public.lc_upsert_lead(text, uuid, text, text, text, text, text, text, text, text, numeric, text, text, jsonb, uuid);
drop function if exists public.lc_upsert_lead(text, uuid, text, text, text, text, text, text, text, date, time, text, text, numeric, text, text, uuid);
drop function if exists public.lc_upsert_lead(text, uuid, text, text, text, text, text, text, text, date, time, text, text, numeric, text, text, jsonb, uuid);
drop function if exists public.lc_upsert_lead(text, uuid, text, text, text, text, text, text, text, date, time, text, text, numeric, text, text, jsonb, uuid, date);

create or replace function public.lc_upsert_lead(
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
  p_contact_date date default null
)
returns uuid
language plpgsql
security invoker
as $$
declare
  v_lead_id uuid;
begin
  v_lead_id := app_private.rpc_upsert_lead(
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
    p_store_id
  );

  perform app_private.rpc_set_lead_contact_date(p_session_token, v_lead_id, p_contact_date);
  return v_lead_id;
end;
$$;

grant execute on function app_private.rpc_set_lead_contact_date(text, uuid, date) to anon, authenticated;
grant execute on function app_private.rpc_list_leads_contact_date(text) to anon, authenticated;
grant execute on function public.lc_list_leads(text) to anon, authenticated;
grant execute on function public.lc_upsert_lead(text, uuid, text, text, text, text, text, text, text, date, time, text, text, numeric, text, text, jsonb, uuid, date) to anon, authenticated;

notify pgrst, 'reload schema';

select
  exists (select 1 from pg_publication where pubname = 'supabase_realtime') as realtime_publication_exists,
  exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'leads') as leads_in_realtime;
