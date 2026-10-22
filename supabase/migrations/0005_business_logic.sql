-- =====================================================================
-- My Hatō — 0005 server-side business logic (atomic PL/pgSQL functions)
-- Clients never send prices/totals. Every privileged action checks
-- permissions + allowed transitions, writes history, audit and notifications.
-- =====================================================================

-- ---------- helpers ----------
create or replace function public.fmt_egp(p_minor bigint)
returns text language sql immutable as $$
  select case when p_minor % 100 = 0
              then to_char(p_minor / 100, 'FM999,999,999,990')
              else to_char(p_minor / 100.0, 'FM999,999,999,990.00') end
$$;

create or replace function public.setting(p_key text)
returns jsonb language sql stable security definer set search_path = public as $$
  select value from public.application_settings where key = p_key
$$;

create or replace function public.next_order_reference()
returns text language sql volatile security definer set search_path = public as $$
  select 'MH-' || to_char(now() at time zone 'Africa/Cairo', 'YYMMDD') || '-' || nextval('public.order_ref_seq')::text
$$;

create or replace function public.next_repair_reference()
returns text language sql volatile security definer set search_path = public as $$
  select 'MY-HATO' || nextval('public.repair_ref_seq')::text
$$;

create or replace function public.require_auth()
returns uuid language plpgsql stable as $$
begin
  if auth.uid() is null then
    raise exception 'AUTH_REQUIRED' using errcode = '28000';
  end if;
  return auth.uid();
end $$;

create or replace function public.require_permission(p text)
returns void language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_auth();
  if not public.has_permission(p) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
end $$;

