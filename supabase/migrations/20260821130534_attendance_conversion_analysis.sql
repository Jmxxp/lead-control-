begin;

create index if not exists attendances_store_professional_name_date_idx
  on public.attendances (store_id, professional_name_snapshot, attended_at desc);

create or replace function app_private.rpc_get_attendance_analysis_v1(
  p_session_token text,
  p_store_id uuid default null,
  p_search text default null,
  p_tag text default null,
  p_professional_id uuid default null,
  p_professional_name text default null,
  p_link_status text default null,
  p_start_date date default null,
  p_end_date date default null
)
returns jsonb
language plpgsql
stable
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
  v_result jsonb;
begin
  select * into v_session
  from app_private.session_user(p_session_token);

  if v_session.user_role::text = 'store' then
    if p_store_id is not null and p_store_id <> v_session.user_store_id then
      raise exception 'Cliente não pode analisar atendimentos de outra loja.';
    end if;
    v_store_id := v_session.user_store_id;
  else
    v_store_id := p_store_id;
  end if;

  if v_store_id is null then
    raise exception 'Selecione um cliente para analisar os atendimentos.';
  end if;

  if not app_private.attendance_store_allowed(
    v_session.admin_user_id,
    v_session.user_id,
    v_session.user_role,
    v_session.user_store_id,
    v_store_id
  ) then
    raise exception 'Cliente não encontrado ou sem permissão.';
  end if;

  if nullif(btrim(coalesce(p_tag, '')), '') is not null
     and lower(btrim(p_tag)) <> 'all' then
    v_tag := app_private.attendance_normalize_tag(p_tag);
    if v_tag is null then
      raise exception 'Etiqueta de atendimento inválida.';
    end if;
  end if;

  if v_link_status is not null
     and v_link_status not in (
       'all', 'matched', 'standalone', 'review',
       'unmatched', 'lead', 'prospection', 'both'
     ) then
    raise exception 'Filtro de vínculo inválido.';
  end if;

  if p_start_date is not null
     and p_end_date is not null
     and p_start_date > p_end_date then
    raise exception 'Período inválido.';
  end if;

  with filtered as materialized (
    select
      a.id,
      a.professional_id,
      coalesce(nullif(btrim(a.professional_name_snapshot), ''), 'Não informado') as professional_name,
      a.tag,
      coalesce(a.purchase_value, 0)::numeric as purchase_value,
      coalesce(a.service_value, 0)::numeric as service_value,
      a.lead_id,
      a.prospection_id,
      a.match_status,
      a.match_ambiguous,
      coalesce(
        nullif(a.phone_normalized, ''),
        case when nullif(a.cpf_normalized, '') is not null then 'cpf:' || a.cpf_normalized end,
        'attendance:' || a.id::text
      ) as customer_key
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
  ), overall as (
    select
      count(*)::bigint as total,
      count(*) filter (where tag = 'budget')::bigint as budgets,
      count(*) filter (where tag = 'purchase')::bigint as purchases,
      count(*) filter (where tag = 'other')::bigint as other,
      count(distinct customer_key)::bigint as unique_customers,
      count(distinct customer_key) filter (where tag = 'purchase')::bigint as unique_buyers,
      coalesce(sum(purchase_value) filter (where tag = 'purchase'), 0)::numeric as revenue,
      coalesce(sum(service_value), 0)::numeric as service_value,
      count(*) filter (where lead_id is not null)::bigint as linked_lead,
      count(*) filter (where prospection_id is not null)::bigint as linked_prospection,
      count(*) filter (where lead_id is not null or prospection_id is not null)::bigint as linked,
      count(*) filter (where lead_id is not null and prospection_id is not null)::bigint as both,
      count(*) filter (where lead_id is null and prospection_id is null)::bigint as unmatched,
      count(*) filter (where match_ambiguous)::bigint as ambiguous
    from filtered
  ), professional_summary as (
    select
      professional_id,
      professional_name,
      count(*)::bigint as total,
      count(*) filter (where tag = 'budget')::bigint as budgets,
      count(*) filter (where tag = 'purchase')::bigint as purchases,
      count(*) filter (where tag = 'other')::bigint as other,
      count(distinct customer_key)::bigint as unique_customers,
      count(distinct customer_key) filter (where tag = 'purchase')::bigint as unique_buyers,
      coalesce(sum(purchase_value) filter (where tag = 'purchase'), 0)::numeric as revenue,
      coalesce(sum(service_value), 0)::numeric as service_value
    from filtered
    group by professional_id, professional_name
  )
  select jsonb_build_object(
    'store_id', v_store_id,
    'metrics', jsonb_build_object(
      'total', o.total,
      'budgets', o.budgets,
      'purchases', o.purchases,
      'other', o.other,
      'unique_customers', o.unique_customers,
      'unique_buyers', o.unique_buyers,
      'conversion', case when o.unique_customers > 0 then round((o.unique_buyers::numeric / o.unique_customers::numeric) * 100, 1) else 0 end,
      'attendance_conversion', case when o.total > 0 then round((o.purchases::numeric / o.total::numeric) * 100, 1) else 0 end,
      'revenue', o.revenue,
      'ticket', case when o.purchases > 0 then round(o.revenue / o.purchases::numeric, 2) else 0 end,
      'service_value', o.service_value,
      'average_service_value', case when o.total > 0 then round(o.service_value / o.total::numeric, 2) else 0 end,
      'linked', o.linked,
      'linked_lead', o.linked_lead,
      'linked_prospection', o.linked_prospection,
      'both', o.both,
      'unmatched', o.unmatched,
      'ambiguous', o.ambiguous
    ),
    'professionals', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'professional_id', ps.professional_id,
          'name', ps.professional_name,
          'total', ps.total,
          'budgets', ps.budgets,
          'purchases', ps.purchases,
          'other', ps.other,
          'unique_customers', ps.unique_customers,
          'unique_buyers', ps.unique_buyers,
          'conversion', case when ps.unique_customers > 0 then round((ps.unique_buyers::numeric / ps.unique_customers::numeric) * 100, 1) else 0 end,
          'attendance_conversion', case when ps.total > 0 then round((ps.purchases::numeric / ps.total::numeric) * 100, 1) else 0 end,
          'revenue', ps.revenue,
          'ticket', case when ps.purchases > 0 then round(ps.revenue / ps.purchases::numeric, 2) else 0 end,
          'service_value', ps.service_value
        )
        order by ps.purchases desc, ps.revenue desc, ps.total desc, ps.professional_name
      )
      from professional_summary ps
    ), '[]'::jsonb)
  ) into v_result
  from overall o;

  return v_result;
