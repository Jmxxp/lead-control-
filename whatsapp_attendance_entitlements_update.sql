-- Lead Control | Entitlements de WhatsApp e Atendimentos
--
-- Dependencias:
--   1. prospection_access_control_update.sql
--   2. whatsapp_module.sql
--   3. attendance_module.sql
--   4. agency_whatsapp_upgrade_update.sql
--
-- Regras de produto:
--   * o Admin define quantos clientes de cada Agencia podem usar WhatsApp;
--   * a Agencia escolhe quais dos seus clientes consomem essa franquia;
--   * reduzir a franquia nunca desativa clientes automaticamente;
--   * enquanto o uso estiver acima da franquia, desligar continua permitido e
--     somente novas ativacoes ficam bloqueadas;
--   * Atendimentos nao possui franquia propria: usa exatamente a mesma
--     autorizacao de Prospeccoes;
--   * revogar acesso nao exclui nenhuma conexao, conversa, mensagem, campanha,
--     atendimento, lead ou prospeccao.
--
-- Migracao incremental e idempotente. Execute depois dos tres modulos acima.

begin;

set local search_path = public, extensions;

do $$
begin
  if to_regclass('public.app_users') is null
     or to_regclass('public.stores') is null
     or to_regclass('public.whatsapp_connections') is null
     or to_regclass('public.whatsapp_contacts') is null
     or to_regclass('public.whatsapp_conversations') is null
     or to_regclass('public.whatsapp_messages') is null
     or to_regclass('public.whatsapp_campaigns') is null
     or to_regclass('public.whatsapp_webhook_events') is null
     or to_regclass('public.whatsapp_logs') is null
     or to_regprocedure(
       'app_private.prospection_store_allowed(uuid,uuid,public.app_user_role,uuid,uuid,boolean)'
     ) is null
     or to_regprocedure(
       'app_private.whatsapp_store_allowed(uuid,uuid,public.app_user_role,uuid,uuid,boolean)'
     ) is null
     or to_regprocedure(
       'app_private.attendance_store_allowed(uuid,uuid,public.app_user_role,uuid,uuid)'
     ) is null
     or to_regprocedure(
       'app_private.rpc_create_technician_with_whatsapp(text,text,text,text,integer,text)'
     ) is null
     or to_regprocedure(
       'app_private.rpc_update_technician_with_whatsapp(text,uuid,text,text,text,integer,text)'
     ) is null
     or to_regprocedure(
       'app_private.rpc_update_store_account(text,uuid,text,text,text,uuid)'
     ) is null then
    raise exception using
      message = 'Instale Prospeccoes, WhatsApp e Atendimentos antes desta migracao.';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Franquia de WhatsApp por Agencia
-- ---------------------------------------------------------------------------

alter table public.app_users
  add column if not exists whatsapp_store_limit integer not null default 0;

update public.app_users
set whatsapp_store_limit = 0
where whatsapp_store_limit is null;

alter table public.app_users
  alter column whatsapp_store_limit set default 0;

alter table public.app_users
  alter column whatsapp_store_limit set not null;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'app_users_whatsapp_store_limit_check'
      and conrelid = 'public.app_users'::regclass
  ) then
    alter table public.app_users
      add constraint app_users_whatsapp_store_limit_check
      check (whatsapp_store_limit between 0 and 9999);
  end if;
end;
$$;

-- A coluna nasce sem default para distinguir uma instalacao nova de uma
-- reexecucao. Somente clientes que ja possuem uma conexao e uma Agencia
-- responsavel sao preservados como liberados. Novos clientes nascem bloqueados.
alter table public.stores
  add column if not exists whatsapp_enabled boolean;

update public.stores st
set whatsapp_enabled = (
  exists (
    select 1
    from public.whatsapp_connections connection
    where connection.store_id = st.id
      and connection.admin_user_id = st.admin_user_id
  )
  or exists (
    select 1
    from public.whatsapp_contacts contact
    where contact.store_id = st.id
      and contact.admin_user_id = st.admin_user_id
  )
  or exists (
    select 1
    from public.whatsapp_conversations conversation
    where conversation.store_id = st.id
      and conversation.admin_user_id = st.admin_user_id
  )
  or exists (
    select 1
    from public.whatsapp_messages message
    where message.store_id = st.id
      and message.admin_user_id = st.admin_user_id
  )
  or exists (
    select 1
    from public.whatsapp_campaigns campaign
    where campaign.store_id = st.id
      and campaign.admin_user_id = st.admin_user_id
  )
  or exists (
    select 1
    from public.whatsapp_webhook_events event
    where event.store_id = st.id
      and event.admin_user_id = st.admin_user_id
  )
  or exists (
    select 1
    from public.whatsapp_logs log
    where log.store_id = st.id
      and log.admin_user_id = st.admin_user_id
  )
)
and st.technician_user_id is not null
where st.whatsapp_enabled is null;

