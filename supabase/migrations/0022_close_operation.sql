-- 0022 "Close the operation": staff finally close an order or a repair with one of four fixed
-- reasons. A closed order/repair disappears from the customer's app for good (RLS), but stays in
-- the console marked as closed with its reason.
--   orders : cancelled_by_customer | purchased
--   repairs: cancelled_by_customer | repaired | unrepairable

alter table public.orders
  add column if not exists closed_at timestamptz,
  add column if not exists close_reason text check (close_reason is null or close_reason in ('cancelled_by_customer','purchased')),
  add column if not exists closed_by uuid references auth.users(id);
alter table public.repair_requests
  add column if not exists closed_at timestamptz,
  add column if not exists close_reason text check (close_reason is null or close_reason in ('cancelled_by_customer','repaired','unrepairable')),
  add column if not exists closed_by uuid references auth.users(id);
grant select (closed_at, close_reason) on public.repair_requests to authenticated;

-- customers only see their own rows that are still open; staff see everything
alter policy orders_read on public.orders
  using ((customer_id = auth.uid() and closed_at is null) or public.has_permission('orders.view'));
alter policy order_items_read on public.order_items
  using (exists (select 1 from public.orders o where o.id = order_id
                  and ((o.customer_id = auth.uid() and o.closed_at is null) or public.has_permission('orders.view'))));
alter policy order_history_read on public.order_status_history
  using (exists (select 1 from public.orders o where o.id = order_id
                  and ((o.customer_id = auth.uid() and o.closed_at is null) or public.has_permission('orders.view'))));

alter policy repairs_read on public.repair_requests
  using ((customer_id = auth.uid() and closed_at is null)
         or public.has_permission('repairs.manage')
         or public.has_role('support')
         or (public.has_permission('repairs.update_assigned') and assigned_technician_id = auth.uid()));

create or replace function public.can_read_repair(p_repair_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.repair_requests r where r.id = p_repair_id and (
      (r.customer_id = auth.uid() and r.closed_at is null) or public.has_permission('repairs.manage') or public.has_role('support')
      or (public.has_permission('repairs.update_assigned') and r.assigned_technician_id = auth.uid())))
$$;

