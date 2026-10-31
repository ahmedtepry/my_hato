-- 0121: the accountant's employee KPI now includes online staff: their delivered orders count as sales and their (frozen) online
-- commission is added to the commission. Online rows are included only when no single branch is selected.
create or replace function public.kpi_employees(p_from timestamptz, p_to timestamptz, p_branch uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform public.require_permission('commission.view');
  if p_from is null or p_to is null or p_to <= p_from or p_to - p_from > interval '400 days' then raise exception 'INVALID_INPUT'; end if;
  perform public._online_freeze();
  return jsonb_build_object('from', p_from, 'to', p_to, 'employees', coalesce((select jsonb_agg(x order by (x ->> 'net_minor')::bigint desc) from (
    select jsonb_build_object('user_id', u.uid, 'name', public._ops_name(u.uid),
             'role', (select ur.role::text from public.user_roles ur where ur.user_id = u.uid limit 1),
             'sales_count', s.n + coalesce(oc.n, 0), 'gross_minor', s.gross + coalesce(oc.v, 0), 'refunds_minor', s.refunds,
             'net_minor', s.gross + coalesce(oc.v, 0) - s.refunds,
             'discount_minor', s.disc, 'tips_minor', s.tips,
             'avg_ticket_minor', case when s.n + coalesce(oc.n, 0) > 0 then round((s.gross + coalesce(oc.v, 0) - s.refunds)::numeric / (s.n + coalesce(oc.n, 0))) else 0 end,
             'commission_minor', coalesce(c.com, 0) + coalesce(oc.com, 0), 'shifts_count', coalesce(sh.n, 0), 'target_minor', ut.monthly_minor,
             'online_orders', coalesce(oc.n, 0), 'online_sales_minor', coalesce(oc.v, 0), 'online_commission_minor', coalesce(oc.com, 0)) as x
      from (select cashier_id as uid from public.pos_sales
             where created_at >= p_from and created_at < p_to and (p_branch is null or branch_id = p_branch) and public._branch_view_ok(branch_id)
            union
            select c2.user_id from public.online_commissions c2 join public.orders o2 on o2.id = c2.order_id
             where p_branch is null and c2.delivered_at >= p_from and c2.delivered_at < p_to and o2.payment_status <> 'refunded') u
      join lateral (select count(*) as n, coalesce(sum(p.total_minor), 0) as gross, coalesce(sum(p.refunded_minor), 0) as refunds,
                           coalesce(sum(p.discount_minor), 0) as disc, coalesce(sum(p.tip_minor), 0) as tips
                      from public.pos_sales p where p.cashier_id = u.uid and p.created_at >= p_from and p.created_at < p_to
                       and (p_branch is null or p.branch_id = p_branch) and public._branch_view_ok(p.branch_id)) s on true
      left join lateral (select sum(i.commission_unit_minor * (i.quantity - i.refunded_qty)) as com
                           from public.pos_sale_items i join public.pos_sales p on p.id = i.sale_id
                          where p.cashier_id = u.uid and p.created_at >= p_from and p.created_at < p_to
                            and (p_branch is null or p.branch_id = p_branch) and public._branch_view_ok(p.branch_id)) c on true
      left join lateral (select count(*)::int as n, coalesce(sum(o.total_minor), 0)::bigint as v, coalesce(sum(k.amount_minor), 0)::bigint as com
                           from public.online_commissions k join public.orders o on o.id = k.order_id
                          where p_branch is null and k.user_id = u.uid and k.delivered_at >= p_from and k.delivered_at < p_to and o.payment_status <> 'refunded') oc on true
      left join lateral (select count(*) as n from public.shifts h where h.cashier_id = u.uid and h.opened_at >= p_from and h.opened_at < p_to
                            and (p_branch is null or h.branch_id = p_branch) and public._branch_view_ok(h.branch_id)) sh on true
      left join public.user_targets ut on ut.user_id = u.uid) q), '[]'::jsonb));
end $$;
revoke all on function public.kpi_employees(timestamptz, timestamptz, uuid) from public, anon;
grant execute on function public.kpi_employees(timestamptz, timestamptz, uuid) to authenticated;
