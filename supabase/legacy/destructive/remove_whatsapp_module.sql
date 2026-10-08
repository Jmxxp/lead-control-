-- Lead Control | retirada definitiva do modulo WhatsApp
--
-- Esta migracao e destrutiva por decisao de produto: remove configuracoes,
-- credenciais, filas, historico e dados operacionais exclusivos do modulo.
-- Leads, telefones, Prospecções e Atendimentos nao sao alterados.

begin;

-- Interrompe o worker antes de retirar filas e credenciais.
do $$
begin
  if to_regclass('cron.job') is not null then
    execute $sql$
      select cron.unschedule(jobid)
      from cron.job
      where jobname = 'whatsapp-worker-10-seconds'
    $sql$;
  end if;
end;
$$;

-- Remove os segredos do scheduler armazenados no Vault, quando o projeto usa
-- o Vault do Supabase. Segredos das Edge Functions devem ser removidos no
-- ambiente de deploy junto com as funcoes.
do $$
begin
  if to_regclass('vault.secrets') is not null then
    execute $sql$
      delete from vault.secrets
      where name in ('whatsapp_project_url', 'whatsapp_worker_secret')
    $sql$;
  end if;
end;
$$;

-- Descobre e remove todas as RPCs e helpers do modulo sem depender das
-- assinaturas instaladas. As operacoes de plano genericas sao recriadas abaixo
-- apenas com Prospecções + Atendimentos.
do $$
declare
  v_function record;
begin
  for v_function in
    select
      ns.nspname as schema_name,
      proc.proname as function_name,
      pg_get_function_identity_arguments(proc.oid) as identity_arguments
    from pg_proc proc
    join pg_namespace ns on ns.oid = proc.pronamespace
    where ns.nspname in ('public', 'app_private')
      and (
        proc.proname like 'wa\_%' escape '\'
        or proc.proname ilike '%whatsapp%'
        or proc.proname in (
          'rpc_update_store_with_feature_access',
          'rpc_create_technician_with_feature_plan',
          'rpc_update_technician_with_feature_plan',
          'lc_update_store_with_feature_access',
          'lc_create_technician_with_feature_plan',
          'lc_update_technician_with_feature_plan'
        )
      )
  loop
    execute format(
      'drop function if exists %I.%I(%s) cascade',
      v_function.schema_name,
      v_function.function_name,
      v_function.identity_arguments
    );
  end loop;
end;
$$;

-- Apaga todas as tabelas publicas e privadas que pertencem exclusivamente ao
-- modulo. CASCADE cobre indices, politicas, gatilhos e tipos de linha.
do $$
declare
  v_table record;
begin
  for v_table in
    select schemaname, tablename
    from pg_tables
    where schemaname in ('public', 'app_private')
      and tablename like 'whatsapp\_%' escape '\'
  loop
    execute format(
      'drop table if exists %I.%I cascade',
      v_table.schemaname,
      v_table.tablename
    );
  end loop;
end;
$$;

drop index if exists public.stores_technician_whatsapp_enabled_idx;

alter table if exists public.stores
  drop column if exists whatsapp_enabled cascade;

alter table if exists public.app_users
  drop column if exists whatsapp_phone cascade,
  drop column if exists whatsapp_store_limit cascade;

-- O canal deixa de ser sugerido em cadastros novos sem apagar o valor dos
-- leads historicos que ja foram registrados com essa origem.
update public.lead_options
set is_active = false
where group_key::text = 'channel'
  and lower(btrim(value)) = 'whatsapp';

