-- Configuracao central de IA: o admin salva uma unica chave e somente a Edge
-- Function usa essa credencial para chamar o provedor.
-- Rode depois de b2b_client_hierarchy_update.sql e client_scoped_configuration_update.sql.

begin;

set search_path = public, extensions;

create table if not exists public.ai_settings (
  admin_user_id uuid primary key references public.app_users(id) on delete cascade,
  provider text not null default 'deepseek',
  model text not null default 'deepseek-chat',
  api_key text not null default '',
  system_prompt text not null default '',
  updated_by_user_id uuid references public.app_users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint ai_settings_provider_check check (provider in ('deepseek', 'gemini')),
  constraint ai_settings_model_check check (length(btrim(model)) between 1 and 160)
);

alter table public.ai_settings enable row level security;

drop trigger if exists ai_settings_set_updated_at on public.ai_settings;
create trigger ai_settings_set_updated_at
before update on public.ai_settings
for each row execute function app_private.set_updated_at();

drop function if exists public.lc_save_ai_settings(text, text, text, text, text);
drop function if exists app_private.rpc_save_ai_settings(text, text, text, text, text);
drop function if exists public.lc_get_ai_settings(text);
drop function if exists app_private.rpc_get_ai_settings(text);
drop function if exists public.lc_ai_runtime_config(text);

create or replace function app_private.rpc_get_ai_settings(p_session_token text)
returns table (
  provider text,
  model text,
  api_key text,
  system_prompt text,
  has_api_key boolean,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text not in ('admin', 'technician') then
    raise exception 'A IA esta disponivel somente para admin e empresas B2B.';
  end if;

  return query
  select
    coalesce(s.provider, 'deepseek'),
    coalesce(s.model, 'deepseek-chat'),
    ''::text,
    coalesce(nullif(btrim(s.system_prompt), ''),
      'Voce e uma IA especialista em analise comercial de leads para oticas. Responda somente ao que o usuario perguntou. Cada conversa recebe dados de uma unica loja selecionada. Nunca combine ou compare dados de lojas diferentes. Use somente os leads fornecidos no contexto e priorize recomendacoes praticas.'),
    coalesce(length(btrim(s.api_key)) > 0, false),
    s.updated_at
  from (select 1) seed
  left join public.ai_settings s
    on s.admin_user_id = v_session.admin_user_id;
end;
$$;

create or replace function public.lc_get_ai_settings(p_session_token text)
returns table (
  provider text,
  model text,
  api_key text,
  system_prompt text,
  has_api_key boolean,
  updated_at timestamptz
)
language sql
security invoker
as $$
  select * from app_private.rpc_get_ai_settings(p_session_token);
$$;

create or replace function app_private.rpc_save_ai_settings(
  p_session_token text,
  p_provider text,
  p_model text,
  p_api_key text default null,
  p_system_prompt text default null
)
returns table (
  provider text,
  model text,
  api_key text,
  system_prompt text,
  has_api_key boolean,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_provider text := lower(btrim(coalesce(p_provider, '')));
  v_model text := btrim(coalesce(p_model, ''));
  v_api_key text := nullif(btrim(coalesce(p_api_key, '')), '');
  v_prompt text := nullif(btrim(coalesce(p_system_prompt, '')), '');
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text <> 'admin' then
    raise exception 'Apenas o admin pode alterar a configuracao central da IA.';
  end if;

  if v_provider not in ('deepseek', 'gemini') then
    raise exception 'Provedor de IA invalido.';
  end if;

  if length(v_model) = 0 or length(v_model) > 160 then
    raise exception 'Informe um modelo de IA valido.';
  end if;

  if v_api_key is null and not exists (
    select 1
    from public.ai_settings s
    where s.admin_user_id = v_session.admin_user_id
      and length(btrim(s.api_key)) > 0
  ) then
    raise exception 'Informe a chave da API antes de salvar.';
  end if;

  insert into public.ai_settings (
    admin_user_id,
    provider,
    model,
    api_key,
    system_prompt,
    updated_by_user_id
  )
  values (
    v_session.admin_user_id,
    v_provider,
    v_model,
    coalesce(v_api_key, ''),
    coalesce(v_prompt, ''),
    v_session.user_id
  )
  on conflict (admin_user_id) do update
  set
    provider = excluded.provider,
    model = excluded.model,
    api_key = coalesce(v_api_key, public.ai_settings.api_key),
    system_prompt = coalesce(v_prompt, public.ai_settings.system_prompt),
    updated_by_user_id = v_session.user_id;

  return query
  select * from app_private.rpc_get_ai_settings(p_session_token);
end;
$$;

create or replace function public.lc_save_ai_settings(
  p_session_token text,
  p_provider text,
  p_model text,
  p_api_key text default null,
  p_system_prompt text default null
)
returns table (
  provider text,
  model text,
  api_key text,
  system_prompt text,
  has_api_key boolean,
  updated_at timestamptz
)
language sql
security invoker
as $$
  select *
  from app_private.rpc_save_ai_settings(
    p_session_token,
    p_provider,
    p_model,
    p_api_key,
    p_system_prompt
  );
$$;

revoke all on table public.ai_settings from public, anon, authenticated;
revoke execute on function app_private.rpc_get_ai_settings(text) from public;
revoke execute on function app_private.rpc_save_ai_settings(text, text, text, text, text) from public;

revoke execute on function public.lc_get_ai_settings(text) from public;
revoke execute on function public.lc_save_ai_settings(text, text, text, text, text) from public;

grant execute on function app_private.rpc_get_ai_settings(text) to anon, authenticated;
grant execute on function app_private.rpc_save_ai_settings(text, text, text, text, text) to anon, authenticated;
grant execute on function public.lc_get_ai_settings(text) to anon, authenticated;
grant execute on function public.lc_save_ai_settings(text, text, text, text, text) to anon, authenticated;

commit;