alter table public.stores
  alter column whatsapp_enabled set default false;

alter table public.stores
  alter column whatsapp_enabled set not null;

-- Preserva os clientes que ja usavam o modulo sem conceder acesso a lojas sem
-- conexao configurada. Depois da migracao o Admin pode reduzir a franquia sem
-- desligamento automatico, exatamente como ocorre em Prospeccoes.
update public.app_users agency
set whatsapp_store_limit = greatest(
  agency.whatsapp_store_limit,
  (
    select count(*)::integer
    from public.stores st
    where st.admin_user_id = agency.admin_user_id
      and st.technician_user_id = agency.id
      and st.is_active = true
      and st.whatsapp_enabled = true
  )
)
where agency.role::text = 'technician';

-- Uma franquia de produto nunca precisa superar a quantidade total de clientes
-- contratada. O ajuste abaixo apenas corrige bases legadas antes da constraint.
update public.app_users
set store_limit = greatest(store_limit, whatsapp_store_limit)
where role::text = 'technician';

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'app_users_whatsapp_within_store_limit_check'
      and conrelid = 'public.app_users'::regclass
  ) then
    alter table public.app_users
      add constraint app_users_whatsapp_within_store_limit_check
      check (
        role::text <> 'technician'
        or whatsapp_store_limit <= store_limit
      );
  end if;
end;
$$;

create index if not exists stores_technician_whatsapp_enabled_idx
  on public.stores (technician_user_id, whatsapp_enabled)
  where is_active = true;

-- O lock na linha da Agencia serializa ativacoes concorrentes. A verificacao
-- acontece somente quando um acesso novo e efetivamente consumido; desligar,
-- inativar ou salvar novamente um acesso existente nunca e bloqueado pela cota.
create or replace function app_private.enforce_whatsapp_store_quota()
returns trigger
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_limit integer;
  v_in_use integer;
begin
  if tg_op = 'UPDATE' then
    if old.technician_user_id is not distinct from new.technician_user_id
       and old.admin_user_id is not distinct from new.admin_user_id
       and old.is_active is not distinct from new.is_active
       and old.whatsapp_enabled is not distinct from new.whatsapp_enabled then
      return new;
    end if;
  end if;

  if new.is_active is distinct from true
     or new.whatsapp_enabled is distinct from true then
    return new;
  end if;

  if new.technician_user_id is null then
    raise exception 'Defina a Agencia responsavel antes de liberar WhatsApp.';
  end if;

  select agency.whatsapp_store_limit
  into v_limit
  from public.app_users agency
  where agency.id = new.technician_user_id
    and agency.admin_user_id = new.admin_user_id
    and agency.role::text = 'technician'
    and agency.is_active = true
  for update;

  if not found then
    raise exception 'Agencia responsavel nao encontrada ou inativa.';
  end if;

  select count(*)::integer
  into v_in_use
  from public.stores st
  where st.technician_user_id = new.technician_user_id
    and st.admin_user_id = new.admin_user_id
    and st.is_active = true
    and st.whatsapp_enabled = true
    and st.id <> new.id;

  if v_in_use >= v_limit then
    raise exception
      'Limite de clientes com WhatsApp atingido (% de %).',
      v_in_use,
      v_limit;
  end if;

  return new;
end;
$$;

drop trigger if exists stores_enforce_whatsapp_quota on public.stores;
create trigger stores_enforce_whatsapp_quota
before insert or update of
  technician_user_id,
  admin_user_id,
  is_active,
  whatsapp_enabled
on public.stores
for each row
execute function app_private.enforce_whatsapp_store_quota();

-- Nenhuma rotina service_role pode reativar uma conexao de uma loja sem
-- licenca, inclusive se houver uma corrida entre validacao na Edge Function e
-- a revogacao feita pela Agencia. O inbound continua permitido: webhooks podem
-- ser recebidos e auditados, mas a conexao nao volta a um estado de envio.
create or replace function app_private.guard_whatsapp_connection_entitlement()
returns trigger
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
begin
  if new.status in ('validating', 'connected', 'token_expiring')
     and not exists (
       select 1
       from public.stores st
       where st.id = new.store_id
         and st.admin_user_id = new.admin_user_id
         and st.is_active = true
         and st.whatsapp_enabled = true
     ) then
    raise exception 'Acesso ao WhatsApp nao esta liberado para este cliente.';
  end if;

  return new;
