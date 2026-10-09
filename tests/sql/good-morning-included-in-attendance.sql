-- Integracao transacional do bundle Bom Dia Vendedor / Atendimento.
-- Requer 20261009135343_include_good_morning_in_additional_modules.sql.
-- Usa apenas fixtures sinteticas e reverte tudo no ROLLBACK final.
begin;
set local lock_timeout = '10s';
set local statement_timeout = '120s';
select pg_catalog.set_config('app.legal_gate_bypass', 'on', true);

do $bundle_test$
declare
  v_suffix text := replace(extensions.gen_random_uuid()::text, '-', '');
  v_admin_id uuid;
  v_agency_a uuid;
  v_agency_b uuid;
  v_store_a uuid;
  v_store_b uuid;
  v_store_c uuid;
  v_admin_token text;
  v_agency_token text;
  v_other_agency_token text;
  v_result jsonb;
  v_error text;
begin
  select id into v_admin_id
  from public.app_users where role::text = 'admin'
  order by created_at, id limit 1;
  if v_admin_id is null then
    insert into public.app_users (
      nick, nick_key, password_hash, full_name, role, is_active
    ) values (
      'qa-bundle-admin-' || v_suffix, 'qa-bundle-admin-' || v_suffix,
      'qa-unused-password', 'Admin QA Bundle', 'admin', true
    ) returning id into v_admin_id;
  else
    update public.app_users set is_active = true where id = v_admin_id;
  end if;
  v_admin_token := 'qa-bundle-admin-token-' || v_suffix;
  insert into public.app_sessions (user_id, token_hash, expires_at)
  values (v_admin_id, encode(extensions.digest(v_admin_token, 'sha256'), 'hex'), now() + interval '1 hour');

  -- O wrapper antigo aceita ate uma cota Bom Dia invalida, sem altera-la
  -- nem usá-la para liberar privilegios. A cota adicional continua validada.
  v_result := public.lc_create_technician_with_all_feature_plan(
    v_admin_token, 'Agencia QA Bundle A', 'qa-bundle-a-' || v_suffix,
    'qa-bundle-password', 4, 2, -500
  );
  v_agency_a := (v_result->>'id')::uuid;
  v_result := public.lc_create_technician_with_feature_plan(
    v_admin_token, 'Agencia QA Bundle B', 'qa-bundle-b-' || v_suffix,
    'qa-bundle-password', 4, 0
  );
  v_agency_b := (v_result->>'id')::uuid;
  if (select good_morning_seller_store_limit from public.app_users where id = v_agency_a) <> 0 then
    raise exception 'A cota legada deveria permanecer sem efeito.';
  end if;
  v_agency_token := 'qa-bundle-a-token-' || v_suffix;
  v_other_agency_token := 'qa-bundle-b-token-' || v_suffix;
  insert into public.app_sessions (user_id, token_hash, expires_at) values
    (v_agency_a, encode(extensions.digest(v_agency_token, 'sha256'), 'hex'), now() + interval '1 hour'),
    (v_agency_b, encode(extensions.digest(v_other_agency_token, 'sha256'), 'hex'), now() + interval '1 hour');

  insert into public.stores (
    admin_user_id, technician_user_id, name, nick, nick_key, is_active,
    lead_enabled, prospection_enabled, attendance_enabled,
    good_morning_seller_enabled
  ) values
    (v_admin_id, v_agency_a, 'Loja QA Bundle A', 'qa-bundle-store-a-' || v_suffix,
      'qa-bundle-store-a-' || v_suffix, true, true, false, false, true),
    (v_admin_id, v_agency_a, 'Loja QA Bundle B', 'qa-bundle-store-b-' || v_suffix,
      'qa-bundle-store-b-' || v_suffix, true, true, false, false, false),
    (v_admin_id, v_agency_a, 'Loja QA Bundle C', 'qa-bundle-store-c-' || v_suffix,
      'qa-bundle-store-c-' || v_suffix, true, true, false, false, false);
  select id into v_store_a from public.stores where nick_key = 'qa-bundle-store-a-' || v_suffix;
  select id into v_store_b from public.stores where nick_key = 'qa-bundle-store-b-' || v_suffix;
  select id into v_store_c from public.stores where nick_key = 'qa-bundle-store-c-' || v_suffix;
  insert into public.app_users (
    admin_user_id, store_id, nick, nick_key, password_hash, full_name, role, is_active
  ) values
    (v_admin_id, v_store_a, 'qa-bundle-store-a-' || v_suffix, 'qa-bundle-store-a-' || v_suffix,
      'qa-unused-password', 'Loja QA Bundle A', 'store', true),
    (v_admin_id, v_store_b, 'qa-bundle-store-b-' || v_suffix, 'qa-bundle-store-b-' || v_suffix,
      'qa-unused-password', 'Loja QA Bundle B', 'store', true),
    (v_admin_id, v_store_c, 'qa-bundle-store-c-' || v_suffix, 'qa-bundle-store-c-' || v_suffix,
      'qa-unused-password', 'Loja QA Bundle C', 'store', true);
  perform public.lc_set_store_agency_accesses(v_admin_token, v_store_a, array[v_agency_a]);
  perform public.lc_set_store_agency_accesses(v_admin_token, v_store_b, array[v_agency_a]);
  perform public.lc_set_store_agency_accesses(v_admin_token, v_store_c, array[v_agency_a]);
  if (select good_morning_seller_enabled from public.stores where id = v_store_a) then
    raise exception 'Bom Dia nao pode ficar ativo sem Atendimento, mesmo via insert antigo.';
  end if;

  perform public.lc_set_store_attendance_access(v_agency_token, v_store_a, true);
  if not (select good_morning_seller_enabled from public.stores where id = v_store_a) then
    raise exception 'Atendimento deve incluir Bom Dia mesmo com cota legada zero.';
  end if;
  if not app_private.good_morning_seller_store_allowed(v_admin_id, v_agency_a, 'technician', null, v_store_a)
     or not app_private.good_morning_seller_store_allowed(v_admin_id, v_admin_id, 'admin', null, v_store_a)
     or not app_private.good_morning_seller_store_allowed(v_admin_id, extensions.gen_random_uuid(), 'store', v_store_a, v_store_a)
     or app_private.good_morning_seller_store_allowed(v_admin_id, v_agency_b, 'technician', null, v_store_a) then
    raise exception 'O bundle deve preservar ACL Admin/Agencia/Loja e isolamento da carteira.';
  end if;
  perform public.lc_set_store_prospection_access(v_agency_token, v_store_a, true);
  v_result := public.lc_get_prospection_entitlements(v_agency_token);
  if (v_result#>>'{profile,premium_store_count}')::integer <> 1
     or (v_result#>>'{profile,module_access_version}')::integer <> 3
     or (v_result#>>'{profile,good_morning_included_in_premium}')::boolean is distinct from true
     or (v_result#>>'{profile,good_morning_seller_store_limit}')::integer <> 2 then
    raise exception 'Dois modulos na mesma loja devem usar uma unica cota adicional v3.';
  end if;

  perform public.lc_set_store_good_morning_seller_access(v_agency_token, v_store_a, false);
  perform public.lc_set_technician_good_morning_seller_limit(v_admin_token, v_agency_a, -999);
  if not (select good_morning_seller_enabled from public.stores where id = v_store_a)
     or (select prospection_store_limit from public.app_users where id = v_agency_a) <> 2 then
    raise exception 'Setters legados nao podem retirar o bundle nem alterar a cota adicional.';
  end if;
  perform public.lc_set_store_prospection_access(v_agency_token, v_store_b, true);
  v_error := null;
  begin
    perform public.lc_set_store_attendance_access(v_agency_token, v_store_c, true);
  exception when others then v_error := sqlerrm;
  end;
  if v_error is null or position('premium' in lower(v_error)) = 0
     or (select attendance_enabled or good_morning_seller_enabled from public.stores where id = v_store_c) then
    raise exception 'Terceira loja adicional deve ser barrada com rollback pela cota premium: %', v_error;
  end if;

  -- Valor legado alto nao bloqueia downgrade do plano canonico.
  update public.app_users set good_morning_seller_store_limit = 4 where id = v_agency_a;
  perform public.lc_update_technician_with_feature_plan(
    v_admin_token, v_agency_a, 'Agencia QA Bundle A', 'qa-bundle-a-' || v_suffix,
    null, 3, 1
  );
  -- Mesmo com duas lojas premium e nova cota 1, trocar modulos da loja ja
  -- licenciada preserva a uniao e nao exige outra ativacao.
  perform public.lc_update_store_with_module_access_v2(
    v_agency_token, v_store_a, 'Loja QA Bundle A', 'qa-bundle-store-a-' || v_suffix,
    null, v_agency_a, true, true, false, true
  );
  if (select good_morning_seller_enabled from public.stores where id = v_store_a) then
    raise exception 'Desativar Atendimento deve desativar Bom Dia apesar da flag legada true.';
  end if;
  perform public.lc_update_store_with_module_access_v2(
    v_agency_token, v_store_a, 'Loja QA Bundle A', 'qa-bundle-store-a-' || v_suffix,
    null, v_agency_a, true, false, true, false
  );
  if not (select attendance_enabled and good_morning_seller_enabled and not prospection_enabled from public.stores where id = v_store_a) then
    raise exception 'Swap sob excesso deve preservar cota e incluir Bom Dia ignorando flag legada false.';
  end if;
  perform public.lc_update_store_with_module_access_v2(
    v_agency_token, v_store_a, 'Loja QA Bundle A', 'qa-bundle-store-a-' || v_suffix,
    null, v_agency_a, true, true, false, false
  );

  -- Transferir para agencia sem cota continua proibido; toda identidade,
  -- carteira e flags anteriores devem sobreviver ao rollback da tentativa.
  v_error := null;
  begin
    perform public.lc_update_store_with_module_access_v2(
      v_admin_token, v_store_a, 'Nome que deve reverter', 'qa-bundle-store-a-' || v_suffix,
      null, v_agency_b, true, false, true, false
    );
  exception when others then v_error := sqlerrm;
  end;
  if v_error is null or position('premium' in lower(v_error)) = 0
     or not (select technician_user_id = v_agency_a and prospection_enabled and not attendance_enabled
         and name = 'Loja QA Bundle A' from public.stores where id = v_store_a)
     or not app_private.technician_can_access_store(v_admin_id, v_agency_a, v_store_a)
     or app_private.technician_can_access_store(v_admin_id, v_agency_b, v_store_a) then
    raise exception 'Transferencia sem cota deve falhar atomicamente: %', v_error;
  end if;

  -- Uma loja compartilhada consome a uniao em cada agencia vinculada.
  perform public.lc_set_store_agency_accesses(v_admin_token, v_store_c, array[v_agency_a, v_agency_b]);
  perform public.lc_set_technician_prospection_limit(v_admin_token, v_agency_a, 3);
  v_error := null;
  begin
    perform public.lc_set_store_attendance_access(v_admin_token, v_store_c, true);
  exception when others then v_error := sqlerrm;
  end;
  if v_error is null or position('premium' in lower(v_error)) = 0 then
    raise exception 'Ativacao compartilhada deve respeitar a cota da segunda agencia: %', v_error;
  end if;
  perform public.lc_set_technician_prospection_limit(v_admin_token, v_agency_b, 1);
  perform public.lc_set_store_attendance_access(v_admin_token, v_store_c, true);
  perform public.lc_set_store_prospection_access(v_admin_token, v_store_c, true);
  v_result := public.lc_get_prospection_entitlements(v_other_agency_token);
  if (v_result#>>'{profile,premium_store_count}')::integer <> 1 then
    raise exception 'A loja compartilhada com dois modulos deve consumir apenas uma cota na segunda agencia.';
  end if;
  perform public.lc_set_store_attendance_access(v_admin_token, v_store_c, false);
  if app_private.good_morning_seller_store_allowed(v_admin_id, v_agency_b, 'technician', null, v_store_c) then
    raise exception 'Prospeccao isolada nao deve liberar Bom Dia sem Atendimento.';
  end if;
  perform public.lc_set_store_prospection_access(v_admin_token, v_store_c, false);
  v_result := public.lc_get_prospection_entitlements(v_other_agency_token);
  if (v_result#>>'{profile,premium_store_count}')::integer <> 0 then
    raise exception 'Desativar ambos os modulos deve liberar a unica cota adicional.';
  end if;

  -- Nenhum wrapper de compatibilidade pode dar a agencia poder de alterar
  -- plano ou de acessar a carteira de outra agencia.
  v_error := null;
  begin
    perform public.lc_set_technician_good_morning_seller_limit(v_agency_token, v_agency_b, 9999);
  exception when others then v_error := sqlerrm;
  end;
  if v_error is null or position('Admin' in v_error) = 0 then
    raise exception 'Setter legado de limite deve continuar exclusivo do Admin: %', v_error;
  end if;
  v_error := null;
  begin
    perform public.lc_set_store_good_morning_seller_access(v_other_agency_token, v_store_a, true);
  exception when others then v_error := sqlerrm;
  end;
  if v_error is null or position('permissao' in lower(v_error)) = 0 then
    raise exception 'Setter legado de acesso deve preservar isolamento da carteira: %', v_error;
  end if;

  -- O wrapper de plano antigo ignora quota obsoleta ate no downgrade.
  perform public.lc_update_technician_with_all_feature_plan(
    v_admin_token, v_agency_a, 'Agencia QA Bundle A', 'qa-bundle-a-' || v_suffix,
    null, 3, 2, 99999
  );
  if (select prospection_store_limit from public.app_users where id = v_agency_a) <> 2 then
    raise exception 'Wrapper antigo deve atualizar somente a cota adicional validada.';
  end if;
  raise notice 'Bundle QA OK: cota unica, defaults, ACL, legado, downgrade, swaps, transferencia e multiagencia.';
end;
$bundle_test$;

rollback;
