-- Smoke test transacional do Broadcast privado de Atendimentos / Bom Dia.
--
-- Pre-requisito: aplicar a migration
-- 20260904144746_attendance_private_realtime_broadcast.sql.
-- O teste cria somente lojas, usuario, sessoes, Lead e dia fechado sinteticos,
-- verifica isolamento de topicos/payloads e reverte tudo no ROLLBACK final.

begin;

set local lock_timeout = '10s';
set local statement_timeout = '120s';
select pg_catalog.set_config('app.legal_gate_bypass', 'on', true);

do $attendance_private_realtime$
declare
  v_run_id uuid := extensions.gen_random_uuid();
  v_suffix text;
  v_admin_id uuid;
  v_store_user_id uuid;
  v_store_a uuid;
  v_store_b uuid;
  v_store_token text;
  v_admin_token text;
  v_store_session_id uuid;
  v_admin_session_id uuid;
  v_store_session_expires_at timestamptz;
  v_admin_session_expires_at timestamptz;
  v_subscription_a jsonb;
  v_subscription_a_again jsonb;
  v_subscription_b jsonb;
  v_topic_a text;
  v_topic_b text;
  v_expired_rpc_topic text;
  v_expired_emitter_topic text;
  v_lead_id uuid;
  v_closed_on date;
  v_error text;
  v_table text;
  v_message_count bigint;
  v_payload jsonb;
