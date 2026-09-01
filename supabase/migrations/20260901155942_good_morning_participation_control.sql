-- Um unico controle de participacao no Bom Dia Vendedor.
-- Admin e a propria loja podem incluir ou pausar um profissional sem alterar
-- seu cadastro geral, sua equipe ou seu historico.

begin;

set local lock_timeout = '10s';
set local statement_timeout = '5min';

create or replace function app_private.rpc_set_good_morning_seller_participation(
  p_session_token text,
  p_store_id uuid,
  p_professional_id uuid,
  p_enabled boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_session record;
  v_previous_enabled boolean;
begin
  if p_store_id is null or p_professional_id is null or p_enabled is null then
    raise exception 'Informe cliente, profissional e participação.';
  end if;

  select *
  into v_session
  from app_private.session_user(p_session_token);

  if v_session.user_role::text not in ('admin', 'store')
     or (
       v_session.user_role::text = 'store'
       and v_session.user_store_id is distinct from p_store_id
     ) then
    raise exception 'Somente o Admin ou a própria loja podem alterar a participação no Bom Dia Vendedor.';
  end if;

  if not app_private.good_morning_seller_store_allowed(
    v_session.admin_user_id,
    v_session.user_id,
    v_session.user_role,
    v_session.user_store_id,
    p_store_id
  ) then
    raise exception 'Bom Dia Vendedor não está licenciado para este cliente.';
  end if;

  -- Mantem a ordem de locks usada pela configuracao completa:
  -- cliente, equipe e por ultimo configuracao/fila.
  perform 1
  from public.stores store_record
  where store_record.id = p_store_id
    and store_record.admin_user_id = v_session.admin_user_id
    and store_record.is_active = true
    and store_record.attendance_enabled = true
    and store_record.good_morning_seller_enabled = true
  for no key update;

  if not found then
    raise exception 'Bom Dia Vendedor não está licenciado para este cliente.';
  end if;

  perform 1
  from public.prospection_professionals professional
  where professional.store_id = p_store_id
    and professional.admin_user_id = v_session.admin_user_id
    and professional.is_active = true
    and professional.archived_at is null
  order by professional.id
  for update;

  select professional.good_morning_seller_enabled
  into v_previous_enabled
  from public.prospection_professionals professional
  where professional.id = p_professional_id
    and professional.store_id = p_store_id
    and professional.admin_user_id = v_session.admin_user_id
    and professional.is_active = true
    and professional.archived_at is null;

  if not found then
    raise exception 'Profissional ativo não encontrado neste cliente.';
  end if;

  perform 1
  from public.good_morning_seller_settings settings
  where settings.store_id = p_store_id
    and settings.admin_user_id = v_session.admin_user_id
  for update;

  if v_previous_enabled is distinct from p_enabled then
    update public.prospection_professionals professional
    set good_morning_seller_enabled = p_enabled,
        updated_at = pg_catalog.now()
    where professional.id = p_professional_id
      and professional.store_id = p_store_id
      and professional.admin_user_id = v_session.admin_user_id
      and professional.is_active = true
      and professional.archived_at is null;

    -- A participacao e persistida imediatamente. A meta e a ordem continuam
    -- sob responsabilidade da loja; ao mudar a equipe, a configuracao fica
    -- pendente de revisao sem apagar nenhum atendimento ou historico.
    delete from public.good_morning_seller_allocations allocation
    where allocation.store_id = p_store_id
      and allocation.admin_user_id = v_session.admin_user_id
      and allocation.professional_id = p_professional_id;

    update public.good_morning_seller_settings settings
    set current_professional_id = case
          when settings.current_professional_id = p_professional_id then null
          else settings.current_professional_id
        end,
        updated_by = v_session.user_id
    where settings.store_id = p_store_id
      and settings.admin_user_id = v_session.admin_user_id;
  end if;

  return app_private.rpc_get_good_morning_seller_workspace(
    p_session_token,
    p_store_id
  ) || pg_catalog.jsonb_build_object('participation_update_available', true);
end;
$$;

-- As RPCs historicas de meta/fila aceitavam o helper de leitura, que tambem
-- autoriza Agencia. Estes wrappers privados fecham a escrita para a propria
-- loja sem duplicar a logica transacional consolidada das RPCs originais.
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
declare
  v_session record;
begin
  select *
  into v_session
  from app_private.session_user(p_session_token);

  if v_session.user_role::text <> 'store'
     or v_session.user_store_id is distinct from p_store_id then
    raise exception 'Somente a própria loja pode configurar meta e fila do Bom Dia Vendedor.';
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
declare
  v_session record;
begin
  select *
  into v_session
  from app_private.session_user(p_session_token);

  if v_session.user_role::text <> 'store'
     or v_session.user_store_id is distinct from p_store_id then
    raise exception 'Somente a própria loja pode avançar a fila do Bom Dia Vendedor.';
  end if;

  return app_private.rpc_advance_good_morning_seller_turn(
    p_session_token,
    p_store_id
  );
end;
$$;

-- O capability abaixo só passa a existir junto com a RPC dedicada. Isso evita
-- que um frontend novo tente chamar a funcao antes de o schema estar pronto.
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
  ) || pg_catalog.jsonb_build_object('participation_update_available', true);
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
  ) || pg_catalog.jsonb_build_object('participation_update_available', true);
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
  ) || pg_catalog.jsonb_build_object('participation_update_available', true);
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
  );
$$;

revoke all on function app_private.rpc_set_good_morning_seller_participation(text, uuid, uuid, boolean)
  from public, anon, authenticated;
grant execute on function app_private.rpc_set_good_morning_seller_participation(text, uuid, uuid, boolean)
  to anon, authenticated;

-- Remove o acesso direto aos escritores antigos; os chamadores passam pelos
-- wrappers store_only, que validam o papel antes de delegar a transacao.
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

revoke all on function public.lc_set_good_morning_seller_participation(text, uuid, uuid, boolean)
  from public;
grant execute on function public.lc_set_good_morning_seller_participation(text, uuid, uuid, boolean)
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

comment on function public.lc_set_good_morning_seller_participation(text, uuid, uuid, boolean) is
  'Inclui ou pausa um profissional no Bom Dia Vendedor; permitido ao Admin ou a propria loja, sem alterar equipe e historico.';
comment on function public.lc_get_good_morning_seller_workspace(text, uuid) is
  'Retorna metas, fila, participantes e o capability da RPC dedicada de participacao.';

notify pgrst, 'reload schema';

commit;
