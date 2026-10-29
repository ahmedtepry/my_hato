-- 0093: the warehouse view. What is not given to a branch is the WAREHOUSE (الوير هاوس). A branch member sees only his own branch store;
-- ("see every branch" alone does not show other branches' stock). The owner decides who may also see what is left in the warehouse and in the other branches (permission stock.others, owner only by default).

insert into public.permission_catalog (permission, grp, name_ar, name_en, desc_ar, desc_en, sensitive, inert, sort) values
 ('stock.others', 'team', 'يشوف المتاح في الوير هاوس والفروع التانية', 'See stock in the warehouse and other branches',
  'لما يدوس على منتج يشوف الباقي منه في الوير هاوس وفي كل فرع. من غيرها بيشوف مخزون فرعه بس',
  'When he opens a product he sees what is left in the warehouse and in every branch. Without it he sees his own branch store only', true, false, 114)
on conflict (permission) do update set name_ar = excluded.name_ar, name_en = excluded.name_en, desc_ar = excluded.desc_ar, desc_en = excluded.desc_en;
insert into public.role_permissions (role, permission) values ('owner', 'stock.others') on conflict do nothing;

-- the list: store totals and the warehouse figure only for who may see them
create or replace function public.stock_overview(p_branch uuid default null, p_search text default null, p_limit int default 60) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_q text := nullif(btrim(coalesce(p_search, '')), ''); v_all boolean;
begin
  perform public.require_permission('stock.view');
  v_all := public.has_permission('stock.others');
  if p_branch is not null and not (case when v_all then public._branch_view_ok(p_branch) else public._branch_ok(p_branch) end) then raise exception 'FORBIDDEN'; end if;
  return coalesce((select jsonb_agg(x order by x.name_ar) from (
    select p.id as product_id, p.sku, p.name_ar, p.name_en,
           case when v_all then p.stock_quantity end as total,
           case when v_all then greatest(public._stock_unallocated(p.id), 0) end as unallocated,
           coalesce((select jsonb_agg(jsonb_build_object('branch_id', bs.branch_id, 'qty', bs.quantity))
                       from public.branch_stock bs where bs.product_id = p.id and bs.quantity > 0 and (v_all or public._branch_ok(bs.branch_id))), '[]'::jsonb) as branches
      from public.products p
     where p.status <> 'archived'
       and (v_q is null or p.name_ar ilike '%' || v_q || '%' or p.name_en ilike '%' || v_q || '%' or p.sku ilike '%' || v_q || '%')
       and (p_branch is null or v_q is not null or exists (select 1 from public.branch_stock bs where bs.product_id = p.id and bs.branch_id = p_branch and bs.quantity > 0))
       and (v_all or v_q is not null or exists (select 1 from public.branch_stock bs where bs.product_id = p.id and bs.quantity > 0 and public._branch_ok(bs.branch_id)))
     order by p.name_ar limit least(greatest(coalesce(p_limit, 60), 1), 200)) x), '[]'::jsonb);
end $$;
revoke all on function public.stock_overview(uuid, text, int) from public, anon;
grant execute on function public.stock_overview(uuid, text, int) to authenticated;

-- one product: where is it? (the warehouse and every branch only for stock.others; otherwise just the branches he may see)
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
               where b.is_active and (v_all or public._branch_ok(b.id))), '[]'::jsonb));
end $$;
revoke all on function public.stock_product_where(uuid) from public, anon;
grant execute on function public.stock_product_where(uuid) to authenticated;
