-- Teste transacional dos entitlements de WhatsApp e Atendimentos.
-- Todas as entidades de QA sao revertidas ao final; nenhuma fixture permanece.
begin;

set local search_path = public, extensions;
select set_config('app.legal_gate_bypass', 'on', true);

do $$
declare
  v_suffix text := replace(gen_random_uuid()::text, '-', '');
  v_admin_id uuid;
  v_agency_id uuid := gen_random_uuid();
  v_other_agency_id uuid := gen_random_uuid();
  v_store_one_id uuid := gen_random_uuid();
  v_store_two_id uuid := gen_random_uuid();
  v_store_user_id uuid := gen_random_uuid();
  v_admin_token text := 'qa-admin-' || gen_random_uuid()::text;
  v_agency_token text := 'qa-agency-' || gen_random_uuid()::text;
  v_other_agency_token text := 'qa-agency-other-' || gen_random_uuid()::text;
  v_store_token text := 'qa-store-' || gen_random_uuid()::text;
  v_connection_id uuid;
  v_template_id uuid;
  v_campaign_id uuid;
  v_professional_id uuid;
  v_created jsonb;
  v_entitlements jsonb;
  v_workspace jsonb;
  v_attendance jsonb;
  v_before_count bigint;
  v_after_count bigint;
  v_expected_error boolean;
