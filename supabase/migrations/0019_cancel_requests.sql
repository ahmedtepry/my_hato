-- 0019 Cancellation requests. Customers no longer cancel orders/repairs directly: they send a
-- request with a reason, staff approve (the order/repair is cancelled) or reject it (with a note,
-- e.g. after calling the customer). One open request per order/repair at a time.

create table public.cancel_requests (
  id uuid primary key default gen_random_uuid(),
  order_id uuid references public.orders(id) on delete cascade,
  repair_id uuid references public.repair_requests(id) on delete cascade,
  customer_id uuid not null references auth.users(id),
  reason text not null check (length(reason) between 2 and 500),
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  staff_note text check (staff_note is null or length(staff_note) <= 500),
  decided_by uuid references auth.users(id),
  decided_at timestamptz,
  created_at timestamptz not null default now(),
  check ((order_id is null) <> (repair_id is null))
);
create unique index cancel_requests_one_open_order on public.cancel_requests(order_id) where status = 'pending' and order_id is not null;
create unique index cancel_requests_one_open_repair on public.cancel_requests(repair_id) where status = 'pending' and repair_id is not null;
create index cancel_requests_pending_idx on public.cancel_requests(status, created_at desc);
create index cancel_requests_customer_idx on public.cancel_requests(customer_id);

alter table public.cancel_requests enable row level security;
revoke all on public.cancel_requests from anon, authenticated;
grant select on public.cancel_requests to authenticated;
create policy cancel_requests_read on public.cancel_requests for select to authenticated
  using (customer_id = auth.uid()
         or (order_id is not null and public.has_permission('orders.manage'))
         or (repair_id is not null and (public.has_permission('repairs.manage') or public.has_permission('repairs.update_assigned'))));

-- a repair can be cancelled (on approval) from any step before the actual repair starts
insert into public.repair_transitions(from_status, to_status) values
  ('device_collected','cancelled'),('received_at_branch','cancelled'),('initial_inspection','cancelled'),
  ('diagnosis_completed','cancelled'),('repair_approved','cancelled'),('waiting_for_parts','cancelled')
on conflict do nothing;

-- ---------------------------------------------------------------- customer side
create or replace function public.customer_request_cancel(p_kind text, p_id uuid, p_reason text)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := public.require_auth();
  v_reason text := left(trim(coalesce(p_reason, '')), 500);
  v_order public.orders%rowtype;
  v_r public.repair_requests%rowtype;
  v_id uuid;
begin
  if length(v_reason) < 2 then raise exception 'CANCEL_REASON_REQUIRED'; end if;
  if p_kind = 'order' then
    select * into v_order from public.orders where id = p_id and customer_id = v_uid for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    if v_order.status not in ('pending_confirmation','confirmed','preparing') then raise exception 'CANNOT_CANCEL'; end if;
    if exists (select 1 from public.cancel_requests where order_id = p_id and status = 'pending') then raise exception 'CANCEL_ALREADY_REQUESTED'; end if;
    insert into public.cancel_requests(order_id, customer_id, reason) values (p_id, v_uid, v_reason) returning id into v_id;
    insert into public.order_status_history(order_id, from_status, to_status, customer_message, changed_by)
    values (p_id, v_order.status, v_order.status, 'طلبت إلغاء الطلب (' || v_reason || '). هنراجع الطلب ونرد عليك قريب.', v_uid);
    perform public.audit_write('order.cancel_requested', 'order', p_id::text, jsonb_build_object('reason', v_reason));
  elsif p_kind = 'repair' then
    select * into v_r from public.repair_requests where id = p_id and customer_id = v_uid for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    if v_r.status not in ('pickup_requested','pickup_scheduled','device_collected','received_at_branch','initial_inspection',
                          'diagnosis_completed','awaiting_approval','repair_approved','waiting_for_parts') then
      raise exception 'CANNOT_CANCEL';
    end if;
    if exists (select 1 from public.cancel_requests where repair_id = p_id and status = 'pending') then raise exception 'CANCEL_ALREADY_REQUESTED'; end if;
    insert into public.cancel_requests(repair_id, customer_id, reason) values (p_id, v_uid, v_reason) returning id into v_id;
    insert into public.repair_status_history(repair_id, from_status, to_status, customer_message_ar, customer_message_en, changed_by)
    values (p_id, v_r.status, v_r.status,
            'طلبت إلغاء طلب الصيانة (' || v_reason || '). هنراجع الطلب ونرد عليك قريب.',
            'You asked to cancel this repair (' || v_reason || '). We will review it and get back to you soon.', v_uid);
    perform public.audit_write('repair.cancel_requested', 'repair', p_id::text, jsonb_build_object('reason', v_reason));
  else
    raise exception 'INVALID_INPUT';
  end if;
  return v_id;
