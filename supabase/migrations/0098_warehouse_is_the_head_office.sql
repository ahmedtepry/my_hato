-- 0098: the head office branch is now called الوير هاوس (the warehouse). It is not a store of its own: its stock is the unallocated stock,
-- so it is no longer listed as a separate branch row in the product's stock sheet.
update public.branches set name_ar = 'الوير هاوس', name_en = 'Warehouse' where is_hq;
create or replace function public.stock_product_where(p_product uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_all boolean; p public.products;
begin
  perform public.require_permission('stock.view');
  v_all := public.has_permission('stock.others');
  select * into p from public.products where id = p_product;
  if not found then raise exception 'NOT_FOUND'; end if;
  return jsonb_build_object(
    'product_id', p.id, 'name_ar', p.name_ar, 'name_en', p.name_en, 'sku', p.sku,
    'can_see_others', v_all,
    'warehouse', case when v_all then greatest(public._stock_unallocated(p.id), 0) end,
    'total', case when v_all then p.stock_quantity end,
    'branches', coalesce((select jsonb_agg(jsonb_build_object('branch_id', b.id, 'name_ar', b.name_ar, 'name_en', b.name_en,
                  'qty', coalesce(bs.quantity, 0), 'mine', public._branch_ok(b.id)) order by public._branch_ok(b.id) desc, b.is_hq, b.created_at)
                from public.branches b left join public.branch_stock bs on bs.branch_id = b.id and bs.product_id = p.id
               where b.is_active and not b.is_hq and (v_all or public._branch_ok(b.id))), '[]'::jsonb));
end $$;
revoke all on function public.stock_product_where(uuid) from public, anon;
grant execute on function public.stock_product_where(uuid) to authenticated;
