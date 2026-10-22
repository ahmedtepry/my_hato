-- 0025 Catalog rows carry the brand name, so product tiles can show "Oppo · A73" without extra queries.
create or replace view public.catalog_products
with (security_invoker = true) as
select
  p.id, p.sku, p.slug, p.category_id, p.brand_id, p.model,
  p.name_ar, p.name_en, p.description_ar, p.description_en,
  p.price_minor, p.compare_at_price_minor, p.currency,
  case when p.compare_at_price_minor is not null
       then round(((p.compare_at_price_minor - p.price_minor)::numeric / p.compare_at_price_minor) * 100)::int
       else 0 end as discount_percent,
  (p.stock_quantity > 0) as in_stock,
  p.stock_quantity, p.warranty_ar, p.warranty_en, p.is_featured,
  p.sold_count, p.rating_avg, p.rating_count, p.published_at, p.keywords,
  (select pi.storage_path from public.product_images pi where pi.product_id = p.id order by pi.sort_order limit 1) as thumb_path,
  (select b.name_ar from public.brands b where b.id = p.brand_id) as brand_name_ar,
  (select b.name_en from public.brands b where b.id = p.brand_id) as brand_name_en
from public.products p
where p.status = 'published';
