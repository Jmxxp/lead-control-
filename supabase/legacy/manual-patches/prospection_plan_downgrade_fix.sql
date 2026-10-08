-- Correção pontual: permite reduzir a franquia de Prospecções sem desligar
-- clientes de forma automática. Enquanto houver mais acessos ativos que
-- licenças contratadas, novas liberações continuam bloqueadas pelo trigger
-- app_private.enforce_prospection_store_quota(); a agência escolhe quais
-- clientes desativar.

begin;

create or replace function app_private.rpc_set_technician_prospection_limit(
  p_session_token text,
  p_technician_id uuid,
  p_limit integer
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_store_limit integer;
begin
  select * into v_session
  from app_private.session_user(p_session_token);

  if v_session.user_role::text <> 'admin' then
    raise exception 'Apenas o Admin pode alterar o limite de Prospeccoes.';
  end if;

  if coalesce(p_limit, -1) not between 0 and 9999 then
    raise exception 'Informe um limite de Prospeccoes entre 0 e 9999.';
  end if;

  select u.store_limit
  into v_store_limit
  from public.app_users u
  where u.id = p_technician_id
    and u.admin_user_id = v_session.admin_user_id
    and u.role::text = 'technician'
    and u.is_active = true
  for update;

  if not found then
    raise exception 'Agencia nao encontrada.';
  end if;

  if p_limit > v_store_limit then
    raise exception 'O limite de Prospeccoes nao pode superar o limite total de % clientes.', v_store_limit;
  end if;

  update public.app_users
  set prospection_store_limit = p_limit
  where id = p_technician_id;

  return true;
end;
$$;

revoke all on function app_private.rpc_set_technician_prospection_limit(text, uuid, integer)
from public, anon, authenticated;

grant execute on function app_private.rpc_set_technician_prospection_limit(text, uuid, integer)
to anon, authenticated;

notify pgrst, 'reload schema';

commit;