end $$;

-- older app versions: the cancel button now files a request instead of cancelling
create or replace function public.customer_cancel_order(p_order_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.customer_request_cancel('order', p_order_id, 'من غير سبب');
end $$;

-- ---------------------------------------------------------------- staff side
create or replace function public.staff_decide_cancel(p_request_id uuid, p_approve boolean, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_req public.cancel_requests%rowtype;
  v_order public.orders%rowtype;
  v_r public.repair_requests%rowtype;
  v_note text := nullif(left(trim(coalesce(p_note, '')), 500), '');
  v_ref text;
begin
  perform public.require_auth();
  select * into v_req from public.cancel_requests where id = p_request_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_req.status <> 'pending' then raise exception 'ALREADY_DECIDED'; end if;

  if v_req.order_id is not null then
    perform public.require_permission('orders.manage');
    select * into v_order from public.orders where id = v_req.order_id for update;
    v_ref := v_order.reference;
    if p_approve then
      perform public._apply_order_status(v_order, 'cancelled', 'customer request: ' || v_req.reason);
      update public.payments set status = 'cancelled' where order_id = v_order.id and status in ('pending','processing');
    else
      insert into public.order_status_history(order_id, from_status, to_status, customer_message, changed_by)
      values (v_order.id, v_order.status, v_order.status,
              'مقدرناش نلغي الطلب' || coalesce(': ' || v_note, '.') || ' طلبك مكمّل عادي.', auth.uid());
      perform public.notify_user(v_order.customer_id, 'بخصوص إلغاء طلبك ' || v_ref, 'About cancelling order ' || v_ref,
        'مقدرناش نلغي الطلب' || coalesce(': ' || v_note, '.') || ' طلبك مكمّل عادي.',
        'We could not cancel your order' || coalesce(': ' || v_note, '.') || ' It continues as normal.',
        'order', v_order.id, v_ref, '/orders/' || v_order.id);
    end if;
  else
    select * into v_r from public.repair_requests where id = v_req.repair_id for update;
    if not public._can_update_repair(v_r) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
    v_ref := v_r.reference;
    if p_approve then
      perform public._apply_repair_status(v_r, 'cancelled', coalesce(v_note, 'تم إلغاء الطلب بناءً على طلبك.'), coalesce(v_note, 'Cancelled at your request.'));
      update public.repair_requests set cancel_reason = 'customer request: ' || v_req.reason where id = v_r.id;
    else
      insert into public.repair_status_history(repair_id, from_status, to_status, customer_message_ar, customer_message_en, changed_by)
      values (v_r.id, v_r.status, v_r.status,
              'مقدرناش نلغي طلب الصيانة' || coalesce(': ' || v_note, '.') || ' الطلب مكمّل عادي.',
              'We could not cancel the repair' || coalesce(': ' || v_note, '.') || ' It continues as normal.', auth.uid());
      perform public.notify_user(v_r.customer_id, 'بخصوص إلغاء ' || v_ref, 'About cancelling ' || v_ref,
        'مقدرناش نلغي طلب الصيانة' || coalesce(': ' || v_note, '.') || ' الطلب مكمّل عادي.',
        'We could not cancel the repair' || coalesce(': ' || v_note, '.') || ' It continues as normal.',
        'repair', v_r.id, v_ref, '/repairs/' || v_r.id);
    end if;
  end if;

  update public.cancel_requests
     set status = case when p_approve then 'approved' else 'rejected' end,
         staff_note = v_note, decided_by = auth.uid(), decided_at = now()
   where id = v_req.id;
  perform public.audit_write(case when p_approve then 'cancel.approved' else 'cancel.rejected' end,
    case when v_req.order_id is not null then 'order' else 'repair' end,
    coalesce(v_req.order_id, v_req.repair_id)::text, jsonb_build_object('reason', v_req.reason, 'note', v_note));
end $$;

revoke all on function public.customer_request_cancel(text, uuid, text) from public, anon;
grant execute on function public.customer_request_cancel(text, uuid, text) to authenticated;
revoke all on function public.staff_decide_cancel(uuid, boolean, text) from public, anon;
grant execute on function public.staff_decide_cancel(uuid, boolean, text) to authenticated;
