-- "تحدّي اليوم" for the cashier: the daily target (monthly target / days of the month), today's real sales against it,
-- and the products that carry a commission today with how many of each were really sold today. Only completed sales count.
create or replace function public.my_challenge_today()
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_from timestamptz; v_to timestamptz; v_day timestamptz;
  v_st jsonb; v_days int; v_target bigint; v_daily bigint; v_prods jsonb := '[]'::jsonb;
begin
  perform public.require_permission('targets.mine');
  select m_from, m_to, m_day into v_from, v_to, v_day from public._cairo_month(null);
  v_st := public.my_target_status();
  v_days := greatest(1, round(extract(epoch from (v_to - v_from)) / 86400.0)::int);
  v_target := coalesce((v_st ->> 'target_minor')::bigint, 0);
  v_daily := case when v_target > 0 then ceil(v_target::numeric / v_days)::bigint else 0 end;
  begin
    select coalesce(jsonb_agg(jsonb_build_object(
        'product_id', x.product_id, 'name_ar', x.name_ar, 'name_en', x.name_en, 'sku', x.sku, 'amount_minor', x.amount_minor,
        'sold_today', coalesce((select sum(i.quantity - i.refunded_qty) from public.pos_sale_items i join public.pos_sales p on p.id = i.sale_id
                                 where p.cashier_id = auth.uid() and p.created_at >= v_day and i.product_id = x.product_id), 0))), '[]'::jsonb)
      into v_prods
      from jsonb_to_recordset(public.commission_today_products()) as x(product_id uuid, name_ar text, name_en text, sku text, amount_minor bigint);
  exception when others then
    v_prods := '[]'::jsonb; -- no commission.today permission or no commission running: the list is just empty
  end;
  return jsonb_build_object(
    'monthly_target_minor', v_target, 'days_in_month', v_days, 'daily_target_minor', v_daily,
    'sales_today_minor', coalesce((v_st ->> 'sales_today_minor')::bigint, 0),
    'month_net_minor', coalesce((v_st ->> 'net_minor')::bigint, 0),
    'commission_today_minor', coalesce((v_st ->> 'commission_today_minor')::bigint, 0),
    'commission_month_minor', coalesce((v_st ->> 'commission_month_minor')::bigint, 0),
    'products', v_prods);
end $$;
revoke all on function public.my_challenge_today() from public, anon;
grant execute on function public.my_challenge_today() to authenticated;
