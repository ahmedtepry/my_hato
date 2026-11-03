-- 0137: net profit of ONE order or POS invoice (selling price minus the product costs frozen on its lines), for the owner's AI chat and the team.
-- Same definition as the profit report: online profit = subtotal (already net of discounts) - cost; the delivery fee is shown apart (it is not product profit).
-- A line with no cost is never guessed: the profit is null and the missing lines are listed. Needs profit.view (owner / manager / accountant).
create or replace function public.order_profit(p_ref text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare o public.orders%rowtype; s public.pos_sales%rowtype; v_items jsonb; v_rev bigint; v_cost bigint; v_missing int;
begin
  perform public.require_permission('profit.view');
  p_ref := btrim(coalesce(p_ref, ''));
  if p_ref = '' or length(p_ref) > 60 then raise exception 'INVALID_INPUT'; end if;
  select * into o from public.orders where upper(reference) = upper(p_ref) limit 1;
  if found then
    select coalesce(jsonb_agg(jsonb_build_object('name', i.name_ar, 'qty', i.quantity, 'unit_price_minor', i.unit_price_minor,
             'cost_unit_minor', c.cost_unit_minor, 'revenue_minor', i.line_total_minor,
             'cost_minor', case when c.item_id is not null then c.cost_unit_minor * i.quantity end,
             'profit_minor', case when c.item_id is not null then i.line_total_minor - c.cost_unit_minor * i.quantity end) order by i.name_ar), '[]'::jsonb),
           coalesce(sum(i.line_total_minor), 0), coalesce(sum(c.cost_unit_minor * i.quantity), 0), count(*) filter (where c.item_id is null)
      into v_items, v_rev, v_cost, v_missing
      from public.order_items i left join public.order_item_costs c on c.item_id = i.id where i.order_id = o.id;
    return jsonb_build_object('kind', 'online', 'reference', o.reference, 'status', o.status, 'payment_status', o.payment_status,
      'items', v_items, 'subtotal_minor', o.subtotal_minor, 'discount_minor', o.discount_minor, 'delivery_fee_minor', o.delivery_fee_minor, 'total_minor', o.total_minor,
      'cost_minor', v_cost, 'net_profit_minor', case when v_missing = 0 then o.subtotal_minor - v_cost end, 'missing_cost_lines', v_missing,
      'margin_pct', case when v_missing = 0 and o.subtotal_minor > 0 then round((o.subtotal_minor - v_cost) * 100.0 / o.subtotal_minor, 1) end,
      'counts_in_profit_report', o.status::text = 'delivered',
      'note', case when o.status::text = 'cancelled' then 'cancelled order: no profit' when o.status::text <> 'delivered' then 'not delivered yet: expected profit' end);
  end if;
  select * into s from public.pos_sales where upper(number::text) = upper(p_ref) limit 1;
  if found then
    select coalesce(jsonb_agg(jsonb_build_object('name', i.name_ar, 'qty', i.quantity - i.refunded_qty, 'cost_unit_minor', c.cost_unit_minor,
             'revenue_minor', i.net_line_minor - i.refunded_amount_minor,
             'cost_minor', case when c.item_id is not null then c.cost_unit_minor * (i.quantity - i.refunded_qty) end,
             'profit_minor', case when c.item_id is not null then (i.net_line_minor - i.refunded_amount_minor) - c.cost_unit_minor * (i.quantity - i.refunded_qty) end) order by i.name_ar), '[]'::jsonb),
           coalesce(sum(i.net_line_minor - i.refunded_amount_minor), 0), coalesce(sum(c.cost_unit_minor * (i.quantity - i.refunded_qty)), 0),
           count(*) filter (where c.item_id is null and i.quantity - i.refunded_qty > 0)
      into v_items, v_rev, v_cost, v_missing
      from public.pos_sale_items i left join public.pos_item_costs c on c.item_id = i.id where i.sale_id = s.id;
    return jsonb_build_object('kind', 'pos', 'reference', s.number, 'items', v_items, 'revenue_minor', v_rev, 'cost_minor', v_cost,
      'net_profit_minor', case when v_missing = 0 then v_rev - v_cost end, 'missing_cost_lines', v_missing,
      'margin_pct', case when v_missing = 0 and v_rev > 0 then round((v_rev - v_cost) * 100.0 / v_rev, 1) end);
  end if;
  raise exception 'NOT_FOUND';
end $$;
revoke all on function public.order_profit(text) from public, anon;
grant execute on function public.order_profit(text) to authenticated;
