-- 0029 Discount codes and offers.
-- Staff create codes (percent or fixed amount, minimum order, total / per-customer limits, end date)
-- and can send an offer notification (optionally with a code) to every customer in the app.
-- The code is applied at checkout: place_order re-validates it inside the order transaction.

create table public.coupons (
  code text primary key check (code ~ '^[A-Z0-9_-]{3,24}$'),
  title_ar text,
  percent_off int check (percent_off is null or percent_off between 1 and 90),
  amount_off_minor bigint check (amount_off_minor is null or amount_off_minor > 0),
  min_order_minor bigint not null default 0 check (min_order_minor >= 0),
  max_uses int check (max_uses is null or max_uses > 0),
  per_customer_limit int not null default 1 check (per_customer_limit > 0),
  uses_count int not null default 0,
  starts_at timestamptz not null default now(),
  ends_at timestamptz,
  is_active boolean not null default true,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((percent_off is null) <> (amount_off_minor is null))
);
create trigger coupons_updated before update on public.coupons for each row execute function public.set_updated_at();
alter table public.coupons enable row level security;
revoke all on public.coupons from anon, authenticated;
grant select on public.coupons to authenticated;
create policy coupons_staff_read on public.coupons for select to authenticated using (public.has_permission('orders.manage'));

create table public.coupon_redemptions (
  id bigint generated always as identity primary key,
  coupon_code text not null references public.coupons(code),
  order_id uuid not null references public.orders(id) on delete cascade,
  user_id uuid not null references auth.users(id),
  discount_minor bigint not null,
  created_at timestamptz not null default now()
);
create index coupon_redemptions_code_user_idx on public.coupon_redemptions(coupon_code, user_id);
alter table public.coupon_redemptions enable row level security;
revoke all on public.coupon_redemptions from anon, authenticated;

alter table public.orders
  add column if not exists coupon_code text,
  add column if not exists coupon_discount_minor bigint not null default 0;

-- discount for a subtotal, or COUPON_* error (not found / inactive / expired / min order / used up)
create or replace function public._coupon_discount(p_c public.coupons, p_user uuid, p_subtotal bigint)
returns bigint language plpgsql stable security definer set search_path = public as $$
declare v_mine int;
begin
  if p_c.code is null or not p_c.is_active then raise exception 'COUPON_INVALID'; end if;
  if p_c.starts_at > now() or (p_c.ends_at is not null and p_c.ends_at < now()) then raise exception 'COUPON_EXPIRED'; end if;
  if p_subtotal < p_c.min_order_minor then raise exception 'COUPON_MIN_ORDER:%', p_c.min_order_minor; end if;
  if p_c.max_uses is not null and p_c.uses_count >= p_c.max_uses then raise exception 'COUPON_USED_UP'; end if;
  select count(*) into v_mine from public.coupon_redemptions r join public.orders o on o.id = r.order_id
   where r.coupon_code = p_c.code and r.user_id = p_user and o.status <> 'cancelled';
  if v_mine >= p_c.per_customer_limit then raise exception 'COUPON_ALREADY_USED'; end if;
  return least(p_subtotal,
               coalesce(floor(p_subtotal * p_c.percent_off / 100.0)::bigint, p_c.amount_off_minor));
end $$;
revoke all on function public._coupon_discount(public.coupons, uuid, bigint) from public, anon, authenticated;

-- checkout preview: discount for the signed-in customer's current cart subtotal
create or replace function public.check_coupon(p_code text, p_subtotal_minor bigint)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_c public.coupons%rowtype;
begin
  select * into v_c from public.coupons where code = upper(trim(coalesce(p_code, '')));
  return jsonb_build_object('code', v_c.code, 'discount_minor', public._coupon_discount(v_c, public.require_auth(), p_subtotal_minor),
                            'percent_off', v_c.percent_off, 'amount_off_minor', v_c.amount_off_minor, 'title_ar', v_c.title_ar);
end $$;
revoke all on function public.check_coupon(text, bigint) from public, anon;
grant execute on function public.check_coupon(text, bigint) to authenticated;

-- staff: create / edit a code
create or replace function public.staff_save_coupon(p_code text, p_title_ar text, p_percent_off int, p_amount_off_minor bigint,
  p_min_order_minor bigint, p_max_uses int, p_per_customer_limit int, p_ends_at timestamptz, p_is_active boolean)
