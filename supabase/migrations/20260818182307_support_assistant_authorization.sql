-- Runtime restrito do Assistente de Suporte IA.
-- A sessao da aplicacao e validada no banco e a chave da IA somente pode ser
-- lida pela Edge Function executando como service_role.

begin;

set local lock_timeout = '10s';
set local statement_timeout = '60s';
set local search_path = public, extensions;

create index if not exists ai_usage_support_user_date_idx
  on public.ai_usage (user_id, created_at desc)
  where request_kind = 'support_assistant';

drop function if exists public.lc_support_assistant_runtime(text);
drop function if exists app_private.rpc_support_assistant_runtime(text);
drop function if exists public.lc_support_assistant_runtime(text, uuid);
drop function if exists app_private.rpc_support_assistant_runtime(text, uuid);
drop function if exists public.lc_complete_support_assistant_usage(uuid, uuid, uuid, integer, integer, integer, text);
drop function if exists app_private.rpc_complete_support_assistant_usage(uuid, uuid, uuid, integer, integer, integer, text);

create function app_private.rpc_support_assistant_runtime(
  p_session_token text,
  p_store_id uuid default null
)
returns table (
  admin_user_id uuid,
  user_id uuid,
  user_role text,
  user_store_id uuid,
  provider text,
  model text,
  api_key text,
  capabilities jsonb,
  allowed_actions text[],
  usage_id uuid
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_scope_store_id uuid;
  v_has_client boolean := false;
  v_has_prospections boolean := false;
  v_provider text;
  v_model text;
  v_api_key text;
  v_usage_id uuid;
begin
  select * into v_session
  from app_private.session_user(p_session_token);

  if v_session.user_role::text not in ('admin', 'technician', 'store') then
    raise exception 'Perfil sem acesso ao Assistente de Suporte.'
      using errcode = '42501';
  end if;

  if v_session.user_role::text = 'store' then
    if p_store_id is not null and p_store_id <> v_session.user_store_id then
      raise exception 'Cliente sem permissao para esta loja.'
        using errcode = '42501';
    end if;
    v_scope_store_id := v_session.user_store_id;
  elsif p_store_id is not null then
    if not exists (
      select 1
      from public.stores st
      where st.id = p_store_id
        and st.admin_user_id = v_session.admin_user_id
        and st.is_active = true
        and (
          v_session.user_role::text = 'admin'
          or (
            v_session.user_role::text = 'technician'
            and st.technician_user_id = v_session.user_id
          )
        )
    ) then
      raise exception 'Cliente sem permissao para esta loja.'
        using errcode = '42501';
    end if;
    v_scope_store_id := p_store_id;
  end if;

  select
    exists (
      select 1
      from public.stores st
      where st.admin_user_id = v_session.admin_user_id
        and st.is_active = true
        and (v_scope_store_id is null or st.id = v_scope_store_id)
        and (
          v_session.user_role::text = 'admin'
          or (
            v_session.user_role::text = 'technician'
            and st.technician_user_id = v_session.user_id
          )
          or (
            v_session.user_role::text = 'store'
            and st.id = v_session.user_store_id
          )
        )
    ),
    exists (
      select 1
      from public.stores st
      where st.admin_user_id = v_session.admin_user_id
        and st.is_active = true
        and st.prospection_enabled = true
        and (v_scope_store_id is null or st.id = v_scope_store_id)
        and (
          v_session.user_role::text = 'admin'
          or (
            v_session.user_role::text = 'technician'
            and st.technician_user_id = v_session.user_id
          )
          or (
            v_session.user_role::text = 'store'
            and st.id = v_session.user_store_id
          )
        )
    )
  into v_has_client, v_has_prospections;

  select settings.provider, settings.model, settings.api_key
  into v_provider, v_model, v_api_key
  from public.ai_settings settings
  where settings.admin_user_id = v_session.admin_user_id
    and settings.provider in ('gemini', 'deepseek')
    and length(btrim(settings.api_key)) > 0
  limit 1;

  if not found then
    raise exception 'A IA ainda nao foi configurada pelo administrador.'
      using errcode = 'P0001';
  end if;

  -- A verificacao e a reserva usam o mesmo lock/transacao por usuario. Assim,
  -- requisicoes simultaneas nao conseguem ultrapassar a janela de 40 chamadas.
  perform pg_advisory_xact_lock(
    hashtextextended('support_assistant:' || v_session.user_id::text, 0)
  );

  if (
    select count(*)
    from public.ai_usage usage
    where usage.user_id = v_session.user_id
      and usage.request_kind = 'support_assistant'
      and usage.created_at > now() - interval '1 hour'
  ) >= 40 then
    raise exception 'Limite temporario do Assistente de Suporte atingido.'
      using errcode = 'P0001';
  end if;

  insert into public.ai_usage (
    admin_user_id,
    user_id,
    store_id,
    provider,
    model,
    request_kind,
    status
  ) values (
    v_session.admin_user_id,
    v_session.user_id,
    v_scope_store_id,
    v_provider,
    v_model,
    'support_assistant',
    'started'
  )
  returning id into v_usage_id;

  return query
  select
    v_session.admin_user_id::uuid,
    v_session.user_id::uuid,
    v_session.user_role::text,
    v_session.user_store_id::uuid,
    v_provider,
    v_model,
    v_api_key,
    jsonb_build_object(
      'leads', v_has_client,
      'prospections', v_has_prospections,
      'attendances', v_has_prospections,
      'client_configuration', v_has_client,
      'categories', v_has_client,
      'options', v_has_client,
      'sequence', v_has_client
    ),
    array_remove(array[
      case when v_has_client then 'open_leads' end,
      case when v_has_prospections then 'open_prospections' end,
      case when v_has_prospections then 'open_attendances' end,
      case when v_has_client then 'open_lead_configuration' end
    ]::text[], null),
    v_usage_id;
end;
$$;

create function public.lc_support_assistant_runtime(
  p_session_token text,
  p_store_id uuid default null
)
returns table (
  admin_user_id uuid,
  user_id uuid,
  user_role text,
  user_store_id uuid,
  provider text,
  model text,
  api_key text,
  capabilities jsonb,
  allowed_actions text[],
  usage_id uuid
)
language sql
security invoker
set search_path = app_private, public, extensions
as $$
  select *
  from app_private.rpc_support_assistant_runtime(p_session_token, p_store_id);
$$;

create function app_private.rpc_complete_support_assistant_usage(
  p_usage_id uuid,
  p_admin_user_id uuid,
  p_user_id uuid,
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
  update public.ai_usage usage
  set
    input_tokens = greatest(coalesce(p_input_tokens, 0), 0),
    output_tokens = case
      when p_output_tokens is null then null
      else greatest(p_output_tokens, 0)
    end,
    latency_ms = greatest(coalesce(p_latency_ms, 0), 0),
    status = case
      when p_status in ('success', 'blocked', 'invalid', 'error') then p_status
      else 'error'
    end
  where usage.id = p_usage_id
    and usage.admin_user_id = p_admin_user_id
    and usage.user_id = p_user_id
    and usage.request_kind = 'support_assistant'
    and usage.status = 'started';

  return found;
end;
$$;

create function public.lc_complete_support_assistant_usage(
  p_usage_id uuid,
  p_admin_user_id uuid,
  p_user_id uuid,
  p_input_tokens integer,
  p_output_tokens integer,
  p_latency_ms integer,
  p_status text
)
returns boolean
language sql
security invoker
set search_path = app_private, public, extensions
as $$
  select app_private.rpc_complete_support_assistant_usage(
    p_usage_id,
    p_admin_user_id,
    p_user_id,
    p_input_tokens,
    p_output_tokens,
    p_latency_ms,
    p_status
  );
$$;

-- Funcoes novas recebem EXECUTE de PUBLIC por padrao no Postgres. Revogamos
-- explicitamente antes de liberar somente o processo servidor da Edge Function.
revoke all on function app_private.rpc_support_assistant_runtime(text, uuid)
  from public, anon, authenticated;
revoke all on function public.lc_support_assistant_runtime(text, uuid)
  from public, anon, authenticated;
revoke all on function app_private.rpc_complete_support_assistant_usage(uuid, uuid, uuid, integer, integer, integer, text)
  from public, anon, authenticated;
revoke all on function public.lc_complete_support_assistant_usage(uuid, uuid, uuid, integer, integer, integer, text)
  from public, anon, authenticated;

grant usage on schema app_private to service_role;
grant execute on function app_private.rpc_support_assistant_runtime(text, uuid)
  to service_role;
grant execute on function public.lc_support_assistant_runtime(text, uuid)
  to service_role;
grant execute on function app_private.rpc_complete_support_assistant_usage(uuid, uuid, uuid, integer, integer, integer, text)
  to service_role;
grant execute on function public.lc_complete_support_assistant_usage(uuid, uuid, uuid, integer, integer, integer, text)
  to service_role;

notify pgrst, 'reload schema';

commit;