end;
$$;

create or replace function public.lc_get_attendance_analysis_v1(
  p_session_token text,
  p_store_id uuid default null,
  p_search text default null,
  p_tag text default null,
  p_professional_id uuid default null,
  p_professional_name text default null,
  p_link_status text default null,
  p_start_date date default null,
  p_end_date date default null
)
returns jsonb
language sql
stable
security invoker
set search_path = app_private, public, extensions
as $$
  select app_private.rpc_get_attendance_analysis_v1(
    p_session_token,
    p_store_id,
    p_search,
    p_tag,
    p_professional_id,
    p_professional_name,
    p_link_status,
    p_start_date,
    p_end_date
  );
$$;

revoke all on function app_private.rpc_get_attendance_analysis_v1(text, uuid, text, text, uuid, text, text, date, date) from public, anon, authenticated;
grant execute on function app_private.rpc_get_attendance_analysis_v1(text, uuid, text, text, uuid, text, text, date, date) to anon, authenticated;

revoke all on function public.lc_get_attendance_analysis_v1(text, uuid, text, text, uuid, text, text, date, date) from public, anon, authenticated;
grant execute on function public.lc_get_attendance_analysis_v1(text, uuid, text, text, uuid, text, text, date, date) to anon, authenticated;

comment on function public.lc_get_attendance_analysis_v1(text, uuid, text, text, uuid, text, text, date, date) is
  'Retorna conversão, resultados financeiros e desempenho individual por vendedor no recorte autorizado de Atendimentos.';

notify pgrst, 'reload schema';

commit;
