-- Rode este arquivo no SQL Editor do Supabase para habilitar
-- o checkbox "Inspecionado" na lista de leads das metricas.

set search_path = public, extensions;

alter table public.leads
  add column if not exists inspected boolean not null default false;

create index if not exists leads_admin_inspected_created_idx
  on public.leads (admin_user_id, inspected, created_at desc);

drop function if exists public.lc_list_leads(text);
drop function if exists app_private.rpc_list_leads(text);

create or replace function app_private.rpc_list_leads(p_session_token text)
returns table (
  id uuid,
  store_id uuid,
  store_name text,
  name text,
  phone text,
  channel text,
  campaign text,
  conversation_start text,
  conclusion text,
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
    l.channel,
    l.campaign,
    l.conversation_start,
    l.conclusion,
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
      v_session.user_role = 'admin'
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
  channel text,
  campaign text,
  conversation_start text,
  conclusion text,
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

drop function if exists public.lc_set_lead_inspected(text, uuid, boolean);
drop function if exists app_private.rpc_set_lead_inspected(text, uuid, boolean);

create or replace function app_private.rpc_set_lead_inspected(
  p_session_token text,
  p_lead_id uuid,
  p_inspected boolean
)
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
    inspected = coalesce(p_inspected, false),
    updated_by = v_session.user_id
  where id = p_lead_id
    and admin_user_id = v_session.admin_user_id
    and (
      v_session.user_role = 'admin'
      or store_id = v_session.user_store_id
    );

  if not found then
    raise exception 'Lead nao encontrado ou sem permissao.';
  end if;

  return true;
end;
$$;

create or replace function public.lc_set_lead_inspected(
  p_session_token text,
  p_lead_id uuid,
  p_inspected boolean
)
returns boolean
language sql
security invoker
as $$
  select app_private.rpc_set_lead_inspected(p_session_token, p_lead_id, p_inspected);
$$;

grant execute on function app_private.rpc_list_leads(text) to anon, authenticated;
grant execute on function public.lc_list_leads(text) to anon, authenticated;
grant execute on function app_private.rpc_set_lead_inspected(text, uuid, boolean) to anon, authenticated;
grant execute on function public.lc_set_lead_inspected(text, uuid, boolean) to anon, authenticated;
