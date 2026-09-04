-- Atendimentos / Bom Dia Vendedor | Realtime privado por sessao e loja.
--
-- O aplicativo usa uma sessao propria (token opaco em public.app_sessions) e
-- conecta ao Supabase com a role anon. Por isso, expor as tabelas comerciais em
-- supabase_realtime exigiria SELECT para anon e quebraria o isolamento por loja.
-- Esta migration nao adiciona nenhuma tabela a Postgres Changes (Leads conserva
-- sua publication legada sem SELECT anon) e transmite somente invalidacoes sem
-- dados de negocio por um topico-capability aleatorio.

begin;

set local lock_timeout = '10s';
set local statement_timeout = '5min';
set local search_path = '';

create table if not exists app_private.attendance_realtime_subscriptions (
  app_session_id uuid not null,
  store_id uuid not null,
  topic text not null,
  expires_at timestamptz not null,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint attendance_realtime_subscriptions_pkey
    primary key (app_session_id, store_id),
  constraint attendance_realtime_subscriptions_session_fk
    foreign key (app_session_id)
    references public.app_sessions(id)
    on delete cascade,
  constraint attendance_realtime_subscriptions_store_fk
    foreign key (store_id)
    references public.stores(id)
    on delete cascade,
  constraint attendance_realtime_subscriptions_topic_key
    unique (topic),
  constraint attendance_realtime_subscriptions_topic_check
    check (topic ~ '^lc:attendance:[0-9a-f]{64}$')
);

create index if not exists attendance_realtime_subscriptions_store_expiry_idx
  on app_private.attendance_realtime_subscriptions (store_id, expires_at);

create index if not exists attendance_realtime_subscriptions_expiry_idx
  on app_private.attendance_realtime_subscriptions (expires_at);

alter table app_private.attendance_realtime_subscriptions
  enable row level security;

revoke all on table app_private.attendance_realtime_subscriptions
  from public, anon, authenticated;
grant select, insert, update, delete
  on table app_private.attendance_realtime_subscriptions
  to service_role;

comment on table app_private.attendance_realtime_subscriptions is
  'Topicos Realtime privados, um por sessao customizada e loja. A capability aleatoria expira com a sessao e nunca contem o token da sessao.';

