-- 0020 Status change + message in one step: staff can attach a message to an order status change.
-- The message is saved on that timeline entry and added to the same notification (one push, not two).

create or replace function public._apply_order_status(p_order public.orders, p_to public.order_status, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_msg record;
  v_extra text := nullif(left(trim(coalesce(current_setting('myhato.order_msg', true), '')), 500), '');
begin
  if not exists (select 1 from public.order_transitions t
                  where t.from_status = p_order.status and t.to_status = p_to
                    and (t.fulfillment is null or t.fulfillment = p_order.fulfillment)) then
    raise exception 'INVALID_TRANSITION:%->%', p_order.status, p_to;
  end if;
  update public.orders set status = p_to,
         payment_status = case when p_to = 'delivered' and p_order.payment_method <> 'online' then 'paid' else payment_status end
   where id = p_order.id;
  insert into public.order_status_history(order_id, from_status, to_status, note, customer_message, changed_by)
  values (p_order.id, p_order.status, p_to, left(p_note, 500), v_extra, auth.uid());
  if p_to = 'cancelled' then
    perform public._restock_order(p_order.id);
  end if;
  select * into v_msg from public.order_status_message(p_to);
  perform public.notify_user(p_order.customer_id,
    'تحديث الطلب ' || p_order.reference, 'Order ' || p_order.reference || ' update',
    v_msg.ar || coalesce(' ' || v_extra, ''), v_msg.en || coalesce(' ' || v_extra, ''),
    'order', p_order.id, p_order.reference, '/orders/' || p_order.id);
end $$;
revoke execute on function public._apply_order_status(public.orders, public.order_status, text) from public, anon, authenticated;

create or replace function public.staff_set_order_status(p_order_id uuid, p_to public.order_status, p_note text default null, p_message text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if length(coalesce(p_message, '')) > 500 then raise exception 'INVALID_INPUT'; end if;
  perform set_config('myhato.order_msg', coalesce(p_message, ''), true);
  perform public.staff_update_order_status(p_order_id, p_to, p_note);
  perform set_config('myhato.order_msg', '', true);
end $$;
revoke all on function public.staff_set_order_status(uuid, public.order_status, text, text) from public, anon;
grant execute on function public.staff_set_order_status(uuid, public.order_status, text, text) to authenticated;
