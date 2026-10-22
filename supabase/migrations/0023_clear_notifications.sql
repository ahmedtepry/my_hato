-- 0023 Notifications: customers can clear them (one or all) — hidden, the rows are kept.
-- "Order received" / "repair received" messages now name the sales team / repair team.

alter table public.notifications add column if not exists cleared_at timestamptz;

create or replace function public.customer_clear_notifications(p_id uuid default null)
returns int language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  update public.notifications set cleared_at = now(), read_at = coalesce(read_at, now())
   where user_id = public.require_auth() and cleared_at is null and (p_id is null or id = p_id);
  get diagnostics v_n = row_count;
  return v_n;
end $$;
revoke all on function public.customer_clear_notifications(uuid) from public, anon;
grant execute on function public.customer_clear_notifications(uuid) to authenticated;

alter policy notifications_own_read on public.notifications
  using ((user_id = auth.uid() and cleared_at is null) or public.has_permission('customers.view'));

create or replace function public.place_order(
  p_idempotency_key text,
  p_fulfillment public.fulfillment_method,
  p_payment_method public.payment_method,
  p_branch_id uuid,
  p_address_id uuid,
  p_delivery_notes text)
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
          v_subtotal, v_list_total - v_subtotal, v_fee, v_subtotal + v_fee);

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

  return jsonb_build_object('order_id', v_order_id, 'reference', v_ref, 'total_minor', v_subtotal + v_fee, 'replayed', false);
end $$;

create or replace function public.request_repair(
  p_idempotency_key text,
  p_device_brand text,
  p_device_model text,
  p_imei_or_serial text,
  p_problem text,
  p_contact_name text,
  p_contact_phone text,
  p_pickup_address_id uuid,       -- null = customer brings the device to the branch
  p_branch_id uuid,
  p_preferred_pickup_at timestamptz,
  p_callback_requested boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := public.require_auth();
  v_existing public.repair_requests%rowtype;
  v_addr public.customer_addresses%rowtype;
  v_id uuid := gen_random_uuid();
  v_ref text;
  v_label record;
begin
  if p_idempotency_key is null or char_length(p_idempotency_key) not between 8 and 100 then
    raise exception 'INVALID_IDEMPOTENCY_KEY';
  end if;
  select * into v_existing from public.repair_requests where customer_id = v_uid and idempotency_key = p_idempotency_key;
  if found then
    return jsonb_build_object('repair_id', v_existing.id, 'reference', v_existing.reference, 'replayed', true);
  end if;

  if char_length(coalesce(trim(p_device_brand), '')) < 2 or char_length(coalesce(trim(p_device_model), '')) < 1
     or char_length(coalesce(trim(p_contact_name), '')) < 2 or coalesce(p_contact_phone, '') !~ '^\+?[0-9]{8,15}$' then
    raise exception 'INVALID_INPUT';
  end if;
  if p_imei_or_serial is not null and p_imei_or_serial !~ '^[A-Za-z0-9\-]{5,30}$' then
    raise exception 'INVALID_IMEI';
  end if;

  if p_pickup_address_id is not null then
    select * into v_addr from public.customer_addresses where id = p_pickup_address_id and user_id = v_uid;
    if not found then raise exception 'INVALID_ADDRESS'; end if;
  elsif p_branch_id is null or not exists (select 1 from public.branches where id = p_branch_id and is_active) then
    raise exception 'INVALID_BRANCH';
  end if;

  if p_preferred_pickup_at is not null and p_preferred_pickup_at < now() then
    raise exception 'INVALID_PICKUP_TIME';
  end if;

  v_ref := public.next_repair_reference();
  insert into public.repair_requests(id, reference, customer_id, idempotency_key, device_brand, device_model, imei_or_serial,
       problem_description, contact_name, contact_phone, pickup_address, branch_id, preferred_pickup_at, callback_requested)
  values (v_id, v_ref, v_uid, p_idempotency_key, trim(p_device_brand), trim(p_device_model), nullif(trim(p_imei_or_serial), ''),
       trim(p_problem), trim(p_contact_name), p_contact_phone,
       case when p_pickup_address_id is not null then jsonb_build_object(
         'recipient_name', v_addr.recipient_name, 'phone', v_addr.phone, 'governorate', v_addr.governorate,
         'city', v_addr.city, 'street', v_addr.street, 'building', v_addr.building, 'landmark', v_addr.landmark) end,
       p_branch_id, p_preferred_pickup_at, coalesce(p_callback_requested, false));

  select * into v_label from public.repair_status_labels where status = 'pickup_requested';
  insert into public.repair_status_history(repair_id, from_status, to_status, customer_message_ar, customer_message_en, changed_by)
  values (v_id, null, 'pickup_requested', v_label.message_ar, v_label.message_en, v_uid);

  -- New repair request -> service mailbox (myhatoservice@gmail.com)
  perform public.enqueue_email('repair_new', 'repair_notification_email',
    jsonb_build_object('repair_id', v_id), 'repair', v_id);

  perform public.notify_user(v_uid, 'تم تسجيل طلب الصيانة', 'Repair request received',
    'تم إرسال طلب الصيانة لفريق الصيانة، وهنكلمك قريب لتأكيد الطلب. رقم الطلب: ' || v_ref,
    'Your repair request was sent to our repair team. We will call you soon to confirm it. Reference: ' || v_ref,
    'repair', v_id, v_ref, '/repairs/' || v_id);

  return jsonb_build_object('repair_id', v_id, 'reference', v_ref, 'replayed', false);
end $$;
