-- 0111: ملخص المحاسب الآلي. Read-only numbers for the accountant robot (today vs yesterday, month, open shifts, cash differences, wallet transfers waiting).
-- Allowed for whoever can see sales or review shifts; every figure respects the branches he may view.
create or replace function public.accountant_brief() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  d0 timestamptz := date_trunc('day', now() at time zone 'Africa/Cairo') at time zone 'Africa/Cairo';
  d1 timestamptz; m0 timestamptz;
begin
  perform public.require_auth();
  if not (public.has_permission('sales.view') or public.has_permission('shifts.review') or public.has_permission('assistant.accountant')) then raise exception 'FORBIDDEN'; end if;
  d1 := d0 - interval '1 day';
  m0 := date_trunc('month', now() at time zone 'Africa/Cairo') at time zone 'Africa/Cairo';
  return jsonb_build_object(
    'today', (select jsonb_build_object('count', count(*), 'gross_minor', coalesce(sum(total_minor), 0), 'refunds_minor', coalesce(sum(refunded_minor), 0), 'discount_minor', coalesce(sum(discount_minor), 0))
                from public.pos_sales p where p.created_at >= d0 and public._branch_view_ok(p.branch_id)),
    'yesterday', (select jsonb_build_object('count', count(*), 'gross_minor', coalesce(sum(total_minor), 0), 'refunds_minor', coalesce(sum(refunded_minor), 0))
                from public.pos_sales p where p.created_at >= d1 and p.created_at < d0 and public._branch_view_ok(p.branch_id)),
    'month', (select jsonb_build_object('count', count(*), 'gross_minor', coalesce(sum(total_minor), 0), 'refunds_minor', coalesce(sum(refunded_minor), 0), 'discount_minor', coalesce(sum(discount_minor), 0))
                from public.pos_sales p where p.created_at >= m0 and public._branch_view_ok(p.branch_id)),
    'online_today', (select jsonb_build_object('count', count(*), 'total_minor', coalesce(sum(total_minor), 0)) from public.orders o where o.created_at >= d0 and o.status <> 'cancelled'),
    'wallet_waiting', (select jsonb_build_object('count', count(*), 'total_minor', coalesce(sum(total_minor), 0)) from public.orders o
                        where o.payment_method = 'wallet' and o.payment_status = 'unpaid' and o.status <> 'cancelled' and o.closed_at is null),
    'open_shifts', coalesce((select jsonb_agg(jsonb_build_object('branch', b.name_ar, 'cashier', public._ops_name(h.cashier_id), 'opened_at', h.opened_at,
                         'hours', round((extract(epoch from (now() - h.opened_at)) / 3600)::numeric, 1)) order by h.opened_at)
                    from public.shifts h join public.branches b on b.id = h.branch_id where h.status = 'open' and public._branch_view_ok(h.branch_id)), '[]'::jsonb),
    'variances', coalesce((select jsonb_agg(jsonb_build_object('branch', b.name_ar, 'cashier', public._ops_name(h.cashier_id), 'closed_at', h.closed_at, 'variance_minor', h.variance_minor) order by h.closed_at desc)
                    from public.shifts h join public.branches b on b.id = h.branch_id
                   where h.status = 'closed' and h.closed_at >= now() - interval '7 days' and coalesce(h.variance_minor, 0) <> 0 and public._branch_view_ok(h.branch_id)), '[]'::jsonb),
    'branches_today', coalesce((select jsonb_agg(jsonb_build_object('name', b.name_ar, 'count', coalesce(s.n, 0), 'gross_minor', coalesce(s.g, 0)) order by coalesce(s.g, 0) desc)
                    from public.branches b left join lateral (select count(*) n, sum(p.total_minor) g from public.pos_sales p where p.branch_id = b.id and p.created_at >= d0) s on true
                   where b.is_active and public._branch_view_ok(b.id)), '[]'::jsonb),
    'top_today', coalesce((select jsonb_agg(x) from (select jsonb_build_object('name', it.name_ar, 'qty', sum(it.quantity - it.refunded_qty), 'total_minor', sum(it.net_line_minor)) x
                    from public.pos_sale_items it join public.pos_sales p on p.id = it.sale_id where p.created_at >= d0 and public._branch_view_ok(p.branch_id)
                   group by it.name_ar order by sum(it.net_line_minor) desc nulls last limit 3) t), '[]'::jsonb));
end $$;
revoke all on function public.accountant_brief() from public, anon;
grant execute on function public.accountant_brief() to authenticated;
