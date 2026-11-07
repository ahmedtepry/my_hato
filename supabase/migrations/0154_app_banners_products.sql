-- A product banner can carry up to 10 products; each becomes a slide that opens its product.
alter table public.banners add column if not exists product_ids uuid[] not null default '{}';
alter table public.banners drop constraint if exists banners_products_chk;
alter table public.banners add constraint banners_products_chk check (cardinality(product_ids) <= 10);
