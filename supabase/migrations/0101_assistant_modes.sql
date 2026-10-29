-- 0101: المساعد الآلي. Two modes, each switched on/off by whoever holds its permission (the owner gives it to a role or a person):
--   assistant.accountant  المحاسب الآلي      -> assistant_month_report(): one month of sales, commissions, shifts, orders and stock, ready for Excel files
--   assistant.support     روبوت خدمة العملاء -> _robot_tick() every 15 minutes: follows orders / repairs / stock and tells the right people (or the customer)
-- (assistant.cashier stays a placeholder.)

update public.permission_catalog set inert = false where permission in ('assistant.accountant', 'assistant.support');
insert into public.role_permissions (role, permission) values ('owner', 'assistant.accountant'), ('owner', 'assistant.support'), ('owner', 'assistant.cashier')
on conflict do nothing;

create table if not exists public.assistant_modes (
  key text primary key check (key in ('accountant', 'support')),
  enabled boolean not null default false,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null
);
alter table public.assistant_modes enable row level security;   -- no policies: only the functions below touch it
insert into public.assistant_modes (key, enabled) values ('accountant', false), ('support', false) on conflict (key) do nothing;

create table if not exists public.assistant_events (
  kind text not null,
  ref text not null,
  text_ar text,
  created_at timestamptz not null default now(),
  primary key (kind, ref)
);
alter table public.assistant_events enable row level security;

create or replace function public._assistant_on(p_key text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select enabled from public.assistant_modes where key = p_key), false)
$$;
revoke all on function public._assistant_on(text) from public, anon, authenticated;

-- what the app shows: only the modes he may switch
create or replace function public.assistant_state() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_acc boolean; v_sup boolean;
begin
  perform public.require_auth();
  v_acc := public.has_permission('assistant.accountant'); v_sup := public.has_permission('assistant.support');
  return jsonb_build_object(
    'accountant', case when v_acc then jsonb_build_object('enabled', public._assistant_on('accountant')) end,
    'support', case when v_sup then jsonb_build_object('enabled', public._assistant_on('support'),
        'log', coalesce((select jsonb_agg(jsonb_build_object('kind', kind, 'text', text_ar, 'at', created_at) order by created_at desc)
                           from (select * from public.assistant_events order by created_at desc limit 30) e), '[]'::jsonb)) end);
end $$;
revoke all on function public.assistant_state() from public, anon;
grant execute on function public.assistant_state() to authenticated;

create or replace function public.assistant_set(p_key text, p_enabled boolean, p_confirm boolean default false) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_key not in ('accountant', 'support') then raise exception 'INVALID_INPUT'; end if;
  perform public.require_permission('assistant.' || p_key);
  if p_enabled and coalesce(p_confirm, false) is not true then raise exception 'CONFIRM_REQUIRED'; end if;
  update public.assistant_modes set enabled = p_enabled, updated_at = now(), updated_by = auth.uid() where key = p_key;
  perform public.audit_write('assistant.switch', 'assistant', p_key, jsonb_build_object('enabled', p_enabled));
end $$;
revoke all on function public.assistant_set(text, boolean, boolean) from public, anon;
grant execute on function public.assistant_set(text, boolean, boolean) to authenticated;

