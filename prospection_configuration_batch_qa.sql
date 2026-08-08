-- QA transacional do salvamento batch da configuracao de Prospeccoes.
-- Execute somente depois de prospection_configuration_batch_update.sql.
-- Todas as fixtures e alteracoes sao revertidas ao final.

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

  v_category_one_id uuid := gen_random_uuid();
  v_category_two_id uuid := gen_random_uuid();
  v_category_delete_id uuid := gen_random_uuid();
  v_tag_one_id uuid := gen_random_uuid();
  v_tag_two_id uuid := gen_random_uuid();
  v_tag_delete_id uuid := gen_random_uuid();
  v_tag_cascade_id uuid := gen_random_uuid();
  v_professional_one_id uuid := gen_random_uuid();
  v_professional_two_id uuid := gen_random_uuid();
  v_prospection_id uuid := gen_random_uuid();

  v_admin_token text := 'qa-config-admin-' || gen_random_uuid()::text;
  v_agency_token text := 'qa-config-agency-' || gen_random_uuid()::text;
  v_other_agency_token text := 'qa-config-other-' || gen_random_uuid()::text;
  v_store_token text := 'qa-config-store-' || gen_random_uuid()::text;

  v_revision text;
  v_read_revision text;
  v_payload jsonb;
  v_incomplete_payload jsonb;
  v_stale_payload jsonb;
  v_result jsonb;
  v_expected_error boolean;
  v_new_category_id uuid;
  v_new_tag_id uuid;
  v_new_professional_id uuid;
