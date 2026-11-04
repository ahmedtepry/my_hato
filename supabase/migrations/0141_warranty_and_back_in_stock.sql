-- 1) Customers see the warranty of what they bought; 2) customers who favourited a product are told when it is back in stock.

-- Warranty length read from the product's warranty text ("سنة", "سنتين", "6 شهور", "2 year"...). null = the text has no clear length.
create or replace function public._warranty_months(p text) returns int
language sql immutable as $$
  select case
    when p is null or btrim(p) = '' then null
    when p ~ 'سنتين|سنتان|2 ?years?' then 24
    when p ~ '[0-9]+ ?(شهر|شهور|أشهر|اشهر|months?)' then (substring(p from '([0-9]+) ?(?:شهر|شهور|أشهر|اشهر|months?)'))::int
    when p ~ '[0-9]+ ?(سنة|سنين|سنوات|years?)' then (substring(p from '([0-9]+) ?(?:سنة|سنين|سنوات|years?)'))::int * 12
    when p ~ 'سنة|year' then 12
    when p ~ 'ستة شهور|نص سنة' then 6
    else null end
$$;

create or replace function public.my_warranties() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_auth();
  return coalesce((
    select jsonb_agg(x order by (x ->> 'delivered_at') desc) from (
      select jsonb_build_object(
        'reference', d.reference, 'name_ar', i.name_ar, 'name_en', i.name_en, 'qty', i.quantity,
        'delivered_at', d.delivered_at, 'warranty_ar', p.warranty_ar, 'warranty_en', p.warranty_en,
        'months', public._warranty_months(coalesce(nullif(p.warranty_ar, ''), p.warranty_en)),
        'ends_at', case when public._warranty_months(coalesce(nullif(p.warranty_ar, ''), p.warranty_en)) is not null
                        then d.delivered_at + make_interval(months => public._warranty_months(coalesce(nullif(p.warranty_ar, ''), p.warranty_en))) end) as x
      from public._delivered_orders d
      join public.orders o on o.id = d.id and o.customer_id = auth.uid()
      join public.order_items i on i.order_id = d.id
      left join public.products p on p.id = i.product_id
      where coalesce(p.warranty_ar, p.warranty_en, '') <> ''
      order by d.delivered_at desc limit 100) t), '[]'::jsonb);
end $$;
revoke all on function public.my_warranties() from public, anon;
grant execute on function public.my_warranties() to authenticated;

-- back in stock
create or replace function public._notify_back_in_stock() returns trigger
language plpgsql security definer set search_path = public as $$
declare f record;
begin
  if coalesce(old.stock_quantity, 0) <= 0 and new.stock_quantity > 0 and new.status::text = 'published' then
    for f in select user_id from public.product_favorites where product_id = new.id limit 500 loop
      perform public.notify_user(f.user_id, '🎉 رجع في المخزون', '🎉 Back in stock',
        coalesce(new.name_ar, '') || ' رجع متاح تاني، الحق اطلبه.', coalesce(new.name_en, new.name_ar, '') || ' is available again.',
        'system', null, null, '/product/' || new.id::text);
    end loop;
  end if;
  return null;
end $$;
drop trigger if exists products_back_in_stock on public.products;
create trigger products_back_in_stock after update of stock_quantity on public.products
  for each row when (old.stock_quantity is distinct from new.stock_quantity) execute function public._notify_back_in_stock();
