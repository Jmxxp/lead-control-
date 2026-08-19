begin;

create or replace function app_private.rpc_list_attendances_v3(
  p_session_token text,
  p_store_id uuid default null,
  p_search text default null,
  p_tag text default null,
  p_professional_id uuid default null,
  p_professional_name text default null,
  p_link_status text default null,
  p_start_date date default null,
  p_end_date date default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_store_id uuid;
  v_search text := nullif(left(btrim(coalesce(p_search, '')), 200), '');
  v_search_digits text := nullif(regexp_replace(coalesce(p_search, ''), '[^0-9]', '', 'g'), '');
  v_tag text;
  v_professional_name text := nullif(left(btrim(coalesce(p_professional_name, '')), 200), '');
  v_link_status text := lower(nullif(btrim(coalesce(p_link_status, '')), ''));
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_total bigint := 0;
  v_items jsonb := '[]'::jsonb;
begin
  select * into v_session from app_private.session_user(p_session_token);
  if v_session.user_role::text = 'store' then
    if p_store_id is not null and p_store_id <> v_session.user_store_id then
      raise exception 'Cliente não pode consultar atendimentos de outra loja.';
    end if;
    v_store_id := v_session.user_store_id;
  else
    v_store_id := p_store_id;
  end if;
  if v_store_id is null then raise exception 'Selecione um cliente para consultar os atendimentos.'; end if;
  if not app_private.attendance_store_allowed(
    v_session.admin_user_id, v_session.user_id, v_session.user_role,
    v_session.user_store_id, v_store_id
  ) then raise exception 'Cliente não encontrado ou sem permissão.'; end if;

  if nullif(btrim(coalesce(p_tag, '')), '') is not null and lower(btrim(p_tag)) <> 'all' then
    v_tag := app_private.attendance_normalize_tag(p_tag);
    if v_tag is null then raise exception 'Etiqueta de atendimento inválida.'; end if;
  end if;
  if v_link_status is not null and v_link_status not in (
    'all', 'matched', 'standalone', 'review', 'unmatched', 'lead', 'prospection', 'both'
  ) then raise exception 'Filtro de vínculo inválido.'; end if;
  if p_start_date is not null and p_end_date is not null and p_start_date > p_end_date then
    raise exception 'Período inválido.';
  end if;

  with filtered as materialized (
    select a.id, a.attended_at
    from public.attendances a
    where a.store_id = v_store_id
      and a.admin_user_id = v_session.admin_user_id
      and a.attended_at >= now() - interval '2 years'
      and (v_tag is null or a.tag = v_tag)
      and (p_professional_id is null or a.professional_id = p_professional_id)
      and (v_professional_name is null or a.professional_name_snapshot = v_professional_name)
      and (p_start_date is null or a.attended_at >= (p_start_date::timestamp at time zone 'America/Sao_Paulo'))
      and (p_end_date is null or a.attended_at < ((p_end_date + 1)::timestamp at time zone 'America/Sao_Paulo'))
      and (
        v_link_status is null or v_link_status = 'all'
        or (v_link_status = 'matched' and a.match_status <> 'unmatched')
        or (v_link_status = 'standalone' and a.match_status = 'unmatched' and not a.match_ambiguous)
        or (v_link_status = 'review' and a.match_ambiguous)
        or (v_link_status in ('unmatched', 'lead', 'prospection', 'both') and a.match_status = v_link_status)
      )
      and (
        v_search is null
        or a.customer_name ilike '%' || v_search || '%'
        or a.description ilike '%' || v_search || '%'
        or a.professional_name_snapshot ilike '%' || v_search || '%'
        or coalesce(a.credited_professional_name_snapshot, '') ilike '%' || v_search || '%'
        or coalesce(a.service_order, '') ilike '%' || v_search || '%'
        or (
          v_search_digits is not null
          and (
            coalesce(a.phone_normalized, '') like '%' || v_search_digits || '%'
            or coalesce(a.cpf_normalized, '') like '%' || v_search_digits || '%'
          )
        )
      )
  ), page as (
    select * from filtered
    order by attended_at desc, id desc
    limit v_limit offset v_offset
  )
  select
    (select count(*) from filtered),
    coalesce(jsonb_agg(
      (result.payload -> 'attendance') || jsonb_build_object('links', result.payload -> 'links')
      order by p.attended_at desc, p.id desc
    ), '[]'::jsonb)
  into v_total, v_items
  from page p
  cross join lateral (
    select app_private.attendance_result_with_identity(p.id, false) as payload
  ) result;

  return jsonb_build_object(
    'store_id', v_store_id,
    'items', v_items,
    'attendances', v_items,
    'total', v_total,
    'limit', v_limit,
    'offset', v_offset,
    'has_more', v_offset::bigint + jsonb_array_length(v_items)::bigint < v_total
  );
end;
$$;

create or replace function app_private.rpc_list_prospection_bonus_purchases(
  p_session_token text,
  p_start_date date default null,
  p_end_date date default null,
  p_store_id uuid default null
)
returns table (
  prospection_id uuid,
  store_id uuid,
  store_name text,
  customer_name text,
  professional_id uuid,
  professional_name text,
  purchased_at timestamptz,
  purchase_amount numeric,
  purchase_order text,
  bonus_minimum numeric,
  bonus_amount numeric,
  bonus_eligible boolean,
  bonus_awarded_amount numeric,
  bonus_credit_status text
)
language plpgsql
stable
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_start date := coalesce(
    p_start_date,
    timezone('America/Sao_Paulo', now())::date
      - extract(isodow from timezone('America/Sao_Paulo', now()))::integer + 1
  );
  v_end date := coalesce(p_end_date, timezone('America/Sao_Paulo', now())::date);
begin
  select * into v_session from app_private.session_user(p_session_token);
  if v_start > v_end then raise exception 'Período inválido.'; end if;
  if p_store_id is not null and not app_private.attendance_store_allowed(
    v_session.admin_user_id, v_session.user_id, v_session.user_role,
    v_session.user_store_id, p_store_id
  ) then raise exception 'Cliente não encontrado ou sem permissão.'; end if;

  return query
  select
    pr.id,
    pr.store_id,
    st.name,
    pr.name,
    coalesce(a.credited_professional_id, pr.professional_id),
    coalesce(
      a.credited_professional_name_snapshot,
      pp.name,
      pr.professional_name_snapshot,
      'Sem responsável'
    ),
    pr.purchased_at,
    coalesce(pr.purchase_amount, a.purchase_value, 0)::numeric,
    coalesce(pr.purchase_order, a.service_order),
    coalesce(a.bonus_minimum_snapshot, ps.bonus_minimum, 300)::numeric,
    coalesce(a.bonus_amount_snapshot, ps.bonus_amount, 20)::numeric,
    coalesce(
      a.bonus_eligible,
      (
        (pr.professional_id is not null or nullif(btrim(coalesce(pr.professional_name_snapshot, '')), '') is not null)
        and coalesce(pr.purchase_amount, 0) >= coalesce(ps.bonus_minimum, 300)
      )
    ),
    coalesce(
      a.bonus_awarded_amount,
      case when (
        pr.professional_id is not null or nullif(btrim(coalesce(pr.professional_name_snapshot, '')), '') is not null
      ) and coalesce(pr.purchase_amount, 0) >= coalesce(ps.bonus_minimum, 300)
        then coalesce(ps.bonus_amount, 20) else 0 end
    )::numeric,
    coalesce(
      a.bonus_credit_status,
      case
        when pr.professional_id is null and nullif(btrim(coalesce(pr.professional_name_snapshot, '')), '') is null
          then 'missing_professional'
        when coalesce(pr.purchase_amount, 0) >= coalesce(ps.bonus_minimum, 300)
          then 'awarded'
        else 'below_minimum'
      end
    )
  from public.prospections pr
  join public.stores st
    on st.id = pr.store_id and st.admin_user_id = pr.admin_user_id
  left join public.prospection_store_settings ps
    on ps.store_id = pr.store_id and ps.admin_user_id = pr.admin_user_id
  left join public.prospection_professionals pp on pp.id = pr.professional_id
  left join lateral (
    select ax.*
    from public.attendances ax
    where ax.prospection_id = pr.id and ax.purchase_credit_applied
    order by ax.attended_at, ax.id
    limit 1
  ) a on true
  where pr.admin_user_id = v_session.admin_user_id
    and pr.purchased_at is not null
    and timezone('America/Sao_Paulo', pr.purchased_at)::date between v_start and v_end
    and (p_store_id is null or pr.store_id = p_store_id)
    and app_private.attendance_store_allowed(
      v_session.admin_user_id, v_session.user_id, v_session.user_role,
      v_session.user_store_id, pr.store_id
    )
  order by pr.purchased_at desc, pr.id desc;
end;
$$;


alter function app_private.rpc_list_prospection_bonus_purchases(text, date, date, uuid) volatile;

notify pgrst, 'reload schema';

commit;