end;
$$;

drop trigger if exists whatsapp_connections_guard_entitlement
on public.whatsapp_connections;
create trigger whatsapp_connections_guard_entitlement
before insert or update of status, store_id, admin_user_id
on public.whatsapp_connections
for each row
execute function app_private.guard_whatsapp_connection_entitlement();

-- Revogar a licenca interrompe novos envios no worker porque conexoes
-- desconectadas nao sao reivindicadas pela fila. Campanhas em andamento ficam
-- pausadas, nao excluidas, e podem ser retomadas depois de nova liberacao e
-- reconexao explicita. Webhooks e historicos permanecem armazenados.
create or replace function app_private.suspend_whatsapp_store_on_disable()
returns trigger
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
begin
  if not (
    (old.whatsapp_enabled is true and new.whatsapp_enabled is false)
    or (old.is_active is true and new.is_active is false)
  ) then
    return new;
  end if;

  update public.whatsapp_campaigns campaign
  set status = 'paused',
      paused_at = coalesce(campaign.paused_at, now()),
      last_error = 'Campanha pausada porque o acesso ao WhatsApp foi desativado.'
  where campaign.store_id = new.id
    and campaign.admin_user_id = new.admin_user_id
    and campaign.status in ('scheduled', 'running');

  update public.whatsapp_connections connection
  set status = 'disconnected',
      disconnected_at = coalesce(connection.disconnected_at, now()),
      last_error_code = 'feature_access_disabled',
      last_error_message = 'Acesso ao WhatsApp desativado para este cliente.'
  where connection.store_id = new.id
    and connection.admin_user_id = new.admin_user_id
    and connection.status <> 'disconnected';

  return new;
end;
$$;

drop trigger if exists stores_suspend_whatsapp_on_disable on public.stores;
create trigger stores_suspend_whatsapp_on_disable
after update of whatsapp_enabled, is_active
on public.stores
for each row
execute function app_private.suspend_whatsapp_store_on_disable();

-- Corrige de forma idempotente uma eventual instalacao parcial: nenhum worker
-- pode manter envio ativo para uma loja que ja esteja marcada como bloqueada.
update public.whatsapp_campaigns campaign
set status = 'paused',
    paused_at = coalesce(campaign.paused_at, now()),
    last_error = 'Campanha pausada porque o acesso ao WhatsApp foi desativado.'
from public.stores st
where st.id = campaign.store_id
  and st.admin_user_id = campaign.admin_user_id
  and (st.whatsapp_enabled = false or st.is_active = false)
  and campaign.status in ('scheduled', 'running');

update public.whatsapp_connections connection
set status = 'disconnected',
    disconnected_at = coalesce(connection.disconnected_at, now()),
    last_error_code = 'feature_access_disabled',
    last_error_message = 'Acesso ao WhatsApp desativado para este cliente.'
from public.stores st
where st.id = connection.store_id
  and st.admin_user_id = connection.admin_user_id
  and (st.whatsapp_enabled = false or st.is_active = false)
  and connection.status <> 'disconnected';

-- ---------------------------------------------------------------------------
-- RPCs de entitlement do WhatsApp
-- ---------------------------------------------------------------------------

