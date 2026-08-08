-- Salvamento atomico da configuracao completa de Prospeccoes.
--
-- A interface envia um snapshot completo por loja. A funcao valida todo o
-- documento antes da primeira escrita e, em caso de qualquer erro, o Postgres
-- reverte configuracoes, categorias, etiquetas e profissionais em conjunto.

begin;

alter table public.prospection_professionals
  add column if not exists archived_at timestamptz,
  add column if not exists archived_by uuid references public.app_users(id) on delete set null;

create or replace function app_private.prospection_configuration_revision(
  p_store_id uuid
)
returns text
language sql
stable
security definer
set search_path = app_private, public, extensions
as $$
  select encode(
    extensions.digest(
      jsonb_build_object(
        'settings', jsonb_build_object(
          'daily_goal', coalesce(ps.daily_goal, 15),
          'bonus_minimum', coalesce(ps.bonus_minimum, 300),
          'bonus_amount', coalesce(ps.bonus_amount, 20),
          'accent_color', coalesce(ps.accent_color, '#16855f'),
          'logo_background_color', coalesce(ps.logo_background_color, '#ffffff')
        ),
        'categories', coalesce((
          select jsonb_agg(
            jsonb_build_array(pc.id, pc.name, pc.sort_order)
            order by pc.id
          )
          from public.prospection_tag_categories pc
          where pc.store_id = p_store_id
        ), '[]'::jsonb),
        'tags', coalesce((
          select jsonb_agg(
            jsonb_build_array(pt.id, pt.category_id, pt.label, pt.sort_order)
            order by pt.id
          )
          from public.prospection_tags pt
          where pt.store_id = p_store_id
        ), '[]'::jsonb),
        'professionals', coalesce((
          select jsonb_agg(
            jsonb_build_array(pp.id, pp.name, pp.is_active)
            order by pp.id
          )
          from public.prospection_professionals pp
          where pp.store_id = p_store_id
            and pp.archived_at is null
        ), '[]'::jsonb)
      )::text,
      'sha256'
    ),
    'hex'
  )
  from (select 1) seed
  left join public.prospection_store_settings ps
    on ps.store_id = p_store_id;
$$;

-- A leitura devolve a mesma revisao usada pelo salvamento otimista. Assim uma
-- aba antiga nunca consegue sobrescrever silenciosamente uma configuracao mais
-- nova salva pelo Admin ou pela Agencia.
create or replace function app_private.rpc_get_prospection_configuration(p_session_token text)
returns jsonb
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_result jsonb;
begin
  select * into v_session from app_private.session_user(p_session_token);

  select jsonb_build_object(
    'settings', coalesce((
      select jsonb_agg(jsonb_build_object(
        'store_id', st.id,
        'daily_goal', coalesce(ps.daily_goal, 15),
        'bonus_minimum', coalesce(ps.bonus_minimum, 300),
        'bonus_amount', coalesce(ps.bonus_amount, 20),
        'accent_color', coalesce(ps.accent_color, '#16855f'),
        'logo_background_color', coalesce(ps.logo_background_color, '#ffffff'),
        'revision', app_private.prospection_configuration_revision(st.id)
      ) order by st.name)
      from public.stores st
      left join public.prospection_store_settings ps on ps.store_id = st.id
      where st.admin_user_id = v_session.admin_user_id
        and st.is_active = true
        and app_private.prospection_store_allowed(
          v_session.admin_user_id, v_session.user_id, v_session.user_role,
          v_session.user_store_id, st.id, false
        )
    ), '[]'::jsonb),
    'professionals', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', pp.id,
        'store_id', pp.store_id,
        'name', pp.name,
        'is_active', pp.is_active
      ) order by pp.name)
      from public.prospection_professionals pp
      where pp.admin_user_id = v_session.admin_user_id
        and pp.archived_at is null
        and app_private.prospection_store_allowed(
          v_session.admin_user_id, v_session.user_id, v_session.user_role,
          v_session.user_store_id, pp.store_id, false
        )
    ), '[]'::jsonb),
    'categories', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', pc.id,
        'store_id', pc.store_id,
        'name', pc.name,
        'sort_order', pc.sort_order
      ) order by pc.sort_order, pc.created_at)
      from public.prospection_tag_categories pc
      where pc.admin_user_id = v_session.admin_user_id
        and app_private.prospection_store_allowed(
          v_session.admin_user_id, v_session.user_id, v_session.user_role,
          v_session.user_store_id, pc.store_id, false
        )
    ), '[]'::jsonb),
    'tags', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', pt.id,
        'store_id', pt.store_id,
        'category_id', pt.category_id,
        'label', pt.label,
        'sort_order', pt.sort_order
      ) order by pt.sort_order, pt.created_at)
      from public.prospection_tags pt
      where pt.admin_user_id = v_session.admin_user_id
        and app_private.prospection_store_allowed(
          v_session.admin_user_id, v_session.user_id, v_session.user_role,
          v_session.user_store_id, pt.store_id, false
        )
    ), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$$;

