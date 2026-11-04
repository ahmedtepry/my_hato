-- The owner's morning brief: yesterday and today so far, plus what needs attention. Plain SQL (no AI), instant. Needs profit.view (owner / manager / accountant).
create or replace function public.owner_brief() returns jsonb
language plpgsql security definer set search_path = public as $$
declare tz constant text := 'Africa/Cairo'; v_today timestamptz; v_yest timestamptz; v_pf jsonb; v_thr int;
begin
  perform public.require_permission('profit.view');
  v_today := date_trunc('day', now() at time zone tz) at time zone tz;
  v_yest := v_today - interval '1 day';
  v_thr := coalesce((public.setting('low_stock_threshold') #>> '{}')::int, 5);
  v_pf := public.profit_report(v_yest, v_today);
  return jsonb_build_object(
    'yesterday', jsonb_build_object(
      'pos_sales', (select count(*) from public.pos_sales where created_at >= v_yest and created_at < v_today),
      'pos_total_minor', (select coalesce(sum(total_minor - refunded_minor), 0) from public.pos_sales where created_at >= v_yest and created_at < v_today),
      'online_orders', (select count(*) from public.orders where created_at >= v_yest and created_at < v_today and status::text <> 'cancelled'),
      'online_total_minor', (select coalesce(sum(total_minor), 0) from public.orders where created_at >= v_yest and created_at < v_today and status::text <> 'cancelled'),
      'profit_minor', coalesce((v_pf #>> '{totals,profit_minor}')::bigint, 0),
      'losing_sales', coalesce((v_pf #>> '{totals,losing_sales}')::int, 0)),
    'today', jsonb_build_object(
      'pos_sales', (select count(*) from public.pos_sales where created_at >= v_today),
      'pos_total_minor', (select coalesce(sum(total_minor - refunded_minor), 0) from public.pos_sales where created_at >= v_today),
      'online_orders', (select count(*) from public.orders where created_at >= v_today and status::text <> 'cancelled'),
      'online_total_minor', (select coalesce(sum(total_minor), 0) from public.orders where created_at >= v_today and status::text <> 'cancelled')),
    'alerts', jsonb_build_object(
      'orders_to_confirm', (select count(*) from public.orders where status::text = 'pending_confirmation' and closed_at is null),
      'orders_stuck_3d', (select count(*) from public.orders where status::text in ('confirmed', 'preparing', 'out_for_delivery') and closed_at is null and created_at < now() - interval '3 days'),
      'low_stock', (select count(*) from public.products where status = 'published' and stock_quantity <= v_thr),
      'low_stock_items', (select coalesce(jsonb_agg(jsonb_build_object('name', name_ar, 'stock', stock_quantity)), '[]'::jsonb)
                            from (select name_ar, stock_quantity from public.products where status = 'published' and stock_quantity <= v_thr order by stock_quantity, name_ar limit 5) t),
      'unmatched_transfers', (select count(*) from public.wallet_transfers where status = 'new' and received_at > now() - interval '3 days'),
      'unpaid_wallet_orders', (select count(*) from public.orders o join public.order_wallet_transfers t on t.order_id = o.id
                                where t.confirmed_at is null and o.status::text <> 'cancelled' and o.payment_status::text <> 'paid'),
      'pending_accounts', (select count(*) from public.customers c where c.review_status = 'pending' and not exists (select 1 from public.user_roles ur where ur.user_id = c.user_id)),
      'products_without_cost', coalesce((v_pf ->> 'products_without_cost')::int, 0)),
    'top_yesterday', coalesce(v_pf -> 'top', '[]'::jsonb));
end $$;
revoke all on function public.owner_brief() from public, anon;
grant execute on function public.owner_brief() to authenticated;
