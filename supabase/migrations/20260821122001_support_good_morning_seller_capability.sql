-- Expõe ao Assistente de Suporte somente a disponibilidade do Bom Dia Vendedor
-- para que o manual respeite a licença da loja atual. A chave do provedor
-- continua restrita ao service_role e nunca é enviada ao navegador.

begin;

set local lock_timeout = '10s';
set local statement_timeout = '60s';
set local search_path = public, extensions;

create or replace function app_private.rpc_support_assistant_runtime(
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
  v_has_good_morning_seller boolean := false;
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
    ),
    exists (
      select 1
      from public.stores st
      where st.admin_user_id = v_session.admin_user_id
        and st.is_active = true
        and st.prospection_enabled = true
        and st.good_morning_seller_enabled = true
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
  into v_has_client, v_has_prospections, v_has_good_morning_seller;

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
      'good_morning_seller', v_has_good_morning_seller,
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

revoke all on function app_private.rpc_support_assistant_runtime(text, uuid)
  from public, anon, authenticated;
grant execute on function app_private.rpc_support_assistant_runtime(text, uuid)
  to service_role;

notify pgrst, 'reload schema';

commit;