returns text language plpgsql security definer set search_path = public as $$
declare v_code text := upper(trim(coalesce(p_code, '')));
begin
  perform public.require_permission('orders.manage');
  insert into public.coupons(code, title_ar, percent_off, amount_off_minor, min_order_minor, max_uses, per_customer_limit, ends_at, is_active, created_by)
  values (v_code, nullif(trim(p_title_ar), ''), p_percent_off, p_amount_off_minor, coalesce(p_min_order_minor, 0), p_max_uses,
          coalesce(p_per_customer_limit, 1), p_ends_at, coalesce(p_is_active, true), auth.uid())
  on conflict (code) do update set title_ar = excluded.title_ar, percent_off = excluded.percent_off,
     amount_off_minor = excluded.amount_off_minor, min_order_minor = excluded.min_order_minor, max_uses = excluded.max_uses,
     per_customer_limit = excluded.per_customer_limit, ends_at = excluded.ends_at, is_active = excluded.is_active;
  perform public.audit_write('coupon.save', 'coupon', v_code, jsonb_build_object('percent', p_percent_off, 'amount', p_amount_off_minor));
  return v_code;
end $$;
revoke all on function public.staff_save_coupon(text, text, int, bigint, bigint, int, int, timestamptz, boolean) from public, anon;
grant execute on function public.staff_save_coupon(text, text, int, bigint, bigint, int, int, timestamptz, boolean) to authenticated;

-- staff: send an offer notification to every customer (team members excluded); returns how many got it
create or replace function public.staff_broadcast_offer(p_title text, p_body text, p_coupon_code text default null)
returns int language plpgsql security definer set search_path = public as $$
declare
  v_code text := nullif(upper(trim(coalesce(p_coupon_code, ''))), '');
  v_link text;
  v_n int := 0;
  r record;
begin
  perform public.require_permission('orders.manage');
  if nullif(trim(p_title), '') is null or nullif(trim(p_body), '') is null or length(p_title) > 120 or length(p_body) > 500 then
    raise exception 'INVALID_INPUT';
  end if;
  if v_code is not null and not exists (select 1 from public.coupons where code = v_code and is_active) then
    raise exception 'COUPON_INVALID';
  end if;
  -- at most 5 broadcasts a day, so customers are not spammed
  if (select count(*) from public.audit_logs where action = 'offer.broadcast' and created_at > now() - interval '24 hours') >= 5 then
    raise exception 'RATE_LIMITED';
  end if;
  v_link := case when v_code is null then '/' else '/cart?coupon=' || v_code end;
  for r in select p.id from public.profiles p
            where not exists (select 1 from public.user_roles ur where ur.user_id = p.id) loop
    perform public.notify_user(r.id, trim(p_title), trim(p_title), trim(p_body), trim(p_body), 'promo', null, v_code, v_link);
    v_n := v_n + 1;
  end loop;
  perform public.audit_write('offer.broadcast', 'coupon', coalesce(v_code, '-'), jsonb_build_object('title', p_title, 'sent', v_n));
  return v_n;
end $$;
revoke all on function public.staff_broadcast_offer(text, text, text) from public, anon;
grant execute on function public.staff_broadcast_offer(text, text, text) to authenticated;