begin
  if pg_catalog.to_regprocedure(
       'public.lc_get_attendance_realtime_subscription_v1(text,uuid)'
     ) is null
     or pg_catalog.to_regprocedure(
       'app_private.attendance_realtime_topic_allowed(text)'
     ) is null
     or pg_catalog.to_regclass(
       'app_private.attendance_realtime_subscriptions'
     ) is null then
    raise exception 'Smoke Realtime: migration ainda nao foi aplicada.';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_policies policy_record
    where policy_record.schemaname = 'realtime'
      and policy_record.tablename = 'messages'
      and policy_record.policyname = 'attendance_private_broadcast_receive'
      and policy_record.cmd = 'SELECT'
      and policy_record.roles @> array['anon'::name, 'authenticated'::name]
  ) then
    raise exception 'Smoke Realtime: policy privada de recepcao ausente.';
  end if;

  if not pg_catalog.has_function_privilege(
       'anon',
       'public.lc_get_attendance_realtime_subscription_v1(text,uuid)',
       'EXECUTE'
     )
     or not pg_catalog.has_function_privilege(
       'authenticated',
       'public.lc_get_attendance_realtime_subscription_v1(text,uuid)',
       'EXECUTE'
     )
     or pg_catalog.has_table_privilege(
       'anon',
       'app_private.attendance_realtime_subscriptions',
       'SELECT'
     )
     or pg_catalog.has_table_privilege(
       'authenticated',
       'app_private.attendance_realtime_subscriptions',
       'SELECT'
     ) then
    raise exception 'Smoke Realtime: ACL da assinatura esta incorreta.';
  end if;

  -- Postgres Changes permanece deliberadamente indisponivel. A role anon nao
  -- ganha SELECT nas tabelas comerciais, e nenhuma delas entra na publication.
  foreach v_table in array array[
    'attendances',
    'good_morning_seller_settings',
    'good_morning_seller_allocations',
    'good_morning_seller_closed_days',
    'prospection_professionals',
    'prospection_store_settings',
    'prospections',
    'stores'
  ]
  loop
    if pg_catalog.has_table_privilege(
         'anon', pg_catalog.format('public.%I', v_table), 'SELECT'
       )
       or pg_catalog.has_table_privilege(
         'authenticated', pg_catalog.format('public.%I', v_table), 'SELECT'
       ) then
      raise exception 'Smoke Realtime: SELECT comercial exposto em public.%.',
        v_table;
    end if;

    if exists (
      select 1
      from pg_catalog.pg_publication_tables publication_table
      where publication_table.pubname = 'supabase_realtime'
        and publication_table.schemaname = 'public'
        and publication_table.tablename = v_table
    ) then
      raise exception 'Smoke Realtime: public.% entrou em Postgres Changes.',
        v_table;
    end if;

    if not exists (
      select 1
      from pg_catalog.pg_class relation
      join pg_catalog.pg_namespace namespace_record
        on namespace_record.oid = relation.relnamespace
      where namespace_record.nspname = 'public'
        and relation.relname = v_table
        and relation.relrowsecurity = true
        and relation.relreplident = 'd'
    ) then
      raise exception 'Smoke Realtime: RLS/replica identity inesperada em public.%.',
        v_table;
    end if;
  end loop;

  -- `leads` ja pertence a publication por uma funcionalidade legada, mas
  -- continua inacessivel ao anon/authenticated. Esta migration usa somente um
  -- trigger de Broadcast e nao amplia o acesso ao conteudo da tabela.
  if pg_catalog.has_table_privilege('anon', 'public.leads', 'SELECT')
     or pg_catalog.has_table_privilege(
       'authenticated', 'public.leads', 'SELECT'
     )
     or not exists (
       select 1
       from pg_catalog.pg_class relation
       where relation.oid = 'public.leads'::pg_catalog.regclass
         and relation.relrowsecurity = true
         and relation.relreplident = 'd'
     ) then
    raise exception 'Smoke Realtime: postura de seguranca de leads mudou.';
  end if;

  v_suffix := pg_catalog.replace(v_run_id::text, '-', '');
  v_store_token := 'qa-realtime-store-' || v_suffix;
  v_admin_token := 'qa-realtime-admin-' || v_suffix;

  select users.id
  into v_admin_id
  from public.app_users users
  where users.role::text = 'admin'
  order by users.created_at, users.id
  limit 1;

  if v_admin_id is null then
    insert into public.app_users (
      nick, nick_key, password_hash, full_name, role, is_active
    ) values (
      'qa-realtime-admin-' || v_suffix,
      'qa-realtime-admin-' || v_suffix,
      'qa-password-hash-not-used',
      'Admin QA Realtime',
      'admin',
      true
    )
    returning id into v_admin_id;
  else
    update public.app_users users
    set is_active = true
    where users.id = v_admin_id
      and users.is_active = false;
  end if;

  insert into public.stores (
    admin_user_id, name, nick, nick_key, is_active,
    lead_enabled, prospection_enabled, attendance_enabled,
    good_morning_seller_enabled
  ) values
    (
      v_admin_id,
      'Loja QA Realtime A ' || pg_catalog.left(v_suffix, 8),
      'qa-rt-a-' || v_suffix,
      'qa-rt-a-' || v_suffix,
      true, true, true, true, true
    ),
    (
      v_admin_id,
      'Loja QA Realtime B ' || pg_catalog.left(v_suffix, 8),
      'qa-rt-b-' || v_suffix,
      'qa-rt-b-' || v_suffix,
      true, true, true, true, true
    );

  select stores.id
  into v_store_a
  from public.stores stores
  where stores.nick = 'qa-rt-a-' || v_suffix;

  select stores.id
  into v_store_b
  from public.stores stores
  where stores.nick = 'qa-rt-b-' || v_suffix;

  insert into public.app_users (
    nick, nick_key, password_hash, full_name, role,
    admin_user_id, store_id, is_active
  ) values (
    'qa-realtime-store-' || v_suffix,
    'qa-realtime-store-' || v_suffix,
    'qa-password-hash-not-used',
    'Usuario Loja QA Realtime',
    'store',
    v_admin_id,
    v_store_a,
    true
  )
  returning id into v_store_user_id;

  insert into public.app_sessions (user_id, token_hash, expires_at)
  values (
    v_store_user_id,
    pg_catalog.encode(
      extensions.digest(v_store_token, 'sha256'),
      'hex'
    ),
    pg_catalog.clock_timestamp() + interval '1 hour'
  )
  returning id, expires_at
  into v_store_session_id, v_store_session_expires_at;

  insert into public.app_sessions (user_id, token_hash, expires_at)
  values (
    v_admin_id,
    pg_catalog.encode(
      extensions.digest(v_admin_token, 'sha256'),
      'hex'
    ),
    pg_catalog.clock_timestamp() + interval '1 hour'
  )
  returning id, expires_at
  into v_admin_session_id, v_admin_session_expires_at;

  -- A primeira RPC deve aproveitar a chamada para eliminar capabilities
  -- expiradas, mesmo que pertençam a outra sessao valida.
  v_expired_rpc_topic := 'lc:attendance:' || pg_catalog.encode(
    extensions.gen_random_bytes(32),
    'hex'
  );
  insert into app_private.attendance_realtime_subscriptions (
    app_session_id,
    store_id,
    topic,
    expires_at
  ) values (
    v_admin_session_id,
    v_store_a,
    v_expired_rpc_topic,
    pg_catalog.clock_timestamp() - interval '1 minute'
  );

  v_subscription_a :=
    public.lc_get_attendance_realtime_subscription_v1(
      v_store_token,
      v_store_a
    );
  v_subscription_a_again :=
    public.lc_get_attendance_realtime_subscription_v1(
      v_store_token,
      v_store_a
    );
  v_subscription_b :=
    public.lc_get_attendance_realtime_subscription_v1(
      v_admin_token,
      v_store_b
    );

  if exists (
    select 1
    from app_private.attendance_realtime_subscriptions subscription
    where subscription.topic = v_expired_rpc_topic
  ) then
    raise exception 'Smoke Realtime: RPC nao removeu capability expirada.';
  end if;

  v_topic_a := v_subscription_a->>'topic';
  v_topic_b := v_subscription_b->>'topic';

  if v_subscription_a->>'transport' is distinct from 'broadcast'
     or v_subscription_a->>'event' is distinct from 'invalidate'
     or v_subscription_a->>'store_id' is distinct from v_store_a::text
     or v_subscription_b->>'store_id' is distinct from v_store_b::text
     or coalesce((v_subscription_a->>'private')::boolean, false) is not true
     or (v_subscription_a->>'payload_version')::integer <> 1
     or v_topic_a !~ '^lc:attendance:[0-9a-f]{64}$'
     or v_topic_b !~ '^lc:attendance:[0-9a-f]{64}$'
     or v_topic_a = v_topic_b
     or v_subscription_a_again->>'topic' is distinct from v_topic_a
     or (v_subscription_a->>'expires_at')::timestamptz
       is distinct from v_store_session_expires_at
     or (v_subscription_b->>'expires_at')::timestamptz
       is distinct from v_admin_session_expires_at
     or not app_private.attendance_realtime_topic_allowed(v_topic_a) then
    raise exception 'Smoke Realtime: contrato/capability invalido: % / %.',
      v_subscription_a,
      v_subscription_b;
  end if;

  -- Uma sessao de loja nao pode obter sequer o topico de outra loja.
  v_error := null;
  begin
    perform public.lc_get_attendance_realtime_subscription_v1(
      v_store_token,
      v_store_b
    );
  exception
    when others then
      get stacked diagnostics v_error = message_text;
  end;

  if v_error is null then
    raise exception 'Smoke Realtime: sessao da Loja A assinou a Loja B.';
  end if;

  -- O emissor tambem precisa remover expiradas antes de procurar destinatarios.
  v_expired_emitter_topic := 'lc:attendance:' || pg_catalog.encode(
    extensions.gen_random_bytes(32),
    'hex'
  );
  insert into app_private.attendance_realtime_subscriptions (
    app_session_id,
    store_id,
    topic,
    expires_at
  ) values (
    v_admin_session_id,
    v_store_a,
    v_expired_emitter_topic,
    pg_catalog.clock_timestamp() - interval '1 minute'
  );

  -- Cada reset abaixo representa uma nova transacao comercial dentro deste
  -- unico smoke transacional e permite testar o dedupe isoladamente.
  perform pg_catalog.set_config(
    'app.attendance_realtime_invalidation_keys',
    '',
    true
  );

  insert into public.leads (
    admin_user_id,
    store_id,
    name,
    phone,
    visited,
    bought,
    created_by
  ) values (
    v_admin_id,
    v_store_a,
    'Lead QA Realtime',
    '11999999999',
    'Não',
    'Não',
    v_admin_id
  )
  returning id into v_lead_id;

  if exists (
    select 1
    from app_private.attendance_realtime_subscriptions subscription
    where subscription.topic = v_expired_emitter_topic
  ) then
    raise exception 'Smoke Realtime: emissor nao removeu capability expirada.';
  end if;

  select pg_catalog.count(*)
  into v_message_count
  from realtime.messages message_record
  where message_record.topic = v_topic_a
    and message_record.event = 'invalidate'
    and message_record.extension = 'broadcast'
    and message_record.private = true;

  if v_message_count <> 1 then
    raise exception 'Smoke Realtime: INSERT de Lead emitiu % mensagens na Loja A.',
      v_message_count;
  end if;

  select message_record.payload
  into v_payload
  from realtime.messages message_record
  where message_record.topic = v_topic_a
    and message_record.event = 'invalidate'
  limit 1;

  -- realtime.send acrescenta somente seu UUID tecnico de entrega (`id`).
  if (v_payload - 'id') is distinct from pg_catalog.jsonb_build_object(
       'resources', pg_catalog.jsonb_build_array('attendance'),
       'version', 1
     )
     or nullif(v_payload->>'id', '')::uuid is null then
    raise exception 'Smoke Realtime: payload de Lead divergente: %.', v_payload;
  end if;

  if exists (
    select 1
    from realtime.messages message_record
    where message_record.topic = v_topic_b
      and message_record.event = 'invalidate'
  ) then
    raise exception 'Smoke Realtime: INSERT da Loja A vazou no topico B.';
  end if;

  -- Mover uma origem entre lojas precisa invalidar OLD e NEW, sem incluir
  -- qualquer identificador de tenant no payload.
  perform pg_catalog.set_config(
    'app.attendance_realtime_invalidation_keys',
    '',
    true
  );
  update public.leads leads
  set store_id = v_store_b
  where leads.id = v_lead_id;

  select pg_catalog.count(*)
  into v_message_count
  from realtime.messages message_record
  where message_record.topic = v_topic_a
    and message_record.event = 'invalidate';
  if v_message_count <> 2 then
    raise exception 'Smoke Realtime: OLD store recebeu % mensagens.',
      v_message_count;
  end if;

  select pg_catalog.count(*)
  into v_message_count
  from realtime.messages message_record
  where message_record.topic = v_topic_b
    and message_record.event = 'invalidate';
  if v_message_count <> 1 then
    raise exception 'Smoke Realtime: NEW store recebeu % mensagens.',
      v_message_count;
  end if;

  if exists (
    select 1
    from realtime.messages message_record
    where message_record.topic in (v_topic_a, v_topic_b)
      and message_record.event = 'invalidate'
      and (message_record.payload - 'id') is distinct from
        pg_catalog.jsonb_build_object(
          'resources', pg_catalog.jsonb_build_array('attendance'),
          'version', 1
        )
  ) then
    raise exception 'Smoke Realtime: Lead emitiu recurso ou payload indevido.';
  end if;

  -- Configuracao exclusiva do Bom Dia nao deve recarregar Atendimentos.
  perform pg_catalog.set_config(
    'app.attendance_realtime_invalidation_keys',
    '',
    true
  );
  v_closed_on := pg_catalog.date_trunc(
    'week',
    current_date + interval '10 years'
  )::date;
  insert into public.good_morning_seller_closed_days (
    store_id,
    admin_user_id,
    closed_on,
    reason,
    created_by
  ) values (
    v_store_a,
    v_admin_id,
    v_closed_on,
    'Fechado para smoke Realtime',
    v_admin_id
  );

  select pg_catalog.count(*)
  into v_message_count
  from realtime.messages message_record
  where message_record.topic = v_topic_a
    and message_record.event = 'invalidate'
    and (message_record.payload - 'id') = pg_catalog.jsonb_build_object(
      'resources', pg_catalog.jsonb_build_array('morning'),
      'version', 1
    );
  if v_message_count <> 1 then
    raise exception 'Smoke Realtime: Bom Dia emitiu % payloads morning.',
      v_message_count;
  end if;

  -- Uma fonte compartilhada emite os dois recursos em uma mensagem e o segundo
  -- UPDATE da mesma loja/transacao e deduplicado.
  perform pg_catalog.set_config(
    'app.attendance_realtime_invalidation_keys',
    '',
    true
  );
  update public.stores stores
  set name = stores.name || ' alterada'
  where stores.id = v_store_a;
  update public.stores stores
  set name = stores.name || ' novamente'
  where stores.id = v_store_a;

  select pg_catalog.count(*)
  into v_message_count
  from realtime.messages message_record
  where message_record.topic = v_topic_a
    and message_record.event = 'invalidate'
    and (message_record.payload - 'id') = pg_catalog.jsonb_build_object(
      'resources', pg_catalog.jsonb_build_array('attendance', 'morning'),
      'version', 1
    );
  if v_message_count <> 1 then
    raise exception 'Smoke Realtime: recurso compartilhado/dedupe emitiu % mensagens.',
      v_message_count;
  end if;

  -- Se a sessao for prorrogada, a capability acompanha exatamente seu prazo.
  update public.app_sessions session_record
  set expires_at = pg_catalog.clock_timestamp() + interval '2 hours'
  where session_record.id = v_admin_session_id
  returning expires_at into v_admin_session_expires_at;

  if not exists (
    select 1
    from app_private.attendance_realtime_subscriptions subscription
    where subscription.app_session_id = v_admin_session_id
      and subscription.store_id = v_store_b
      and subscription.expires_at = v_admin_session_expires_at
  ) then
    raise exception 'Smoke Realtime: capability nao acompanhou a sessao.';
  end if;

  -- Revogar o modulo envia no maximo a ultima invalidacao para o canal ja
  -- aberto e apaga a capability que perdeu autorizacao na mesma transacao.
  perform pg_catalog.set_config(
    'app.attendance_realtime_invalidation_keys',
    '',
    true
  );
  update public.stores stores
  set
    attendance_enabled = false,
    good_morning_seller_enabled = false
  where stores.id = v_store_a;

  if exists (
       select 1
       from app_private.attendance_realtime_subscriptions subscription
       where subscription.app_session_id = v_store_session_id
         and subscription.store_id = v_store_a
     )
     or app_private.attendance_realtime_topic_allowed(v_topic_a) then
    raise exception 'Smoke Realtime: acesso removido manteve capability ativa.';
  end if;

  select pg_catalog.count(*)
  into v_message_count
  from realtime.messages message_record
  where message_record.topic = v_topic_a
    and message_record.event = 'invalidate'
    and (message_record.payload - 'id') = pg_catalog.jsonb_build_object(
      'resources', pg_catalog.jsonb_build_array('attendance', 'morning'),
      'version', 1
    );
  if v_message_count <> 2 then
    raise exception 'Smoke Realtime: revogacao nao emitiu a ultima invalidacao.';
  end if;

  update public.app_sessions session_record
  set revoked_at = pg_catalog.clock_timestamp()
  where session_record.id = v_admin_session_id;

  if exists (
       select 1
       from app_private.attendance_realtime_subscriptions subscription
       where subscription.app_session_id = v_admin_session_id
     )
     or app_private.attendance_realtime_topic_allowed(v_topic_b) then
    raise exception 'Smoke Realtime: sessao revogada manteve capability ativa.';
  end if;
end;
$attendance_private_realtime$;

rollback;
