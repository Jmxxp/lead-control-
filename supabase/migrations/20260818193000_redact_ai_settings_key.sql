begin;

-- A configuracao exibida no navegador informa apenas se existe uma chave.
-- O valor real continua disponivel exclusivamente pelas RPCs de runtime do servidor.
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
  select * into v_session
  from app_private.session_user(p_session_token);

  if v_session.user_role::text not in ('admin', 'technician') then
    raise exception 'A IA esta disponivel somente para admin e empresas B2B.';
  end if;

  return query
  select
    coalesce(settings.provider, 'deepseek'),
    coalesce(settings.model, 'deepseek-chat'),
    ''::text,
    coalesce(
      nullif(btrim(settings.system_prompt), ''),
      'Voce e uma IA especialista em analise comercial. Use somente os dados agregados da loja selecionada, sinalize amostras pequenas e priorize acoes mensuraveis.'
    ),
    coalesce(length(btrim(settings.api_key)) > 0, false),
    settings.updated_at
  from (select 1) seed
  left join public.ai_settings settings
    on settings.admin_user_id = v_session.admin_user_id;
end;
$$;

revoke all on function app_private.rpc_get_ai_settings(text)
  from public;
grant execute on function app_private.rpc_get_ai_settings(text)
  to anon, authenticated;

notify pgrst, 'reload schema';

commit;