create or replace function public.notify_user(
  p_user uuid, p_title_ar text, p_title_en text, p_body_ar text, p_body_en text,
  p_entity_type text, p_entity_id uuid, p_reference text, p_deep_link text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  insert into public.notifications(user_id, title_ar, title_en, body_ar, body_en, entity_type, entity_id, entity_reference, deep_link)
  values (p_user, p_title_ar, p_title_en, p_body_ar, p_body_en, p_entity_type, p_entity_id, p_reference, p_deep_link)
  returning id into v_id;
  insert into public.notification_delivery_logs(notification_id, channel, status) values (v_id, 'in_app', 'delivered');
  -- push channel: picked up by send-customer-notification Edge Function when FCM is configured
  insert into public.notification_delivery_logs(notification_id, channel, status) values (v_id, 'push', 'queued');
  return v_id;
end $$;

create or replace function public.enqueue_email(p_kind public.email_kind, p_to_setting text, p_payload jsonb, p_related_type text, p_related_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_to text := public.setting(p_to_setting) #>> '{}';
begin
  if v_to is null or v_to = '' then
    return;
  end if;
  insert into public.email_outbox(kind, to_email, payload, related_type, related_id)
  values (p_kind, v_to, p_payload, p_related_type, p_related_id)
  on conflict (kind, related_id) do nothing;
end $$;

-- ---------- stock change logging for manual edits ----------
create or replace function public.products_log_manual_stock()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.stock_quantity <> old.stock_quantity and coalesce(current_setting('myhato.stock_ctx', true), '') = '' then
    insert into public.inventory_movements(product_id, delta, reason, note, created_by)
    values (new.id, new.stock_quantity - old.stock_quantity, 'manual_adjust', 'direct edit', auth.uid());
  end if;
  return new;
end $$;
create trigger products_stock_log after update of stock_quantity on public.products
  for each row execute function public.products_log_manual_stock();

create or replace function public.variants_log_manual_stock()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.stock_quantity <> old.stock_quantity and coalesce(current_setting('myhato.stock_ctx', true), '') = '' then
    insert into public.inventory_movements(product_id, variant_id, delta, reason, note, created_by)
    values (new.product_id, new.id, new.stock_quantity - old.stock_quantity, 'manual_adjust', 'direct edit', auth.uid());
  end if;
  return new;
end $$;
create trigger variants_stock_log after update of stock_quantity on public.product_variants
  for each row execute function public.variants_log_manual_stock();

-- =====================================================================
-- CART
-- =====================================================================
create or replace function public.ensure_cart()
returns uuid language plpgsql security definer set search_path = public as $$
declare v_uid uuid := public.require_auth(); v_cart uuid;
begin
  insert into public.carts(user_id) values (v_uid)
  on conflict (user_id) do update set updated_at = now()
  returning id into v_cart;
  return v_cart;
end $$;

-- Sets absolute quantity (0 removes). Validates product is published & active variant.
create or replace function public.cart_set_item(p_product_id uuid, p_variant_id uuid, p_quantity int)
returns void language plpgsql security definer set search_path = public as $$
declare v_cart uuid := public.ensure_cart();
begin
  if p_quantity < 0 or p_quantity > 20 then
    raise exception 'INVALID_QUANTITY';
  end if;
  if not exists (select 1 from public.products where id = p_product_id and status = 'published') then
    raise exception 'PRODUCT_UNAVAILABLE';
  end if;
  if p_variant_id is not null and not exists (
      select 1 from public.product_variants where id = p_variant_id and product_id = p_product_id and is_active) then
    raise exception 'VARIANT_UNAVAILABLE';
  end if;

  if p_quantity = 0 then
    delete from public.cart_items
     where cart_id = v_cart and product_id = p_product_id and variant_id is not distinct from p_variant_id;
  else
    update public.cart_items set quantity = p_quantity
     where cart_id = v_cart and product_id = p_product_id and variant_id is not distinct from p_variant_id;
    if not found then
      insert into public.cart_items(cart_id, product_id, variant_id, quantity)
      values (v_cart, p_product_id, p_variant_id, p_quantity);
    end if;
  end if;
  update public.carts set updated_at = now() where id = v_cart;
end $$;

-- Merge a guest (local) cart after sign in: [{product_id, variant_id, quantity}]
create or replace function public.cart_merge(p_items jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare v_item jsonb; v_cart uuid := public.ensure_cart(); v_existing int;
begin
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 50 then
    raise exception 'INVALID_ITEMS';
  end if;
  for v_item in select * from jsonb_array_elements(p_items) loop
    select quantity into v_existing from public.cart_items
     where cart_id = v_cart and product_id = (v_item->>'product_id')::uuid
       and variant_id is not distinct from nullif(v_item->>'variant_id','')::uuid;
    begin
      perform public.cart_set_item(
        (v_item->>'product_id')::uuid,
        nullif(v_item->>'variant_id','')::uuid,
        least(20, coalesce(v_existing, 0) + greatest(1, (v_item->>'quantity')::int)));
    exception when others then
      -- skip unavailable products silently during merge
      null;
    end;
  end loop;
end $$;

-- Server-priced cart view for the current user
create or replace function public.get_cart()
returns table (
  item_id uuid, product_id uuid, variant_id uuid, sku text, name_ar text, name_en text,
  variant_name_ar text, variant_name_en text, thumb_path text,
  unit_price_minor bigint, list_price_minor bigint, quantity int, line_total_minor bigint,
  available_stock int, is_available boolean)
language sql stable security definer set search_path = public as $$
  select ci.id, p.id, v.id, coalesce(v.sku, p.sku), p.name_ar, p.name_en, v.name_ar, v.name_en,
         (select storage_path from public.product_images pi where pi.product_id = p.id order by sort_order limit 1),
         coalesce(v.price_minor, p.price_minor),
         greatest(coalesce(v.price_minor, p.price_minor), coalesce(p.compare_at_price_minor, 0)),
         ci.quantity,
         coalesce(v.price_minor, p.price_minor) * ci.quantity,
         coalesce(v.stock_quantity, p.stock_quantity),
         (p.status = 'published' and coalesce(v.is_active, true) and coalesce(v.stock_quantity, p.stock_quantity) >= ci.quantity)
    from public.carts c
    join public.cart_items ci on ci.cart_id = c.id
    join public.products p on p.id = ci.product_id
    left join public.product_variants v on v.id = ci.variant_id
   where c.user_id = auth.uid()
   order by ci.created_at
$$;

-- Delivery fee quote (same logic as place_order)
create or replace function public.quote_delivery_fee(p_governorate text, p_subtotal_minor bigint)
returns bigint language plpgsql stable security definer set search_path = public as $$
declare v_fee bigint; v_free bigint := coalesce((public.setting('free_delivery_threshold_minor') #>> '{}')::bigint, 0);
begin
  if v_free > 0 and p_subtotal_minor >= v_free then return 0; end if;
  select fee_minor into v_fee from public.delivery_zones where governorate = p_governorate and is_active;
  if v_fee is null then
    v_fee := coalesce((public.setting('default_delivery_fee_minor') #>> '{}')::bigint, 0);
  end if;
  return v_fee;
end $$;

-- =====================================================================
-- ORDERS
-- =====================================================================
create or replace function public._clear_cart(p_cart_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from public.cart_items where cart_id = p_cart_id;
end $$;
revoke execute on function public._clear_cart(uuid) from public, anon, authenticated;

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
  if v_profile.phone is null or not v_profile.phone_verified then
    raise exception 'PHONE_NOT_VERIFIED';
  end if;

  if p_fulfillment = 'pickup' then
    if not exists (select 1 from public.branches where id = p_branch_id and is_active) then
      raise exception 'INVALID_BRANCH';
    end if;
  else
    select * into v_addr from public.customer_addresses where id = p_address_id and user_id = v_uid;
    if not found then raise exception 'INVALID_ADDRESS'; end if;
  end if;

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
          coalesce(nullif(v_profile.full_name, ''), v_addr.recipient_name, v_profile.phone),
          v_profile.phone, v_profile.email,
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
    'تم إرسال الطلب للدعم، وهنكلمك قريب لتأكيد الطلب. رقم الطلب: ' || v_ref,
    'Your order was sent to our team. We will call you soon to confirm it. Order: ' || v_ref,
    'order', v_order_id, v_ref, '/orders/' || v_order_id);

  return jsonb_build_object('order_id', v_order_id, 'reference', v_ref, 'total_minor', v_subtotal + v_fee, 'replayed', false);
end $$;

create or replace function public.order_status_message(p_status public.order_status, out ar text, out en text)
language sql immutable as $$
  select case p_status
    when 'confirmed' then 'تم تأكيد طلبك.'
    when 'preparing' then 'جاري تجهيز طلبك.'
    when 'ready_for_pickup' then 'طلبك جاهز للاستلام من الفرع.'
    when 'out_for_delivery' then 'طلبك في الطريق إليك.'
    when 'delivered' then 'تم تسليم طلبك. شكرًا لاختيارك My Hatō.'
    when 'cancelled' then 'تم إلغاء طلبك.'
    else 'تم تحديث حالة طلبك.' end,
  case p_status
    when 'confirmed' then 'Your order is confirmed.'
    when 'preparing' then 'Your order is being prepared.'
    when 'ready_for_pickup' then 'Your order is ready for pickup at the branch.'
    when 'out_for_delivery' then 'Your order is out for delivery.'
    when 'delivered' then 'Your order was delivered. Thank you for choosing My Hatō.'
    when 'cancelled' then 'Your order was cancelled.'
    else 'Your order status was updated.' end
$$;

create or replace function public._restock_order(p_order_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare r record;
begin
  perform set_config('myhato.stock_ctx', 'order_cancel', true);
  for r in select product_id, variant_id, sum(quantity)::int as qty
             from public.order_items
            where order_id = p_order_id and product_id is not null
            group by product_id, variant_id loop
    if r.variant_id is null then
      update public.products set stock_quantity = stock_quantity + r.qty, sold_count = greatest(0, sold_count - r.qty)
       where id = r.product_id;
    else
      update public.product_variants set stock_quantity = stock_quantity + r.qty where id = r.variant_id;
    end if;
    insert into public.inventory_movements(product_id, variant_id, delta, reason, order_id, created_by)
    values (r.product_id, r.variant_id, r.qty, 'order_cancel', p_order_id, auth.uid());
  end loop;
  perform set_config('myhato.stock_ctx', '', true);
end $$;

create or replace function public._apply_order_status(p_order public.orders, p_to public.order_status, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare v_msg record;
begin
  if not exists (select 1 from public.order_transitions t
                  where t.from_status = p_order.status and t.to_status = p_to
                    and (t.fulfillment is null or t.fulfillment = p_order.fulfillment)) then
    raise exception 'INVALID_TRANSITION:%->%', p_order.status, p_to;
  end if;

  update public.orders set status = p_to,
         payment_status = case when p_to = 'delivered' then 'paid' else payment_status end
   where id = p_order.id;
  insert into public.order_status_history(order_id, from_status, to_status, note, changed_by)
  values (p_order.id, p_order.status, p_to, left(p_note, 500), auth.uid());

  if p_to = 'cancelled' then
    perform public._restock_order(p_order.id);
  end if;

  select * into v_msg from public.order_status_message(p_to);
  perform public.notify_user(p_order.customer_id,
    'تحديث الطلب ' || p_order.reference, 'Order ' || p_order.reference || ' update',
    v_msg.ar, v_msg.en, 'order', p_order.id, p_order.reference, '/orders/' || p_order.id);
end $$;

create or replace function public.staff_update_order_status(p_order_id uuid, p_to public.order_status, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_order public.orders%rowtype;
begin
  perform public.require_permission('orders.manage');
  select * into v_order from public.orders where id = p_order_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  perform public._apply_order_status(v_order, p_to, p_note);
  perform public.audit_write('order.status', 'order', p_order_id::text,
    jsonb_build_object('from', v_order.status, 'to', p_to, 'note', p_note));
end $$;

create or replace function public.customer_cancel_order(p_order_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_order public.orders%rowtype;
begin
  select * into v_order from public.orders where id = p_order_id and customer_id = public.require_auth() for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_order.status <> 'pending_confirmation' then raise exception 'CANNOT_CANCEL'; end if;
  perform public._apply_order_status(v_order, 'cancelled', 'cancelled by customer');
end $$;

create or replace function public.staff_adjust_stock(p_product_id uuid, p_variant_id uuid, p_delta int, p_reason text, p_note text)
returns int language plpgsql security definer set search_path = public as $$
declare v_new int;
begin
  perform public.require_permission('inventory.manage');
  if p_delta = 0 or p_reason not in ('manual_adjust','restock','correction') then raise exception 'INVALID_INPUT'; end if;
  perform set_config('myhato.stock_ctx', 'adjust', true);
  if p_variant_id is null then
    update public.products set stock_quantity = stock_quantity + p_delta where id = p_product_id returning stock_quantity into v_new;
  else
    update public.product_variants set stock_quantity = stock_quantity + p_delta
     where id = p_variant_id and product_id = p_product_id returning stock_quantity into v_new;
  end if;
  perform set_config('myhato.stock_ctx', '', true);
  if v_new is null then raise exception 'NOT_FOUND'; end if;
  insert into public.inventory_movements(product_id, variant_id, delta, reason, note, created_by)
  values (p_product_id, p_variant_id, p_delta, p_reason, left(p_note, 300), auth.uid());
  perform public.audit_write('inventory.adjust', 'product', p_product_id::text,
    jsonb_build_object('variant_id', p_variant_id, 'delta', p_delta, 'reason', p_reason));
  return v_new;
end $$;

-- =====================================================================
-- REPAIRS
-- =====================================================================
create or replace function public.request_repair(
  p_idempotency_key text,
  p_device_brand text,
  p_device_model text,
  p_imei_or_serial text,
  p_problem text,
  p_contact_name text,
  p_contact_phone text,
  p_pickup_address_id uuid,       -- null = customer drops device at branch
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
    v_label.message_ar || ' رقم الطلب: ' || v_ref, v_label.message_en || ' Reference: ' || v_ref,
    'repair', v_id, v_ref, '/repairs/' || v_id);

  return jsonb_build_object('repair_id', v_id, 'reference', v_ref, 'replayed', false);
end $$;

-- attach uploaded photo (file must already be uploaded to repair-photos/{uid}/{repair_id}/...)
create or replace function public.add_repair_attachment(p_repair_id uuid, p_storage_path text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_uid uuid := public.require_auth(); v_id uuid; v_r public.repair_requests%rowtype; v_staff boolean;
begin
  select * into v_r from public.repair_requests where id = p_repair_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  v_staff := coalesce(public.has_permission('repairs.manage') or (public.has_permission('repairs.update_assigned') and v_r.assigned_technician_id = v_uid), false);
  if v_r.customer_id <> v_uid and not v_staff then raise exception 'FORBIDDEN'; end if;
  if p_storage_path not like (v_r.customer_id::text || '/' || p_repair_id::text || '/%') then raise exception 'INVALID_PATH'; end if;
  if (select count(*) from public.repair_attachments where repair_id = p_repair_id) >= 10 then raise exception 'TOO_MANY_FILES'; end if;
  insert into public.repair_attachments(repair_id, storage_path, uploaded_by, is_internal)
  values (p_repair_id, p_storage_path, v_uid, v_staff and v_r.customer_id <> v_uid) returning id into v_id;
  return v_id;
end $$;

create or replace function public._can_update_repair(p_r public.repair_requests)
returns boolean language sql stable security definer set search_path = public as $$
  -- coalesce: an unassigned repair (NULL technician) must evaluate to FALSE, never NULL
  select coalesce(public.has_permission('repairs.manage')
      or (public.has_permission('repairs.update_assigned') and p_r.assigned_technician_id = auth.uid()), false)
$$;

create or replace function public._apply_repair_status(p_r public.repair_requests, p_to public.repair_status, p_extra_ar text, p_extra_en text)
returns void language plpgsql security definer set search_path = public as $$
declare v_label record; v_msg_ar text; v_msg_en text;
begin
  if not exists (select 1 from public.repair_transitions where from_status = p_r.status and to_status = p_to) then
    raise exception 'INVALID_TRANSITION:%->%', p_r.status, p_to;
  end if;
  select * into v_label from public.repair_status_labels where status = p_to;
  -- extra text starting with an Arabic comma continues the sentence ("...حاليًا، والتكلفة المعتمدة ...")
  v_msg_ar := case when p_extra_ar like '،%' then rtrim(v_label.message_ar, '.') || p_extra_ar
                   else v_label.message_ar || coalesce(' ' || p_extra_ar, '') end;
  v_msg_en := v_label.message_en || coalesce(' ' || p_extra_en, '');

  update public.repair_requests set status = p_to,
         received_at = case when p_to = 'received_at_branch' then now() else received_at end
   where id = p_r.id;
  insert into public.repair_status_history(repair_id, from_status, to_status, customer_message_ar, customer_message_en, changed_by)
  values (p_r.id, p_r.status, p_to, v_msg_ar, v_msg_en, auth.uid());
  perform public.notify_user(p_r.customer_id, v_label.label_ar || ' — ' || p_r.reference, v_label.label_en || ' — ' || p_r.reference,
    v_msg_ar, v_msg_en, 'repair', p_r.id, p_r.reference, '/repairs/' || p_r.id);
end $$;

create or replace function public.staff_update_repair_status(p_repair_id uuid, p_to public.repair_status, p_customer_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_r public.repair_requests%rowtype; v_extra_ar text; v_extra_en text;
begin
  perform public.require_auth();
  select * into v_r from public.repair_requests where id = p_repair_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if not public._can_update_repair(v_r) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;

  if p_to in ('awaiting_approval', 'repair_approved') then
    raise exception 'USE_QUOTE_WORKFLOW';
  end if;
  if p_to = 'cancelled' and nullif(trim(p_customer_note), '') is null then
    raise exception 'CANCEL_REASON_REQUIRED';
  end if;

  -- chargeable repair cannot start without an approved quote when approval policy is on
  if p_to = 'repair_in_progress' and v_r.status = 'diagnosis_completed'
     and coalesce((public.setting('repair_requires_approval') #>> '{}')::boolean, true)
     and coalesce(v_r.estimated_cost_minor, 0) > 0 then
    raise exception 'APPROVAL_REQUIRED';
  end if;

  if v_r.approved_cost_minor is not null and p_to = 'repair_in_progress' then
    v_extra_ar := '، والتكلفة المعتمدة ' || public.fmt_egp(v_r.approved_cost_minor) || ' ج.م.';
    v_extra_en := 'Approved cost: EGP ' || public.fmt_egp(v_r.approved_cost_minor) || '.';
  end if;
  if nullif(trim(p_customer_note), '') is not null then
    v_extra_ar := coalesce(v_extra_ar || ' ', '') || trim(p_customer_note);
    v_extra_en := coalesce(v_extra_en || ' ', '') || trim(p_customer_note);
  end if;

  perform public._apply_repair_status(v_r, p_to, v_extra_ar, v_extra_en);
  if p_to = 'cancelled' then
    update public.repair_requests set cancel_reason = left(p_customer_note, 500) where id = p_repair_id;
  end if;
  perform public.audit_write('repair.status', 'repair', p_repair_id::text,
    jsonb_build_object('from', v_r.status, 'to', p_to));
end $$;

-- Update non-status fields (diagnosis, notes, dates, warranty, QC, pickup schedule)
create or replace function public.staff_update_repair_details(p_repair_id uuid, p_fields jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare v_r public.repair_requests%rowtype; v_key text;
begin
  perform public.require_auth();
  select * into v_r from public.repair_requests where id = p_repair_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if not public._can_update_repair(v_r) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  for v_key in select jsonb_object_keys(p_fields) loop
    if v_key not in ('diagnosis','customer_notes','internal_notes','expected_completion_at','warranty_terms',
                     'qc_result','scheduled_pickup_at','imei_or_serial') then
      raise exception 'FIELD_NOT_ALLOWED:%', v_key;
    end if;
  end loop;
  update public.repair_requests set
    diagnosis = case when p_fields ? 'diagnosis' then left(p_fields->>'diagnosis', 2000) else diagnosis end,
    customer_notes = case when p_fields ? 'customer_notes' then left(p_fields->>'customer_notes', 2000) else customer_notes end,
    internal_notes = case when p_fields ? 'internal_notes' then left(p_fields->>'internal_notes', 4000) else internal_notes end,
    expected_completion_at = case when p_fields ? 'expected_completion_at' then (p_fields->>'expected_completion_at')::timestamptz else expected_completion_at end,
    warranty_terms = case when p_fields ? 'warranty_terms' then left(p_fields->>'warranty_terms', 1000) else warranty_terms end,
    qc_result = case when p_fields ? 'qc_result' then left(p_fields->>'qc_result', 1000) else qc_result end,
    scheduled_pickup_at = case when p_fields ? 'scheduled_pickup_at' then (p_fields->>'scheduled_pickup_at')::timestamptz else scheduled_pickup_at end,
    imei_or_serial = case when p_fields ? 'imei_or_serial' then nullif(p_fields->>'imei_or_serial','') else imei_or_serial end
  where id = p_repair_id;
  perform public.audit_write('repair.details', 'repair', p_repair_id::text,
    jsonb_build_object('fields', (select jsonb_agg(k) from jsonb_object_keys(p_fields) k)));
end $$;

create or replace function public.staff_assign_technician(p_repair_id uuid, p_technician_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.require_permission('repairs.manage');
  if not exists (select 1 from public.user_roles where user_id = p_technician_id and role in ('technician','manager','owner')) then
    raise exception 'NOT_A_TECHNICIAN';
  end if;
  update public.repair_requests set assigned_technician_id = p_technician_id where id = p_repair_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  insert into public.repair_assignments(repair_id, technician_id, assigned_by) values (p_repair_id, p_technician_id, auth.uid());
  perform public.audit_write('repair.assign', 'repair', p_repair_id::text, jsonb_build_object('technician_id', p_technician_id));
end $$;

-- Create quote -> status awaiting_approval, customer notified. Supersedes previous pending quote.
create or replace function public.staff_create_repair_quote(p_repair_id uuid, p_amount_minor bigint, p_description text, p_diagnosis text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_r public.repair_requests%rowtype; v_quote uuid; v_amount text;
begin
  perform public.require_auth();
  select * into v_r from public.repair_requests where id = p_repair_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if not public._can_update_repair(v_r) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_amount_minor is null or p_amount_minor < 0 or p_amount_minor > 100000000 then raise exception 'INVALID_AMOUNT'; end if;

  update public.repair_quotes set status = 'superseded' where repair_id = p_repair_id and status = 'pending';
  insert into public.repair_quotes(repair_id, amount_minor, description, created_by)
  values (p_repair_id, p_amount_minor, left(p_description, 1000), auth.uid()) returning id into v_quote;

  update public.repair_requests set estimated_cost_minor = p_amount_minor,
         diagnosis = coalesce(nullif(trim(p_diagnosis), ''), diagnosis)
   where id = p_repair_id;

  -- price changed after an earlier approval -> approval is requested again
  if v_r.status <> 'awaiting_approval' then
    select * into v_r from public.repair_requests where id = p_repair_id;
    v_amount := public.fmt_egp(p_amount_minor);
    perform public._apply_repair_status(v_r, 'awaiting_approval',
      'تم تحديد تكلفة الصيانة بـ ' || v_amount || ' ج.م.',
      'Repair cost set to EGP ' || v_amount || '.');
  else
    v_amount := public.fmt_egp(p_amount_minor);
    insert into public.repair_status_history(repair_id, from_status, to_status, customer_message_ar, customer_message_en, changed_by)
    values (p_repair_id, 'awaiting_approval', 'awaiting_approval',
      'تم تحديث تكلفة الصيانة إلى ' || v_amount || ' ج.م. برجاء مراجعة التفاصيل والموافقة.',
      'Repair cost updated to EGP ' || v_amount || '. Please review and approve.', auth.uid());
    perform public.notify_user(v_r.customer_id, 'تحديث تكلفة الصيانة — ' || v_r.reference, 'Repair quote updated — ' || v_r.reference,
      'تم تحديد تكلفة الصيانة بـ ' || v_amount || ' ج.م. برجاء مراجعة التفاصيل والموافقة.',
      'Repair cost set to EGP ' || v_amount || '. Please review and approve.',
      'repair', v_r.id, v_r.reference, '/repairs/' || v_r.id);
  end if;
  perform public.audit_write('repair.quote', 'repair', p_repair_id::text, jsonb_build_object('amount_minor', p_amount_minor, 'quote_id', v_quote));
  return v_quote;
end $$;

create or replace function public._decide_quote(p_quote_id uuid, p_decision text, p_via text, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare v_q public.repair_quotes%rowtype; v_r public.repair_requests%rowtype;
begin
  if p_decision not in ('approved','rejected') then raise exception 'INVALID_DECISION'; end if;
  select * into v_q from public.repair_quotes where id = p_quote_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  select * into v_r from public.repair_requests where id = v_q.repair_id for update;

  if p_via = 'customer_app' and v_r.customer_id <> auth.uid() then raise exception 'NOT_FOUND'; end if;
  if v_q.status <> 'pending' or v_r.status <> 'awaiting_approval' then raise exception 'QUOTE_NOT_PENDING'; end if;

  insert into public.repair_approvals(repair_id, quote_id, decision, quoted_amount_minor, decided_by, via, staff_note)
  values (v_r.id, v_q.id, p_decision, v_q.amount_minor, auth.uid(), p_via, p_note);
  update public.repair_quotes set status = p_decision::public.quote_status where id = v_q.id;

  if p_decision = 'approved' then
    update public.repair_requests set approved_cost_minor = v_q.amount_minor where id = v_r.id;
    perform public._apply_repair_status(v_r, 'repair_approved',
      'التكلفة المعتمدة ' || public.fmt_egp(v_q.amount_minor) || ' ج.م.', 'Approved cost: EGP ' || public.fmt_egp(v_q.amount_minor) || '.');
  else
    perform public._apply_repair_status(v_r, 'cancelled', 'تم رفض عرض السعر، وهنتواصل معاك لترتيب استلام جهازك.',
      'Quote rejected. We will contact you to arrange returning your device.');
    update public.repair_requests set cancel_reason = 'quote rejected' where id = v_r.id;
  end if;

  -- customer response -> service mailbox
  perform public.enqueue_email('repair_customer_response', 'repair_notification_email',
    jsonb_build_object('repair_id', v_r.id, 'quote_id', v_q.id, 'decision', p_decision, 'via', p_via), 'repair_quote', v_q.id);
  perform public.audit_write('repair.quote_decision', 'repair', v_r.id::text,
    jsonb_build_object('quote_id', v_q.id, 'decision', p_decision, 'via', p_via, 'amount_minor', v_q.amount_minor));
end $$;

create or replace function public.customer_respond_to_quote(p_quote_id uuid, p_decision text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.require_auth();
  perform public._decide_quote(p_quote_id, p_decision, 'customer_app', null);
end $$;

-- e.g. customer approved by phone call: auditable, requires note
create or replace function public.staff_record_quote_decision(p_quote_id uuid, p_decision text, p_note text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.require_permission('repairs.manage');
  if nullif(trim(p_note), '') is null then raise exception 'NOTE_REQUIRED'; end if;
  perform public._decide_quote(p_quote_id, p_decision, 'staff_recorded', trim(p_note));
end $$;

-- Staff full repair view incl. internal notes (customers can never call this successfully)
create or replace function public.staff_get_repair(p_repair_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_r public.repair_requests%rowtype;
begin
  perform public.require_permission('repairs.view');
  select * into v_r from public.repair_requests where id = p_repair_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  if not coalesce(public.has_permission('repairs.manage') or public.has_role('support')
          or v_r.assigned_technician_id = auth.uid(), false) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return to_jsonb(v_r) || jsonb_build_object(
    'history', (select coalesce(jsonb_agg(h order by h.created_at), '[]') from public.repair_status_history h where h.repair_id = v_r.id),
    'quotes', (select coalesce(jsonb_agg(q order by q.created_at desc), '[]') from public.repair_quotes q where q.repair_id = v_r.id),
    'approvals', (select coalesce(jsonb_agg(a order by a.created_at desc), '[]') from public.repair_approvals a where a.repair_id = v_r.id),
    'attachments', (select coalesce(jsonb_agg(t order by t.created_at), '[]') from public.repair_attachments t where t.repair_id = v_r.id),
    'parts', (select coalesce(jsonb_agg(p), '[]') from public.repair_parts p where p.repair_id = v_r.id),
    'notifications', (select coalesce(jsonb_agg(jsonb_build_object('id', n.id, 'title_ar', n.title_ar, 'created_at', n.created_at,
                        'read_at', n.read_at, 'deliveries', (select jsonb_agg(jsonb_build_object('channel', d.channel, 'status', d.status))
                                                             from public.notification_delivery_logs d where d.notification_id = n.id))
                        order by n.created_at desc), '[]')
                      from public.notifications n where n.entity_type = 'repair' and n.entity_id = v_r.id),
    'emails', (select coalesce(jsonb_agg(jsonb_build_object('kind', e.kind, 'to', e.to_email, 'status', e.status, 'attempts', e.attempts, 'sent_at', e.sent_at)), '[]')
               from public.email_outbox e where e.related_id = v_r.id or e.related_id in (select id from public.repair_quotes where repair_id = v_r.id)),
    'customer', (select jsonb_build_object('full_name', full_name, 'phone', phone, 'phone_verified', phone_verified, 'email', email)
                 from public.profiles where id = v_r.customer_id)
  );
end $$;

-- Guest lookup payload: called ONLY by the secure-guest-repair-lookup Edge Function (service_role) after OTP verification.
create or replace function public.guest_repair_public_view(p_reference text)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'reference', r.reference, 'status', r.status,
    'label_ar', l.label_ar, 'label_en', l.label_en,
    'device', r.device_brand || ' ' || r.device_model,
    'estimated_cost_minor', r.estimated_cost_minor, 'approved_cost_minor', r.approved_cost_minor,
    'expected_completion_at', r.expected_completion_at, 'updated_at', r.updated_at,
    'timeline', (select jsonb_agg(jsonb_build_object('status', h.to_status, 'message_ar', h.customer_message_ar,
                                  'message_en', h.customer_message_en, 'at', h.created_at) order by h.created_at)
                   from public.repair_status_history h where h.repair_id = r.id))
  from public.repair_requests r join public.repair_status_labels l on l.status = r.status
  where r.reference = upper(trim(p_reference))
$$;
revoke all on function public.guest_repair_public_view(text) from public, anon, authenticated;

-- ---------- staff management (owner only) ----------
create or replace function public.staff_set_role(p_user_id uuid, p_role public.app_role, p_grant boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.require_permission('staff.manage');
  if p_user_id = auth.uid() and not p_grant and p_role = 'owner' then
    raise exception 'CANNOT_REMOVE_OWN_OWNER_ROLE';
  end if;
  if p_grant then
    insert into public.user_roles(user_id, role, granted_by) values (p_user_id, p_role, auth.uid()) on conflict do nothing;
  else
    delete from public.user_roles where user_id = p_user_id and role = p_role;
  end if;
  perform public.audit_write(case when p_grant then 'staff.grant' else 'staff.revoke' end, 'user', p_user_id::text,
    jsonb_build_object('role', p_role));
end $$;

create or replace function public.request_account_deletion()
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.profiles set deletion_requested_at = now() where id = public.require_auth();
  perform public.audit_write('account.deletion_requested', 'user', auth.uid()::text, '{}');
end $$;

-- dashboard stats
create or replace function public.staff_dashboard_stats()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_staff() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return jsonb_build_object(
    'total_orders', (select count(*) from public.orders),
    'new_orders_today', (select count(*) from public.orders where created_at >= date_trunc('day', now() at time zone 'Africa/Cairo') at time zone 'Africa/Cairo'),
    'pending_orders', (select count(*) from public.orders where status = 'pending_confirmation'),
    'completed_orders', (select count(*) from public.orders where status = 'delivered'),
    'total_sales_minor', (select coalesce(sum(total_minor), 0) from public.orders where status = 'delivered'),
    'active_repairs', (select count(*) from public.repair_requests where status not in ('delivered','cancelled')),
    'repairs_awaiting_approval', (select count(*) from public.repair_requests where status = 'awaiting_approval'),
    'repairs_ready', (select count(*) from public.repair_requests where status = 'ready_for_pickup'),
    'low_stock', (select count(*) from public.products where status = 'published'
                    and stock_quantity <= coalesce((public.setting('low_stock_threshold') #>> '{}')::int, 5)),
    'failed_emails', (select count(*) from public.email_outbox where status = 'failed')
  );
end $$;

-- rate limiter used by Edge Functions (service role)
create or replace function public.hit_rate_limit(p_bucket text, p_key_hash text, p_window_seconds int, p_max int)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_window timestamptz := to_timestamp(floor(extract(epoch from now()) / p_window_seconds) * p_window_seconds); v_count int;
begin
  insert into public.rate_limits(bucket, key_hash, window_start, count) values (p_bucket, p_key_hash, v_window, 1)
  on conflict (bucket, key_hash, window_start) do update set count = public.rate_limits.count + 1
  returning count into v_count;
  return v_count <= p_max;   -- true = allowed
end $$;
revoke all on function public.hit_rate_limit(text, text, int, int) from public, anon, authenticated;
