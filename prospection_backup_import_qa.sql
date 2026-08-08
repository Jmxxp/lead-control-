-- QA transacional do importador de backup do Prospec.
-- Todas as fixtures e importacoes sao revertidas ao final.

begin;

set local search_path = public, extensions;
select set_config('app.legal_gate_bypass', 'on', true);

do $$
declare
  v_suffix text := replace(gen_random_uuid()::text, '-', '');
  v_admin_id uuid;
  v_agency_id uuid := gen_random_uuid();
  v_other_agency_id uuid := gen_random_uuid();
  v_store_id uuid := gen_random_uuid();
  v_store_user_id uuid := gen_random_uuid();
  v_admin_token text := 'qa-import-admin-' || gen_random_uuid()::text;
  v_agency_token text := 'qa-import-agency-' || gen_random_uuid()::text;
  v_other_token text := 'qa-import-other-' || gen_random_uuid()::text;
  v_store_token text := 'qa-import-store-' || gen_random_uuid()::text;
  v_source_store_id text := 'qa-source-' || gen_random_uuid()::text;
  v_payload jsonb;
  v_invalid_payload jsonb;
  v_preview jsonb;
  v_result jsonb;
  v_replay jsonb;
  v_expected_error boolean;
  v_before_count integer;
begin
  select id into v_admin_id
  from public.app_users
  where role::text = 'admin' and is_active = true
  limit 1;
  if v_admin_id is null then
    raise exception 'QA importacao: nenhum Admin ativo encontrado.';
  end if;

  insert into public.app_users (
    id, nick, nick_key, password_hash, full_name, role,
    admin_user_id, store_id, store_limit, prospection_store_limit
  ) values
    (
      v_agency_id, 'qa_import_agency_' || v_suffix, 'qa_import_agency_' || v_suffix,
      crypt('Qa-import-1', gen_salt('bf')), 'QA Import Agency', 'technician',
      v_admin_id, null, 1, 1
    ),
    (
      v_other_agency_id, 'qa_import_other_' || v_suffix, 'qa_import_other_' || v_suffix,
      crypt('Qa-import-2', gen_salt('bf')), 'QA Import Other Agency', 'technician',
      v_admin_id, null, 1, 1
    );

  insert into public.stores (
    id, admin_user_id, technician_user_id, name, nick, nick_key, prospection_enabled
  ) values (
    v_store_id, v_admin_id, v_agency_id, 'QA Import Target',
    'qa_import_store_' || v_suffix, 'qa_import_store_' || v_suffix, true
  );

  insert into public.app_users (
    id, nick, nick_key, password_hash, full_name, role,
    admin_user_id, store_id, store_limit, prospection_store_limit
  ) values (
    v_store_user_id, 'qa_import_client_' || v_suffix, 'qa_import_client_' || v_suffix,
    crypt('Qa-import-3', gen_salt('bf')), 'QA Import Client', 'store',
    v_admin_id, v_store_id, 0, 0
  );

  insert into public.app_sessions (user_id, token_hash, expires_at) values
    (v_admin_id, encode(digest(v_admin_token, 'sha256'), 'hex'), now() + interval '1 hour'),
    (v_agency_id, encode(digest(v_agency_token, 'sha256'), 'hex'), now() + interval '1 hour'),
    (v_other_agency_id, encode(digest(v_other_token, 'sha256'), 'hex'), now() + interval '1 hour'),
    (v_store_user_id, encode(digest(v_store_token, 'sha256'), 'hex'), now() + interval '1 hour');

  v_payload := jsonb_build_object(
    'format', 'prospec-backup',
    'schema_version', 1,
    'exported_at', now(),
    'integrity', jsonb_build_object('import_ready', true),
    'application', jsonb_build_object('bonus_rules', jsonb_build_object(
      'minimum_purchase_value_exclusive', 350,
      'amount_per_sale', 25
    )),
    'data', jsonb_build_object('stores', jsonb_build_array(jsonb_build_object(
      'id', v_source_store_id,
      'name', 'Nome que nao pode substituir o destino',
      'username', 'login-que-nao-pode-ser-importado',
      'daily_goal', 7,
      'tags', jsonb_build_array(jsonb_build_object('id', 'tag-one', 'label', 'Aniversario')),
      'professionals', jsonb_build_array(jsonb_build_object(
        'id', 'professional-one',
        'name', 'Ana QA',
        'is_active', true,
        'created_at', now() - interval '1 year',
        'updated_at', now() - interval '1 day'
      )),
      'prospects', jsonb_build_array(
        jsonb_build_object(
          'id', 'prospect-one',
          'store_id', v_source_store_id,
          'name', null,
          'phone', '(11) 90000-0000',
          'cpf', null,
          'notes', 'Registro sintetico de QA',
          'probability', 'blue',
          'tags', jsonb_build_array('Aniversario', 'Captados'),
          'professional_id', 'professional-one',
          'professional_name_snapshot', 'Ana QA',
          'created_at', now() - interval '2 days',
          'updated_at', now() - interval '1 day',
          'returned_at', now() - interval '12 hours',
          'purchased_at', now() - interval '10 hours',
          'purchase_value', 499.90,
          'purchase_os', 'OS-QA-1'
        ),
        jsonb_build_object(
          'id', 'prospect-expired',
          'store_id', v_source_store_id,
          'name', 'Expirado QA',
          'phone', null,
          'probability', 'red',
          'tags', jsonb_build_array('Captados'),
          'professional_id', 'professional-one',
          'created_at', now() - interval '3 years',
          'updated_at', now() - interval '3 years',
          'returned_at', null,
          'purchased_at', null,
          'purchase_value', null,
          'purchase_os', null
        )
      )
    )))
  );

  -- Admin e Agencia podem validar; validar nao grava nada.
  v_preview := public.lc_import_prospec_backup(v_admin_token, v_store_id, v_payload, true);
  if coalesce((v_preview #>> '{counts,prospects,total}')::integer, -1) <> 2
     or coalesce((v_preview #>> '{counts,prospects,eligible}')::integer, -1) <> 1
     or coalesce((v_preview #>> '{counts,prospects,skipped_expired}')::integer, -1) <> 1
     or coalesce((v_preview #>> '{counts,tags,total}')::integer, -1) <> 2
     or coalesce((v_preview #>> '{counts,tags,recovered_from_history}')::integer, -1) <> 1
     or coalesce((v_preview #>> '{counts,normalized,missing_names}')::integer, -1) <> 1 then
    raise exception 'QA importacao: a previa retornou contagens incorretas: %', v_preview;
  end if;
  if exists (select 1 from public.prospections where store_id = v_store_id) then
    raise exception 'QA importacao: a validacao gravou uma prospeccao.';
  end if;

  perform public.lc_import_prospec_backup(v_agency_token, v_store_id, v_payload, true);

  -- Cliente e outra Agencia nao podem importar na loja.
  v_expected_error := false;
  begin
    perform public.lc_import_prospec_backup(v_store_token, v_store_id, v_payload, true);
  exception when others then
    v_expected_error := position('Apenas o Admin ou a Agencia' in sqlerrm) > 0;
  end;
  if not v_expected_error then raise exception 'QA importacao: o Cliente conseguiu validar um backup.'; end if;

  v_expected_error := false;
  begin
    perform public.lc_import_prospec_backup(v_other_token, v_store_id, v_payload, true);
  exception when others then
    v_expected_error := position('sem permissao' in lower(sqlerrm)) > 0;
  end;
  if not v_expected_error then raise exception 'QA importacao: outra Agencia acessou a loja.'; end if;

  v_result := public.lc_import_prospec_backup(v_agency_token, v_store_id, v_payload, false);
  if coalesce((v_result #>> '{counts,prospects,inserted}')::integer, -1) <> 1
     or coalesce((v_result #>> '{counts,professionals,created}')::integer, -1) <> 1
     or coalesce((v_result #>> '{counts,tags,created}')::integer, -1) <> 2 then
    raise exception 'QA importacao: o resultado da gravacao esta incorreto: %', v_result;
  end if;

  if (select name from public.stores where id = v_store_id) <> 'QA Import Target'
     or (select nick from public.stores where id = v_store_id) <> 'qa_import_store_' || v_suffix then
    raise exception 'QA importacao: identidade/login da loja foram alterados.';
  end if;
  if not exists (
    select 1
    from public.prospections pr
    join public.prospection_professionals pp on pp.id = pr.professional_id
    where pr.store_id = v_store_id
      and pr.import_source_id = 'prospect-one'
      and pr.name like 'Contato importado · %'
      and pr.tags @> array['Aniversario', 'Captados']::text[]
      and pp.name = 'Ana QA'
      and pr.returned_at is not null
      and pr.purchased_at is not null
      and pr.purchase_amount = 499.90
      and pr.purchase_order = 'OS-QA-1'
  ) then
    raise exception 'QA importacao: o registro nao preservou os dados e vinculos.';
  end if;
  if (select count(*) from public.prospections where store_id = v_store_id) <> 1 then
    raise exception 'QA importacao: registro expirado foi importado.';
  end if;
  if not exists (
    select 1 from public.prospection_store_settings
    where store_id = v_store_id and daily_goal = 7 and bonus_minimum = 350 and bonus_amount = 25
  ) then
    raise exception 'QA importacao: meta e bonificacao nao foram aplicadas.';
  end if;

  -- Repetir o mesmo arquivo nao duplica nada.
  v_replay := public.lc_import_prospec_backup(v_agency_token, v_store_id, v_payload, false);
  if coalesce((v_replay->>'already_imported')::boolean, false) is not true
     or coalesce((v_replay #>> '{counts,prospects,inserted}')::integer, -1) <> 0
     or coalesce((v_replay #>> '{counts,prospects,unchanged}')::integer, -1) <> 1
     or (select count(*) from public.prospections where store_id = v_store_id) <> 1
     or (select count(*) from public.prospection_import_batches where store_id = v_store_id) <> 1 then
    raise exception 'QA importacao: repeticao do backup nao foi idempotente.';
  end if;

  -- Payload invalido falha inteiro e nao altera o lote existente.
  select count(*) into v_before_count from public.prospections where store_id = v_store_id;
  v_invalid_payload := jsonb_set(v_payload, '{data,stores,0,prospects,0,probability}', '"purple"'::jsonb);
  v_expected_error := false;
  begin
    perform public.lc_import_prospec_backup(v_agency_token, v_store_id, v_invalid_payload, false);
  exception when others then
    v_expected_error := position('Probabilidade invalida' in sqlerrm) > 0;
  end;
  if not v_expected_error
     or (select count(*) from public.prospections where store_id = v_store_id) <> v_before_count then
    raise exception 'QA importacao: payload invalido nao foi revertido integralmente.';
  end if;
end;
$$;

rollback;