begin
  select id
  into v_admin_id
  from public.app_users
  where role::text = 'admin'
    and is_active = true
  limit 1;

  if v_admin_id is null then
    raise exception 'QA: nenhum Admin ativo encontrado para a transacao isolada.';
  end if;

  insert into public.app_users (
    id, nick, nick_key, password_hash, full_name, role,
    admin_user_id, store_id, store_limit,
    prospection_store_limit, whatsapp_store_limit, whatsapp_phone
  ) values
    (
      v_agency_id, 'qa_agency_' || v_suffix, 'qa_agency_' || v_suffix,
      crypt('Qa-password-3', gen_salt('bf')), 'QA Agency', 'technician',
      v_admin_id, null, 2, 0, 0, '5511999999999'
    ),
    (
      v_other_agency_id, 'qa_other_agency_' || v_suffix, 'qa_other_agency_' || v_suffix,
      crypt('Qa-password-6', gen_salt('bf')), 'QA Other Agency', 'technician',
      v_admin_id, null, 1, 0, 0, '5511977777777'
    );

  insert into public.stores (
    id, admin_user_id, technician_user_id, name, nick, nick_key,
    prospection_enabled, whatsapp_enabled
  ) values
    (
      v_store_one_id, v_admin_id, v_agency_id, 'QA Store One',
      'qa_store_one_' || v_suffix, 'qa_store_one_' || v_suffix, false, false
    ),
    (
      v_store_two_id, v_admin_id, v_agency_id, 'QA Store Two',
      'qa_store_two_' || v_suffix, 'qa_store_two_' || v_suffix, false, false
    );

  insert into public.app_users (
    id, nick, nick_key, password_hash, full_name, role,
    admin_user_id, store_id, store_limit,
    prospection_store_limit, whatsapp_store_limit
  ) values (
    v_store_user_id, 'qa_store_user_' || v_suffix, 'qa_store_user_' || v_suffix,
    crypt('Qa-password-4', gen_salt('bf')), 'QA Store User', 'store',
    v_admin_id, v_store_one_id, 0, 0, 0
  );

  insert into public.app_sessions (user_id, token_hash, expires_at)
  values
    (v_admin_id, encode(digest(v_admin_token, 'sha256'), 'hex'), now() + interval '1 hour'),
    (v_agency_id, encode(digest(v_agency_token, 'sha256'), 'hex'), now() + interval '1 hour'),
    (v_other_agency_id, encode(digest(v_other_agency_token, 'sha256'), 'hex'), now() + interval '1 hour'),
    (v_store_user_id, encode(digest(v_store_token, 'sha256'), 'hex'), now() + interval '1 hour');

  -- O Admin cria uma Agencia com todas as franquias em uma unica transacao.
  v_created := public.lc_create_technician_with_feature_plan(
    v_admin_token,
    'QA Created Agency',
    'qa_created_' || v_suffix,
    'Qa-password-5',
    3,
    '5511988888888',
    2,
    1
  );
  if coalesce((v_created->>'prospection_store_limit')::integer, -1) <> 2
     or coalesce((v_created->>'whatsapp_store_limit')::integer, -1) <> 1 then
    raise exception 'QA: a criacao atomica nao aplicou as franquias.';
  end if;

  perform public.lc_set_technician_whatsapp_limit(v_admin_token, v_agency_id, 1);

  -- A Agencia enxerga o plano e pode escolher apenas um cliente.
  perform public.lc_set_store_whatsapp_access(v_agency_token, v_store_one_id, true);
  v_entitlements := public.lc_get_whatsapp_entitlements(v_agency_token);
  if coalesce((v_entitlements #>> '{profile,whatsapp_store_limit}')::integer, -1) <> 1
     or coalesce((v_entitlements #>> '{profile,whatsapp_store_count}')::integer, -1) <> 1 then
    raise exception 'QA: contagem de entitlement WhatsApp incorreta.';
  end if;

  v_expected_error := false;
  begin
    perform public.lc_set_store_whatsapp_access(v_agency_token, v_store_two_id, true);
  exception when others then
    v_expected_error := position('Limite de clientes com WhatsApp atingido' in sqlerrm) > 0;
  end;
  if not v_expected_error then
    raise exception 'QA: a segunda ativacao deveria exceder a franquia WhatsApp.';
  end if;

  v_expected_error := false;
  begin
    perform public.lc_set_technician_whatsapp_limit(v_agency_token, v_agency_id, 2);
  exception when others then
    v_expected_error := position('Apenas o Admin' in sqlerrm) > 0;
  end;
  if not v_expected_error then
    raise exception 'QA: a Agencia conseguiu alterar a propria franquia WhatsApp.';
  end if;

  v_expected_error := false;
  begin
    perform public.lc_set_store_whatsapp_access(v_store_token, v_store_one_id, false);
  exception when others then
    v_expected_error := position('Somente o Admin ou a Agencia' in sqlerrm) > 0;
  end;
  if not v_expected_error then
    raise exception 'QA: o cliente conseguiu administrar o proprio entitlement.';
  end if;

  v_expected_error := false;
  begin
    perform public.lc_set_store_whatsapp_access(v_other_agency_token, v_store_one_id, false);
  exception when others then
    v_expected_error := position('Cliente nao encontrado ou sem permissao' in sqlerrm) > 0;
  end;
  if not v_expected_error then
    raise exception 'QA: o isolamento entre Agencias falhou.';
  end if;

  -- Reduzir abaixo do uso nao desliga dados; somente impede a proxima ativacao.
  perform public.lc_set_technician_whatsapp_limit(v_admin_token, v_agency_id, 0);
  if not (select whatsapp_enabled from public.stores where id = v_store_one_id) then
    raise exception 'QA: reduzir a franquia desligou um cliente automaticamente.';
  end if;
  perform public.lc_set_store_whatsapp_access(v_agency_token, v_store_one_id, false);

  v_expected_error := false;
  begin
    perform public.lc_set_store_whatsapp_access(v_agency_token, v_store_one_id, true);
  exception when others then
    v_expected_error := position('Limite de clientes com WhatsApp atingido' in sqlerrm) > 0;
  end;
  if not v_expected_error then
    raise exception 'QA: uma cota zero permitiu nova ativacao WhatsApp.';
  end if;

  perform public.lc_set_technician_whatsapp_limit(v_admin_token, v_agency_id, 1);
  perform public.lc_set_store_whatsapp_access(v_agency_token, v_store_one_id, true);

  -- O guard server-side autoriza a loja licenciada, mas nao sua configuracao.
  if not public.wa_assert_store_access(v_store_token, v_store_one_id, false) then
    raise exception 'QA: a loja licenciada nao conseguiu usar o WhatsApp.';
  end if;
  v_expected_error := false;
  begin
    perform public.wa_assert_store_access(v_store_token, v_store_one_id, true);
  exception when others then
    v_expected_error := position('sem acesso ao WhatsApp' in sqlerrm) > 0;
  end;
  if not v_expected_error then
    raise exception 'QA: a loja conseguiu configurar a integracao da Agencia.';
  end if;

  -- A revogacao desconecta sem apagar a conexao e a reativacao nao a religa.
  insert into public.whatsapp_connections (
    admin_user_id, store_id, name, phone_number_id,
    business_account_id, app_id, status
  ) values (
    v_admin_id, v_store_one_id, 'QA Connection',
    'qa-phone-' || v_suffix, 'qa-business-' || v_suffix,
    'qa-app-' || v_suffix, 'connected'
  ) returning id into v_connection_id;

  insert into public.whatsapp_templates (
    admin_user_id, store_id, connection_id,
    name, language_code, category, status
  ) values (
    v_admin_id, v_store_one_id, v_connection_id,
    'qa_template_' || v_suffix, 'pt_BR', 'MARKETING', 'APPROVED'
  ) returning id into v_template_id;

  insert into public.whatsapp_campaigns (
    admin_user_id, store_id, connection_id,
    template_id, name, status, started_at
  ) values (
    v_admin_id, v_store_one_id, v_connection_id,
    v_template_id, 'QA Campaign', 'running', now()
  ) returning id into v_campaign_id;

  perform public.lc_set_store_whatsapp_access(v_agency_token, v_store_one_id, false);
  if (select status from public.whatsapp_connections where id = v_connection_id) <> 'disconnected' then
    raise exception 'QA: a conexao nao foi suspensa na revogacao.';
  end if;
  if not exists (select 1 from public.whatsapp_connections where id = v_connection_id) then
    raise exception 'QA: a conexao foi apagada na revogacao.';
  end if;
  if (select status from public.whatsapp_campaigns where id = v_campaign_id) <> 'paused' then
    raise exception 'QA: a campanha nao foi pausada na revogacao.';
  end if;
  if not exists (select 1 from public.whatsapp_campaigns where id = v_campaign_id) then
    raise exception 'QA: a campanha foi apagada na revogacao.';
  end if;

  v_expected_error := false;
  begin
    update public.whatsapp_connections set status = 'connected' where id = v_connection_id;
  exception when others then
    v_expected_error := position('Acesso ao WhatsApp nao esta liberado' in sqlerrm) > 0;
  end;
  if not v_expected_error then
    raise exception 'QA: uma conexao bloqueada voltou ao estado conectado.';
  end if;

  perform public.lc_set_store_whatsapp_access(v_agency_token, v_store_one_id, true);
  if (select status from public.whatsapp_connections where id = v_connection_id) <> 'disconnected' then
    raise exception 'QA: reativar a licenca religou uma conexao sem validacao.';
  end if;
  if (select status from public.whatsapp_campaigns where id = v_campaign_id) <> 'paused' then
    raise exception 'QA: reativar a licenca retomou uma campanha automaticamente.';
  end if;

  -- Atendimentos usa exatamente o mesmo entitlement de Prospeccoes.
  perform public.lc_set_technician_prospection_limit(v_admin_token, v_agency_id, 1);
  perform public.lc_set_store_prospection_access(v_agency_token, v_store_one_id, true);
  insert into public.prospection_professionals (id, store_id, admin_user_id, name)
  values (gen_random_uuid(), v_store_one_id, v_admin_id, 'QA Professional')
  returning id into v_professional_id;

  v_workspace := public.lc_get_attendance_workspace(v_agency_token, v_store_one_id);
  v_attendance := public.lc_upsert_attendance(
    v_agency_token,
    v_store_one_id,
    'QA Professional',
    'QA Customer',
    '11999999999',
    'QA entitlement attendance',
    'budget',
    100,
    null,
    null,
    gen_random_uuid()::text
  );
  select count(*) into v_before_count
  from public.attendances
  where store_id = v_store_one_id;
  if v_before_count <> 1 then
    raise exception 'QA: o atendimento de controle nao foi salvo.';
  end if;

  perform public.lc_set_store_prospection_access(v_agency_token, v_store_one_id, false);
  if app_private.attendance_store_allowed(
    v_admin_id, v_agency_id, 'technician', null, v_store_one_id
  ) then
    raise exception 'QA: Atendimentos continuou liberado sem Prospeccoes.';
  end if;
  v_expected_error := false;
  begin
    v_workspace := public.lc_get_attendance_workspace(v_agency_token, v_store_one_id);
  exception when others then
    v_expected_error := lower(sqlerrm) like '%sem permiss%';
  end;
  if not v_expected_error then
    raise exception 'QA: a RPC de Atendimentos ignorou o bloqueio de Prospeccoes.';
  end if;

  v_expected_error := false;
  begin
    perform public.lc_list_attendances(
      v_agency_token,
      v_store_one_id,
      null,
      null,
      null,
      null,
      null,
      null,
      50,
      0
    );
  exception when others then
    v_expected_error := lower(sqlerrm) like '%sem permiss%';
  end;
  if not v_expected_error then
    raise exception 'QA: a listagem de Atendimentos ignorou o bloqueio de Prospeccoes.';
  end if;

  v_expected_error := false;
  begin
    perform public.lc_upsert_attendance(
      v_agency_token,
      v_store_one_id,
      'QA Professional',
      'QA Blocked Customer',
      '11988887777',
      'QA blocked write',
      'other',
      10,
      null,
      null,
      gen_random_uuid()::text
    );
  exception when others then
    v_expected_error := lower(sqlerrm) like '%sem permiss%';
  end;
  if not v_expected_error then
    raise exception 'QA: a gravacao de Atendimentos ignorou o bloqueio de Prospeccoes.';
  end if;
  select count(*) into v_after_count
  from public.attendances
  where store_id = v_store_one_id;
  if v_after_count <> v_before_count then
    raise exception 'QA: bloquear Prospeccoes apagou Atendimentos.';
  end if;
  if not (select whatsapp_enabled from public.stores where id = v_store_one_id) then
    raise exception 'QA: bloquear Prospeccoes bloqueou o WhatsApp independente.';
  end if;

  perform public.lc_set_store_prospection_access(v_agency_token, v_store_one_id, true);
  v_workspace := public.lc_get_attendance_workspace(v_agency_token, v_store_one_id);
  perform public.lc_set_store_whatsapp_access(v_agency_token, v_store_one_id, false);
  if not (select prospection_enabled from public.stores where id = v_store_one_id) then
    raise exception 'QA: bloquear WhatsApp bloqueou Prospeccoes/Atendimentos.';
  end if;

  -- A edicao atomica da loja nao pode deixar nome/flags parcialmente salvos.
  perform public.lc_set_technician_whatsapp_limit(v_admin_token, v_agency_id, 0);
  v_expected_error := false;
  begin
    perform public.lc_update_store_with_feature_access(
      v_agency_token,
      v_store_one_id,
      'QA Store Partial Change',
      'qa_store_one_' || v_suffix,
      null,
      v_agency_id,
      false,
      true
    );
  exception when others then
    v_expected_error := position('Limite de clientes com WhatsApp atingido' in sqlerrm) > 0;
  end;
  if not v_expected_error then
    raise exception 'QA: a edicao atomica deveria falhar pela franquia WhatsApp.';
  end if;
  if exists (
    select 1
    from public.stores
    where id = v_store_one_id
      and (name <> 'QA Store One' or prospection_enabled is not true or whatsapp_enabled is not false)
  ) then
    raise exception 'QA: a edicao atomica deixou alteracoes parciais.';
  end if;

  perform public.lc_set_technician_whatsapp_limit(v_admin_token, v_agency_id, 1);
  perform public.lc_update_store_with_feature_access(
    v_agency_token,
    v_store_one_id,
    'QA Store Atomic',
    'qa_store_one_' || v_suffix,
    null,
    v_agency_id,
    true,
    true
  );
  if exists (
    select 1
    from public.stores
    where id = v_store_one_id
      and (name <> 'QA Store Atomic' or prospection_enabled is not true or whatsapp_enabled is not true)
  ) then
    raise exception 'QA: a edicao atomica valida nao aplicou os dois acessos.';
  end if;

  -- Atualizacao atomica reduz o total e as duas franquias sem violar constraints.
  v_created := public.lc_update_technician_with_feature_plan(
    v_admin_token,
    v_agency_id,
    'QA Agency Updated',
    'qa_agency_' || v_suffix,
    null,
    0,
    '5511999999999',
    0,
    0
  );
  if exists (
    select 1
    from public.app_users
    where id = v_agency_id
      and (store_limit <> 0 or prospection_store_limit <> 0 or whatsapp_store_limit <> 0)
  ) then
    raise exception 'QA: a reducao atomica deixou limites inconsistentes.';
  end if;

  -- Mesmo acima do novo plano, desativar continua permitido e reativar nao.
  perform public.lc_set_store_prospection_access(v_agency_token, v_store_one_id, false);
  perform public.lc_set_store_whatsapp_access(v_agency_token, v_store_one_id, false);
end;
$$;

rollback;
