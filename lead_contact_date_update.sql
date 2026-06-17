-- Rode este arquivo no SQL Editor do Supabase para adicionar
-- a data em que o lead entrou em contato.
-- O campo nao e obrigatorio: quando vier vazio, o banco usa o dia atual.

set search_path = public, extensions;

alter table public.leads
  add column if not exists contact_date date;

update public.leads
set contact_date = coalesce(contact_date, (timezone('America/Sao_Paulo', created_at))::date, (timezone('America/Sao_Paulo', now()))::date)
where contact_date is null;

alter table public.leads
  alter column contact_date set default ((timezone('America/Sao_Paulo', now()))::date);

alter table public.leads
  alter column contact_date set not null;

create index if not exists leads_admin_contact_date_idx
  on public.leads (admin_user_id, contact_date desc, created_at desc);

create index if not exists leads_store_contact_date_idx
  on public.leads (store_id, contact_date desc, created_at desc);

drop function if exists public.lc_list_leads(text);
drop function if exists app_private.rpc_list_leads(text);

create or replace function app_private.rpc_list_leads(p_session_token text)
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
    l.id,
    l.store_id,
    st.name as store_name,
    l.name,
    l.phone,
    l.contact_date,
    l.channel,
    l.campaign,
    l.conversation_start,
    l.conclusion,
    l.scheduled,
    l.scheduled_visit_date,
    l.scheduled_visit_time,
    l.visited,
    l.bought,
    l.purchase_amount,
    l.service_order,
    l.notes,
    l.inspected,
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'category_id', c.id,
          'category_name', c.name,
          'value', v.value
        )
        order by c.sort_order, c.created_at
      )
      from public.lead_custom_values v
      join public.lead_custom_categories c
        on c.id = v.category_id
       and c.admin_user_id = v.admin_user_id
       and c.is_active = true
      where v.lead_id = l.id
        and v.admin_user_id = l.admin_user_id
    ), '[]'::jsonb) as custom_values,
    l.created_at,
    l.updated_at
  from public.leads l
  join public.stores st on st.id = l.store_id
  where l.admin_user_id = v_session.admin_user_id
    and (
      v_session.user_role::text in ('admin', 'technician')
      or l.store_id = v_session.user_store_id
    )
  order by l.created_at desc;
end;
$$;

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
  select * from app_private.rpc_list_leads(p_session_token);
$$;

drop function if exists public.lc_upsert_lead(text, uuid, text, text, text, text, text, text, text, text, uuid);
drop function if exists app_private.rpc_upsert_lead(text, uuid, text, text, text, text, text, text, text, text, uuid);
drop function if exists public.lc_upsert_lead(text, uuid, text, text, text, text, text, text, text, text, numeric, text, uuid);
drop function if exists app_private.rpc_upsert_lead(text, uuid, text, text, text, text, text, text, text, text, numeric, text, uuid);
drop function if exists public.lc_upsert_lead(text, uuid, text, text, text, text, text, text, text, text, numeric, text, text, uuid);
drop function if exists app_private.rpc_upsert_lead(text, uuid, text, text, text, text, text, text, text, text, numeric, text, text, uuid);
drop function if exists public.lc_upsert_lead(text, uuid, text, text, text, text, text, text, text, text, numeric, text, text, jsonb, uuid);
drop function if exists app_private.rpc_upsert_lead(text, uuid, text, text, text, text, text, text, text, text, numeric, text, text, jsonb, uuid);
drop function if exists public.lc_upsert_lead(text, uuid, text, text, text, text, text, text, text, date, time, text, text, numeric, text, text, uuid);
drop function if exists app_private.rpc_upsert_lead(text, uuid, text, text, text, text, text, text, text, date, time, text, text, numeric, text, text, uuid);
drop function if exists public.lc_upsert_lead(text, uuid, text, text, text, text, text, text, text, date, time, text, text, numeric, text, text, jsonb, uuid);
drop function if exists app_private.rpc_upsert_lead(text, uuid, text, text, text, text, text, text, text, date, time, text, text, numeric, text, text, jsonb, uuid);