-- place_order with a discount code (the 6-argument version keeps working for older app versions)
create or replace function public.place_order(
  p_idempotency_key text,
  p_fulfillment public.fulfillment_method,
  p_payment_method public.payment_method,
  p_branch_id uuid,
  p_address_id uuid,
  p_delivery_notes text,
  p_coupon_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := public.require_auth();
  v_existing public.orders%rowtype;
  v_profile public.profiles%rowtype;
  v_addr public.customer_addresses%rowtype;
  v_cart uuid;
  v_order_id uuid;
  v_ref text;
  v_subtotal bigint := 0;
  v_list_total bigint := 0;
  v_fee bigint := 0;
  v_line record;
  v_items jsonb := '[]'::jsonb;
  v_count int := 0;
  v_phone text;
  v_enabled jsonb := public.setting('enabled_payment_methods');
  v_coupon public.coupons%rowtype;
  v_coupon_discount bigint := 0;
  v_code text := nullif(upper(trim(coalesce(p_coupon_code, ''))), '');
begin
  if p_idempotency_key is null or char_length(p_idempotency_key) not between 8 and 100 then
    raise exception 'INVALID_IDEMPOTENCY_KEY';
  end if;

  -- idempotent replay: same key returns the same order, never a duplicate
  select * into v_existing from public.orders where customer_id = v_uid and idempotency_key = p_idempotency_key;
  if found then
    return jsonb_build_object('order_id', v_existing.id, 'reference', v_existing.reference, 'total_minor', v_existing.total_minor, 'replayed', true);
  end if;

  if v_enabled is not null and not (v_enabled ? p_payment_method::text) then
    raise exception 'PAYMENT_METHOD_DISABLED';
  end if;

  select * into v_profile from public.profiles where id = v_uid;
  -- the account must be verified: email confirmed by OTP (Supabase Auth) or phone confirmed by SMS OTP
  if v_profile.id is null or not (v_profile.email_verified or v_profile.phone_verified) then
    raise exception 'ACCOUNT_NOT_VERIFIED';
  end if;

  if p_fulfillment = 'pickup' then
    if not exists (select 1 from public.branches where id = p_branch_id and is_active) then
      raise exception 'INVALID_BRANCH';
    end if;
  else
    select * into v_addr from public.customer_addresses where id = p_address_id and user_id = v_uid;
    if not found then raise exception 'INVALID_ADDRESS'; end if;
  end if;

  -- a reachable phone for the order: verified phone, else the customer's contact phone, else the delivery address phone
  v_phone := coalesce(case when v_profile.phone_verified then v_profile.phone end,
                      v_profile.contact_phone,
                      case when p_fulfillment = 'delivery' then v_addr.phone end);
  if v_phone is null then raise exception 'PHONE_REQUIRED'; end if;

  select id into v_cart from public.carts where user_id = v_uid;
  if v_cart is null then raise exception 'CART_EMPTY'; end if;

  -- lock product + variant rows in deterministic order to prevent overselling / deadlocks
  perform 1 from public.products p
   where p.id in (select product_id from public.cart_items where cart_id = v_cart)
   order by p.id for update;
  perform 1 from public.product_variants v
   where v.id in (select variant_id from public.cart_items where cart_id = v_cart and variant_id is not null)
   order by v.id for update;

  v_ref := public.next_order_reference();
  v_order_id := gen_random_uuid();

  for v_line in
    select ci.product_id, ci.variant_id, ci.quantity, p.sku, p.name_ar, p.name_en, p.status,
           p.stock_quantity as p_stock, p.compare_at_price_minor,
           v.sku as v_sku, v.name_ar as v_name_ar, v.name_en as v_name_en, v.is_active as v_active,
           v.stock_quantity as v_stock,
           coalesce(v.price_minor, p.price_minor) as unit_price
      from public.cart_items ci
      join public.products p on p.id = ci.product_id
      left join public.product_variants v on v.id = ci.variant_id
     where ci.cart_id = v_cart
     order by ci.created_at
  loop
    if v_line.status <> 'published' or (v_line.variant_id is not null and not v_line.v_active) then
      raise exception 'PRODUCT_UNAVAILABLE:%', v_line.sku;
    end if;
    if (v_line.variant_id is null and v_line.p_stock < v_line.quantity)
       or (v_line.variant_id is not null and v_line.v_stock < v_line.quantity) then
      raise exception 'OUT_OF_STOCK:%', coalesce(v_line.v_sku, v_line.sku);
    end if;

    v_count := v_count + 1;
    v_subtotal := v_subtotal + v_line.unit_price * v_line.quantity;
    v_list_total := v_list_total + greatest(v_line.unit_price, coalesce(v_line.compare_at_price_minor, 0)) * v_line.quantity;
    v_items := v_items || jsonb_build_object(
      'product_id', v_line.product_id, 'variant_id', v_line.variant_id,
      'sku', coalesce(v_line.v_sku, v_line.sku), 'name_ar', v_line.name_ar, 'name_en', v_line.name_en,
      'variant_name_ar', v_line.v_name_ar, 'variant_name_en', v_line.v_name_en,
      'unit_price_minor', v_line.unit_price,
      'list_price_minor', greatest(v_line.unit_price, coalesce(v_line.compare_at_price_minor, 0)),
      'quantity', v_line.quantity);
  end loop;

  if v_count = 0 then raise exception 'CART_EMPTY'; end if;

  if p_fulfillment = 'delivery' then
    v_fee := public.quote_delivery_fee(v_addr.governorate, v_subtotal);
  end if;

  -- discount code (validated again here: the checkout preview is only a hint)
  if v_code is not null then
    select * into v_coupon from public.coupons where code = v_code for update;
    v_coupon_discount := public._coupon_discount(v_coupon, v_uid, v_subtotal);  -- raises COUPON_* when not usable
  end if;

  insert into public.orders(id, reference, customer_id, idempotency_key, fulfillment, payment_method, branch_id,
                            customer_name, customer_phone, customer_email, delivery_address, delivery_notes,
                            subtotal_minor, discount_minor, delivery_fee_minor, total_minor)
  values (v_order_id, v_ref, v_uid, p_idempotency_key, p_fulfillment, p_payment_method,
          case when p_fulfillment = 'pickup' then p_branch_id end,
          coalesce(nullif(v_profile.full_name, ''), v_addr.recipient_name, v_phone),
          v_phone, v_profile.email,
          case when p_fulfillment = 'delivery' then jsonb_build_object(
            'recipient_name', v_addr.recipient_name, 'phone', v_addr.phone, 'governorate', v_addr.governorate,
            'city', v_addr.city, 'street', v_addr.street, 'building', v_addr.building, 'landmark', v_addr.landmark) end,
          left(nullif(trim(p_delivery_notes), ''), 500),
          v_subtotal - v_coupon_discount, (v_list_total - v_subtotal) + v_coupon_discount, v_fee, v_subtotal - v_coupon_discount + v_fee);
  if v_coupon_discount > 0 then
    update public.orders set coupon_code = v_code, coupon_discount_minor = v_coupon_discount where id = v_order_id;
    insert into public.coupon_redemptions(coupon_code, order_id, user_id, discount_minor) values (v_code, v_order_id, v_uid, v_coupon_discount);
    update public.coupons set uses_count = uses_count + 1 where code = v_code;
  end if;

  insert into public.order_items(order_id, product_id, variant_id, sku, name_ar, name_en, variant_name_ar, variant_name_en,
                                 unit_price_minor, list_price_minor, quantity, line_total_minor)
  select v_order_id, (i->>'product_id')::uuid, nullif(i->>'variant_id','')::uuid, i->>'sku', i->>'name_ar', i->>'name_en',
         i->>'variant_name_ar', i->>'variant_name_en', (i->>'unit_price_minor')::bigint, (i->>'list_price_minor')::bigint,
         (i->>'quantity')::int, (i->>'unit_price_minor')::bigint * (i->>'quantity')::int
    from jsonb_array_elements(v_items) i;

  -- atomic stock decrement (CHECK stock_quantity >= 0 is the last line of defence)
  perform set_config('myhato.stock_ctx', 'order', true);
  for v_line in
    select (i->>'product_id')::uuid as pid, nullif(i->>'variant_id','')::uuid as vid, sum((i->>'quantity')::int)::int as qty
      from jsonb_array_elements(v_items) i group by 1, 2
  loop
    if v_line.vid is null then
      update public.products set stock_quantity = stock_quantity - v_line.qty, sold_count = sold_count + v_line.qty
       where id = v_line.pid;
    else
      update public.product_variants set stock_quantity = stock_quantity - v_line.qty where id = v_line.vid;
      update public.products set sold_count = sold_count + v_line.qty where id = v_line.pid;
    end if;
    insert into public.inventory_movements(product_id, variant_id, delta, reason, order_id, created_by)
    values (v_line.pid, v_line.vid, -v_line.qty, 'order', v_order_id, v_uid);
  end loop;
  perform set_config('myhato.stock_ctx', '', true);

  insert into public.order_status_history(order_id, from_status, to_status, changed_by)
  values (v_order_id, null, 'pending_confirmation', v_uid);

  -- clear cart only now (same transaction: if anything above fails, nothing is committed)
  perform public._clear_cart(v_cart);

  perform public.enqueue_email('order_new', 'orders_notification_email',
    jsonb_build_object('order_id', v_order_id), 'order', v_order_id);

  perform public.notify_user(v_uid,
    'تم استلام طلبك', 'Order received',
    'تم إرسال طلبك لفريق المبيعات، وهنكلمك قريب لتأكيد الطلب. رقم الطلب: ' || v_ref,
    'Your order was sent to our sales team. We will call you soon to confirm it. Order: ' || v_ref,
    'order', v_order_id, v_ref, '/orders/' || v_order_id);

  return jsonb_build_object('order_id', v_order_id, 'reference', v_ref, 'total_minor', v_subtotal - v_coupon_discount + v_fee,
                            'coupon_discount_minor', v_coupon_discount, 'replayed', false);
end $$;

create or replace function public.place_order(
  p_idempotency_key text,
  p_fulfillment public.fulfillment_method,
  p_payment_method public.payment_method,
  p_branch_id uuid,
  p_address_id uuid,
  p_delivery_notes text)
returns jsonb language sql security definer set search_path = public as $$
  select public.place_order(p_idempotency_key, p_fulfillment, p_payment_method, p_branch_id, p_address_id, p_delivery_notes, null::text);
$$;
revoke all on function public.place_order(text, public.fulfillment_method, public.payment_method, uuid, uuid, text, text) from public, anon;
grant execute on function public.place_order(text, public.fulfillment_method, public.payment_method, uuid, uuid, text, text) to authenticated;