-- ------------------------------------------------------------ the automatic accountant
create or replace function public.assistant_month_report(p_year int, p_month int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_from timestamptz; v_to timestamptz;
begin
  perform public.require_permission('assistant.accountant');
  if not public._assistant_on('accountant') then raise exception 'MODE_OFF'; end if;
  if p_year is null or p_month is null or p_year not between 2024 and 2100 or p_month not between 1 and 12 then raise exception 'INVALID_INPUT'; end if;
  v_from := make_timestamptz(p_year, p_month, 1, 0, 0, 0, 'Africa/Cairo');
  v_to := v_from + interval '1 month';
  perform public.audit_write('assistant.report', 'assistant', 'accountant', jsonb_build_object('year', p_year, 'month', p_month));
  return jsonb_build_object(
    'year', p_year, 'month', p_month,
    'branches', coalesce((select jsonb_agg(x order by x ->> 'name') from (
      select jsonb_build_object('id', b.id, 'name', b.name_ar, 'sales_count', coalesce(s.n, 0), 'gross_minor', coalesce(s.gross, 0), 'discount_minor', coalesce(s.disc, 0),
               'refunds_minor', coalesce(s.refunds, 0), 'net_minor', coalesce(s.gross, 0) - coalesce(s.refunds, 0), 'commission_minor', coalesce(i.com, 0),
               'cost_minor', coalesce(i.cost, 0), 'profit_minor', coalesce(s.gross, 0) - coalesce(s.refunds, 0) - coalesce(i.cost, 0)) as x
        from public.branches b
        left join lateral (select count(*) n, sum(total_minor) gross, sum(discount_minor) disc, sum(refunded_minor) refunds from public.pos_sales p
                            where p.branch_id = b.id and p.created_at >= v_from and p.created_at < v_to) s on true
        left join lateral (select sum(it.commission_unit_minor * (it.quantity - it.refunded_qty)) com,
                                  sum(coalesce(c.cost_unit_minor, 0) * (it.quantity - it.refunded_qty)) cost
                             from public.pos_sale_items it join public.pos_sales p on p.id = it.sale_id left join public.pos_item_costs c on c.item_id = it.id
                            where p.branch_id = b.id and p.created_at >= v_from and p.created_at < v_to) i on true
       where b.is_active and public._branch_view_ok(b.id)) q), '[]'::jsonb),
    'employees', coalesce((select jsonb_agg(x order by x ->> 'name') from (
      select jsonb_build_object('user_id', u.uid, 'name', public._ops_name(u.uid), 'role', (select ur.role::text from public.user_roles ur where ur.user_id = u.uid limit 1),
               'sales_count', s.n, 'gross_minor', s.gross, 'refunds_minor', s.refunds, 'net_minor', s.gross - s.refunds, 'discount_minor', s.disc,
               'commission_minor', coalesce(c.com, 0), 'shifts_count', coalesce(sh.n, 0), 'target_minor', ut.monthly_minor,
               'lines', coalesce((select jsonb_agg(jsonb_build_object('sale_number', p.number, 'at', p.created_at, 'branch', br.name_ar, 'product', it.name_ar,
                                   'quantity', it.quantity, 'refunded_qty', it.refunded_qty, 'unit_minor', it.commission_unit_minor,
                                   'total_minor', it.commission_unit_minor * (it.quantity - it.refunded_qty)) order by p.created_at)
                                   from public.pos_sale_items it join public.pos_sales p on p.id = it.sale_id join public.branches br on br.id = p.branch_id
                                  where p.cashier_id = u.uid and p.created_at >= v_from and p.created_at < v_to and it.commission_unit_minor > 0 and public._branch_view_ok(p.branch_id)), '[]'::jsonb)) as x
        from (select distinct cashier_id as uid from public.pos_sales where created_at >= v_from and created_at < v_to and public._branch_view_ok(branch_id)) u
        join lateral (select count(*) n, coalesce(sum(p.total_minor), 0) gross, coalesce(sum(p.refunded_minor), 0) refunds, coalesce(sum(p.discount_minor), 0) disc
                        from public.pos_sales p where p.cashier_id = u.uid and p.created_at >= v_from and p.created_at < v_to and public._branch_view_ok(p.branch_id)) s on true
        left join lateral (select sum(i.commission_unit_minor * (i.quantity - i.refunded_qty)) com from public.pos_sale_items i join public.pos_sales p on p.id = i.sale_id
                            where p.cashier_id = u.uid and p.created_at >= v_from and p.created_at < v_to and public._branch_view_ok(p.branch_id)) c on true
        left join lateral (select count(*) n from public.shifts h where h.cashier_id = u.uid and h.opened_at >= v_from and h.opened_at < v_to and public._branch_view_ok(h.branch_id)) sh on true
        left join public.user_targets ut on ut.user_id = u.uid) q), '[]'::jsonb),
    'shifts', coalesce((select jsonb_agg(jsonb_build_object('branch', b.name_ar, 'cashier', public._ops_name(h.cashier_id), 'opened_at', h.opened_at, 'closed_at', h.closed_at,
               'opening_minor', h.opening_cash_minor, 'expected_minor', h.expected_cash_minor, 'counted_minor', h.counted_cash_minor, 'variance_minor', h.variance_minor, 'status', h.status)
               order by h.opened_at) from public.shifts h join public.branches b on b.id = h.branch_id
              where h.opened_at >= v_from and h.opened_at < v_to and public._branch_view_ok(h.branch_id)), '[]'::jsonb),
    'orders', coalesce((select jsonb_agg(jsonb_build_object('reference', o.reference, 'at', o.created_at, 'status', o.status::text, 'payment_method', o.payment_method::text,
               'payment_status', o.payment_status::text, 'fulfillment', o.fulfillment::text, 'total_minor', o.total_minor) order by o.created_at)
               from (select * from public.orders where created_at >= v_from and created_at < v_to order by created_at limit 5000) o), '[]'::jsonb),
    'stock', coalesce((select jsonb_agg(jsonb_build_object('sku', p.sku, 'name', p.name_ar, 'total', p.stock_quantity,
               'unallocated', greatest(public._stock_unallocated(p.id), 0),
               'branches', coalesce((select jsonb_agg(jsonb_build_object('branch', b.name_ar, 'qty', bs.quantity) order by b.name_ar)
                                       from public.branch_stock bs join public.branches b on b.id = bs.branch_id where bs.product_id = p.id and bs.quantity > 0), '[]'::jsonb)) order by p.name_ar)
               from public.products p where p.status <> 'archived'), '[]'::jsonb),
    'receipts', coalesce((select jsonb_agg(jsonb_build_object('number', r.number, 'at', r.created_at, 'supplier', r.supplier, 'branch', coalesce(b.name_ar, 'الوير هاوس'),
               'by', public._ops_name(r.created_by), 'items', (select jsonb_agg(jsonb_build_object('name', i.name_ar, 'qty', i.qty) order by i.name_ar) from public.goods_receipt_items i where i.receipt_id = r.id)) order by r.created_at)
               from public.goods_receipts r left join public.branches b on b.id = r.branch_id where r.created_at >= v_from and r.created_at < v_to), '[]'::jsonb),
    'stocktakes', coalesce((select jsonb_agg(jsonb_build_object('number', s.number, 'at', s.created_at, 'branch', b.name_ar, 'by', public._ops_name(s.created_by), 'diff_pieces', s.diff_pieces,
               'differences', (select jsonb_agg(jsonb_build_object('name', i.name_ar, 'expected', i.expected, 'counted', i.counted) order by i.name_ar) from public.stocktake_items i where i.stocktake_id = s.id and i.expected <> i.counted)) order by s.created_at)
               from public.stocktakes s join public.branches b on b.id = s.branch_id where s.created_at >= v_from and s.created_at < v_to and public._branch_view_ok(s.branch_id)), '[]'::jsonb));
end $$;
revoke all on function public.assistant_month_report(int, int) from public, anon;
grant execute on function public.assistant_month_report(int, int) to authenticated;

-- ------------------------------------------------------------ the customer-service robot
-- Runs every 15 minutes (pg_cron, set up on the server). Each thing is done once per order / repair / product (assistant_events keeps count).
create or replace function public._robot_tick() returns int
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  if not public._assistant_on('support') then return 0; end if;

  -- 1) an online order nobody confirmed for an hour: tell the team
  for r in select o.id, o.reference from public.orders o
            where o.status = 'pending_confirmation' and o.created_at < now() - interval '60 minutes' and o.created_at > now() - interval '3 days'
              and not exists (select 1 from public.assistant_events e where e.kind = 'order_pending' and e.ref = o.reference) limit 30 loop
    insert into public.assistant_events (kind, ref, text_ar) values ('order_pending', r.reference, 'نبّهت الفريق إن الطلب ' || r.reference || ' لسه مستني التأكيد');
    perform public._notify_staff('orders.manage', '⏰ طلب مستني تأكيدك', '⏰ An order is waiting', 'الطلب ' || r.reference || ' لسه ما اتأكدش من أكتر من ساعة.',
      'Order ' || r.reference || ' has not been confirmed for over an hour.', r.reference);
    n := n + 1;
  end loop;

  -- 2) an online payment left unfinished for a day: remind the customer
  for r in select o.id, o.reference, o.customer_id from public.orders o
            where o.payment_method = 'online' and o.payment_status in ('pending', 'unpaid', 'failed') and o.status <> 'cancelled'
              and o.created_at < now() - interval '24 hours' and o.created_at > now() - interval '7 days'
              and not exists (select 1 from public.assistant_events e where e.kind = 'order_unpaid' and e.ref = o.reference) limit 30 loop
    insert into public.assistant_events (kind, ref, text_ar) values ('order_unpaid', r.reference, 'فكّرت العميل يكمّل دفع الطلب ' || r.reference);
    perform public.notify_user(r.customer_id, 'طلبك لسه مستني الدفع', 'Your order is waiting for payment', 'الطلب ' || r.reference || ' لسه ما اتدفعش. كمّل الدفع عشان نجهّزه لك.',
      'Order ' || r.reference || ' is not paid yet. Complete the payment so we can prepare it.', 'order', r.id, r.reference, '/orders/' || r.id);
    n := n + 1;
  end loop;

  -- 3) an order ready for pickup for two days: remind the customer
  for r in select o.id, o.reference, o.customer_id from public.orders o
            where o.status = 'ready_for_pickup' and o.updated_at < now() - interval '48 hours'
              and not exists (select 1 from public.assistant_events e where e.kind = 'order_pickup' and e.ref = o.reference) limit 30 loop
    insert into public.assistant_events (kind, ref, text_ar) values ('order_pickup', r.reference, 'فكّرت العميل يستلم الطلب ' || r.reference);
    perform public.notify_user(r.customer_id, 'طلبك جاهز للاستلام', 'Your order is ready', 'الطلب ' || r.reference || ' جاهز في الفرع من يومين. عدّي عليه وقت ما يناسبك.',
      'Order ' || r.reference || ' has been ready at the branch for two days.', 'order', r.id, r.reference, '/orders/' || r.id);
    n := n + 1;
  end loop;

  -- 4) a repair quote waiting for the customer's answer: remind him after a day, tell the team after three
  for r in select q.id, q.reference, q.customer_id, q.updated_at from public.repair_requests q
            where q.status = 'awaiting_approval' and q.updated_at < now() - interval '24 hours'
              and not exists (select 1 from public.assistant_events e where e.kind = 'repair_quote' and e.ref = q.reference) limit 30 loop
    insert into public.assistant_events (kind, ref, text_ar) values ('repair_quote', r.reference, 'فكّرت العميل يرد على عرض الصيانة ' || r.reference);
    perform public.notify_user(r.customer_id, 'عرض الصيانة مستني ردك', 'Your repair quote is waiting', 'عرض صيانة ' || r.reference || ' مستني موافقتك. وافق أو ارفض عشان نكمّل.',
      'The quote for ' || r.reference || ' is waiting for your answer.', 'repair', r.id, r.reference, '/repairs/' || r.id);
    n := n + 1;
  end loop;
  for r in select q.id, q.reference from public.repair_requests q
            where q.status = 'awaiting_approval' and q.updated_at < now() - interval '72 hours'
              and not exists (select 1 from public.assistant_events e where e.kind = 'repair_quote_team' and e.ref = q.reference) limit 30 loop
    insert into public.assistant_events (kind, ref, text_ar) values ('repair_quote_team', r.reference, 'نبّهت الفريق إن العميل ما ردّش على عرض ' || r.reference || ' من 3 أيام');
    perform public._notify_staff('repairs.manage', '📞 عميل ما ردّش على العرض', '📞 No answer to a quote', 'عرض ' || r.reference || ' من 3 أيام من غير رد. كلّم العميل.',
      'The quote for ' || r.reference || ' has had no answer for 3 days. Call the customer.', r.reference);
    n := n + 1;
  end loop;

  -- 5) a repaired device waiting at the branch for three days: remind the customer
  for r in select q.id, q.reference, q.customer_id from public.repair_requests q
            where q.status = 'ready_for_pickup' and q.updated_at < now() - interval '72 hours'
              and not exists (select 1 from public.assistant_events e where e.kind = 'repair_pickup' and e.ref = q.reference) limit 30 loop
    insert into public.assistant_events (kind, ref, text_ar) values ('repair_pickup', r.reference, 'فكّرت العميل يستلم جهازه ' || r.reference);
    perform public.notify_user(r.customer_id, 'جهازك جاهز', 'Your device is ready', 'جهازك (' || r.reference || ') جاهز للاستلام من 3 أيام.',
      'Your device (' || r.reference || ') has been ready for 3 days.', 'repair', r.id, r.reference, '/repairs/' || r.id);
    n := n + 1;
  end loop;

  -- 6) a product almost out of stock: tell the people who manage stock (once, until it is restocked)
  delete from public.assistant_events e where e.kind = 'low_stock' and exists (select 1 from public.products p where p.id::text = e.ref and p.stock_quantity > 3);
  for r in select p.id, p.name_ar, p.stock_quantity from public.products p
            where p.status = 'published' and p.stock_quantity between 0 and 3
              and not exists (select 1 from public.assistant_events e where e.kind = 'low_stock' and e.ref = p.id::text) limit 20 loop
    insert into public.assistant_events (kind, ref, text_ar) values ('low_stock', r.id::text, 'نبّهت إن ' || r.name_ar || ' قرب يخلص (' || r.stock_quantity || ')');
    perform public._notify_staff('inventory.manage', '🔻 منتج قرب يخلص', '🔻 Low stock', r.name_ar || ': فاضل ' || r.stock_quantity || ' بس.', r.name_ar || ': only ' || r.stock_quantity || ' left.', 'LOW-' || left(r.id::text, 6));
    n := n + 1;
  end loop;

  delete from public.assistant_events where created_at < now() - interval '120 days' and kind <> 'low_stock';
  return n;
end $$;
revoke all on function public._robot_tick() from public, anon, authenticated;

-- "run it now" for whoever may switch the robot (also handy to see it work)
create or replace function public.assistant_run_robot() returns int
language plpgsql security definer set search_path = public as $$
begin
  perform public.require_permission('assistant.support');
  if not public._assistant_on('support') then raise exception 'MODE_OFF'; end if;
  return public._robot_tick();
end $$;
revoke all on function public.assistant_run_robot() from public, anon;
grant execute on function public.assistant_run_robot() to authenticated;
