-- 0081: the seller can see which products carry a commission TODAY (permission commission.today), and the POS tells him what he earned.
insert into public.permission_catalog (permission, grp, name_ar, name_en, desc_ar, desc_en, sensitive, inert, sort) values
 ('commission.today', 'pos', 'يشوف المنتجات اللي عليها كوميشن النهارده', 'See today''s commission products',
  'يشوف في صفحة «تارجتي وعمولتي» المنتجات اللي عليها كوميشن شغال النهارده وقيمة الكوميشن، ويطلعله تشجيع بعد كل بيعة فيها كوميشن', 'Sees on his target page the products with a commission running today and its value, and a cheer after each sale that earned one', false, false, 95)
on conflict (permission) do update set name_ar = excluded.name_ar, name_en = excluded.name_en, desc_ar = excluded.desc_ar, desc_en = excluded.desc_en;
insert into public.role_permissions (role, permission) values
 ('owner','commission.today'),('manager','commission.today'),('sales','commission.today'),('cashier','commission.today')
on conflict do nothing;

create or replace function public.commission_today_products() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_today date := (now() at time zone 'Africa/Cairo')::date;
begin
  perform public.require_permission('commission.today');
  return coalesce((select jsonb_agg(jsonb_build_object('product_id', p.id, 'name_ar', p.name_ar, 'name_en', p.name_en, 'sku', p.sku,
                      'amount_minor', c.amount_minor, 'ends_on', c.ends_on) order by c.amount_minor desc, p.name_ar)
    from public.product_commissions c join public.products p on p.id = c.product_id
    where p.status = 'published' and c.amount_minor > 0 and (c.starts_on is null or c.starts_on <= v_today) and (c.ends_on is null or c.ends_on >= v_today)), '[]'::jsonb);
end $$;
revoke all on function public.commission_today_products() from public, anon;
grant execute on function public.commission_today_products() to authenticated;