begin
  select id into v_admin_id
  from public.app_users
  where role::text = 'admin'
    and is_active = true
  limit 1;

  if v_admin_id is null then
    raise exception 'QA configuracao: nenhum Admin ativo encontrado.';
  end if;

  insert into public.app_users (
    id, nick, nick_key, password_hash, full_name, role,
    admin_user_id, store_id, store_limit, prospection_store_limit
  ) values
    (
      v_agency_id,
      'qa_config_agency_' || v_suffix,
      'qa_config_agency_' || v_suffix,
      crypt('Qa-config-1', gen_salt('bf')),
      'QA Config Agency',
      'technician',
      v_admin_id,
      null,
      1,
      1
    ),
    (
      v_other_agency_id,
      'qa_config_other_' || v_suffix,
      'qa_config_other_' || v_suffix,
      crypt('Qa-config-2', gen_salt('bf')),
      'QA Config Other Agency',
      'technician',
      v_admin_id,
      null,
      1,
      1
    );

  insert into public.stores (
    id, admin_user_id, technician_user_id, name, nick, nick_key,
    prospection_enabled
  ) values (
    v_store_id,
    v_admin_id,
    v_agency_id,
    'QA Config Store',
    'qa_config_store_' || v_suffix,
    'qa_config_store_' || v_suffix,
    true
  );

  insert into public.app_users (
    id, nick, nick_key, password_hash, full_name, role,
    admin_user_id, store_id, store_limit, prospection_store_limit
  ) values (
    v_store_user_id,
    'qa_config_client_' || v_suffix,
    'qa_config_client_' || v_suffix,
    crypt('Qa-config-3', gen_salt('bf')),
    'QA Config Client',
    'store',
    v_admin_id,
    v_store_id,
    0,
    0
  );

  insert into public.app_sessions (user_id, token_hash, expires_at) values
    (v_admin_id, encode(digest(v_admin_token, 'sha256'), 'hex'), now() + interval '1 hour'),
    (v_agency_id, encode(digest(v_agency_token, 'sha256'), 'hex'), now() + interval '1 hour'),
    (v_other_agency_id, encode(digest(v_other_agency_token, 'sha256'), 'hex'), now() + interval '1 hour'),
    (v_store_user_id, encode(digest(v_store_token, 'sha256'), 'hex'), now() + interval '1 hour');

  insert into public.prospection_store_settings (
    store_id, admin_user_id, daily_goal, bonus_minimum, bonus_amount,
    accent_color, logo_background_color
  ) values (
    v_store_id, v_admin_id, 15, 300, 20, '#16855f', '#ffffff'
  );

  insert into public.prospection_tag_categories (
    id, store_id, admin_user_id, name, sort_order
  ) values
    (v_category_one_id, v_store_id, v_admin_id, 'Origem', 10),
    (v_category_two_id, v_store_id, v_admin_id, 'Resultado', 20),
    (v_category_delete_id, v_store_id, v_admin_id, 'Remover categoria', 30);

  insert into public.prospection_tags (
    id, store_id, admin_user_id, category_id, label, sort_order
  ) values
    (v_tag_one_id, v_store_id, v_admin_id, v_category_one_id, 'Aniversario', 10),
    (v_tag_delete_id, v_store_id, v_admin_id, v_category_one_id, 'Etiqueta excluida', 20),
    (v_tag_two_id, v_store_id, v_admin_id, v_category_two_id, 'Mensagem', 10),
    (v_tag_cascade_id, v_store_id, v_admin_id, v_category_delete_id, 'Etiqueta em cascata', 10);

  insert into public.prospection_professionals (
    id, store_id, admin_user_id, name, is_active
  ) values
    (v_professional_one_id, v_store_id, v_admin_id, 'Ana', true),
    (v_professional_two_id, v_store_id, v_admin_id, 'Bia', true);

  insert into public.prospections (
    id, admin_user_id, store_id, name, probability, tags,
    professional_id, professional_name_snapshot, created_by, updated_by
  ) values (
    v_prospection_id,
    v_admin_id,
    v_store_id,
    'Cliente historico QA',
    'blue',
    array['Aniversario', 'Etiqueta excluida']::text[],
    v_professional_one_id,
    'Ana',
    v_agency_id,
    v_agency_id
  );

  v_revision := app_private.prospection_configuration_revision(v_store_id);

  select item.value->>'revision'
  into v_read_revision
  from jsonb_array_elements(public.lc_get_prospection_configuration(v_agency_token)->'settings') item(value)
  where item.value->>'store_id' = v_store_id::text;

  if v_read_revision is distinct from v_revision then
    raise exception 'QA configuracao: a leitura nao devolveu a revisao atual da loja.';
  end if;

  v_payload := jsonb_build_object(
    'schema_version', 1,
    'base_revision', v_revision,
    'settings', jsonb_build_object(
      'daily_goal', 22,
      'bonus_minimum', 450.50,
      'bonus_amount', 35.25,
      'accent_color', '#2463eb',
      'logo_background_color', '#f4f7fb'
    ),
    'categories', jsonb_build_array(
      jsonb_build_object(
        'id', v_category_one_id,
        'name', 'Resultado',
        'tags', jsonb_build_array(
          jsonb_build_object(
            'id', v_tag_one_id,
            'label', 'Mensagem'
          ),
          jsonb_build_object(
            'id', null,
            'client_key', 'tag-retorno',
            'label', 'Retorno'
          )
        )
      ),
      jsonb_build_object(
        'id', v_category_two_id,
        'name', 'Origem',
        'tags', jsonb_build_array(
          jsonb_build_object(
            'id', v_tag_two_id,
            'label', 'Aniversario'
          )
        )
      ),
      jsonb_build_object(
        'id', null,
        'client_key', 'category-new',
        'name', 'Nova categoria',
        'tags', jsonb_build_array(
          jsonb_build_object(
            'id', null,
            'client_key', 'tag-new',
            'label', 'Novo marcador'
          )
        )
      )
    ),
    'professionals', jsonb_build_array(
      jsonb_build_object(
        'id', v_professional_one_id,
        'name', 'Bia',
        'is_active', false
      ),
      jsonb_build_object(
        'id', v_professional_two_id,
        'name', 'Ana',
        'is_active', true
      ),
      jsonb_build_object(
        'id', null,
        'client_key', 'professional-new',
        'name', 'Carla',
        'is_active', true
      )
    ),
    'deleted_category_ids', jsonb_build_array(v_category_delete_id),
    'deleted_tag_ids', jsonb_build_array(v_tag_delete_id)
  );

  -- Cliente e Agencia alheia nunca podem configurar a loja.
  v_expected_error := false;
  begin
    perform public.lc_save_prospection_configuration(
      v_store_token, v_store_id, v_payload
    );
  exception when others then
    v_expected_error := position('sem permissao' in lower(sqlerrm)) > 0;
  end;
  if not v_expected_error then
    raise exception 'QA configuracao: o Cliente conseguiu salvar a configuracao.';
  end if;

  v_expected_error := false;
  begin
    perform public.lc_save_prospection_configuration(
      v_other_agency_token, v_store_id, v_payload
    );
  exception when others then
    v_expected_error := position('sem permissao' in lower(sqlerrm)) > 0;
  end;
  if not v_expected_error then
    raise exception 'QA configuracao: outra Agencia conseguiu acessar a loja.';
  end if;

  -- Um snapshot incompleto precisa falhar antes de mudar ate mesmo as metas.
  v_incomplete_payload := jsonb_set(
    v_payload,
    '{professionals}',
    jsonb_build_array(v_payload #> '{professionals,0}')
  );
  v_expected_error := false;
  begin
    perform public.lc_save_prospection_configuration(
      v_agency_token, v_store_id, v_incomplete_payload
    );
  exception when others then
    v_expected_error := position('lista de profissionais esta incompleta' in lower(sqlerrm)) > 0;
  end;
  if not v_expected_error
     or (select daily_goal from public.prospection_store_settings where store_id = v_store_id) <> 15 then
    raise exception 'QA configuracao: snapshot incompleto nao foi rejeitado atomicamente.';
  end if;

  -- A revisao e obrigatoria e protege uma tela antiga contra sobrescrita.
  v_expected_error := false;
  begin
    perform public.lc_save_prospection_configuration(
      v_agency_token, v_store_id, v_payload - 'base_revision'
    );
  exception when others then
    v_expected_error := position('revisao da configuracao e obrigatoria' in lower(sqlerrm)) > 0;
  end;
  if not v_expected_error then
    raise exception 'QA configuracao: snapshot sem revisao foi aceito.';
  end if;

  v_stale_payload := jsonb_set(v_payload, '{base_revision}', to_jsonb(repeat('0', 64)));
  v_expected_error := false;
  begin
    perform public.lc_save_prospection_configuration(
      v_agency_token, v_store_id, v_stale_payload
    );
  exception when others then
    v_expected_error := position('alterada em outra sessao' in lower(sqlerrm)) > 0;
  end;
  if not v_expected_error
     or (select daily_goal from public.prospection_store_settings where store_id = v_store_id) <> 15 then
    raise exception 'QA configuracao: revisao antiga nao foi rejeitada atomicamente.';
  end if;

  -- A Agencia proprietaria salva settings e todo o editor em uma transacao.
  v_result := public.lc_save_prospection_configuration(
    v_agency_token,
    v_store_id,
    v_payload
  );

  if coalesce((v_result->>'ok')::boolean, false) is not true
     or coalesce((v_result #>> '{counts,categories_created}')::integer, -1) <> 1
     or coalesce((v_result #>> '{counts,categories_deleted}')::integer, -1) <> 1
     or coalesce((v_result #>> '{counts,tags_created}')::integer, -1) <> 2
     or coalesce((v_result #>> '{counts,tags_deleted}')::integer, -1) <> 2
     or coalesce((v_result #>> '{counts,professionals_created}')::integer, -1) <> 1 then
    raise exception 'QA configuracao: contagens incorretas no resultado: %', v_result;
  end if;

  if not exists (
    select 1
    from public.prospection_store_settings ps
    where ps.store_id = v_store_id
      and ps.daily_goal = 22
      and ps.bonus_minimum = 450.50
      and ps.bonus_amount = 35.25
      and ps.accent_color = '#2463eb'
      and ps.logo_background_color = '#f4f7fb'
  ) then
    raise exception 'QA configuracao: settings nao foram salvos juntos.';
  end if;

  -- Trocas de nomes precisam vencer os indices unicos sem salvar item a item.
  if not exists (
    select 1 from public.prospection_tag_categories
    where id = v_category_one_id and name = 'Resultado' and sort_order = 10
  ) or not exists (
    select 1 from public.prospection_tag_categories
    where id = v_category_two_id and name = 'Origem' and sort_order = 20
  ) or exists (
    select 1 from public.prospection_tag_categories where id = v_category_delete_id
  ) or exists (
    select 1 from public.prospection_tags where id = v_tag_cascade_id
  ) then
    raise exception 'QA configuracao: categorias nao foram sincronizadas corretamente.';
  end if;

  if not exists (
    select 1 from public.prospection_tags
    where id = v_tag_one_id
      and category_id = v_category_one_id
      and label = 'Mensagem'
      and sort_order = 10
  ) or not exists (
    select 1 from public.prospection_tags
    where id = v_tag_two_id
      and category_id = v_category_two_id
      and label = 'Aniversario'
      and sort_order = 10
  ) or exists (
    select 1 from public.prospection_tags where id = v_tag_delete_id
  ) then
    raise exception 'QA configuracao: etiquetas nao foram sincronizadas corretamente.';
  end if;

  if not exists (
    select 1 from public.prospection_professionals
    where id = v_professional_one_id and name = 'Bia' and is_active = false
  ) or not exists (
    select 1 from public.prospection_professionals
    where id = v_professional_two_id and name = 'Ana' and is_active = true
  ) or not exists (
    select 1 from public.prospections
    where id = v_prospection_id and professional_id = v_professional_one_id
  ) then
    raise exception 'QA configuracao: profissionais ou seus vinculos historicos foram corrompidos.';
  end if;

  -- Etiquetas historicas sao snapshots imutaveis; configuracao nao reescreve
  -- registros antigos que podem ter vindo de importacao ou rotulos reutilizados.
  if not exists (
    select 1
    from public.prospections pr
    where pr.id = v_prospection_id
      and pr.tags @> array['Aniversario', 'Etiqueta excluida']::text[]
      and not (pr.tags @> array['Mensagem']::text[])
  ) then
    raise exception 'QA configuracao: etiquetas historicas foram alteradas indevidamente.';
  end if;

  v_new_category_id := (v_result->'id_map'->'categories'->>'category-new')::uuid;
  v_new_tag_id := (v_result->'id_map'->'tags'->>'tag-new')::uuid;
  v_new_professional_id := (v_result->'id_map'->'professionals'->>'professional-new')::uuid;

  if not exists (
    select 1 from public.prospection_tag_categories
    where id = v_new_category_id and store_id = v_store_id and name = 'Nova categoria'
  ) or not exists (
    select 1 from public.prospection_tags
    where id = v_new_tag_id and category_id = v_new_category_id and label = 'Novo marcador'
  ) or not exists (
    select 1 from public.prospection_professionals
    where id = v_new_professional_id and store_id = v_store_id and name = 'Carla'
  ) then
    raise exception 'QA configuracao: mapa ou criacao de novos itens esta incorreto.';
  end if;

  if coalesce(v_result->>'revision', '') = ''
     or v_result->>'revision' <> app_private.prospection_configuration_revision(v_store_id)
     or v_result->>'revision' = v_revision then
    raise exception 'QA configuracao: a revisao final nao representa o snapshot salvo.';
  end if;
end;
$$;

rollback;
