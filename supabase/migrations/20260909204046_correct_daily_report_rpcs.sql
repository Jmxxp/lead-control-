-- Corrige a resolucao de nomes nos RPCs que retornam TABLE e alinha a
-- volatilidade com a validacao de sessao/termos executada em cada leitura.

begin;

set local lock_timeout = '10s';
set local statement_timeout = '2min';

create or replace function public.lc_get_push_public_key_v1(
  p_session_token text
)
returns table(public_key text)
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  perform 1
  from app_private.session_user(p_session_token);

  return query
  select secret.decrypted_secret
  from vault.decrypted_secrets secret
  where secret.name = 'daily_report_vapid_public_key'
    and nullif(secret.decrypted_secret, '') is not null
  limit 1;
end;
$$;

alter function public.lc_get_daily_report_settings_v1(text, uuid) volatile;

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
  on conflict on constraint daily_report_settings_pkey do update
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

revoke all on function public.lc_get_push_public_key_v1(text)
  from public, anon, authenticated, service_role;
grant execute on function public.lc_get_push_public_key_v1(text)
  to anon, authenticated, service_role;

revoke all on function public.lc_save_daily_report_setting_v1(
  text, uuid, uuid, boolean, time, text
) from public, anon, authenticated, service_role;
grant execute on function public.lc_save_daily_report_setting_v1(
  text, uuid, uuid, boolean, time, text
) to anon, authenticated, service_role;

notify pgrst, 'reload schema';

commit;