-- A policy de realtime.messages nao recebe p_session_token. Ela valida a
-- capability opaca contra uma assinatura ainda ativa e revalida sessao, usuario,
-- loja, modulo e vinculo da agencia antes de permitir o join do topico.
create or replace function app_private.attendance_realtime_topic_allowed(
  p_topic text
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select
    pg_catalog.octet_length(coalesce(p_topic, '')) between 78 and 78
    and exists (
      select 1
      from app_private.attendance_realtime_subscriptions subscription
      join public.app_sessions session_record
        on session_record.id = subscription.app_session_id
      join public.app_users account
        on account.id = session_record.user_id
      where subscription.topic = p_topic
        and subscription.expires_at > pg_catalog.now()
        and session_record.revoked_at is null
        and session_record.expires_at > pg_catalog.now()
        and account.is_active = true
        and app_private.attendance_store_allowed(
          coalesce(account.admin_user_id, account.id),
          account.id,
          account.role,
          account.store_id,
          subscription.store_id
        )
    );
$$;

revoke all on function app_private.attendance_realtime_topic_allowed(text)
  from public, anon, authenticated;
grant execute on function app_private.attendance_realtime_topic_allowed(text)
  to anon, authenticated;

drop policy if exists attendance_private_broadcast_receive
  on realtime.messages;
create policy attendance_private_broadcast_receive
on realtime.messages
for select
to anon, authenticated
using (
  realtime.messages.extension = 'broadcast'
  and app_private.attendance_realtime_topic_allowed(
    (select realtime.topic())
  )
);

-- Remove capabilities que ja nao podem autorizar um canal. No emissor, a
-- checagem por loja acontece somente depois da ultima invalidacao de uma
-- mudanca de acesso, para que conexoes ja abertas consigam reconciliar a UI.
create or replace function app_private.prune_attendance_realtime_subscriptions(
  p_store_id uuid default null,
  p_check_store_authorization boolean default false
)
returns void
language sql
volatile
security definer
set search_path = ''
as $$
  delete from app_private.attendance_realtime_subscriptions subscription
  where (p_store_id is null or subscription.store_id = p_store_id)
    and (
      subscription.expires_at <= pg_catalog.now()
      or not exists (
        select 1
        from public.app_sessions session_record
        join public.app_users account
          on account.id = session_record.user_id
        where session_record.id = subscription.app_session_id
          and session_record.revoked_at is null
          and session_record.expires_at > pg_catalog.now()
          and account.is_active = true
      )
      or (
        coalesce(p_check_store_authorization, false)
        and not exists (
          select 1
          from public.app_sessions session_record
          join public.app_users account
            on account.id = session_record.user_id
          where session_record.id = subscription.app_session_id
            and session_record.revoked_at is null
            and session_record.expires_at > pg_catalog.now()
            and account.is_active = true
            and app_private.attendance_store_allowed(
              coalesce(account.admin_user_id, account.id),
              account.id,
              account.role,
              account.store_id,
              subscription.store_id
            )
        )
      )
    );
$$;

revoke all on function
  app_private.prune_attendance_realtime_subscriptions(uuid, boolean)
  from public, anon, authenticated;

-- Entrega a capability vinculada ao prazo da propria sessao. Assim o frontend
-- nao depende de um renovador paralelo; logout/revogacao remove a capability e
-- a policy mais o emissor sempre revalidam o estado corrente.
create or replace function app_private.rpc_get_attendance_realtime_subscription_v1(
  p_session_token text,
  p_store_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_session record;
  v_app_session_id uuid;
  v_app_session_expires_at timestamptz;
  v_new_topic text;
  v_topic text;
  v_expires_at timestamptz;
begin
  select *
  into v_session
  from app_private.session_user(p_session_token);

  perform app_private.prune_attendance_realtime_subscriptions();

  if p_store_id is null or not app_private.attendance_store_allowed(
    v_session.admin_user_id,
    v_session.user_id,
    v_session.user_role,
    v_session.user_store_id,
    p_store_id
  ) then
    raise exception 'Atendimentos nao esta disponivel para este cliente.';
  end if;

  select session_record.id, session_record.expires_at
  into v_app_session_id, v_app_session_expires_at
  from public.app_sessions session_record
  where session_record.user_id = v_session.user_id
    and session_record.token_hash = pg_catalog.encode(
      extensions.digest(p_session_token, 'sha256'),
      'hex'
    )
    and session_record.revoked_at is null
    and session_record.expires_at > pg_catalog.now()
  limit 1;

  if v_app_session_id is null then
    raise exception 'Sessao invalida ou expirada.' using errcode = '28000';
  end if;

  v_new_topic := 'lc:attendance:' || pg_catalog.encode(
    extensions.gen_random_bytes(32),
    'hex'
  );
  v_expires_at := v_app_session_expires_at;

  insert into app_private.attendance_realtime_subscriptions as subscription (
    app_session_id,
    store_id,
    topic,
    expires_at
  ) values (
    v_app_session_id,
    p_store_id,
    v_new_topic,
    v_expires_at
  )
  on conflict (app_session_id, store_id) do update
  set
    topic = case
      when subscription.expires_at > pg_catalog.now()
        then subscription.topic
      else excluded.topic
    end,
    expires_at = excluded.expires_at,
    updated_at = pg_catalog.now()
  returning
    subscription.topic,
    subscription.expires_at
  into v_topic, v_expires_at;

  return pg_catalog.jsonb_build_object(
    'transport', 'broadcast',
    'store_id', p_store_id,
    'topic', v_topic,
    'event', 'invalidate',
    'private', true,
    'expires_at', v_expires_at,
    'payload_version', 1
  );
end;
$$;

create or replace function public.lc_get_attendance_realtime_subscription_v1(
  p_session_token text,
  p_store_id uuid
)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select app_private.rpc_get_attendance_realtime_subscription_v1(
    p_session_token,
    p_store_id
  );
$$;

revoke all on function
  app_private.rpc_get_attendance_realtime_subscription_v1(text, uuid)
  from public, anon, authenticated;
grant execute on function
  app_private.rpc_get_attendance_realtime_subscription_v1(text, uuid)
  to anon, authenticated;

revoke all on function
  public.lc_get_attendance_realtime_subscription_v1(text, uuid)
  from public;
grant execute on function
  public.lc_get_attendance_realtime_subscription_v1(text, uuid)
  to anon, authenticated;

comment on function public.lc_get_attendance_realtime_subscription_v1(text, uuid)
is 'Autoriza a sessao customizada e retorna uma assinatura que expira com a sessao para um canal Broadcast privado de invalidacao, sem expor linhas comerciais.';

-- Emite no maximo uma invalidacao por recurso/loja em cada transacao. Recursos
-- diferentes continuam independentes para evitar reload desnecessario do Bom
-- Dia quando somente o workspace de Atendimentos mudou (e vice-versa).
create or replace function app_private.broadcast_attendance_realtime_invalidation(
  p_store_id uuid,
  p_resources text[],
  p_include_previously_authorized boolean default false
)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_marked_keys text := coalesce(
    pg_catalog.current_setting(
      'app.attendance_realtime_invalidation_keys',
      true
    ),
    ''
  );
  v_pending_resources text[] := array[]::text[];
  v_resource text;
  v_key text;
  v_topic record;
begin
  if p_store_id is null then
    return;
  end if;

  -- No caminho quente, limita a limpeza a loja da propria escrita.
  perform app_private.prune_attendance_realtime_subscriptions(
    p_store_id,
    false
  );

  foreach v_resource in array coalesce(
    p_resources,
    array[]::text[]
  )
  loop
    v_resource := pg_catalog.lower(pg_catalog.btrim(v_resource));
    if v_resource not in ('attendance', 'morning')
       or v_resource = any(v_pending_resources) then
      continue;
    end if;

    v_key := p_store_id::text || ':' || v_resource;
    if not v_key = any(
      coalesce(
        pg_catalog.string_to_array(v_marked_keys, ','),
        array[]::text[]
      )
    ) then
      v_pending_resources := pg_catalog.array_append(
        v_pending_resources,
        v_resource
      );
    end if;
  end loop;

  if pg_catalog.cardinality(v_pending_resources) > 0 then
    for v_topic in
      select subscription.topic
      from app_private.attendance_realtime_subscriptions subscription
      join public.app_sessions session_record
        on session_record.id = subscription.app_session_id
      join public.app_users account
        on account.id = session_record.user_id
      where subscription.store_id = p_store_id
        and subscription.expires_at > pg_catalog.now()
        and session_record.revoked_at is null
        and session_record.expires_at > pg_catalog.now()
        and account.is_active = true
        and (
          p_include_previously_authorized
          or app_private.attendance_store_allowed(
            coalesce(account.admin_user_id, account.id),
            account.id,
            account.role,
            account.store_id,
            subscription.store_id
          )
        )
    loop
      perform realtime.send(
        pg_catalog.jsonb_build_object(
          'resources', pg_catalog.to_jsonb(v_pending_resources),
          'version', 1
        ),
        'invalidate',
        v_topic.topic,
        true
      );
    end loop;

    foreach v_resource in array v_pending_resources
    loop
      v_key := p_store_id::text || ':' || v_resource;
      v_marked_keys := case
        when v_marked_keys = '' then v_key
        else v_marked_keys || ',' || v_key
      end;
    end loop;

    perform pg_catalog.set_config(
      'app.attendance_realtime_invalidation_keys',
      v_marked_keys,
      true
    );
  end if;

  -- Uma mudanca de acesso pode emitir uma ultima invalidacao por bypass apenas
  -- nesta chamada. Logo depois, qualquer capability sem autorizacao e apagada.
  perform app_private.prune_attendance_realtime_subscriptions(
    p_store_id,
    true
  );
exception
  when others then
    begin
      perform app_private.prune_attendance_realtime_subscriptions(
        p_store_id,
        true
      );
    exception
      when others then
        null;
    end;
    -- Realtime e auxiliar: indisponibilidade do transporte nunca pode reverter
    -- uma operacao comercial valida.
    raise warning 'Falha ao emitir invalidacao privada de Atendimentos: %',
      sqlerrm;
end;
$$;

create or replace function app_private.attendance_realtime_invalidate_row()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_new jsonb;
  v_old jsonb;
  v_new_store_id uuid;
  v_old_store_id uuid;
  v_resources text[] := coalesce(tg_argv, array[]::text[]);
  v_include_previously_authorized boolean := false;
begin
  if tg_op = 'INSERT' then
    v_new := pg_catalog.to_jsonb(new);
  elsif tg_op = 'UPDATE' then
    v_new := pg_catalog.to_jsonb(new);
    v_old := pg_catalog.to_jsonb(old);

    -- Triggers de updated_at nao representam uma mudanca visivel e poderiam
    -- criar um ciclo ao recarregar workspaces que atualizam snapshots.
    if (v_new - 'updated_at') = (v_old - 'updated_at') then
      return new;
    end if;
  else
    v_old := pg_catalog.to_jsonb(old);
  end if;

  if tg_table_schema = 'public' and tg_table_name = 'stores' then
    v_new_store_id := nullif(v_new->>'id', '')::uuid;
    v_old_store_id := nullif(v_old->>'id', '')::uuid;
    v_include_previously_authorized := true;
  else
    v_new_store_id := nullif(v_new->>'store_id', '')::uuid;
    v_old_store_id := nullif(v_old->>'store_id', '')::uuid;
    v_include_previously_authorized :=
      tg_table_schema = 'app_private'
      and tg_table_name = 'store_agency_accesses';
  end if;

  if pg_catalog.cardinality(v_resources) = 0 then
    v_resources := array['attendance']::text[];
  end if;

  if v_old_store_id is not null then
    perform app_private.broadcast_attendance_realtime_invalidation(
      v_old_store_id,
      v_resources,
      v_include_previously_authorized
    );
  end if;

  if v_new_store_id is not null
     and v_new_store_id is distinct from v_old_store_id then
    perform app_private.broadcast_attendance_realtime_invalidation(
      v_new_store_id,
      v_resources,
      v_include_previously_authorized
    );
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

-- Revogar/logout da sessao remove imediatamente todas as capabilities. O
-- frontend ja encerra o canal no logout, e tanto policy quanto emissor
-- revalidam a sessao para impedir mensagens futuras.
create or replace function app_private.invalidate_attendance_realtime_session()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if new.revoked_at is null
     and new.expires_at > pg_catalog.now() then
    update app_private.attendance_realtime_subscriptions subscription
    set
      expires_at = new.expires_at,
      updated_at = pg_catalog.now()
    where subscription.app_session_id = new.id
      and subscription.expires_at is distinct from new.expires_at;
    return new;
  end if;

  delete from app_private.attendance_realtime_subscriptions subscription
  where subscription.app_session_id = new.id;

  return new;
exception
  when others then
    raise warning 'Falha ao invalidar canal Realtime da sessao: %', sqlerrm;
    return new;
end;
$$;

revoke all on function
  app_private.broadcast_attendance_realtime_invalidation(
    uuid,
    text[],
    boolean
  )
  from public, anon, authenticated;
revoke all on function app_private.attendance_realtime_invalidate_row()
  from public, anon, authenticated;
revoke all on function app_private.invalidate_attendance_realtime_session()
  from public, anon, authenticated;

-- Fontes diretas dos workspaces de Atendimentos e Bom Dia Vendedor.
drop trigger if exists attendances_private_realtime_invalidate
  on public.attendances;
create trigger attendances_private_realtime_invalidate
after insert or update or delete on public.attendances
for each row execute function
  app_private.attendance_realtime_invalidate_row('attendance', 'morning');

drop trigger if exists good_morning_settings_private_realtime_invalidate
  on public.good_morning_seller_settings;
create trigger good_morning_settings_private_realtime_invalidate
after insert or update or delete on public.good_morning_seller_settings
for each row execute function
  app_private.attendance_realtime_invalidate_row('morning');

drop trigger if exists good_morning_allocations_private_realtime_invalidate
  on public.good_morning_seller_allocations;
create trigger good_morning_allocations_private_realtime_invalidate
after insert or update or delete on public.good_morning_seller_allocations
for each row execute function
  app_private.attendance_realtime_invalidate_row('morning');

drop trigger if exists good_morning_closed_days_private_realtime_invalidate
  on public.good_morning_seller_closed_days;
create trigger good_morning_closed_days_private_realtime_invalidate
after insert or update or delete on public.good_morning_seller_closed_days
for each row execute function
  app_private.attendance_realtime_invalidate_row('morning');

drop trigger if exists prospection_professionals_attendance_realtime_invalidate
  on public.prospection_professionals;
create trigger prospection_professionals_attendance_realtime_invalidate
after insert or update or delete on public.prospection_professionals
for each row execute function
  app_private.attendance_realtime_invalidate_row('attendance', 'morning');

drop trigger if exists prospection_settings_attendance_realtime_invalidate
  on public.prospection_store_settings;
create trigger prospection_settings_attendance_realtime_invalidate
after insert or update or delete on public.prospection_store_settings
for each row execute function
  app_private.attendance_realtime_invalidate_row('attendance');

-- Alguns KPIs de Atendimentos derivam o credito efetivo da prospeccao ligada.
drop trigger if exists prospections_attendance_realtime_invalidate
  on public.prospections;
create trigger prospections_attendance_realtime_invalidate
after insert or update or delete on public.prospections
for each row execute function
  app_private.attendance_realtime_invalidate_row('attendance');

-- O retorno de Atendimentos inclui identidade e desfecho do Lead vinculado.
-- Alteracoes de marketing/notas nao exigem reload desse workspace.
drop trigger if exists leads_attendance_realtime_invalidate
  on public.leads;
create trigger leads_attendance_realtime_invalidate
after insert or update of
  admin_user_id,
  store_id,
  name,
  phone,
  visited,
  bought,
  purchase_amount,
  service_order,
  attendance_visit_source_id,
  attendance_purchase_source_id
on public.leads
for each row execute function
  app_private.attendance_realtime_invalidate_row('attendance');

drop trigger if exists leads_attendance_realtime_delete
  on public.leads;
create trigger leads_attendance_realtime_delete
after delete on public.leads
for each row execute function
  app_private.attendance_realtime_invalidate_row('attendance');

-- Mudancas de acesso precisam avisar tambem quem acabou de perder o escopo;
-- depois desse unico aviso, a revalidacao normal deixa de emitir para o canal.
drop trigger if exists stores_attendance_realtime_invalidate
  on public.stores;
create trigger stores_attendance_realtime_invalidate
after update of
  admin_user_id,
  name,
  nick,
  avatar_url,
  technician_user_id,
  is_active,
  attendance_enabled,
  good_morning_seller_enabled
on public.stores
for each row execute function
  app_private.attendance_realtime_invalidate_row('attendance', 'morning');

drop trigger if exists store_agency_access_attendance_realtime_invalidate
  on app_private.store_agency_accesses;
create trigger store_agency_access_attendance_realtime_invalidate
after insert or update or delete on app_private.store_agency_accesses
for each row execute function
  app_private.attendance_realtime_invalidate_row('attendance', 'morning');

drop trigger if exists app_sessions_attendance_realtime_invalidate
  on public.app_sessions;
create trigger app_sessions_attendance_realtime_invalidate
after update of revoked_at, expires_at on public.app_sessions
for each row execute function
  app_private.invalidate_attendance_realtime_session();

comment on function
  app_private.broadcast_attendance_realtime_invalidation(
    uuid,
    text[],
    boolean
  )
is 'Publica apenas recursos permitidos por loja/transacao para assinaturas privadas ainda validas; nunca serializa NEW ou OLD.';

do $attendance_realtime_contract$
begin
  if pg_catalog.to_regprocedure(
       'public.lc_get_attendance_realtime_subscription_v1(text,uuid)'
     ) is null
     or pg_catalog.to_regprocedure(
       'app_private.rpc_get_attendance_realtime_subscription_v1(text,uuid)'
     ) is null
     or not pg_catalog.has_function_privilege(
       'anon',
       'public.lc_get_attendance_realtime_subscription_v1(text,uuid)',
       'EXECUTE'
     )
     or not pg_catalog.has_function_privilege(
       'authenticated',
       'public.lc_get_attendance_realtime_subscription_v1(text,uuid)',
       'EXECUTE'
     ) then
    raise exception 'Contrato RPC Realtime de Atendimentos incompleto.';
  end if;
end;
$attendance_realtime_contract$;

notify pgrst, 'reload schema';

commit;