create or replace function app_private.rpc_get_whatsapp_entitlements(
  p_session_token text
)
returns jsonb
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select *
  into v_session
  from app_private.session_user(p_session_token);

  return jsonb_build_object(
    'profile', jsonb_build_object(
      'role', v_session.user_role::text,
      'whatsapp_store_limit', case
        when v_session.user_role::text = 'technician' then coalesce((
          select agency.whatsapp_store_limit
          from public.app_users agency
          where agency.id = v_session.user_id
        ), 0)
        else 0
      end,
      'whatsapp_store_count', case
        when v_session.user_role::text = 'technician' then (
          select count(*)
          from public.stores st
          where st.admin_user_id = v_session.admin_user_id
            and st.technician_user_id = v_session.user_id
            and st.is_active = true
            and st.whatsapp_enabled = true
        )
        else 0
      end
    ),
    'stores', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'store_id', st.id,
          'technician_id', st.technician_user_id,
          'whatsapp_enabled', st.whatsapp_enabled
        )
        order by st.created_at, st.id
      )
      from public.stores st
      where st.admin_user_id = v_session.admin_user_id
        and st.is_active = true
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
    ), '[]'::jsonb),
    'technicians', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'technician_id', agency.id,
          'whatsapp_store_limit', agency.whatsapp_store_limit,
          'whatsapp_store_count', (
            select count(*)
            from public.stores st
            where st.admin_user_id = v_session.admin_user_id
              and st.technician_user_id = agency.id
              and st.is_active = true
              and st.whatsapp_enabled = true
          )
        )
        order by agency.full_name, agency.nick, agency.id
      )
      from public.app_users agency
      where agency.admin_user_id = v_session.admin_user_id
        and agency.role::text = 'technician'
        and agency.is_active = true
        and (
          v_session.user_role::text = 'admin'
          or agency.id = v_session.user_id
        )
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function app_private.rpc_set_technician_whatsapp_limit(
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
  select *
  into v_session
  from app_private.session_user(p_session_token);

  if v_session.user_role::text <> 'admin' then
    raise exception 'Apenas o Admin pode alterar o limite de WhatsApp.';
  end if;

  if coalesce(p_limit, -1) not between 0 and 9999 then
    raise exception 'Informe um limite de WhatsApp entre 0 e 9999.';
  end if;

  select agency.store_limit
  into v_store_limit
  from public.app_users agency
  where agency.id = p_technician_id
    and agency.admin_user_id = v_session.admin_user_id
    and agency.role::text = 'technician'
    and agency.is_active = true
  for update;

  if not found then
    raise exception 'Agencia nao encontrada.';
  end if;

  if p_limit > v_store_limit then
    raise exception
      'O limite de WhatsApp nao pode superar o limite total de % clientes.',
      v_store_limit;
  end if;

  -- Nao compara com o uso atual de proposito. A reducao de plano deve ser
  -- possivel; o trigger bloqueia apenas a proxima ativacao.
  update public.app_users
  set whatsapp_store_limit = p_limit
  where id = p_technician_id;

  return true;
end;
$$;

create or replace function app_private.rpc_set_store_whatsapp_access(
  p_session_token text,
  p_store_id uuid,
  p_enabled boolean
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_store record;
begin
  select *
  into v_session
  from app_private.session_user(p_session_token);

  if v_session.user_role::text not in ('admin', 'technician') then
    raise exception 'Somente o Admin ou a Agencia podem alterar este acesso.';
  end if;

  select st.*
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

  -- FALSE passa pelo trigger sem consultar cota, inclusive quando a Agencia
  -- esta acima do novo limite. TRUE e serializado e validado no trigger.
  update public.stores
  set whatsapp_enabled = coalesce(p_enabled, false)
  where id = p_store_id;

  return true;
end;
$$;

-- Salva a conta do cliente e os dois acessos como uma unica operacao. Isso
-- evita um estado parcial quando, por exemplo, Prospeccoes cabe na franquia mas
-- WhatsApp nao. A desativacao necessaria acontece antes de uma transferencia;
-- qualquer falha posterior reverte nome, login, Agencia e os dois toggles.
create or replace function app_private.rpc_update_store_with_feature_access(
  p_session_token text,
  p_store_id uuid,
  p_name text,
  p_nick text,
  p_password text default null,
  p_technician_id uuid default null,
  p_prospection_enabled boolean default false,
  p_whatsapp_enabled boolean default false
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

  select st.prospection_enabled, st.whatsapp_enabled
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

  if v_store.whatsapp_enabled is true
     and coalesce(p_whatsapp_enabled, false) is false then
    perform app_private.rpc_set_store_whatsapp_access(
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

  if v_store.whatsapp_enabled is false
     and coalesce(p_whatsapp_enabled, false) is true then
    perform app_private.rpc_set_store_whatsapp_access(
      p_session_token,
      p_store_id,
      true
    );
  end if;

  return v_result || jsonb_build_object(
    'prospection_enabled', coalesce(p_prospection_enabled, false),
    'whatsapp_enabled', coalesce(p_whatsapp_enabled, false)
  );
end;
$$;

-- Criacao atomica do plano completo. Se contato, Prospeccoes ou WhatsApp
-- falharem, a Agencia criada pela primeira chamada tambem e revertida.
create or replace function app_private.rpc_create_technician_with_feature_plan(
  p_session_token text,
  p_full_name text,
  p_nick text,
  p_password text,
  p_store_limit integer,
  p_whatsapp text,
  p_prospection_limit integer,
  p_whatsapp_limit integer
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
  if coalesce(p_whatsapp_limit, -1) not between 0 and p_store_limit then
    raise exception
      'A franquia de WhatsApp deve ficar entre 0 e o limite total de clientes.';
  end if;

  v_result := app_private.rpc_create_technician_with_whatsapp(
    p_session_token,
    p_full_name,
    p_nick,
    p_password,
    p_store_limit,
    p_whatsapp
  );

  begin
    v_technician_id := nullif(v_result->>'id', '')::uuid;
  exception
    when others then
      v_technician_id := null;
  end;
  if v_technician_id is null then
    raise exception 'Nao foi possivel identificar a Agencia criada.';
  end if;

  perform app_private.rpc_set_technician_prospection_limit(
    p_session_token,
    v_technician_id,
    p_prospection_limit
  );
  perform app_private.rpc_set_technician_whatsapp_limit(
    p_session_token,
    v_technician_id,
    p_whatsapp_limit
  );

  return v_result || jsonb_build_object(
    'store_limit', p_store_limit,
    'prospection_store_limit', p_prospection_limit,
    'whatsapp_store_limit', p_whatsapp_limit
  );
end;
$$;

-- Atualizacao atomica e ordenada do plano. Ao reduzir o total, as franquias
-- descem primeiro para respeitar as constraints. Ao aumentar, o total sobe
-- primeiro. Qualquer erro reverte nome, login, senha, contato e todos os limites.
create or replace function app_private.rpc_update_technician_with_feature_plan(
  p_session_token text,
  p_technician_id uuid,
  p_full_name text,
  p_nick text,
  p_password text default null,
  p_store_limit integer default 5,
  p_whatsapp text default null,
  p_prospection_limit integer default 0,
  p_whatsapp_limit integer default 0
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
  if coalesce(p_whatsapp_limit, -1) not between 0 and p_store_limit then
    raise exception
      'A franquia de WhatsApp deve ficar entre 0 e o limite total de clientes.';
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
    perform app_private.rpc_set_technician_whatsapp_limit(
      p_session_token,
      p_technician_id,
      p_whatsapp_limit
    );

    v_result := app_private.rpc_update_technician_with_whatsapp(
      p_session_token,
      p_technician_id,
      p_full_name,
      p_nick,
      p_password,
      p_store_limit,
      p_whatsapp
    );
  else
    v_result := app_private.rpc_update_technician_with_whatsapp(
      p_session_token,
      p_technician_id,
      p_full_name,
      p_nick,
      p_password,
      p_store_limit,
      p_whatsapp
    );

    perform app_private.rpc_set_technician_prospection_limit(
      p_session_token,
      p_technician_id,
      p_prospection_limit
    );
    perform app_private.rpc_set_technician_whatsapp_limit(
      p_session_token,
      p_technician_id,
      p_whatsapp_limit
    );
  end if;

  return v_result || jsonb_build_object(
    'store_limit', p_store_limit,
    'prospection_store_limit', p_prospection_limit,
    'whatsapp_store_limit', p_whatsapp_limit
  );
end;
$$;

create or replace function public.lc_create_technician_with_feature_plan(
  p_session_token text,
  p_full_name text,
  p_nick text,
  p_password text,
  p_store_limit integer,
  p_whatsapp text,
  p_prospection_limit integer,
  p_whatsapp_limit integer
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
    p_whatsapp,
    p_prospection_limit,
    p_whatsapp_limit
  );
$$;

create or replace function public.lc_update_technician_with_feature_plan(
  p_session_token text,
  p_technician_id uuid,
  p_full_name text,
  p_nick text,
  p_password text default null,
  p_store_limit integer default 5,
  p_whatsapp text default null,
  p_prospection_limit integer default 0,
  p_whatsapp_limit integer default 0
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
    p_whatsapp,
    p_prospection_limit,
    p_whatsapp_limit
  );
$$;

create or replace function public.lc_get_whatsapp_entitlements(
  p_session_token text
)
returns jsonb
language sql
security invoker
set search_path = app_private, public, extensions
as $$
  select app_private.rpc_get_whatsapp_entitlements(p_session_token);
$$;

create or replace function public.lc_set_technician_whatsapp_limit(
  p_session_token text,
  p_technician_id uuid,
  p_limit integer
)
returns boolean
language sql
security invoker
set search_path = app_private, public, extensions
as $$
  select app_private.rpc_set_technician_whatsapp_limit(
    p_session_token,
    p_technician_id,
    p_limit
  );
$$;

create or replace function public.lc_set_store_whatsapp_access(
  p_session_token text,
  p_store_id uuid,
  p_enabled boolean
)
returns boolean
language sql
security invoker
set search_path = app_private, public, extensions
as $$
  select app_private.rpc_set_store_whatsapp_access(
    p_session_token,
    p_store_id,
    p_enabled
  );
$$;

create or replace function public.lc_update_store_with_feature_access(
  p_session_token text,
  p_store_id uuid,
  p_name text,
  p_nick text,
  p_password text default null,
  p_technician_id uuid default null,
  p_prospection_enabled boolean default false,
  p_whatsapp_enabled boolean default false
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
    p_prospection_enabled,
    p_whatsapp_enabled
  );
$$;

-- ---------------------------------------------------------------------------
-- Autorizacao central dos modulos
-- ---------------------------------------------------------------------------

-- Todas as RPCs de usuario do modulo WhatsApp passam por este helper. Ao
-- incorporar whatsapp_enabled aqui, leitura, escrita, configuracao, campanhas,
-- exportacoes, anexos e chamadas das Edge Functions com sessao ficam bloqueadas
-- no servidor mesmo que alguem ignore o frontend.
create or replace function app_private.whatsapp_store_allowed(
  p_admin_user_id uuid,
  p_user_id uuid,
  p_user_role public.app_user_role,
  p_user_store_id uuid,
  p_store_id uuid,
  p_configuration_write boolean default false
)
returns boolean
language sql
stable
security definer
set search_path = app_private, public, extensions
as $$
  select exists (
    select 1
    from public.stores st
    where st.id = p_store_id
      and st.admin_user_id = p_admin_user_id
      and st.is_active = true
      and st.whatsapp_enabled = true
      and (
        p_user_role::text = 'admin'
        or (
          p_user_role::text = 'technician'
          and st.technician_user_id = p_user_id
        )
        or (
          coalesce(p_configuration_write, false) = false
          and p_user_role::text = 'store'
          and st.id = p_user_store_id
        )
      )
  );
$$;

-- Usada pela Edge Function antes de testar/validar credenciais ainda nao
-- persistidas. Sem esta RPC, o fluxo runtimeFromUnsaved conseguiria consultar a
-- Meta sem passar por wa_service_connection_runtime e pelo helper central.
create or replace function public.wa_assert_store_access(
  p_session_token text,
  p_store_id uuid,
  p_configuration_write boolean default false
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select *
  into v_session
  from app_private.session_user(p_session_token);

  if not app_private.whatsapp_store_allowed(
    v_session.admin_user_id,
    v_session.user_id,
    v_session.user_role,
    v_session.user_store_id,
    p_store_id,
    coalesce(p_configuration_write, false)
  ) then
    raise exception 'Cliente nao encontrado ou sem acesso ao WhatsApp.';
  end if;

  return true;
end;
$$;

-- Runtime usado exclusivamente pelo worker outbound. A revalidacao acontece
-- depois do claim/prepare e antes de expor o token, fechando a corrida mais
-- relevante entre desativacao e envio. Os runtimes inbound por telefone,
-- Business Account e Verify Token permanecem deliberadamente sem este gate:
-- a Meta deve receber 200 e os eventos continuam auditados, embora invisiveis
-- aos usuarios enquanto a licenca estiver bloqueada.
create or replace function public.wa_service_connection_runtime_by_id(
  p_connection_id uuid,
  p_encryption_key text
)
returns jsonb
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_connection record;
  v_secrets jsonb;
begin
  if length(coalesce(p_encryption_key, '')) < 32 then
    raise exception 'Chave de criptografia do WhatsApp ausente.';
  end if;

  select connection.*
  into v_connection
  from public.whatsapp_connections connection
  join public.stores st
    on st.id = connection.store_id
   and st.admin_user_id = connection.admin_user_id
   and st.is_active = true
   and st.whatsapp_enabled = true
  where connection.id = p_connection_id
    and connection.status in ('connected', 'token_expiring');

  if not found then
    raise exception 'Conexao nao encontrada, inativa ou sem licenca.';
  end if;

  begin
    select extensions.pgp_sym_decrypt(secret.secret_cipher, p_encryption_key)::jsonb
    into v_secrets
    from app_private.whatsapp_connection_secrets secret
    where secret.connection_id = v_connection.id;
  exception
    when others then
      raise exception
        'Nao foi possivel decifrar as credenciais. Verifique WHATSAPP_CREDENTIAL_ENCRYPTION_KEY.';
  end;

  if v_secrets is null then
    raise exception 'Credenciais da conexao nao encontradas.';
  end if;

  return (to_jsonb(v_connection) - 'created_by' - 'updated_by')
    || jsonb_build_object('secrets', v_secrets);
end;
$$;

-- Atendimentos compartilha exatamente o entitlement de Prospeccoes. Nao ha
-- coluna attendance_enabled, cota adicional ou caminho administrativo paralelo.
-- Como as tres RPCs publicas de Atendimentos usam este helper, liberar ou
-- bloquear Prospeccoes produz o mesmo efeito no servidor imediatamente.
create or replace function app_private.attendance_store_allowed(
  p_admin_user_id uuid,
  p_user_id uuid,
  p_user_role public.app_user_role,
  p_user_store_id uuid,
  p_store_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = app_private, public, extensions
as $$
  select app_private.prospection_store_allowed(
    p_admin_user_id,
    p_user_id,
    p_user_role,
    p_user_store_id,
    p_store_id,
    false
  );
$$;

-- ---------------------------------------------------------------------------
-- Permissoes e publicacao no PostgREST
-- ---------------------------------------------------------------------------

revoke all on function app_private.enforce_whatsapp_store_quota()
from public, anon, authenticated;
revoke all on function app_private.suspend_whatsapp_store_on_disable()
from public, anon, authenticated;
revoke all on function app_private.guard_whatsapp_connection_entitlement()
from public, anon, authenticated;
revoke all on function app_private.rpc_get_whatsapp_entitlements(text)
from public, anon, authenticated;
revoke all on function app_private.rpc_set_technician_whatsapp_limit(text, uuid, integer)
from public, anon, authenticated;
revoke all on function app_private.rpc_set_store_whatsapp_access(text, uuid, boolean)
from public, anon, authenticated;
revoke all on function app_private.rpc_update_store_with_feature_access(
  text, uuid, text, text, text, uuid, boolean, boolean
) from public, anon, authenticated;
revoke all on function app_private.rpc_create_technician_with_feature_plan(
  text, text, text, text, integer, text, integer, integer
) from public, anon, authenticated;
revoke all on function app_private.rpc_update_technician_with_feature_plan(
  text, uuid, text, text, text, integer, text, integer, integer
) from public, anon, authenticated;
revoke all on function app_private.whatsapp_store_allowed(
  uuid, uuid, public.app_user_role, uuid, uuid, boolean
) from public, anon, authenticated;
revoke all on function app_private.attendance_store_allowed(
  uuid, uuid, public.app_user_role, uuid, uuid
) from public, anon, authenticated;

revoke all on function public.wa_assert_store_access(text, uuid, boolean)
from public, anon, authenticated;
revoke all on function public.wa_service_connection_runtime_by_id(uuid, text)
from public, anon, authenticated;
revoke all on function public.lc_create_technician_with_feature_plan(
  text, text, text, text, integer, text, integer, integer
) from public;
revoke all on function public.lc_update_technician_with_feature_plan(
  text, uuid, text, text, text, integer, text, integer, integer
) from public;
revoke all on function public.lc_update_store_with_feature_access(
  text, uuid, text, text, text, uuid, boolean, boolean
) from public;

-- Os wrappers publicos sao SECURITY INVOKER, portanto seus tres alvos internos
-- recebem apenas EXECUTE. Todos validam a sessao e o papel novamente.
grant execute on function app_private.rpc_get_whatsapp_entitlements(text)
to anon, authenticated;
grant execute on function app_private.rpc_set_technician_whatsapp_limit(text, uuid, integer)
to anon, authenticated;
grant execute on function app_private.rpc_set_store_whatsapp_access(text, uuid, boolean)
to anon, authenticated;
grant execute on function app_private.rpc_update_store_with_feature_access(
  text, uuid, text, text, text, uuid, boolean, boolean
) to anon, authenticated;
grant execute on function app_private.rpc_create_technician_with_feature_plan(
  text, text, text, text, integer, text, integer, integer
) to anon, authenticated;
grant execute on function app_private.rpc_update_technician_with_feature_plan(
  text, uuid, text, text, text, integer, text, integer, integer
) to anon, authenticated;

-- Funcoes de servico do WhatsApp ja possuem grants exclusivos para service_role
-- e continuam usando o mesmo helper central quando recebem uma sessao.
grant execute on function app_private.whatsapp_store_allowed(
  uuid, uuid, public.app_user_role, uuid, uuid, boolean
) to service_role;
grant execute on function public.wa_assert_store_access(text, uuid, boolean)
to service_role;
grant execute on function public.wa_service_connection_runtime_by_id(uuid, text)
to service_role;
grant execute on function public.lc_create_technician_with_feature_plan(
  text, text, text, text, integer, text, integer, integer
) to anon, authenticated;
grant execute on function public.lc_update_technician_with_feature_plan(
  text, uuid, text, text, text, integer, text, integer, integer
) to anon, authenticated;
grant execute on function public.lc_update_store_with_feature_access(
  text, uuid, text, text, text, uuid, boolean, boolean
) to anon, authenticated;

revoke all on function public.lc_get_whatsapp_entitlements(text)
from public;
revoke all on function public.lc_set_technician_whatsapp_limit(text, uuid, integer)
from public;
revoke all on function public.lc_set_store_whatsapp_access(text, uuid, boolean)
from public;

grant execute on function public.lc_get_whatsapp_entitlements(text)
to anon, authenticated;
grant execute on function public.lc_set_technician_whatsapp_limit(text, uuid, integer)
to anon, authenticated;
grant execute on function public.lc_set_store_whatsapp_access(text, uuid, boolean)
to anon, authenticated;

comment on column public.app_users.whatsapp_store_limit is
  'Franquia de clientes com WhatsApp que o Admin concedeu a esta Agencia.';
comment on column public.stores.whatsapp_enabled is
  'Licenca de WhatsApp consumida da Agencia responsavel; nao controla Prospeccoes nem Atendimentos.';
comment on function public.lc_get_whatsapp_entitlements(text) is
  'Retorna franquia, uso e acessos de WhatsApp dentro do escopo da sessao.';
comment on function public.lc_set_technician_whatsapp_limit(text, uuid, integer) is
  'Admin altera a franquia WhatsApp da Agencia; reducao abaixo do uso e permitida.';
comment on function public.lc_set_store_whatsapp_access(text, uuid, boolean) is
  'Admin ou Agencia responsavel ativa/desativa WhatsApp; apenas novas ativacoes consomem cota.';
comment on function public.lc_create_technician_with_feature_plan(
  text, text, text, text, integer, text, integer, integer
) is 'Cria Agencia, contato e franquias de recursos em uma unica transacao.';
comment on function public.lc_update_technician_with_feature_plan(
  text, uuid, text, text, text, integer, text, integer, integer
) is 'Atualiza Agencia e plano completo atomicamente, com ordem segura nas reducoes.';
comment on function public.lc_update_store_with_feature_access(
  text, uuid, text, text, text, uuid, boolean, boolean
) is 'Atualiza conta do cliente e acessos Prospec/Atendimentos/WhatsApp atomicamente.';
comment on function public.wa_assert_store_access(text, uuid, boolean) is
  'Edge Function valida entitlement antes de operar credenciais WhatsApp ainda nao persistidas.';
comment on function app_private.attendance_store_allowed(
  uuid, uuid, public.app_user_role, uuid, uuid
) is 'Atendimentos usa exatamente o mesmo entitlement de Prospeccoes.';

notify pgrst, 'reload schema';

commit;

-- Verificacao de instalacao (somente leitura):
-- select
--   to_regprocedure('public.lc_get_whatsapp_entitlements(text)') as leitura,
--   to_regprocedure('public.lc_set_technician_whatsapp_limit(text,uuid,integer)') as limite,
--   to_regprocedure('public.lc_set_store_whatsapp_access(text,uuid,boolean)') as acesso,
--   to_regprocedure('public.lc_create_technician_with_feature_plan(text,text,text,text,integer,text,integer,integer)') as criar_plano,
--   to_regprocedure('public.lc_update_technician_with_feature_plan(text,uuid,text,text,text,integer,text,integer,integer)') as atualizar_plano,
--   to_regprocedure('public.lc_update_store_with_feature_access(text,uuid,text,text,text,uuid,boolean,boolean)') as atualizar_cliente,
--   to_regprocedure('public.wa_assert_store_access(text,uuid,boolean)') as edge_guard,
--   to_regprocedure('app_private.attendance_store_allowed(uuid,uuid,public.app_user_role,uuid,uuid)') as atendimentos;
