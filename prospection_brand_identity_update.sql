-- Controle de Leads | Prospecções
-- Atualização incremental para cor de fundo das logos transparentes.
-- Pode ser executada isoladamente no SQL Editor do Supabase.

alter table public.prospection_store_settings
  add column if not exists logo_background_color text not null default '#ffffff';

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
        'logo_background_color', coalesce(ps.logo_background_color, '#ffffff')
      ) order by st.name)
      from public.stores st
      left join public.prospection_store_settings ps on ps.store_id = st.id
      where st.admin_user_id = v_session.admin_user_id
        and st.is_active = true
        and app_private.prospection_store_allowed(
          v_session.admin_user_id,
          v_session.user_id,
          v_session.user_role,
          v_session.user_store_id,
          st.id,
          false
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
        and app_private.prospection_store_allowed(
          v_session.admin_user_id,
          v_session.user_id,
          v_session.user_role,
          v_session.user_store_id,
          pp.store_id,
          false
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
          v_session.admin_user_id,
          v_session.user_id,
          v_session.user_role,
          v_session.user_store_id,
          pc.store_id,
          false
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
          v_session.admin_user_id,
          v_session.user_id,
          v_session.user_role,
          v_session.user_store_id,
          pt.store_id,
          false
        )
    ), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$$;

create or replace function app_private.rpc_save_prospection_logo_background(
  p_session_token text,
  p_store_id uuid,
  p_logo_background_color text
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if not app_private.prospection_store_allowed(
    v_session.admin_user_id,
    v_session.user_id,
    v_session.user_role,
    v_session.user_store_id,
    p_store_id,
    true
  ) then
    raise exception 'Sem permissao para configurar a identidade deste cliente.';
  end if;

  if coalesce(p_logo_background_color, '') !~ '^#[0-9a-fA-F]{6}$' then
    raise exception 'Cor de fundo da logo invalida.';
  end if;

  insert into public.prospection_store_settings (
    store_id,
    admin_user_id,
    logo_background_color
  ) values (
    p_store_id,
    v_session.admin_user_id,
    lower(p_logo_background_color)
  )
  on conflict (store_id) do update set
    logo_background_color = excluded.logo_background_color;

  return true;
end;
$$;

create or replace function public.lc_save_prospection_logo_background(
  p_session_token text,
  p_store_id uuid,
  p_logo_background_color text
)
returns boolean
language sql
security invoker
as $$
  select app_private.rpc_save_prospection_logo_background(
    p_session_token,
    p_store_id,
    p_logo_background_color
  );
$$;

revoke all on function app_private.rpc_save_prospection_logo_background(text, uuid, text) from public, anon, authenticated;
grant execute on function app_private.rpc_save_prospection_logo_background(text, uuid, text) to anon, authenticated;
revoke all on function public.lc_save_prospection_logo_background(text, uuid, text) from public;
grant execute on function public.lc_save_prospection_logo_background(text, uuid, text) to anon, authenticated;