-- Salva a conta do cliente e sua unica licença adicional como uma operacao
-- atomica. Desativa antes de transferir para liberar a cota na agencia atual.
create or replace function app_private.rpc_update_store_with_feature_access(
  p_session_token text,
  p_store_id uuid,
  p_name text,
  p_nick text,
  p_password text default null,
  p_technician_id uuid default null,
  p_prospection_enabled boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_store record;
  v_result jsonb;
begin
  select *
  into v_session
  from app_private.session_user(p_session_token);

  if v_session.user_role::text not in ('admin', 'technician') then
    raise exception 'Sem permissao para editar este cliente.';
  end if;

  select st.prospection_enabled
  into v_store
  from public.stores st
  where st.id = p_store_id
    and st.admin_user_id = v_session.admin_user_id
    and st.is_active = true
    and (
      v_session.user_role::text = 'admin'
      or st.technician_user_id = v_session.user_id
    )
  for update;

  if not found then
    raise exception 'Cliente nao encontrado ou sem permissao.';
  end if;

  if v_store.prospection_enabled is true
     and coalesce(p_prospection_enabled, false) is false then
    perform app_private.rpc_set_store_prospection_access(
      p_session_token,
      p_store_id,
      false
    );
  end if;

  select to_jsonb(updated)
  into strict v_result
  from app_private.rpc_update_store_account(
    p_session_token,
    p_store_id,
    p_name,
    p_nick,
    p_password,
    p_technician_id
  ) updated;

  if v_store.prospection_enabled is false
     and coalesce(p_prospection_enabled, false) is true then
    perform app_private.rpc_set_store_prospection_access(
      p_session_token,
      p_store_id,
      true
    );
  end if;

  return v_result || jsonb_build_object(
    'prospection_enabled', coalesce(p_prospection_enabled, false)
  );
end;
$$;

create or replace function app_private.rpc_create_technician_with_feature_plan(
  p_session_token text,
  p_full_name text,
  p_nick text,
  p_password text,
  p_store_limit integer,
  p_prospection_limit integer
)
returns jsonb
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_result jsonb;
  v_technician_id uuid;
begin
  if coalesce(p_store_limit, -1) not between 0 and 9999 then
    raise exception 'Informe um limite de clientes entre 0 e 9999.';
  end if;

  if coalesce(p_prospection_limit, -1) not between 0 and p_store_limit then
    raise exception
      'A franquia de Prospeccoes deve ficar entre 0 e o limite total de clientes.';
  end if;

  select to_jsonb(created)
  into strict v_result
  from app_private.rpc_create_technician(
    p_session_token,
    p_full_name,
    p_nick,
    p_password,
    p_store_limit
  ) created;

  v_technician_id := nullif(v_result->>'id', '')::uuid;
  if v_technician_id is null then
    raise exception 'Nao foi possivel identificar a Agencia criada.';
  end if;

  perform app_private.rpc_set_technician_prospection_limit(
    p_session_token,
    v_technician_id,
    p_prospection_limit
  );

  return v_result || jsonb_build_object(
    'store_limit', p_store_limit,
    'prospection_store_limit', p_prospection_limit
  );
end;
$$;

create or replace function app_private.rpc_update_technician_with_feature_plan(
  p_session_token text,
  p_technician_id uuid,
  p_full_name text,
  p_nick text,
  p_password text default null,
  p_store_limit integer default 5,
  p_prospection_limit integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_current_store_limit integer;
  v_result jsonb;
begin
  select *
  into v_session
  from app_private.session_user(p_session_token);

  if v_session.user_role::text <> 'admin' then
    raise exception 'Apenas o Admin pode alterar o plano da Agencia.';
  end if;

  if coalesce(p_store_limit, -1) not between 0 and 9999 then
    raise exception 'Informe um limite de clientes entre 0 e 9999.';
  end if;

  if coalesce(p_prospection_limit, -1) not between 0 and p_store_limit then
    raise exception
      'A franquia de Prospeccoes deve ficar entre 0 e o limite total de clientes.';
  end if;

  select agency.store_limit
  into v_current_store_limit
  from public.app_users agency
  where agency.id = p_technician_id
    and agency.admin_user_id = v_session.admin_user_id
    and agency.role::text = 'technician'
    and agency.is_active = true
  for update;

  if not found then
    raise exception 'Agencia nao encontrada.';
  end if;

  if p_store_limit < v_current_store_limit then
    perform app_private.rpc_set_technician_prospection_limit(
      p_session_token,
      p_technician_id,
      p_prospection_limit
    );
  end if;

  select to_jsonb(updated)
  into strict v_result
  from app_private.rpc_update_technician_account(
    p_session_token,
    p_technician_id,
    p_full_name,
    p_nick,
    p_password,
    p_store_limit
  ) updated;

  if p_store_limit >= v_current_store_limit then
    perform app_private.rpc_set_technician_prospection_limit(
      p_session_token,
      p_technician_id,
      p_prospection_limit
    );
  end if;

  return v_result || jsonb_build_object(
    'store_limit', p_store_limit,
    'prospection_store_limit', p_prospection_limit
  );
end;
$$;

create or replace function public.lc_update_store_with_feature_access(
  p_session_token text,
  p_store_id uuid,
  p_name text,
  p_nick text,
  p_password text default null,
  p_technician_id uuid default null,
  p_prospection_enabled boolean default false
)
returns jsonb
language sql
security invoker
set search_path = app_private, public, extensions
as $$
  select app_private.rpc_update_store_with_feature_access(
    p_session_token,
    p_store_id,
    p_name,
    p_nick,
    p_password,
    p_technician_id,
    p_prospection_enabled
  );
$$;

create or replace function public.lc_create_technician_with_feature_plan(
  p_session_token text,
  p_full_name text,
  p_nick text,
  p_password text,
  p_store_limit integer,
  p_prospection_limit integer
)
returns jsonb
language sql
security invoker
set search_path = app_private, public, extensions
as $$
  select app_private.rpc_create_technician_with_feature_plan(
    p_session_token,
    p_full_name,
    p_nick,
    p_password,
    p_store_limit,
    p_prospection_limit
  );
$$;

create or replace function public.lc_update_technician_with_feature_plan(
  p_session_token text,
  p_technician_id uuid,
  p_full_name text,
  p_nick text,
  p_password text default null,
  p_store_limit integer default 5,
  p_prospection_limit integer default 0
)
returns jsonb
language sql
security invoker
set search_path = app_private, public, extensions
as $$
  select app_private.rpc_update_technician_with_feature_plan(
    p_session_token,
    p_technician_id,
    p_full_name,
    p_nick,
    p_password,
    p_store_limit,
    p_prospection_limit
  );
$$;

revoke all on function app_private.rpc_update_store_with_feature_access(
  text, uuid, text, text, text, uuid, boolean
) from public, anon, authenticated;
revoke all on function app_private.rpc_create_technician_with_feature_plan(
  text, text, text, text, integer, integer
) from public, anon, authenticated;
revoke all on function app_private.rpc_update_technician_with_feature_plan(
  text, uuid, text, text, text, integer, integer
) from public, anon, authenticated;

grant execute on function app_private.rpc_update_store_with_feature_access(
  text, uuid, text, text, text, uuid, boolean
) to anon, authenticated;
grant execute on function app_private.rpc_create_technician_with_feature_plan(
  text, text, text, text, integer, integer
) to anon, authenticated;
grant execute on function app_private.rpc_update_technician_with_feature_plan(
  text, uuid, text, text, text, integer, integer
) to anon, authenticated;

revoke all on function public.lc_update_store_with_feature_access(
  text, uuid, text, text, text, uuid, boolean
) from public;
revoke all on function public.lc_create_technician_with_feature_plan(
  text, text, text, text, integer, integer
) from public;
revoke all on function public.lc_update_technician_with_feature_plan(
  text, uuid, text, text, text, integer, integer
) from public;

grant execute on function public.lc_update_store_with_feature_access(
  text, uuid, text, text, text, uuid, boolean
) to anon, authenticated;
grant execute on function public.lc_create_technician_with_feature_plan(
  text, text, text, text, integer, integer
) to anon, authenticated;
grant execute on function public.lc_update_technician_with_feature_plan(
  text, uuid, text, text, text, integer, integer
) to anon, authenticated;

comment on function public.lc_update_store_with_feature_access(
  text, uuid, text, text, text, uuid, boolean
) is 'Atualiza cliente e acesso a Prospecções + Atendimentos atomicamente.';
comment on function public.lc_create_technician_with_feature_plan(
  text, text, text, text, integer, integer
) is 'Cria Agencia com limite de clientes e franquia de Prospecções + Atendimentos.';
comment on function public.lc_update_technician_with_feature_plan(
  text, uuid, text, text, text, integer, integer
) is 'Atualiza Agencia, limite de clientes e franquia de Prospecções + Atendimentos.';

commit;
