-- 0107: the customer no longer sees a branch on a pickup order until staff confirm one.
-- Staff (permission orders.set_branch) tell the customer the nearest branch and set it on the order.
alter table public.orders add column if not exists branch_confirmed boolean not null default false;

insert into public.permission_catalog (permission, grp, name_ar, name_en, desc_ar, desc_en, sensitive, inert, sort) values
 ('orders.set_branch', 'orders', 'يحدد فرع الاستلام للطلب', 'Set the pickup branch on an order',
  'بعد ما يكلّم العميل يحدد أقرب فرع ليه ويتسجّل في الطلب ويوصله إشعار', 'After calling the customer, sets the nearest branch on the order and notifies them', false, false, 60)
on conflict (permission) do update set name_ar = excluded.name_ar, name_en = excluded.name_en, desc_ar = excluded.desc_ar, desc_en = excluded.desc_en;
insert into public.role_permissions (role, permission) values ('owner', 'orders.set_branch'), ('manager', 'orders.set_branch'), ('sales', 'orders.set_branch') on conflict do nothing;

create or replace function public.staff_set_order_branch(p_order_id uuid, p_branch_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_order public.orders%rowtype; v_b public.branches%rowtype; v_old uuid;
begin
  perform public.require_permission('orders.set_branch');
  select * into v_order from public.orders where id = p_order_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_order.fulfillment <> 'pickup' or v_order.closed_at is not null then raise exception 'INVALID_INPUT'; end if;
  select * into v_b from public.branches where id = p_branch_id and is_active;
  if not found then raise exception 'INVALID_INPUT'; end if;
  v_old := v_order.branch_id;
  update public.orders set branch_id = v_b.id, branch_confirmed = true where id = v_order.id;
  insert into public.order_status_history(order_id, from_status, to_status, customer_message, changed_by)
  values (v_order.id, v_order.status, v_order.status, 'فرع الاستلام: ' || coalesce(v_b.name_ar, ''), auth.uid());
  perform public.notify_user(v_order.customer_id,
    'فرع استلام طلبك ' || v_order.reference, 'Pickup branch for order ' || v_order.reference,
    'هتستلم طلبك من ' || coalesce(v_b.name_ar, ''), 'You will pick up your order at ' || coalesce(v_b.name_en, v_b.name_ar, ''),
    'order', v_order.id, v_order.reference, '/orders/' || v_order.id);
  perform public.audit_write('order.set_branch', 'order', v_order.id::text, jsonb_build_object('from', v_old, 'to', v_b.id));
end $$;
revoke all on function public.staff_set_order_branch(uuid, uuid) from public, anon;
grant execute on function public.staff_set_order_branch(uuid, uuid) to authenticated;