create or replace function app_private.rpc_upsert_lead(
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
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_store_id uuid;
  v_lead_id uuid;
  v_contact_date date;
  v_scheduled text;
  v_visited text;
  v_bought text;
begin
  select * into v_session from app_private.session_user(p_session_token);

  v_contact_date := coalesce(p_contact_date, (timezone('America/Sao_Paulo', now()))::date);
  v_scheduled := nullif(btrim(coalesce(p_scheduled, '')), '');
  v_visited := nullif(btrim(coalesce(p_visited, '')), '');
  v_bought := nullif(btrim(coalesce(p_bought, '')), '');

  if length(btrim(coalesce(p_name, ''))) = 0 or length(btrim(coalesce(p_phone, ''))) = 0 then
    raise exception 'Preencha nome e telefone.';
  end if;

  if jsonb_typeof(coalesce(p_custom_values, '[]'::jsonb)) <> 'array' then
    raise exception 'Categorias adicionais invalidas.';
  end if;

  if v_scheduled is null then
    raise exception 'Informe se o lead agendou visita ou nao.';
  end if;

  if v_scheduled not in ('Sim', 'Não') then
    raise exception 'Agendamento invalido.';
  end if;

  if v_scheduled = 'Sim' and p_scheduled_visit_date is null then
    raise exception 'Informe a data da visita agendada.';
  end if;

  if v_visited = 'Sim' and v_bought is null then
    raise exception 'Informe se o lead comprou ou nao.';
  end if;

  if v_bought = 'Sim'
     and (p_purchase_amount is null or p_purchase_amount <= 0 or nullif(btrim(coalesce(p_service_order, '')), '') is null) then
    raise exception 'Informe o valor da compra e a OS.';
  end if;

  if v_session.user_role::text = 'store' then
    v_store_id := v_session.user_store_id;
  else
    v_store_id := p_store_id;
  end if;

  if p_lead_id is not null and v_store_id is null then
    select store_id
    into v_store_id
    from public.leads
    where id = p_lead_id
      and admin_user_id = v_session.admin_user_id;
  end if;

  if v_store_id is null then
    raise exception 'Loja obrigatoria para cadastrar lead.';
  end if;

  if not exists (
    select 1
    from public.stores
    where id = v_store_id
      and admin_user_id = v_session.admin_user_id
      and is_active = true
  ) then
    raise exception 'Loja nao encontrada ou sem permissao.';
  end if;

  if p_lead_id is null then
    insert into public.leads (
      admin_user_id,
      store_id,
      name,
      phone,
      contact_date,
      channel,
      campaign,
      conversation_start,
      conclusion,
      scheduled,
      scheduled_visit_date,
      scheduled_visit_time,
      visited,
      bought,
      purchase_amount,
      service_order,
      notes,
      created_by,
      updated_by
    )
    values (
      v_session.admin_user_id,
      v_store_id,
      btrim(p_name),
      btrim(p_phone),
      v_contact_date,
      nullif(btrim(coalesce(p_channel, '')), ''),
      nullif(btrim(coalesce(p_campaign, '')), ''),
      nullif(btrim(coalesce(p_conversation_start, '')), ''),
      nullif(btrim(coalesce(p_conclusion, '')), ''),
      v_scheduled,
      case when v_scheduled = 'Sim' then p_scheduled_visit_date else null end,
      case when v_scheduled = 'Sim' then p_scheduled_visit_time else null end,
      v_visited,
      v_bought,
      case when v_bought = 'Sim' then p_purchase_amount else null end,
      case when v_bought = 'Sim' then nullif(btrim(coalesce(p_service_order, '')), '') else null end,
      nullif(btrim(coalesce(p_notes, '')), ''),
      v_session.user_id,
      v_session.user_id
    )
    returning id into v_lead_id;
  else
    update public.leads
    set
      store_id = v_store_id,
      name = btrim(p_name),
      phone = btrim(p_phone),
      contact_date = v_contact_date,
      channel = nullif(btrim(coalesce(p_channel, '')), ''),
      campaign = nullif(btrim(coalesce(p_campaign, '')), ''),
      conversation_start = nullif(btrim(coalesce(p_conversation_start, '')), ''),
      conclusion = nullif(btrim(coalesce(p_conclusion, '')), ''),
      scheduled = v_scheduled,
      scheduled_visit_date = case when v_scheduled = 'Sim' then p_scheduled_visit_date else null end,
      scheduled_visit_time = case when v_scheduled = 'Sim' then p_scheduled_visit_time else null end,
      visited = v_visited,
      bought = v_bought,
      purchase_amount = case when v_bought = 'Sim' then p_purchase_amount else null end,
      service_order = case when v_bought = 'Sim' then nullif(btrim(coalesce(p_service_order, '')), '') else null end,
      notes = nullif(btrim(coalesce(p_notes, '')), ''),
      updated_by = v_session.user_id
    where id = p_lead_id
      and admin_user_id = v_session.admin_user_id
      and (
        v_session.user_role::text = 'admin'
        or store_id = v_session.user_store_id
      )
    returning id into v_lead_id;

    if not found then
      raise exception 'Lead nao encontrado ou sem permissao.';
    end if;
  end if;

  delete from public.lead_custom_values
  where lead_id = v_lead_id
    and admin_user_id = v_session.admin_user_id;

  insert into public.lead_custom_values (admin_user_id, lead_id, category_id, value)
  select
    v_session.admin_user_id,
    v_lead_id,
    c.id,
    o.value
  from jsonb_array_elements(coalesce(p_custom_values, '[]'::jsonb)) as item(value)
  join public.lead_custom_categories c
    on c.id = nullif(item.value->>'category_id', '')::uuid
   and c.admin_user_id = v_session.admin_user_id
   and c.is_active = true
  join public.lead_custom_options o
    on o.category_id = c.id
   and o.admin_user_id = v_session.admin_user_id
   and o.is_active = true
   and lower(o.value) = lower(nullif(btrim(coalesce(item.value->>'value', '')), ''))
  where nullif(btrim(coalesce(item.value->>'value', '')), '') is not null
  on conflict (lead_id, category_id) do update
  set
    value = excluded.value,
    updated_at = now();

  return v_lead_id;
end;
$$;

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
language sql
security invoker
as $$
  select app_private.rpc_upsert_lead(
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
$$;

grant execute on function app_private.rpc_list_leads(text) to anon, authenticated;
grant execute on function public.lc_list_leads(text) to anon, authenticated;
grant execute on function app_private.rpc_upsert_lead(text, uuid, text, text, text, text, text, text, text, date, time, text, text, numeric, text, text, jsonb, uuid, date) to anon, authenticated;
grant execute on function public.lc_upsert_lead(text, uuid, text, text, text, text, text, text, text, date, time, text, text, numeric, text, text, jsonb, uuid, date) to anon, authenticated;

notify pgrst, 'reload schema';

-- Verificacao do Realtime no projeto. Se leads_in_realtime vier false,
-- a tabela public.leads ainda nao esta publicada para Postgres Changes.
-- Para habilitar depois, rode:
-- alter publication supabase_realtime add table public.leads;
with realtime_tables as (
  select schemaname, tablename
  from pg_publication_tables
  where pubname = 'supabase_realtime'
)
select
  exists (
    select 1
    from pg_publication
    where pubname = 'supabase_realtime'
  ) as realtime_publication_exists,
  exists (
    select 1
    from realtime_tables
    where schemaname = 'public'
      and tablename = 'leads'
  ) as leads_in_realtime,
  coalesce((
    select jsonb_agg(format('%I.%I', schemaname, tablename) order by schemaname, tablename)
    from realtime_tables
  ), '[]'::jsonb) as realtime_tables;
