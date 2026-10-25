-- 0055: sales figures for the owner: today / last 7 days / this month, compared with the period before, plus an export.
-- A sale is an order that was delivered (cancelled and still-open orders are not counted). The amount is the order total
-- (what the customer pays, delivery fee included). Day boundaries follow Cairo time.
-- New permission sales.view: the owner has it, and can give it to a role or one account from the permissions screen.
insert into public.role_permissions (role, permission) values ('owner', 'sales.view') on conflict do nothing;
insert into public.permission_catalog (permission, grp, name_ar, name_en, desc_ar, desc_en, sensitive, inert, sort)
values ('sales.view', 'system', 'يشوف المبيعات', 'See sales',
        'يشوف أرقام المبيعات اليومية والأسبوعية والشهرية ويسحبها في ملف Excel',
        'Sees daily, weekly and monthly sales and exports them to Excel', true, false, 46)
on conflict (permission) do nothing;

create or replace function public._sales_bounds(p_period text)
returns table(cur_from timestamptz, prev_from timestamptz, prev_to timestamptz)
language plpgsql stable set search_path = public as $$
declare
  v_tz constant text := 'Africa/Cairo';
  v_now timestamptz := now();
  v_today date := (now() at time zone 'Africa/Cairo')::date;
begin
  if p_period = 'day' then
    return query select v_today::timestamp at time zone v_tz, (v_today - 1)::timestamp at time zone v_tz, v_now - interval '1 day';
  elsif p_period = 'week' then
    return query select (v_today - 6)::timestamp at time zone v_tz, (v_today - 13)::timestamp at time zone v_tz, v_now - interval '7 days';
  elsif p_period = 'month' then
    return query select date_trunc('month', v_today)::timestamp at time zone v_tz,
                        (date_trunc('month', v_today) - interval '1 month')::timestamp at time zone v_tz,
                        v_now - interval '1 month';
  else
    raise exception 'INVALID_INPUT';
  end if;
end $$;

-- delivered orders with the moment they were delivered
create or replace view public._delivered_orders as
select o.id, o.reference, o.customer_name, o.fulfillment, o.payment_method, o.total_minor, o.delivery_fee_minor,
       coalesce((select min(h.created_at) from public.order_status_history h where h.order_id = o.id and h.to_status = 'delivered'), o.updated_at) as delivered_at
from public.orders o where o.status = 'delivered';
revoke all on public._delivered_orders from public, anon, authenticated;

create or replace function public.sales_report(p_period text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  b record; v_now timestamptz := now(); v_tz constant text := 'Africa/Cairo';
  v_total bigint; v_prev bigint; v_n int; v_deliv int; v_pick int; v_series jsonb; v_top jsonb; v_pend_n int; v_pend bigint;
begin
  perform public.require_permission('sales.view');
  select * into b from public._sales_bounds(p_period);
  select coalesce(sum(total_minor), 0), count(*), count(*) filter (where fulfillment = 'delivery'), count(*) filter (where fulfillment = 'pickup')
    into v_total, v_n, v_deliv, v_pick from public._delivered_orders where delivered_at >= b.cur_from and delivered_at <= v_now;
  select coalesce(sum(total_minor), 0) into v_prev from public._delivered_orders where delivered_at >= b.prev_from and delivered_at <= b.prev_to;

  if p_period = 'day' then
    select coalesce(jsonb_agg(jsonb_build_object('label', to_char(g, 'HH24'), 'total_minor', coalesce(s.t, 0)) order by g), '[]'::jsonb) into v_series
    from generate_series(b.cur_from, v_now, interval '1 hour') g
    left join lateral (select sum(total_minor) t from public._delivered_orders d
                       where d.delivered_at >= g and d.delivered_at < g + interval '1 hour') s on true;
  else
    select coalesce(jsonb_agg(jsonb_build_object('label', to_char(g, 'YYYY-MM-DD'), 'total_minor', coalesce(s.t, 0)) order by g), '[]'::jsonb) into v_series
    from generate_series((b.cur_from at time zone v_tz)::date, (v_now at time zone v_tz)::date, interval '1 day') g
    left join lateral (select sum(total_minor) t from public._delivered_orders d
                       where (d.delivered_at at time zone v_tz)::date = g::date) s on true;
  end if;

  select coalesce(jsonb_agg(x), '[]'::jsonb) into v_top from (
    select jsonb_build_object('name_ar', i.name_ar, 'name_en', i.name_en, 'qty', sum(i.quantity), 'total_minor', sum(i.line_total_minor)) as x
    from public.order_items i join public._delivered_orders d on d.id = i.order_id
    where d.delivered_at >= b.cur_from and d.delivered_at <= v_now
    group by i.name_ar, i.name_en order by sum(i.line_total_minor) desc limit 5) t;

  select count(*), coalesce(sum(total_minor), 0) into v_pend_n, v_pend from public.orders where status not in ('delivered', 'cancelled');

  return jsonb_build_object('total_minor', v_total, 'prev_total_minor', v_prev, 'orders', v_n, 'delivery_orders', v_deliv, 'pickup_orders', v_pick,
    'series', v_series, 'top', v_top, 'pending_orders', v_pend_n, 'pending_minor', v_pend, 'from', b.cur_from, 'to', v_now);
end $$;

-- every order and product line of the period, for the Excel file
create or replace function public.sales_export(p_period text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare b record; v_now timestamptz := now(); v_orders jsonb; v_products jsonb;
begin
  perform public.require_permission('sales.view');
  select * into b from public._sales_bounds(p_period);
  select coalesce(jsonb_agg(jsonb_build_object('reference', reference, 'delivered_at', delivered_at, 'customer_name', customer_name,
           'fulfillment', fulfillment, 'payment_method', payment_method, 'delivery_fee_minor', delivery_fee_minor, 'total_minor', total_minor)
           order by delivered_at), '[]'::jsonb) into v_orders
    from public._delivered_orders where delivered_at >= b.cur_from and delivered_at <= v_now;
  select coalesce(jsonb_agg(x), '[]'::jsonb) into v_products from (
    select jsonb_build_object('name_ar', i.name_ar, 'qty', sum(i.quantity), 'total_minor', sum(i.line_total_minor)) as x
    from public.order_items i join public._delivered_orders d on d.id = i.order_id
    where d.delivered_at >= b.cur_from and d.delivered_at <= v_now
    group by i.name_ar order by sum(i.line_total_minor) desc) t;
  return jsonb_build_object('orders', v_orders, 'products', v_products, 'from', b.cur_from, 'to', v_now);
end $$;

revoke all on function public._sales_bounds(text), public.sales_report(text), public.sales_export(text) from public, anon;
grant execute on function public.sales_report(text), public.sales_export(text) to authenticated;
