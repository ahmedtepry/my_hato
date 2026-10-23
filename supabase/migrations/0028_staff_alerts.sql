-- 0028 Staff alerts: every team member with the matching permission gets a notification (shown in the
-- app and as a phone notification) for new orders, new repairs, cancellation requests, reviews waiting
-- for moderation and products running low on stock. Tapping one opens the console.
-- Alerts never block the business action that triggered them (errors are swallowed).

create or replace function public._notify_staff(p_permission text, p_title_ar text, p_title_en text,
                                                p_body_ar text, p_body_en text, p_reference text)
returns void language plpgsql security definer set search_path = public as $$
declare r record;
begin
  for r in select distinct ur.user_id
             from public.user_roles ur
             join public.role_permissions rp on rp.role = ur.role
            where rp.permission = p_permission loop
    perform public.notify_user(r.user_id, p_title_ar, p_title_en, p_body_ar, p_body_en, 'system', null, p_reference, '/hato-console');
  end loop;
exception when others then
  null; -- an alert must never stop an order / repair / review from being saved
end $$;
revoke all on function public._notify_staff(text, text, text, text, text, text) from public, anon, authenticated;

-- new order
create or replace function public._alert_new_order() returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public._notify_staff('orders.manage',
    '🛒 طلب جديد ' || new.reference, '🛒 New order ' || new.reference,
    coalesce(new.customer_name, '') || ' — ' || round(new.total_minor / 100.0) || ' ج.م — ' ||
      case when new.fulfillment = 'pickup' then 'استلام من الفرع' else 'توصيل' end,
    coalesce(new.customer_name, '') || ' — EGP ' || round(new.total_minor / 100.0),
    new.reference);
  return null;
end $$;
create trigger orders_alert_staff after insert on public.orders for each row execute function public._alert_new_order();

-- new repair request
create or replace function public._alert_new_repair() returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public._notify_staff('repairs.manage',
    '🔧 طلب صيانة جديد ' || new.reference, '🔧 New repair ' || new.reference,
    coalesce(new.contact_name, '') || ' — ' || coalesce(new.device_brand, '') || ' ' || coalesce(new.device_model, ''),
    coalesce(new.contact_name, '') || ' — ' || coalesce(new.device_brand, '') || ' ' || coalesce(new.device_model, ''),
    new.reference);
  return null;
end $$;
create trigger repairs_alert_staff after insert on public.repair_requests for each row execute function public._alert_new_repair();

-- cancellation request
create or replace function public._alert_cancel_request() returns trigger language plpgsql security definer set search_path = public as $$
declare v_ref text;
begin
  if new.order_id is not null then
    select reference into v_ref from public.orders where id = new.order_id;
    perform public._notify_staff('orders.manage', '⚠️ طلب إلغاء ' || v_ref, '⚠️ Cancellation request ' || v_ref,
      'السبب: ' || new.reason, 'Reason: ' || new.reason, v_ref);
  else
    select reference into v_ref from public.repair_requests where id = new.repair_id;
    perform public._notify_staff('repairs.manage', '⚠️ طلب إلغاء صيانة ' || v_ref, '⚠️ Repair cancellation ' || v_ref,
      'السبب: ' || new.reason, 'Reason: ' || new.reason, v_ref);
  end if;
  return null;
end $$;
create trigger cancel_requests_alert_staff after insert on public.cancel_requests for each row execute function public._alert_cancel_request();

-- review waiting for moderation
create or replace function public._alert_pending_review() returns trigger language plpgsql security definer set search_path = public as $$
declare v_name text;
begin
  if new.status = 'pending' and (tg_op = 'INSERT' or old.status is distinct from 'pending') then
    select name_ar into v_name from public.products where id = new.product_id;
    perform public._notify_staff('products.manage', '⭐ تقييم محتاج مراجعة', '⭐ Review to check',
      coalesce(v_name, '') || ' — ' || new.rating || '★', coalesce(v_name, '') || ' — ' || new.rating || '★', null);
  end if;
  return null;
end $$;
create trigger product_reviews_alert_staff after insert or update of status on public.product_reviews
  for each row execute function public._alert_pending_review();

-- stock crossed the low-stock threshold (or ran out)
create or replace function public._alert_low_stock() returns trigger language plpgsql security definer set search_path = public as $$
declare v_min int := coalesce((public.setting('low_stock_threshold') #>> '{}')::int, 5);
begin
  if new.status = 'published' and new.stock_quantity < old.stock_quantity then
    if new.stock_quantity = 0 then
      perform public._notify_staff('inventory.manage', '📦 نفد: ' || new.name_ar, '📦 Out of stock: ' || new.name_en,
        'الكود ' || new.sku || ' — زوّد الكمية من لوحة المسؤول', 'SKU ' || new.sku, new.sku);
    elsif new.stock_quantity <= v_min and old.stock_quantity > v_min then
      perform public._notify_staff('inventory.manage', '📦 مخزون قليل: ' || new.name_ar, '📦 Low stock: ' || new.name_en,
        'باقي ' || new.stock_quantity || ' بس — الكود ' || new.sku, new.stock_quantity || ' left — SKU ' || new.sku, new.sku);
    end if;
  end if;
  return null;
end $$;
create trigger products_alert_low_stock after update of stock_quantity on public.products
  for each row execute function public._alert_low_stock();

revoke all on function public._alert_new_order() from public, anon, authenticated;
revoke all on function public._alert_new_repair() from public, anon, authenticated;
revoke all on function public._alert_cancel_request() from public, anon, authenticated;
revoke all on function public._alert_pending_review() from public, anon, authenticated;
revoke all on function public._alert_low_stock() from public, anon, authenticated;