-- Compatibilidade com telas antigas: um nome arquivado restaura a mesma
-- identidade, enquanto IDs arquivados não podem ser alterados diretamente.
create or replace function app_private.rpc_upsert_prospection_professional(
  p_session_token text,
  p_store_id uuid,
  p_professional_id uuid,
  p_name text,
  p_is_active boolean default true
)
returns uuid
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_professional_id uuid;
  v_name text;
begin
  select * into v_session from app_private.session_user(p_session_token);
  v_name := btrim(coalesce(p_name, ''));

  if not app_private.prospection_store_allowed(
    v_session.admin_user_id, v_session.user_id, v_session.user_role,
    v_session.user_store_id, p_store_id, true
  ) then
    raise exception 'Sem permissao para configurar este cliente.';
  end if;
  if length(v_name) = 0 then raise exception 'Informe o nome do profissional.'; end if;

  perform 1
  from public.stores st
  where st.id = p_store_id
    and st.admin_user_id = v_session.admin_user_id
  for update;

  if p_professional_id is null then
    select pp.id into v_professional_id
    from public.prospection_professionals pp
    where pp.store_id = p_store_id
      and pp.admin_user_id = v_session.admin_user_id
      and lower(pp.name) = lower(v_name)
    order by (pp.archived_at is null) desc, pp.created_at
    limit 1
    for update;

    if v_professional_id is null then
      insert into public.prospection_professionals (
        store_id, admin_user_id, name, is_active
      ) values (
        p_store_id, v_session.admin_user_id, v_name, coalesce(p_is_active, true)
      ) returning id into v_professional_id;
    else
      update public.prospection_professionals pp
      set name = v_name,
          is_active = coalesce(p_is_active, true),
          archived_at = null,
          archived_by = null
      where pp.id = v_professional_id;
    end if;
  else
    update public.prospection_professionals pp
    set name = v_name,
        is_active = coalesce(p_is_active, true)
    where pp.id = p_professional_id
      and pp.store_id = p_store_id
      and pp.admin_user_id = v_session.admin_user_id
      and pp.archived_at is null
    returning pp.id into v_professional_id;

    if not found then raise exception 'Profissional nao encontrado.'; end if;
  end if;

  return v_professional_id;
end;
$$;

