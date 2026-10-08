begin;

set local lock_timeout = '10s';
set local statement_timeout = '60s';

-- A listagem valida a sessão por app_private.session_user(), que atualiza
-- app_sessions.last_seen_at. Portanto, tanto a implementação quanto o wrapper
-- público precisam aceitar escrita; STABLE força uma transação read-only no
-- PostgREST e faz a RPC responder HTTP 405.
alter function app_private.rpc_list_attendances_v4(
  text, uuid, text, text, uuid, text, text, date, date, integer, integer
) volatile;

alter function public.lc_list_attendances_v4(
  text, uuid, text, text, uuid, text, text, date, date, integer, integer
) volatile;

do $$
declare
  v_private_volatility "char";
  v_public_volatility "char";
begin
  select p.provolatile
  into v_private_volatility
  from pg_catalog.pg_proc p
  where p.oid = pg_catalog.to_regprocedure(
    'app_private.rpc_list_attendances_v4(text,uuid,text,text,uuid,text,text,date,date,integer,integer)'
  );

  select p.provolatile
  into v_public_volatility
  from pg_catalog.pg_proc p
  where p.oid = pg_catalog.to_regprocedure(
    'public.lc_list_attendances_v4(text,uuid,text,text,uuid,text,text,date,date,integer,integer)'
  );

  if v_private_volatility is distinct from 'v'
     or v_public_volatility is distinct from 'v' then
    raise exception 'As funções de listagem V4 precisam permanecer VOLATILE.';
  end if;
end $$;

notify pgrst, 'reload schema';

commit;
