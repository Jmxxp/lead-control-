-- Admin e a propria loja possuem o mesmo controle operacional do
-- Bom Dia Vendedor. A Agencia permanece com acesso somente de leitura.

begin;

set local lock_timeout = '10s';
set local statement_timeout = '5min';

create or replace function app_private.good_morning_seller_settings_manage_allowed(
  p_session_token text,
  p_store_id uuid
)
returns boolean
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_session record;
begin
  if p_store_id is null then
    return false;
  end if;

  select *
  into v_session
  from app_private.session_user(p_session_token);

  if v_session.user_role::text not in ('admin', 'store') then
    return false;
  end if;

  if v_session.user_role::text = 'store'
     and v_session.user_store_id is distinct from p_store_id then
    return false;
  end if;

  return app_private.good_morning_seller_store_allowed(
    v_session.admin_user_id,
    v_session.user_id,
    v_session.user_role,
    v_session.user_store_id,
    p_store_id
  );
end;
$$;

-- Mantemos os nomes internos por compatibilidade com a migration anterior,
-- mas o gate passa a aceitar Admin e a propria loja.
create or replace function app_private.rpc_save_good_morning_seller_settings_store_only(
  p_session_token text,
  p_store_id uuid,
  p_monthly_goal numeric,
  p_allocation_mode text,
  p_allocations jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not app_private.good_morning_seller_settings_manage_allowed(
    p_session_token,
    p_store_id
  ) then
    raise exception 'Somente o Admin ou a própria loja podem configurar meta e fila do Bom Dia Vendedor.';
  end if;

  return app_private.rpc_save_good_morning_seller_settings(
    p_session_token,
    p_store_id,
    p_monthly_goal,
    p_allocation_mode,
    p_allocations
  );
end;
$$;

create or replace function app_private.rpc_advance_good_morning_seller_turn_store_only(
  p_session_token text,
  p_store_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not app_private.good_morning_seller_settings_manage_allowed(
    p_session_token,
    p_store_id
  ) then
    raise exception 'Somente o Admin ou a própria loja podem avançar a fila do Bom Dia Vendedor.';
  end if;

  return app_private.rpc_advance_good_morning_seller_turn(
    p_session_token,
    p_store_id
  );
end;
$$;

create or replace function public.lc_get_good_morning_seller_workspace(
  p_session_token text,
  p_store_id uuid
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app_private.rpc_get_good_morning_seller_workspace(
    p_session_token,
    p_store_id
  ) || pg_catalog.jsonb_build_object(
    'participation_update_available', true,
    'can_manage_settings', app_private.good_morning_seller_settings_manage_allowed(
      p_session_token,
      p_store_id
    )
  );
$$;

create or replace function public.lc_save_good_morning_seller_settings(
  p_session_token text,
  p_store_id uuid,
  p_monthly_goal numeric,
  p_allocation_mode text,
  p_allocations jsonb
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app_private.rpc_save_good_morning_seller_settings_store_only(
    p_session_token,
    p_store_id,
    p_monthly_goal,
    p_allocation_mode,
    p_allocations
  ) || pg_catalog.jsonb_build_object(
    'participation_update_available', true,
    'can_manage_settings', true
  );
$$;

create or replace function public.lc_advance_good_morning_seller_turn(
  p_session_token text,
  p_store_id uuid
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app_private.rpc_advance_good_morning_seller_turn_store_only(
    p_session_token,
    p_store_id
  ) || pg_catalog.jsonb_build_object(
    'participation_update_available', true,
    'can_manage_settings', true
  );
$$;

create or replace function public.lc_set_good_morning_seller_participation(
  p_session_token text,
  p_store_id uuid,
  p_professional_id uuid,
  p_enabled boolean
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app_private.rpc_set_good_morning_seller_participation(
    p_session_token,
    p_store_id,
    p_professional_id,
    p_enabled
  ) || pg_catalog.jsonb_build_object(
    'participation_update_available', true,
    'can_manage_settings', true
  );
$$;

revoke all on function app_private.good_morning_seller_settings_manage_allowed(text, uuid)
  from public, anon, authenticated;
grant execute on function app_private.good_morning_seller_settings_manage_allowed(text, uuid)
  to anon, authenticated;

-- Os escritores consolidados continuam inacessiveis diretamente. Toda escrita
-- passa pelos gates Admin-ou-loja abaixo, mantendo a Agencia sem bypass.
revoke all on function app_private.rpc_save_good_morning_seller_settings(text, uuid, numeric, text, jsonb)
  from public, anon, authenticated;
revoke all on function app_private.rpc_advance_good_morning_seller_turn(text, uuid)
  from public, anon, authenticated;

revoke all on function app_private.rpc_save_good_morning_seller_settings_store_only(text, uuid, numeric, text, jsonb)
  from public, anon, authenticated;
grant execute on function app_private.rpc_save_good_morning_seller_settings_store_only(text, uuid, numeric, text, jsonb)
  to anon, authenticated;

revoke all on function app_private.rpc_advance_good_morning_seller_turn_store_only(text, uuid)
  from public, anon, authenticated;
grant execute on function app_private.rpc_advance_good_morning_seller_turn_store_only(text, uuid)
  to anon, authenticated;

revoke all on function public.lc_get_good_morning_seller_workspace(text, uuid)
  from public;
grant execute on function public.lc_get_good_morning_seller_workspace(text, uuid)
  to anon, authenticated;

revoke all on function public.lc_save_good_morning_seller_settings(text, uuid, numeric, text, jsonb)
  from public;
grant execute on function public.lc_save_good_morning_seller_settings(text, uuid, numeric, text, jsonb)
  to anon, authenticated;

revoke all on function public.lc_advance_good_morning_seller_turn(text, uuid)
  from public;
grant execute on function public.lc_advance_good_morning_seller_turn(text, uuid)
  to anon, authenticated;

revoke all on function public.lc_set_good_morning_seller_participation(text, uuid, uuid, boolean)
  from public;
grant execute on function public.lc_set_good_morning_seller_participation(text, uuid, uuid, boolean)
  to anon, authenticated;

comment on function app_private.good_morning_seller_settings_manage_allowed(text, uuid) is
  'Autoriza configuracao integral do Bom Dia Vendedor para Admin ou para a propria loja; Agencia permanece somente leitura.';
comment on function public.lc_save_good_morning_seller_settings(text, uuid, numeric, text, jsonb) is
  'Salva meta, rateio e ordem do Bom Dia Vendedor; permitido ao Admin ou a propria loja.';
comment on function public.lc_advance_good_morning_seller_turn(text, uuid) is
  'Avanca a fila do Bom Dia Vendedor; permitido ao Admin ou a propria loja.';

notify pgrst, 'reload schema';

commit;
