-- 0132: (1) manual refund record for online orders, (2) find a customer by phone at the till, (3) drawer expense report.

-- (1) online refund (money is returned by hand: wallet / bank / cash; this records it, tells the customer, and marks the order refunded when it is the full amount)
create table if not exists public.order_refunds (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id),
  amount_minor bigint not null check (amount_minor > 0),
  reason text not null check (char_length(btrim(reason)) between 3 and 300),
  method text not null check (method in ('wallet', 'bank', 'cash', 'other')),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);
create index if not exists order_refunds_order_idx on public.order_refunds (order_id);
alter table public.order_refunds enable row level security;

create or replace function public.staff_order_refund(p_order_id uuid, p_amount_minor bigint, p_reason text, p_method text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := public.require_auth(); o public.orders%rowtype; v_done bigint;
begin
  perform public.require_permission('wallet.refund');
  select * into o from public.orders where id = p_order_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if o.payment_status::text not in ('paid', 'partially_refunded') and o.status::text <> 'delivered' then raise exception 'NOT_REFUNDABLE'; end if;
  if char_length(btrim(coalesce(p_reason, ''))) < 3 or p_method not in ('wallet', 'bank', 'cash', 'other') then raise exception 'INVALID_INPUT'; end if;
  select coalesce(sum(amount_minor), 0) into v_done from public.order_refunds where order_id = o.id;
  if p_amount_minor is null or p_amount_minor <= 0 or v_done + p_amount_minor > o.total_minor then raise exception 'REFUND_EXCEEDS_TOTAL'; end if;
  insert into public.order_refunds (order_id, amount_minor, reason, method, created_by) values (o.id, p_amount_minor, left(btrim(p_reason), 300), p_method, v_uid);
  v_done := v_done + p_amount_minor;
  if v_done = o.total_minor and o.payment_status::text <> 'refunded' then update public.orders set payment_status = 'refunded' where id = o.id; end if;
  perform public.audit_write('order.refund', 'order', o.reference, jsonb_build_object('amount_minor', p_amount_minor, 'method', p_method, 'reason', left(btrim(p_reason), 300), 'refunded_total', v_done));
  if o.customer_id is not null then
    perform public.notify_user(o.customer_id, 'تم رد مبلغ لطلبك', 'A refund was issued for your order',
      'اترد لك ' || (p_amount_minor / 100.0)::text || ' ج.م على طلب ' || o.reference, 'A refund of ' || (p_amount_minor / 100.0)::text || ' EGP was issued for order ' || o.reference,
      'order', o.id, o.reference, null);
  end if;
  return jsonb_build_object('refunded_minor', v_done, 'total_minor', o.total_minor);
end $$;
revoke all on function public.staff_order_refund(uuid, bigint, text, text) from public, anon;
grant execute on function public.staff_order_refund(uuid, bigint, text, text) to authenticated;

create or replace function public.staff_order_refunds(p_order_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_auth();
  if not (public.has_permission('orders.view') or public.has_permission('orders.manage')) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('amount_minor', r.amount_minor, 'reason', r.reason, 'method', r.method, 'created_at', r.created_at) order by r.created_at desc)
                     from public.order_refunds r where r.order_id = p_order_id), '[]'::jsonb);
end $$;
revoke all on function public.staff_order_refunds(uuid) from public, anon;
grant execute on function public.staff_order_refunds(uuid) to authenticated;

-- (2) find a customer by an exact phone number (no browsing: the cashier only sees the person whose number he typed)
create or replace function public.pos_find_customer(p_phone text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare d text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'); r record;
begin
  perform public.require_permission('pos.sell');
  if char_length(d) < 8 then raise exception 'INVALID_INPUT'; end if;
  d := right(d, 10);
  select p.id, p.full_name, coalesce(p.contact_phone, p.phone) as phone into r
    from public.profiles p
   where right(regexp_replace(coalesce(p.contact_phone, ''), '\D', '', 'g'), 10) = d or right(regexp_replace(coalesce(p.phone, ''), '\D', '', 'g'), 10) = d
   limit 1;
  if not found then return null; end if;
  return jsonb_build_object('id', r.id, 'name', r.full_name, 'phone', r.phone);
end $$;
revoke all on function public.pos_find_customer(text) from public, anon;
grant execute on function public.pos_find_customer(text) to authenticated;

-- (3) expenses paid out of the drawers, for the owner / accountant
create or replace function public.pos_expense_report(p_from timestamptz default null, p_to timestamptz default null)
returns table (id uuid, created_at timestamptz, branch_id uuid, branch_name_ar text, cashier_name text, amount_minor bigint, reason text)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_auth();
  if not (public.has_permission('sales.view') or public.has_permission('shifts.review') or public.has_permission('books.period')) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return query
    select e.id, e.created_at, e.branch_id, b.name_ar,
           (select coalesce(tm.login_display, p.full_name) from public.profiles p left join public.team_members tm on tm.user_id = p.id where p.id = e.created_by),
           e.amount_minor, e.reason
      from public.pos_expenses e join public.branches b on b.id = e.branch_id
     where public._branch_ok(e.branch_id) and (p_from is null or e.created_at >= p_from) and (p_to is null or e.created_at < p_to)
     order by e.created_at desc limit 500;
end $$;
revoke all on function public.pos_expense_report(timestamptz, timestamptz) from public, anon;
grant execute on function public.pos_expense_report(timestamptz, timestamptz) to authenticated;