-- O responsável selecionado recebe um lock de leitura até o fim da gravação.
-- Uma exclusão concorrente aguarda sem serializar toda a operação da loja.
create or replace function app_private.rpc_upsert_prospection(
  p_session_token text,
  p_prospection_id uuid,
  p_store_id uuid,
  p_name text,
  p_phone text default null,
  p_cpf text default null,
  p_notes text default null,
  p_probability text default 'blue',
  p_tags text[] default '{}'::text[],
  p_professional_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_store_id uuid;
  v_prospection_id uuid;
  v_professional_name text;
  v_tags text[];
begin
  select * into v_session from app_private.session_user(p_session_token);
  v_store_id := case when v_session.user_role::text = 'store' then v_session.user_store_id else p_store_id end;

  if not app_private.prospection_store_allowed(
    v_session.admin_user_id,
    v_session.user_id,
    v_session.user_role,
    v_session.user_store_id,
    v_store_id,
    false
  ) then
    raise exception 'Cliente nao encontrado ou sem permissao.';
  end if;

  if length(btrim(coalesce(p_name, ''))) = 0 then
    raise exception 'Informe o nome da prospeccao.';
  end if;

  if coalesce(p_probability, '') not in ('red', 'yellow', 'blue', 'green') then
    raise exception 'Probabilidade invalida.';
  end if;

  if p_professional_id is not null then
    select pp.name into v_professional_name
    from public.prospection_professionals pp
    where pp.id = p_professional_id
      and pp.store_id = v_store_id
      and pp.admin_user_id = v_session.admin_user_id
      and pp.is_active = true
      and pp.archived_at is null
    for share;

    if not found then
      raise exception 'Profissional nao encontrado para este cliente.';
    end if;
  end if;

  select coalesce(array_agg(pt.label order by pt.label), '{}'::text[])
  into v_tags
  from public.prospection_tags pt
  where pt.store_id = v_store_id
    and pt.admin_user_id = v_session.admin_user_id
    and pt.label = any(coalesce(p_tags, '{}'::text[]));

  if p_prospection_id is null then
    insert into public.prospections (
      admin_user_id,
      store_id,
      name,
      phone,
      cpf,
      notes,
      probability,
      tags,
      professional_id,
      professional_name_snapshot,
      created_by,
      updated_by
    ) values (
      v_session.admin_user_id,
      v_store_id,
      btrim(p_name),
      nullif(btrim(coalesce(p_phone, '')), ''),
      nullif(btrim(coalesce(p_cpf, '')), ''),
      nullif(btrim(coalesce(p_notes, '')), ''),
      p_probability,
      v_tags,
      p_professional_id,
      v_professional_name,
      v_session.user_id,
      v_session.user_id
    ) returning id into v_prospection_id;
  else
    update public.prospections pr
    set
      name = btrim(p_name),
      phone = nullif(btrim(coalesce(p_phone, '')), ''),
      cpf = nullif(btrim(coalesce(p_cpf, '')), ''),
      notes = nullif(btrim(coalesce(p_notes, '')), ''),
      probability = p_probability,
      tags = v_tags,
      professional_id = p_professional_id,
      professional_name_snapshot = v_professional_name,
      updated_by = v_session.user_id
    where pr.id = p_prospection_id
      and pr.admin_user_id = v_session.admin_user_id
      and pr.store_id = v_store_id
    returning pr.id into v_prospection_id;

    if not found then
      raise exception 'Prospeccao nao encontrada ou sem permissao.';
    end if;
  end if;

  return v_prospection_id;
end;
$$;

create or replace function app_private.rpc_save_prospection_configuration(
  p_session_token text,
  p_store_id uuid,
  p_payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_settings jsonb;
  v_categories jsonb;
  v_professionals jsonb;
  v_deleted_categories_json jsonb;
  v_deleted_tags_json jsonb;
  v_deleted_professionals_json jsonb;

  v_category_ids uuid[] := array[]::uuid[];
  v_tag_ids uuid[] := array[]::uuid[];
  v_professional_ids uuid[] := array[]::uuid[];
  v_deleted_category_ids uuid[] := array[]::uuid[];
  v_deleted_tag_ids uuid[] := array[]::uuid[];
  v_deleted_professional_ids uuid[] := array[]::uuid[];

  v_daily_goal integer;
  v_bonus_minimum numeric(12,2);
  v_bonus_amount numeric(12,2);
  v_accent_color text;
  v_logo_background_color text;
  v_expected_revision text;
  v_current_revision text;

  v_category jsonb;
  v_tag jsonb;
  v_professional jsonb;
  v_category_position bigint;
  v_tag_position bigint;
  v_category_id uuid;
  v_tag_id uuid;
  v_professional_id uuid;
  v_client_key text;
  v_name text;
  v_label text;
  v_active boolean;

  v_category_id_map jsonb := '{}'::jsonb;
  v_tag_id_map jsonb := '{}'::jsonb;
  v_professional_id_map jsonb := '{}'::jsonb;

  v_categories_created integer := 0;
  v_tags_created integer := 0;
  v_professionals_created integer := 0;
  v_professionals_restored integer := 0;
  v_professionals_archived integer := 0;
  v_categories_deleted integer := 0;
  v_tags_deleted integer := 0;
begin
  select * into v_session
  from app_private.session_user(p_session_token);

  if not app_private.prospection_store_allowed(
    v_session.admin_user_id,
    v_session.user_id,
    v_session.user_role,
    v_session.user_store_id,
    p_store_id,
    true
  ) then
    raise exception 'Sem permissao para configurar este cliente.';
  end if;

  -- Serializa salvamentos batch para a mesma loja. Os RPCs legados continuam
  -- disponiveis, mas a interface nova usa somente esta operacao atomica.
  perform 1
  from public.stores st
  where st.id = p_store_id
    and st.admin_user_id = v_session.admin_user_id
    and st.is_active = true
    and st.prospection_enabled = true
  for update;

  if not found then
    raise exception 'Cliente nao encontrado ou sem acesso a Prospeccoes.';
  end if;

  if jsonb_typeof(p_payload) is distinct from 'object' then
    raise exception 'A configuracao enviada e invalida.';
  end if;
  if coalesce(p_payload->>'schema_version', '') <> '1' then
    raise exception 'Versao de configuracao nao suportada.';
  end if;
  if jsonb_typeof(p_payload->'base_revision') is distinct from 'string'
     or (p_payload->>'base_revision') !~ '^[0-9a-f]{64}$' then
    raise exception 'A revisao da configuracao e obrigatoria. Recarregue a tela e tente novamente.';
  end if;
  if octet_length(p_payload::text) > 2097152 then
    raise exception 'A configuracao excede o limite de 2 MB.';
  end if;

  v_settings := p_payload->'settings';
  v_categories := p_payload->'categories';
  v_professionals := p_payload->'professionals';
  v_deleted_categories_json := coalesce(p_payload->'deleted_category_ids', '[]'::jsonb);
  v_deleted_tags_json := coalesce(p_payload->'deleted_tag_ids', '[]'::jsonb);
  v_deleted_professionals_json := coalesce(p_payload->'deleted_professional_ids', '[]'::jsonb);

  if jsonb_typeof(v_settings) is distinct from 'object'
     or jsonb_typeof(v_categories) is distinct from 'array'
     or jsonb_typeof(v_professionals) is distinct from 'array'
     or jsonb_typeof(v_deleted_categories_json) is distinct from 'array'
     or jsonb_typeof(v_deleted_tags_json) is distinct from 'array'
     or jsonb_typeof(v_deleted_professionals_json) is distinct from 'array' then
    raise exception 'O snapshot de configuracao esta incompleto.';
  end if;

  if jsonb_array_length(v_categories) > 100
     or jsonb_array_length(v_professionals) > 500 then
    raise exception 'A configuracao possui itens demais para uma unica loja.';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(v_categories) item(value)
    where jsonb_typeof(item.value) is distinct from 'object'
       or jsonb_typeof(item.value->'tags') is distinct from 'array'
  ) then
    raise exception 'Existe uma categoria invalida no snapshot.';
  end if;

  if (
    select count(*)
    from jsonb_array_elements(v_categories) category(value)
    cross join lateral jsonb_array_elements(category.value->'tags') tag(value)
  ) > 1000 then
    raise exception 'A configuracao possui etiquetas demais para uma unica loja.';
  end if;

  -- Campos principais e limites compativeis com as constraints remotas.
  if jsonb_typeof(v_settings->'daily_goal') is distinct from 'number'
     or jsonb_typeof(v_settings->'bonus_minimum') is distinct from 'number'
     or jsonb_typeof(v_settings->'bonus_amount') is distinct from 'number'
     or jsonb_typeof(v_settings->'accent_color') is distinct from 'string'
     or jsonb_typeof(v_settings->'logo_background_color') is distinct from 'string' then
    raise exception 'Metas, bonificacao ou cores possuem formato invalido.';
  end if;

  begin
    v_daily_goal := (v_settings->>'daily_goal')::integer;
    v_bonus_minimum := (v_settings->>'bonus_minimum')::numeric;
    v_bonus_amount := (v_settings->>'bonus_amount')::numeric;
  exception
    when numeric_value_out_of_range or invalid_text_representation then
      raise exception 'Metas ou valores de bonificacao invalidos.';
  end;

  v_accent_color := lower(btrim(v_settings->>'accent_color'));
  v_logo_background_color := lower(btrim(v_settings->>'logo_background_color'));

  if v_daily_goal not between 1 and 9999 then
    raise exception 'Informe uma meta diaria entre 1 e 9999.';
  end if;
  if v_bonus_minimum < 0 or v_bonus_minimum > 9999999999.99
     or v_bonus_amount < 0 or v_bonus_amount > 9999999999.99 then
    raise exception 'Os valores de bonificacao estao fora do limite permitido.';
  end if;
  if v_accent_color !~ '^#[0-9a-f]{6}$'
     or v_logo_background_color !~ '^#[0-9a-f]{6}$' then
    raise exception 'Informe cores validas no formato hexadecimal.';
  end if;

  -- Valida a forma de categorias, etiquetas e profissionais antes de casts.
  if exists (
    select 1
    from jsonb_array_elements(v_categories) category(value)
    where jsonb_typeof(category.value->'name') is distinct from 'string'
       or length(btrim(category.value->>'name')) not between 1 and 60
       or (
         nullif(category.value->>'id', '') is not null
         and (
           jsonb_typeof(category.value->'id') is distinct from 'string'
           or (category.value->>'id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
         )
       )
       or (
         nullif(category.value->>'id', '') is null
         and (
           jsonb_typeof(category.value->'client_key') is distinct from 'string'
           or length(btrim(category.value->>'client_key')) not between 1 and 120
         )
       )
       or (
         category.value ? 'client_key'
         and category.value->'client_key' <> 'null'::jsonb
         and (
           jsonb_typeof(category.value->'client_key') is distinct from 'string'
           or length(btrim(category.value->>'client_key')) not between 1 and 120
         )
       )
  ) then
    raise exception 'Existe uma categoria com nome, identificador ou chave invalida.';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(v_categories) category(value)
    cross join lateral jsonb_array_elements(category.value->'tags') tag(value)
    where jsonb_typeof(tag.value) is distinct from 'object'
       or jsonb_typeof(tag.value->'label') is distinct from 'string'
       or length(btrim(tag.value->>'label')) not between 1 and 60
       or (
         nullif(tag.value->>'id', '') is not null
         and (
           jsonb_typeof(tag.value->'id') is distinct from 'string'
           or (tag.value->>'id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
         )
       )
       or (
         nullif(tag.value->>'id', '') is null
         and (
           jsonb_typeof(tag.value->'client_key') is distinct from 'string'
           or length(btrim(tag.value->>'client_key')) not between 1 and 120
         )
       )
       or (
         tag.value ? 'client_key'
         and tag.value->'client_key' <> 'null'::jsonb
         and (
           jsonb_typeof(tag.value->'client_key') is distinct from 'string'
           or length(btrim(tag.value->>'client_key')) not between 1 and 120
         )
       )
  ) then
    raise exception 'Existe uma etiqueta com nome, identificador ou chave invalida.';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(v_professionals) professional(value)
    where jsonb_typeof(professional.value) is distinct from 'object'
       or jsonb_typeof(professional.value->'name') is distinct from 'string'
       or length(btrim(professional.value->>'name')) not between 1 and 100
       or jsonb_typeof(professional.value->'is_active') is distinct from 'boolean'
       or (
         nullif(professional.value->>'id', '') is not null
         and (
           jsonb_typeof(professional.value->'id') is distinct from 'string'
           or (professional.value->>'id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
         )
       )
       or (
         nullif(professional.value->>'id', '') is null
         and (
           jsonb_typeof(professional.value->'client_key') is distinct from 'string'
           or length(btrim(professional.value->>'client_key')) not between 1 and 120
         )
       )
       or (
         professional.value ? 'client_key'
         and professional.value->'client_key' <> 'null'::jsonb
         and (
           jsonb_typeof(professional.value->'client_key') is distinct from 'string'
           or length(btrim(professional.value->>'client_key')) not between 1 and 120
         )
       )
  ) then
    raise exception 'Existe um profissional com nome, status, identificador ou chave invalida.';
  end if;

  if exists (
    select 1
    from jsonb_array_elements_text(v_deleted_categories_json) deleted(value)
    where deleted.value !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  ) or exists (
    select 1
    from jsonb_array_elements_text(v_deleted_tags_json) deleted(value)
    where deleted.value !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  ) or exists (
    select 1
    from jsonb_array_elements_text(v_deleted_professionals_json) deleted(value)
    where deleted.value !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  ) then
    raise exception 'A lista de exclusoes possui um identificador invalido.';
  end if;

  -- Unicidade dentro do documento, usando a mesma regra case-insensitive dos
  -- indices do banco. Etiquetas sao unicas na loja inteira, nao por categoria.
  if exists (
    select 1
    from jsonb_array_elements(v_categories) category(value)
    group by lower(btrim(category.value->>'name'))
    having count(*) > 1
  ) then
    raise exception 'Existem categorias repetidas.';
  end if;
  if exists (
    select 1
    from jsonb_array_elements(v_categories) category(value)
    cross join lateral jsonb_array_elements(category.value->'tags') tag(value)
    group by lower(btrim(tag.value->>'label'))
    having count(*) > 1
  ) then
    raise exception 'Existem etiquetas repetidas.';
  end if;
  if exists (
    select 1
    from jsonb_array_elements(v_professionals) professional(value)
    group by lower(btrim(professional.value->>'name'))
    having count(*) > 1
  ) then
    raise exception 'Existem profissionais repetidos.';
  end if;

  if exists (
    select 1 from jsonb_array_elements(v_categories) item(value)
    where nullif(item.value->>'id', '') is not null
    group by item.value->>'id' having count(*) > 1
  ) or exists (
    select 1
    from jsonb_array_elements(v_categories) category(value)
    cross join lateral jsonb_array_elements(category.value->'tags') item(value)
    where nullif(item.value->>'id', '') is not null
    group by item.value->>'id' having count(*) > 1
  ) or exists (
    select 1 from jsonb_array_elements(v_professionals) item(value)
    where nullif(item.value->>'id', '') is not null
    group by item.value->>'id' having count(*) > 1
  ) then
    raise exception 'O snapshot repete identificadores.';
  end if;

  if exists (
    select 1 from jsonb_array_elements(v_categories) item(value)
    where nullif(item.value->>'client_key', '') is not null
    group by item.value->>'client_key' having count(*) > 1
  ) or exists (
    select 1
    from jsonb_array_elements(v_categories) category(value)
    cross join lateral jsonb_array_elements(category.value->'tags') item(value)
    where nullif(item.value->>'client_key', '') is not null
    group by item.value->>'client_key' having count(*) > 1
  ) or exists (
    select 1 from jsonb_array_elements(v_professionals) item(value)
    where nullif(item.value->>'client_key', '') is not null
    group by item.value->>'client_key' having count(*) > 1
  ) then
    raise exception 'O snapshot repete chaves temporarias.';
  end if;

  if (
    select count(*) from jsonb_array_elements_text(v_deleted_categories_json)
  ) <> (
    select count(distinct value) from jsonb_array_elements_text(v_deleted_categories_json) item(value)
  ) or (
    select count(*) from jsonb_array_elements_text(v_deleted_tags_json)
  ) <> (
    select count(distinct value) from jsonb_array_elements_text(v_deleted_tags_json) item(value)
  ) or (
    select count(*) from jsonb_array_elements_text(v_deleted_professionals_json)
  ) <> (
    select count(distinct value) from jsonb_array_elements_text(v_deleted_professionals_json) item(value)
  ) then
    raise exception 'A lista de exclusoes repete identificadores.';
  end if;

  select coalesce(array_agg((item.value->>'id')::uuid), array[]::uuid[])
  into v_category_ids
  from jsonb_array_elements(v_categories) item(value)
  where nullif(item.value->>'id', '') is not null;

  select coalesce(array_agg((item.value->>'id')::uuid), array[]::uuid[])
  into v_tag_ids
  from jsonb_array_elements(v_categories) category(value)
  cross join lateral jsonb_array_elements(category.value->'tags') item(value)
  where nullif(item.value->>'id', '') is not null;

  select coalesce(array_agg((item.value->>'id')::uuid), array[]::uuid[])
  into v_professional_ids
  from jsonb_array_elements(v_professionals) item(value)
  where nullif(item.value->>'id', '') is not null;

  select coalesce(array_agg(item.value::uuid), array[]::uuid[])
  into v_deleted_category_ids
  from jsonb_array_elements_text(v_deleted_categories_json) item(value);

  select coalesce(array_agg(item.value::uuid), array[]::uuid[])
  into v_deleted_tag_ids
  from jsonb_array_elements_text(v_deleted_tags_json) item(value);

  select coalesce(array_agg(item.value::uuid), array[]::uuid[])
  into v_deleted_professional_ids
  from jsonb_array_elements_text(v_deleted_professionals_json) item(value);

  if v_category_ids && v_deleted_category_ids
     or v_tag_ids && v_deleted_tag_ids
     or v_professional_ids && v_deleted_professional_ids then
    raise exception 'Um item nao pode ser salvo e excluido ao mesmo tempo.';
  end if;

  -- Todo ID recebido precisa pertencer exatamente a loja e ao tenant atual.
  if exists (
    select 1
    from unnest(v_category_ids) received(id)
    left join public.prospection_tag_categories pc
      on pc.id = received.id
     and pc.store_id = p_store_id
     and pc.admin_user_id = v_session.admin_user_id
    where pc.id is null
  ) or exists (
    select 1
    from unnest(v_deleted_category_ids) received(id)
    left join public.prospection_tag_categories pc
      on pc.id = received.id
     and pc.store_id = p_store_id
     and pc.admin_user_id = v_session.admin_user_id
    where pc.id is null
  ) then
    raise exception 'Categoria nao encontrada ou pertencente a outro cliente.';
  end if;

  if exists (
    select 1
    from unnest(v_tag_ids) received(id)
    left join public.prospection_tags pt
      on pt.id = received.id
     and pt.store_id = p_store_id
     and pt.admin_user_id = v_session.admin_user_id
    where pt.id is null
  ) or exists (
    select 1
    from unnest(v_deleted_tag_ids) received(id)
    left join public.prospection_tags pt
      on pt.id = received.id
     and pt.store_id = p_store_id
     and pt.admin_user_id = v_session.admin_user_id
    where pt.id is null
  ) then
    raise exception 'Etiqueta nao encontrada ou pertencente a outro cliente.';
  end if;

  if exists (
    select 1
    from unnest(v_professional_ids) received(id)
    left join public.prospection_professionals pp
      on pp.id = received.id
     and pp.store_id = p_store_id
     and pp.admin_user_id = v_session.admin_user_id
     and pp.archived_at is null
    where pp.id is null
  ) or exists (
    select 1
    from unnest(v_deleted_professional_ids) received(id)
    left join public.prospection_professionals pp
      on pp.id = received.id
     and pp.store_id = p_store_id
     and pp.admin_user_id = v_session.admin_user_id
     and pp.archived_at is null
    where pp.id is null
  ) then
    raise exception 'Profissional nao encontrado ou pertencente a outro cliente.';
  end if;

  -- Snapshot completo: nada existente pode desaparecer por falha do frontend.
  -- Exclusoes de categorias e etiquetas precisam ser sempre explicitas.
  if exists (
    select 1
    from public.prospection_professionals pp
    where pp.store_id = p_store_id
      and pp.admin_user_id = v_session.admin_user_id
      and pp.archived_at is null
      and not (pp.id = any(v_professional_ids))
      and not (pp.id = any(v_deleted_professional_ids))
  ) then
    raise exception 'A lista de profissionais esta incompleta. Recarregue a configuracao.';
  end if;

  if exists (
    select 1
    from public.prospection_tag_categories pc
    where pc.store_id = p_store_id
      and pc.admin_user_id = v_session.admin_user_id
      and not (pc.id = any(v_category_ids))
      and not (pc.id = any(v_deleted_category_ids))
  ) then
    raise exception 'A lista de categorias esta incompleta. Recarregue a configuracao.';
  end if;

  if exists (
    select 1
    from public.prospection_tags pt
    where pt.store_id = p_store_id
      and pt.admin_user_id = v_session.admin_user_id
      and not (pt.id = any(v_tag_ids))
      and not (pt.id = any(v_deleted_tag_ids))
      and not (pt.category_id = any(v_deleted_category_ids))
  ) then
    raise exception 'A lista de etiquetas esta incompleta. Recarregue a configuracao.';
  end if;

  v_expected_revision := p_payload->>'base_revision';
  v_current_revision := app_private.prospection_configuration_revision(p_store_id);
  if v_expected_revision <> v_current_revision then
    raise exception 'Esta configuracao foi alterada em outra sessao. Recarregue antes de salvar.';
  end if;

  select count(*)
  into v_tags_deleted
  from public.prospection_tags pt
  where pt.store_id = p_store_id
    and pt.admin_user_id = v_session.admin_user_id
    and (
      pt.id = any(v_deleted_tag_ids)
      or pt.category_id = any(v_deleted_category_ids)
    );

  delete from public.prospection_tags pt
  where pt.store_id = p_store_id
    and pt.admin_user_id = v_session.admin_user_id
    and pt.id = any(v_deleted_tag_ids);

  delete from public.prospection_tag_categories pc
  where pc.store_id = p_store_id
    and pc.admin_user_id = v_session.admin_user_id
    and pc.id = any(v_deleted_category_ids);
  get diagnostics v_categories_deleted = row_count;

  update public.prospection_professionals pp
  set is_active = false,
      archived_at = clock_timestamp(),
      archived_by = v_session.user_id
  where pp.store_id = p_store_id
    and pp.admin_user_id = v_session.admin_user_id
    and pp.archived_at is null
    and pp.id = any(v_deleted_professional_ids);
  get diagnostics v_professionals_archived = row_count;

  -- Libera temporariamente os indices case-insensitive para suportar trocas de
  -- nomes como Ana <-> Beatriz e Etiqueta A <-> Etiqueta B.
  update public.prospection_tag_categories pc
  set name = '__lc_batch_category_' || gen_random_uuid()::text
  where pc.store_id = p_store_id
    and pc.admin_user_id = v_session.admin_user_id
    and pc.id = any(v_category_ids);

  update public.prospection_tags pt
  set label = '__lc_batch_tag_' || gen_random_uuid()::text
  where pt.store_id = p_store_id
    and pt.admin_user_id = v_session.admin_user_id
    and pt.id = any(v_tag_ids);

  update public.prospection_professionals pp
  set name = '__lc_batch_professional_' || gen_random_uuid()::text
  where pp.store_id = p_store_id
    and pp.admin_user_id = v_session.admin_user_id
    and pp.id = any(v_professional_ids);

  insert into public.prospection_store_settings (
    store_id,
    admin_user_id,
    daily_goal,
    bonus_minimum,
    bonus_amount,
    accent_color,
    logo_background_color
  ) values (
    p_store_id,
    v_session.admin_user_id,
    v_daily_goal,
    v_bonus_minimum,
    v_bonus_amount,
    v_accent_color,
    v_logo_background_color
  )
  on conflict (store_id) do update set
    daily_goal = excluded.daily_goal,
    bonus_minimum = excluded.bonus_minimum,
    bonus_amount = excluded.bonus_amount,
    accent_color = excluded.accent_color,
    logo_background_color = excluded.logo_background_color;

  for v_category, v_category_position in
    select item.value, item.position
    from jsonb_array_elements(v_categories) with ordinality item(value, position)
    order by item.position
  loop
    v_name := btrim(v_category->>'name');
    v_client_key := nullif(btrim(coalesce(v_category->>'client_key', '')), '');

    if nullif(v_category->>'id', '') is null then
      v_category_id := gen_random_uuid();
      insert into public.prospection_tag_categories (
        id, store_id, admin_user_id, name, sort_order
      ) values (
        v_category_id, p_store_id, v_session.admin_user_id,
        v_name, v_category_position::integer * 10
      );
      v_categories_created := v_categories_created + 1;
    else
      v_category_id := (v_category->>'id')::uuid;
      update public.prospection_tag_categories pc
      set name = v_name,
          sort_order = v_category_position::integer * 10
      where pc.id = v_category_id
        and pc.store_id = p_store_id
        and pc.admin_user_id = v_session.admin_user_id;
    end if;

    if v_client_key is not null then
      v_category_id_map := v_category_id_map
        || jsonb_build_object(v_client_key, v_category_id::text);
    end if;

    for v_tag, v_tag_position in
      select item.value, item.position
      from jsonb_array_elements(v_category->'tags') with ordinality item(value, position)
      order by item.position
    loop
      v_label := btrim(v_tag->>'label');
      v_client_key := nullif(btrim(coalesce(v_tag->>'client_key', '')), '');

      if nullif(v_tag->>'id', '') is null then
        v_tag_id := gen_random_uuid();
        insert into public.prospection_tags (
          id, store_id, admin_user_id, category_id, label, sort_order
        ) values (
          v_tag_id, p_store_id, v_session.admin_user_id,
          v_category_id, v_label, v_tag_position::integer * 10
        );
        v_tags_created := v_tags_created + 1;
      else
        v_tag_id := (v_tag->>'id')::uuid;
        update public.prospection_tags pt
        set category_id = v_category_id,
            label = v_label,
            sort_order = v_tag_position::integer * 10
        where pt.id = v_tag_id
          and pt.store_id = p_store_id
          and pt.admin_user_id = v_session.admin_user_id;
      end if;

      if v_client_key is not null then
        v_tag_id_map := v_tag_id_map
          || jsonb_build_object(v_client_key, v_tag_id::text);
      end if;
    end loop;
  end loop;

  for v_professional in
    select item.value
    from jsonb_array_elements(v_professionals) item(value)
  loop
    v_name := btrim(v_professional->>'name');
    v_active := (v_professional->>'is_active')::boolean;
    v_client_key := nullif(btrim(coalesce(v_professional->>'client_key', '')), '');

    if nullif(v_professional->>'id', '') is null then
      select pp.id into v_professional_id
      from public.prospection_professionals pp
      where pp.store_id = p_store_id
        and pp.admin_user_id = v_session.admin_user_id
        and pp.archived_at is not null
        and lower(pp.name) = lower(v_name)
      order by pp.created_at
      limit 1
      for update;

      if v_professional_id is null then
        v_professional_id := gen_random_uuid();
        insert into public.prospection_professionals (
          id, store_id, admin_user_id, name, is_active
        ) values (
          v_professional_id, p_store_id, v_session.admin_user_id,
          v_name, v_active
        );
        v_professionals_created := v_professionals_created + 1;
      else
        update public.prospection_professionals pp
        set name = v_name,
            is_active = v_active,
            archived_at = null,
            archived_by = null
        where pp.id = v_professional_id;
        v_professionals_restored := v_professionals_restored + 1;
      end if;
    else
      v_professional_id := (v_professional->>'id')::uuid;
      update public.prospection_professionals pp
      set name = v_name,
          is_active = v_active
      where pp.id = v_professional_id
        and pp.store_id = p_store_id
        and pp.admin_user_id = v_session.admin_user_id
        and pp.archived_at is null;
    end if;

    if v_client_key is not null then
      v_professional_id_map := v_professional_id_map
        || jsonb_build_object(v_client_key, v_professional_id::text);
    end if;
  end loop;

  v_current_revision := app_private.prospection_configuration_revision(p_store_id);

  return jsonb_build_object(
    'ok', true,
    'store_id', p_store_id,
    'revision', v_current_revision,
    'counts', jsonb_build_object(
      'categories_upserted', jsonb_array_length(v_categories),
      'categories_created', v_categories_created,
      'categories_deleted', v_categories_deleted,
      'tags_upserted', (
        select count(*)
        from jsonb_array_elements(v_categories) category(value)
        cross join lateral jsonb_array_elements(category.value->'tags') tag(value)
      ),
      'tags_created', v_tags_created,
      'tags_deleted', v_tags_deleted,
      'professionals_upserted', jsonb_array_length(v_professionals),
      'professionals_created', v_professionals_created,
      'professionals_restored', v_professionals_restored,
      'professionals_archived', v_professionals_archived
    ),
    'id_map', jsonb_build_object(
      'categories', v_category_id_map,
      'tags', v_tag_id_map,
      'professionals', v_professional_id_map
    )
  );
end;
$$;

create or replace function public.lc_save_prospection_configuration(
  p_session_token text,
  p_store_id uuid,
  p_payload jsonb
)
returns jsonb
language sql
security invoker
set search_path = public, app_private, extensions
as $$
  select app_private.rpc_save_prospection_configuration(
    p_session_token,
    p_store_id,
    p_payload
  );
$$;

revoke all on function app_private.prospection_configuration_revision(uuid)
  from public, anon, authenticated;
revoke all on function app_private.rpc_upsert_prospection_professional(text, uuid, uuid, text, boolean)
  from public, anon, authenticated;
grant execute on function app_private.rpc_upsert_prospection_professional(text, uuid, uuid, text, boolean)
  to anon, authenticated;
revoke all on function app_private.rpc_upsert_prospection(text, uuid, uuid, text, text, text, text, text, text[], uuid)
  from public, anon, authenticated;
grant execute on function app_private.rpc_upsert_prospection(text, uuid, uuid, text, text, text, text, text, text[], uuid)
  to anon, authenticated;
revoke all on function app_private.rpc_get_prospection_configuration(text)
  from public, anon, authenticated;
grant execute on function app_private.rpc_get_prospection_configuration(text)
  to anon, authenticated;
revoke all on function app_private.rpc_save_prospection_configuration(text, uuid, jsonb)
  from public, anon, authenticated;
grant execute on function app_private.rpc_save_prospection_configuration(text, uuid, jsonb)
  to anon, authenticated;

revoke all on function public.lc_save_prospection_configuration(text, uuid, jsonb)
  from public;
grant execute on function public.lc_save_prospection_configuration(text, uuid, jsonb)
  to anon, authenticated;

notify pgrst, 'reload schema';

commit;