-- cancellation requests of closed orders/repairs are hidden from the customer too
-- (checked with definer rights: the customer's own view no longer shows the closed row)
create or replace function public._is_closed(p_order_id uuid, p_repair_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.orders where id = p_order_id and closed_at is not null)
      or exists (select 1 from public.repair_requests where id = p_repair_id and closed_at is not null)
$$;
revoke all on function public._is_closed(uuid, uuid) from public, anon;
grant execute on function public._is_closed(uuid, uuid) to authenticated;

alter policy cancel_requests_read on public.cancel_requests
  using ((customer_id = auth.uid() and not public._is_closed(order_id, repair_id))
         or (order_id is not null and public.has_permission('orders.manage'))
         or (repair_id is not null and (public.has_permission('repairs.manage') or public.has_permission('repairs.update_assigned'))));

-- guest tracking never finds a closed repair
create or replace function public.guest_repair_lookup(p_reference text, p_phone text)
returns jsonb language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_digits text := regexp_replace(translate(coalesce(p_reference, ''), '٠١٢٣٤٥٦٧٨٩', '0123456789'), '[^0-9]', '', 'g');
  v_ref text;
  v_phone text := public.normalize_eg_mobile(p_phone);
  v_ip text;
  v_id uuid;
begin
  if v_digits = '' or length(v_digits) > 10 or v_phone is null then
    return jsonb_build_object('found', false, 'error', 'INVALID_INPUT');
  end if;
  v_ref := 'MY-HATO' || (v_digits::bigint)::text;   -- "75", "MY-HATO075", "my hato 75" -> MY-HATO75

  v_ip := coalesce(split_part(coalesce(current_setting('request.headers', true)::json ->> 'x-forwarded-for', ''), ',', 1), '');
  if not public.hit_rate_limit('guest_lookup_ref', encode(digest(v_ref, 'sha256'), 'hex'), 900, 6)
     or not public.hit_rate_limit('guest_lookup_ip', encode(digest('ip:' || v_ip, 'sha256'), 'hex'), 3600, 30) then
    return jsonb_build_object('found', false, 'error', 'RATE_LIMITED');
  end if;

  select r.id into v_id
    from public.repair_requests r
    left join public.customers c on c.user_id = r.customer_id
    left join public.profiles p on p.id = r.customer_id
   where r.reference = v_ref
     and r.closed_at is null
     and (public.normalize_eg_mobile(r.contact_phone) = v_phone
          or c.phone = v_phone
          or (p.phone_verified and public.normalize_eg_mobile(p.phone) = v_phone));
  if v_id is null then
    return jsonb_build_object('found', false);
  end if;
  return jsonb_build_object('found', true, 'repair', public.guest_repair_public_view(v_ref));
end $$;

create or replace function public.staff_close(p_kind text, p_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare v_r public.repair_requests%rowtype;
begin
  perform public.require_auth();
  if p_kind = 'order' then
    perform public.require_permission('orders.manage');
    if p_reason not in ('cancelled_by_customer','purchased') then raise exception 'INVALID_INPUT'; end if;
    update public.orders set closed_at = now(), close_reason = p_reason, closed_by = auth.uid()
     where id = p_id and closed_at is null;
    if not found then raise exception 'ALREADY_CLOSED'; end if;
    update public.cancel_requests
       set status = case when p_reason = 'cancelled_by_customer' then 'approved' else 'rejected' end,
           staff_note = 'تم إغلاق العملية', decided_by = auth.uid(), decided_at = now()
     where order_id = p_id and status = 'pending';
    perform public.audit_write('order.closed', 'order', p_id::text, jsonb_build_object('reason', p_reason));
  elsif p_kind = 'repair' then
    select * into v_r from public.repair_requests where id = p_id for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    if not public.has_permission('repairs.manage') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
    if p_reason not in ('cancelled_by_customer','repaired','unrepairable') then raise exception 'INVALID_INPUT'; end if;
    if v_r.closed_at is not null then raise exception 'ALREADY_CLOSED'; end if;
    update public.repair_requests set closed_at = now(), close_reason = p_reason, closed_by = auth.uid() where id = p_id;
    update public.cancel_requests
       set status = case when p_reason = 'cancelled_by_customer' then 'approved' else 'rejected' end,
           staff_note = 'تم إغلاق العملية', decided_by = auth.uid(), decided_at = now()
     where repair_id = p_id and status = 'pending';
    perform public.audit_write('repair.closed', 'repair', p_id::text, jsonb_build_object('reason', p_reason));
  else
    raise exception 'INVALID_INPUT';
  end if;
end $$;
revoke all on function public.staff_close(text, uuid, text) from public, anon;
grant execute on function public.staff_close(text, uuid, text) to authenticated;

-- dashboard counts only open work
create or replace function public.staff_dashboard_stats()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_staff() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return jsonb_build_object(
    'total_orders', (select count(*) from public.orders),
    'new_orders_today', (select count(*) from public.orders where created_at >= date_trunc('day', now() at time zone 'Africa/Cairo') at time zone 'Africa/Cairo'),
    'pending_orders', (select count(*) from public.orders where status = 'pending_confirmation' and closed_at is null),
    'completed_orders', (select count(*) from public.orders where status = 'delivered'),
    'total_sales_minor', (select coalesce(sum(total_minor), 0) from public.orders where status = 'delivered'),
    'active_repairs', (select count(*) from public.repair_requests where status not in ('delivered','cancelled','unrepairable') and closed_at is null),
    'repairs_awaiting_approval', (select count(*) from public.repair_requests where status = 'awaiting_approval' and closed_at is null),
    'repairs_ready', (select count(*) from public.repair_requests where status = 'ready_for_pickup' and closed_at is null),
    'closed_operations', (select count(*) from public.orders where closed_at is not null)
                        + (select count(*) from public.repair_requests where closed_at is not null),
    'low_stock', (select count(*) from public.products where status = 'published'
                    and stock_quantity <= coalesce((public.setting('low_stock_threshold') #>> '{}')::int, 5)),
    'failed_emails', (select count(*) from public.email_outbox where status = 'failed')
  );
end $$;
