-- =====================================================================
-- My Hatō — 0002 catalog (bilingual AR/EN, admin-editable categories)
-- =====================================================================

create table public.categories (
  id uuid primary key default gen_random_uuid(),
  parent_id uuid references public.categories(id) on delete set null,
  kind text not null check (kind in ('phones','accessories','used')),  -- 'used' = pre-owned devices (section shown as "coming soon" until enabled)
  slug text not null unique,
  name_ar text not null,
  name_en text not null,
  image_path text,
  sort_order int not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index categories_parent_idx on public.categories(parent_id);
create trigger categories_updated before update on public.categories
  for each row execute function public.set_updated_at();

create table public.brands (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  name_ar text not null,
  name_en text not null,
  logo_path text,
  sort_order int not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger brands_updated before update on public.brands
  for each row execute function public.set_updated_at();

create table public.products (
  id uuid primary key default gen_random_uuid(),
  sku text not null unique,
  slug text not null unique,
  category_id uuid not null references public.categories(id),
  brand_id uuid references public.brands(id),
  model text,
  name_ar text not null,
  name_en text not null,
  description_ar text,
  description_en text,
  price_minor bigint not null check (price_minor >= 0),
  compare_at_price_minor bigint check (compare_at_price_minor is null or compare_at_price_minor > price_minor),
  currency char(3) not null default 'EGP' check (currency = 'EGP'),
  stock_quantity int not null default 0 check (stock_quantity >= 0),
  warranty_ar text,
  warranty_en text,
  keywords text[] not null default '{}',
  status text not null default 'draft' check (status in ('draft','published','archived')),
  is_featured boolean not null default false,
  sold_count int not null default 0 check (sold_count >= 0),
  rating_avg numeric(3,2) not null default 0,
  rating_count int not null default 0,
  published_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index products_category_idx on public.products(category_id);
create index products_brand_idx on public.products(brand_id);
create index products_status_idx on public.products(status, published_at desc);
create index products_price_idx on public.products(price_minor);
create index products_sold_idx on public.products(sold_count desc);
create index products_name_trgm on public.products using gin ((name_ar || ' ' || name_en || ' ' || coalesce(model,'') || ' ' || sku) extensions.gin_trgm_ops);
create trigger products_updated before update on public.products
  for each row execute function public.set_updated_at();

create or replace function public.products_set_published_at()
returns trigger language plpgsql as $$
begin
  if new.status = 'published' and (tg_op = 'INSERT' or old.status is distinct from 'published') then
    new.published_at = coalesce(new.published_at, now());
  end if;
  return new;
end $$;
create trigger products_published_at before insert or update on public.products
  for each row execute function public.products_set_published_at();

create table public.product_variants (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete cascade,
  sku text not null unique,
  name_ar text not null,
  name_en text not null,
  color_hex text,
  price_minor bigint check (price_minor is null or price_minor >= 0), -- null = inherit product price
  stock_quantity int not null default 0 check (stock_quantity >= 0),
  sort_order int not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);
create index product_variants_product_idx on public.product_variants(product_id);

create table public.product_images (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete cascade,
  storage_path text not null,
  alt_ar text,
  alt_en text,
  sort_order int not null default 0,
  created_at timestamptz not null default now()
);
create index product_images_product_idx on public.product_images(product_id, sort_order);

-- 360° frames: only products with >= 12 ordered frames are shown as 360° in the app.
create table public.product_360_assets (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete cascade,
  storage_path text not null,
  frame_index int not null check (frame_index >= 0),
  created_at timestamptz not null default now(),
  unique (product_id, frame_index)
);

create table public.product_specifications (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete cascade,
  label_ar text not null,
  label_en text not null,
  value_ar text not null,
  value_en text not null,
  sort_order int not null default 0
);
create index product_specs_product_idx on public.product_specifications(product_id, sort_order);

create table public.product_favorites (
  user_id uuid not null references auth.users(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, product_id)
);

create table public.recently_viewed (
  user_id uuid not null references auth.users(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  viewed_at timestamptz not null default now(),
  primary key (user_id, product_id)
);

create table public.banners (
  id uuid primary key default gen_random_uuid(),
  title_ar text not null,
  title_en text not null,
  image_path text not null,
  link_type text check (link_type in ('product','category','repair','url')),
  link_value text,
  sort_order int not null default 0,
  is_active boolean not null default true,
  starts_at timestamptz,
  ends_at timestamptz,
  created_at timestamptz not null default now()
);

-- Public view: published products only, computed discount, in-stock flag.
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
  (select pi.storage_path from public.product_images pi where pi.product_id = p.id order by pi.sort_order limit 1) as thumb_path
from public.products p
where p.status = 'published';
