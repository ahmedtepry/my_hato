-- 0018 Order tracking: "shipped" step, friendlier customer messages, and staff updates to the
-- customer without changing the status (e.g. "the courier will bring it tomorrow").

insert into public.order_transitions(from_status, to_status, fulfillment) values
  ('confirmed','shipped','delivery'),
  ('confirmed','out_for_delivery','delivery'),
  ('confirmed','ready_for_pickup','pickup'),
  ('preparing','shipped','delivery'),
  ('shipped','out_for_delivery','delivery'),
  ('shipped','delivered','delivery'),
  ('shipped','cancelled','delivery')
on conflict do nothing;

create or replace function public.order_status_message(p_status public.order_status, out ar text, out en text)
language sql immutable as $$
  select case p_status
    when 'confirmed' then 'أكدنا طلبك وهنبدأ نجهزه.'
    when 'preparing' then 'بنجهّز طلبك دلوقتي.'
    when 'shipped' then 'طلبك اتشحن مع شركة الشحن وهيوصلك قريب.'
    when 'ready_for_pickup' then 'طلبك جاهز تستلمه من الفرع.'
    when 'out_for_delivery' then 'طلبك مع المندوب وفي الطريق ليك.'
    when 'delivered' then 'طلبك اتسلّم. شكرًا لاختيارك My Hatō!'
    when 'cancelled' then 'تم إلغاء طلبك.'
    else 'تم تحديث حالة طلبك.' end,
  case p_status
    when 'confirmed' then 'Your order is confirmed and we will start preparing it.'
    when 'preparing' then 'We are preparing your order.'
    when 'shipped' then 'Your order was handed to the shipping company and will reach you soon.'
    when 'ready_for_pickup' then 'Your order is ready for pickup at the branch.'
    when 'out_for_delivery' then 'Your order is with the courier and on its way.'
    when 'delivered' then 'Your order was delivered. Thank you for choosing My Hatō!'
    when 'cancelled' then 'Your order was cancelled.'
    else 'Your order status was updated.' end
$$;

-- message shown to the customer in the order timeline (status changes leave it null)
alter table public.order_status_history add column if not exists customer_message text;

create or replace function public.staff_post_order_update(p_order_id uuid, p_message text)
returns void language plpgsql security definer set search_path = public as $$
declare v_order public.orders%rowtype;
begin
  perform public.require_permission('orders.manage');
  select * into v_order from public.orders where id = p_order_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  if nullif(trim(p_message), '') is null or length(p_message) > 500 then raise exception 'INVALID_INPUT'; end if;
  insert into public.order_status_history(order_id, from_status, to_status, customer_message, changed_by)
  values (v_order.id, v_order.status, v_order.status, trim(p_message), auth.uid());
  perform public.notify_user(v_order.customer_id,
    'تحديث على طلبك ' || v_order.reference, 'Update on order ' || v_order.reference,
    trim(p_message), trim(p_message), 'order', v_order.id, v_order.reference, '/orders/' || v_order.id);
  perform public.audit_write('order.update', 'order', v_order.id::text, jsonb_build_object('message', left(p_message, 200)));
end $$;
revoke all on function public.staff_post_order_update(uuid, text) from public, anon;
grant execute on function public.staff_post_order_update(uuid, text) to authenticated;
