-- Atendimentos | data operacional obrigatoria no contrato V3.
--
-- O RPC legado interno aceitava p_attended_on nulo e o convertia em hoje.
-- Mantemos a implementacao original isolada e colocamos um guard seguro entre
-- ela e a API publica para impedir que uma data omitida altere o mes da venda.

begin;

set local lock_timeout = '10s';
set local statement_timeout = '2min';

create or replace function app_private.rpc_upsert_attendance_v3_required_date(
  p_session_token text,
  p_store_id uuid,
  p_professional_name text,
  p_customer_name text,
  p_phone text,
  p_cpf text,
  p_description text,
  p_tag text,
  p_service_value numeric,
  p_purchase_value numeric,
  p_service_order text,
  p_attended_on date,
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if p_attended_on is null then
    raise exception using
      errcode = '22004',
      message = 'Informe a data em que o atendimento aconteceu.';
  end if;

  return app_private.rpc_upsert_attendance_v3(
    p_session_token,
    p_store_id,
    p_professional_name,
    p_customer_name,
    p_phone,
    p_cpf,
    p_description,
    p_tag,
    p_service_value,
    p_purchase_value,
    p_service_order,
    p_attended_on,
    p_idempotency_key
  );
end;
$$;

-- A data nao possui mais DEFAULT. Assim, omissao e NULL falham em vez de
-- serem gravados silenciosamente como um atendimento de hoje.
-- PostgreSQL nao permite remover defaults com CREATE OR REPLACE; a troca
-- explicita abaixo preserva a mesma identidade SQL dentro desta transacao.
drop function public.lc_upsert_attendance_v3(
  text, uuid, text, text, text, text, text, text,
  numeric, numeric, text, date, text
);

create function public.lc_upsert_attendance_v3(
  p_session_token text,
  p_store_id uuid,
  p_professional_name text,
  p_customer_name text,
  p_phone text,
  p_cpf text,
  p_description text,
  p_tag text,
  p_service_value numeric,
  p_purchase_value numeric,
  p_service_order text,
  p_attended_on date,
  p_idempotency_key text default null
)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select app_private.rpc_upsert_attendance_v3_required_date(
    p_session_token,
    p_store_id,
    p_professional_name,
    p_customer_name,
    p_phone,
    p_cpf,
    p_description,
    p_tag,
    p_service_value,
    p_purchase_value,
    p_service_order,
    p_attended_on,
    p_idempotency_key
  );
$$;

-- A implementacao que ainda possui fallback para hoje deixa de ser chamavel.
revoke all on function app_private.rpc_upsert_attendance_v3(
  text, uuid, text, text, text, text, text, text,
  numeric, numeric, text, date, text
) from public, anon, authenticated, service_role;

revoke all on function app_private.rpc_upsert_attendance_v3_required_date(
  text, uuid, text, text, text, text, text, text,
  numeric, numeric, text, date, text
) from public, anon, authenticated, service_role;
grant execute on function app_private.rpc_upsert_attendance_v3_required_date(
  text, uuid, text, text, text, text, text, text,
  numeric, numeric, text, date, text
) to anon, authenticated, service_role;

revoke all on function public.lc_upsert_attendance_v3(
  text, uuid, text, text, text, text, text, text,
  numeric, numeric, text, date, text
) from public, anon, authenticated, service_role;
grant execute on function public.lc_upsert_attendance_v3(
  text, uuid, text, text, text, text, text, text,
  numeric, numeric, text, date, text
) to anon, authenticated, service_role;

comment on function app_private.rpc_upsert_attendance_v3_required_date(
  text, uuid, text, text, text, text, text, text,
  numeric, numeric, text, date, text
) is
  'Guard privado que exige a data operacional antes de delegar a gravacao auditavel do atendimento.';

comment on function public.lc_upsert_attendance_v3(
  text, uuid, text, text, text, text, text, text,
  numeric, numeric, text, date, text
) is
  'Registra atendimento somente com data operacional explicita; nunca converte data ausente em hoje.';

do $qa$
declare
  v_guard_is_definer boolean;
  v_guard_config text[];
  v_guard_default_count integer;
  v_public_default_count integer;
  v_guard_rejected_null boolean := false;
  v_public_rejected_null boolean := false;
begin
  if pg_catalog.to_regprocedure(
       'app_private.rpc_upsert_attendance_v3_required_date(text,uuid,text,text,text,text,text,text,numeric,numeric,text,date,text)'
     ) is null
     or pg_catalog.to_regprocedure(
       'public.lc_upsert_attendance_v3(text,uuid,text,text,text,text,text,text,numeric,numeric,text,date,text)'
     ) is null then
    raise exception 'QA atendimento: contrato V3 com data obrigatoria ausente.';
  end if;

  select function_record.prosecdef,
         function_record.proconfig,
         function_record.pronargdefaults
  into v_guard_is_definer, v_guard_config, v_guard_default_count
  from pg_catalog.pg_proc function_record
  where function_record.oid = pg_catalog.to_regprocedure(
    'app_private.rpc_upsert_attendance_v3_required_date(text,uuid,text,text,text,text,text,text,numeric,numeric,text,date,text)'
  );

  select function_record.pronargdefaults
  into v_public_default_count
  from pg_catalog.pg_proc function_record
  where function_record.oid = pg_catalog.to_regprocedure(
    'public.lc_upsert_attendance_v3(text,uuid,text,text,text,text,text,text,numeric,numeric,text,date,text)'
  );

  if not coalesce(v_guard_is_definer, false)
     or not coalesce('search_path=""' = any(v_guard_config), false) then
    raise exception 'QA atendimento: guard precisa de SECURITY DEFINER e search_path vazio.';
  end if;

  -- Apenas a chave de idempotencia final continua opcional.
  if v_guard_default_count <> 1 or v_public_default_count <> 1 then
    raise exception 'QA atendimento: p_attended_on ainda possui valor padrao.';
  end if;

  if pg_catalog.has_function_privilege(
       'anon',
       'app_private.rpc_upsert_attendance_v3(text,uuid,text,text,text,text,text,text,numeric,numeric,text,date,text)',
       'EXECUTE'
     )
     or pg_catalog.has_function_privilege(
       'authenticated',
       'app_private.rpc_upsert_attendance_v3(text,uuid,text,text,text,text,text,text,numeric,numeric,text,date,text)',
       'EXECUTE'
     )
     or pg_catalog.has_function_privilege(
       'service_role',
       'app_private.rpc_upsert_attendance_v3(text,uuid,text,text,text,text,text,text,numeric,numeric,text,date,text)',
       'EXECUTE'
     ) then
    raise exception 'QA atendimento: implementacao com fallback ainda esta exposta.';
  end if;

  if not pg_catalog.has_function_privilege(
       'anon',
       'app_private.rpc_upsert_attendance_v3_required_date(text,uuid,text,text,text,text,text,text,numeric,numeric,text,date,text)',
       'EXECUTE'
     )
     or not pg_catalog.has_function_privilege(
       'authenticated',
       'app_private.rpc_upsert_attendance_v3_required_date(text,uuid,text,text,text,text,text,text,numeric,numeric,text,date,text)',
       'EXECUTE'
     )
     or not pg_catalog.has_function_privilege(
       'service_role',
       'app_private.rpc_upsert_attendance_v3_required_date(text,uuid,text,text,text,text,text,text,numeric,numeric,text,date,text)',
       'EXECUTE'
     )
     or not pg_catalog.has_function_privilege(
       'anon',
       'public.lc_upsert_attendance_v3(text,uuid,text,text,text,text,text,text,numeric,numeric,text,date,text)',
       'EXECUTE'
     )
     or not pg_catalog.has_function_privilege(
       'authenticated',
       'public.lc_upsert_attendance_v3(text,uuid,text,text,text,text,text,text,numeric,numeric,text,date,text)',
       'EXECUTE'
     ) then
    raise exception 'QA atendimento: ACL do guard ou da API publica incompleta.';
  end if;

  begin
    perform app_private.rpc_upsert_attendance_v3_required_date(
      null, null, null, null, null, null, null, null,
      null, null, null, null, null
    );
  exception
    when sqlstate '22004' then
      v_guard_rejected_null := true;
  end;

  begin
    perform public.lc_upsert_attendance_v3(
      null, null, null, null, null, null, null, null,
      null, null, null, null, null
    );
  exception
    when sqlstate '22004' then
      v_public_rejected_null := true;
  end;

  if not v_guard_rejected_null or not v_public_rejected_null then
    raise exception 'QA atendimento: data operacional nula nao foi bloqueada.';
  end if;
end;
$qa$;

notify pgrst, 'reload schema';

commit;
