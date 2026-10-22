-- =====================================================================
-- My Hatō — 0003 cart, branches, orders, inventory
-- =====================================================================

create table public.branches (
  id uuid primary key default gen_random_uuid(),
  name_ar text not null,
  name_en text not null,
  address_ar text not null,
  address_en text not null,
  phone text,
  hours_ar text,
  hours_en text,
  pickup_instructions_ar text,
  pickup_instructions_en text,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.delivery_zones (
  id uuid primary key default gen_random_uuid(),
  governorate text not null unique,
  fee_minor bigint not null check (fee_minor >= 0),
  eta_ar text,
  eta_en text,
  is_active boolean not null default true
);

create table public.carts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references auth.users(id) on delete cascade,
  updated_at timestamptz not null default now()
);

create table public.cart_items (
  id uuid primary key default gen_random_uuid(),
  cart_id uuid not null references public.carts(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  variant_id uuid references public.product_variants(id) on delete cascade,
  quantity int not null check (quantity > 0 and quantity <= 20),
  created_at timestamptz not null default now(),
  unique (cart_id, product_id, variant_id)
);
create index cart_items_cart_idx on public.cart_items(cart_id);

-- unique index treating NULL variant as one slot
create unique index cart_items_unique_novariant on public.cart_items(cart_id, product_id) where variant_id is null;

create sequence public.order_ref_seq start 1000;

create table public.orders (
  id uuid primary key default gen_random_uuid(),
  reference text not null unique,
  customer_id uuid not null references auth.users(id),
  idempotency_key text not null,
  status public.order_status not null default 'pending_confirmation',
  fulfillment public.fulfillment_method not null,
  payment_method public.payment_method not null,
  payment_status public.payment_status not null default 'unpaid',
  branch_id uuid references public.branches(id),
  -- immutable snapshots (so later profile/address edits do not alter history)
  customer_name text not null,
  customer_phone text not null,
  customer_email text,
  delivery_address jsonb,
  delivery_notes text,
  subtotal_minor bigint not null check (subtotal_minor >= 0),
  discount_minor bigint not null default 0 check (discount_minor >= 0),
  delivery_fee_minor bigint not null default 0 check (delivery_fee_minor >= 0),
  total_minor bigint not null check (total_minor >= 0),
  currency char(3) not null default 'EGP',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (customer_id, idempotency_key),
  check ((fulfillment = 'pickup' and branch_id is not null) or (fulfillment = 'delivery' and delivery_address is not null)),
  check (total_minor = subtotal_minor + delivery_fee_minor)  -- subtotal is already net of discounts
);
create index orders_customer_idx on public.orders(customer_id, created_at desc);
create index orders_status_idx on public.orders(status, created_at desc);
create trigger orders_updated before update on public.orders
  for each row execute function public.set_updated_at();

create table public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  product_id uuid references public.products(id) on delete set null,
  variant_id uuid references public.product_variants(id) on delete set null,
  sku text not null,
  name_ar text not null,
  name_en text not null,
  variant_name_ar text,
  variant_name_en text,
  unit_price_minor bigint not null check (unit_price_minor >= 0),
  list_price_minor bigint not null check (list_price_minor >= 0),
  quantity int not null check (quantity > 0),
  line_total_minor bigint not null check (line_total_minor >= 0),
  check (line_total_minor = unit_price_minor * quantity)
);
create index order_items_order_idx on public.order_items(order_id);

create table public.order_status_history (
  id bigint generated always as identity primary key,
  order_id uuid not null references public.orders(id) on delete cascade,
  from_status public.order_status,
  to_status public.order_status not null,
  note text,
  changed_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);
create index order_status_history_order_idx on public.order_status_history(order_id, created_at);

create table public.order_transitions (
  from_status public.order_status not null,
  to_status public.order_status not null,
  fulfillment public.fulfillment_method, -- null = applies to both
  primary key (from_status, to_status)
);
insert into public.order_transitions(from_status, to_status, fulfillment) values
  ('pending_confirmation','confirmed',null),
  ('pending_confirmation','cancelled',null),
  ('confirmed','preparing',null),
  ('confirmed','cancelled',null),
  ('preparing','ready_for_pickup','pickup'),
  ('preparing','out_for_delivery','delivery'),
  ('preparing','cancelled',null),
  ('ready_for_pickup','delivered','pickup'),
  ('ready_for_pickup','cancelled','pickup'),
  ('out_for_delivery','delivered','delivery'),
  ('out_for_delivery','cancelled','delivery');

create table public.inventory_movements (
  id bigint generated always as identity primary key,
  product_id uuid not null references public.products(id),
  variant_id uuid references public.product_variants(id),
  delta int not null check (delta <> 0),
  reason text not null check (reason in ('order','order_cancel','manual_adjust','restock','correction')),
  order_id uuid references public.orders(id),
  note text,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);
create index inventory_movements_product_idx on public.inventory_movements(product_id, created_at desc);
