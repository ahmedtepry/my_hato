-- 0113: online commission = the PRODUCT commission (same amounts the owner sets for the cashier), frozen once per delivered order the employee confirmed.
-- It joins the same commission + target bar as the cashier sales. The accountant report separates MONEY (wallet / delivery cash / paid at a branch till)
-- from COMMISSION, and flags online orders paid at a branch that already show up as a till sale, so money is never counted twice.
create table if not exists public.online_commissions (
  order_id uuid primary key references public.orders (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  amount_minor bigint not null check (amount_minor >= 0),
  delivered_at timestamptz not null,
  frozen_at timestamptz not null default now()
);
create index if not exists online_commissions_user on public.online_commissions (user_id, delivered_at);
alter table public.online_commissions enable row level security;
revoke all on public.online_commissions from anon, authenticated;

create table if not exists public.online_settled (
  order_id uuid primary key references public.orders (id) on delete cascade,
  settled_by uuid references auth.users (id) on delete set null,
  note text,
  created_at timestamptz not null default now()
);
alter table public.online_settled enable row level security;
revoke all on public.online_settled from anon, authenticated;

-- freeze the commission of delivered orders that have none yet (idempotent; the commission running on the delivery day, Cairo)
create or replace function public._online_freeze() returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into public.online_commissions (order_id, user_id, amount_minor, delivered_at)
  select o.id, public._online_confirmer(o.id), coalesce((
           select sum(it.quantity * coalesce((select pc.amount_minor from public.product_commissions pc
                       where pc.product_id = it.product_id
                         and (pc.starts_on is null or pc.starts_on <= (d.at at time zone 'Africa/Cairo')::date)
                         and (pc.ends_on is null or pc.ends_on >= (d.at at time zone 'Africa/Cairo')::date)), 0))
             from public.order_items it where it.order_id = o.id), 0), d.at
    from public.orders o
    join lateral (select min(h.created_at) at from public.order_status_history h where h.order_id = o.id and h.to_status = 'delivered') d on d.at is not null
   where o.status = 'delivered' and public._online_confirmer(o.id) is not null
     and not exists (select 1 from public.online_commissions c where c.order_id = o.id)
   limit 2000
  on conflict (order_id) do nothing;
end $$;
revoke all on function public._online_freeze() from public, anon, authenticated;

create or replace function public._online_com(p_user uuid, p_from timestamptz, p_to timestamptz) returns bigint
language sql stable security definer set search_path = public as $$
  select coalesce(sum(c.amount_minor), 0)::bigint from public.online_commissions c join public.orders o on o.id = c.order_id
   where c.user_id = p_user and c.delivered_at >= p_from and c.delivered_at < p_to and o.payment_status <> 'refunded'
$$;
revoke all on function public._online_com(uuid, timestamptz, timestamptz) from public, anon, authenticated;

-- the employee's robot: commission is now the product commission
create or replace function public.my_online_status() returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_from timestamptz; v_to timestamptz; v_day timestamptz; v_p public.online_plan%rowtype; v_n integer; v_v bigint; v_nd integer; v_vd bigint; v_sh timestamptz;
begin
  perform public.require_permission('online.mine');
  perform public._online_freeze();
  select m_from, m_to, m_day into v_from, v_to, v_day from public._cairo_month(null);
  select * into v_p from public.online_plan where user_id = auth.uid();
  select n, value_minor into v_n, v_v from public._online_done(auth.uid(), v_from, v_to);
  select n, value_minor into v_nd, v_vd from public._online_done(auth.uid(), v_day, v_to);
  select opened_at into v_sh from public.online_shifts where user_id = auth.uid() and closed_at is null;
  perform public._online_check_alerts(auth.uid(), v_n, v_v);
  return jsonb_build_object('daily_hours', v_p.daily_hours, 'orders_target', v_p.orders_monthly, 'value_target_minor', v_p.value_monthly_minor,
    'orders_done', v_n, 'value_done_minor', v_v, 'orders_today', v_nd, 'value_today_minor', v_vd,
    'orders_pct', case when coalesce(v_p.orders_monthly, 0) > 0 then round(v_n * 100.0 / v_p.orders_monthly, 1) end,
    'value_pct', case when coalesce(v_p.value_monthly_minor, 0) > 0 then round(v_v * 100.0 / v_p.value_monthly_minor, 1) end,
    'commission_minor', public._online_com(auth.uid(), v_from, v_to),
    'commission_today_minor', public._online_com(auth.uid(), v_day, v_to),
    'shift_opened_at', v_sh, 'at', now());
end $$;
revoke all on function public.my_online_status() from public, anon;
grant execute on function public.my_online_status() to authenticated;

-- the cashier-style bar (commission + target) now includes what he sold online
create or replace function public.my_target_status() returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_from timestamptz; v_to timestamptz; v_day timestamptz; v_t bigint; v_net bigint; v_com bigint; v_net_d bigint; v_com_d bigint; v_on bigint; v_onc bigint; v_ond bigint; v_oncd bigint;
begin
  perform public.require_permission('targets.mine');
  perform public._online_freeze();
  select m_from, m_to, m_day into v_from, v_to, v_day from public._cairo_month(null);
  select monthly_minor into v_t from public.user_targets where user_id = auth.uid();
  select coalesce(sum(total_minor - refunded_minor), 0) into v_net from public.pos_sales where cashier_id = auth.uid() and created_at >= v_from and created_at < v_to;
  select coalesce(sum(total_minor - refunded_minor), 0) into v_net_d from public.pos_sales where cashier_id = auth.uid() and created_at >= v_day;
  select coalesce(sum(i.commission_unit_minor * (i.quantity - i.refunded_qty)), 0) into v_com from public.pos_sale_items i
    join public.pos_sales p on p.id = i.sale_id where p.cashier_id = auth.uid() and p.created_at >= v_from and p.created_at < v_to;
  select coalesce(sum(i.commission_unit_minor * (i.quantity - i.refunded_qty)), 0) into v_com_d from public.pos_sale_items i
    join public.pos_sales p on p.id = i.sale_id where p.cashier_id = auth.uid() and p.created_at >= v_day;
  select value_minor into v_on from public._online_done(auth.uid(), v_from, v_to);
  select value_minor into v_ond from public._online_done(auth.uid(), v_day, v_to);
  v_onc := public._online_com(auth.uid(), v_from, v_to); v_oncd := public._online_com(auth.uid(), v_day, v_to);
  return jsonb_build_object('month_from', v_from, 'target_minor', v_t, 'net_minor', v_net + v_on,
    'pct', case when coalesce(v_t, 0) > 0 then round((v_net + v_on) * 100.0 / v_t, 1) else null end,
    'commission_month_minor', v_com + v_onc, 'commission_today_minor', v_com_d + v_oncd, 'sales_today_minor', v_net_d + v_ond,
    'online_minor', v_on, 'online_commission_minor', v_onc, 'at', now());
end $$;
revoke all on function public.my_target_status() from public, anon;
grant execute on function public.my_target_status() to authenticated;

-- the accountant: mark an online order as really settled (for example paid at the branch outside the till)
create or replace function public.online_mark_settled(p_reference text, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  perform public.require_permission('online.review');
  select id into v_id from public.orders where reference = p_reference;
  if v_id is null then raise exception 'NOT_FOUND'; end if;
  insert into public.online_settled (order_id, settled_by, note) values (v_id, auth.uid(), left(p_note, 300))
  on conflict (order_id) do update set settled_by = auth.uid(), note = excluded.note, created_at = now();
  perform public.audit_write('online.settled', 'order', p_reference, jsonb_build_object('note', left(p_note, 300)));
end $$;
revoke all on function public.online_mark_settled(text, text) from public, anon;
grant execute on function public.online_mark_settled(text, text) to authenticated;

-- the accountant's Online page (replaces the 0112 version)
create or replace function public.online_report(p_year int, p_month int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_from timestamptz; v_to timestamptz;
begin
  perform public.require_permission('online.review');
  if p_year is null or p_month is null or p_year not between 2024 and 2100 or p_month not between 1 and 12 then raise exception 'INVALID_INPUT'; end if;
  perform public._online_freeze();
  v_from := make_timestamptz(p_year, p_month, 1, 0, 0, 0, 'Africa/Cairo');
  v_to := v_from + interval '1 month';
  perform public.audit_write('online.report', 'system', 'online', jsonb_build_object('year', p_year, 'month', p_month));
  return (with ord as (
      select o.id, o.reference, o.created_at, o.status::text st, o.fulfillment::text ful, o.payment_method::text pm, o.payment_status::text ps, o.total_minor,
             o.branch_id, o.branch_confirmed, o.customer_id, public._online_confirmer(o.id) as conf,
             (select min(h.created_at) from public.order_status_history h where h.order_id = o.id and h.to_status = 'delivered') as delivered_at,
             case when o.payment_method in ('wallet', 'online') then 'online_money'
                  when o.payment_method = 'pay_at_branch' or o.fulfillment = 'pickup' then 'branch_till'
                  else 'delivery_cash' end as bucket
        from public.orders o where o.created_at >= v_from and o.created_at < v_to and o.status <> 'cancelled'),
    x as (
      select c.*, oc.amount_minor as com, (s.order_id is not null) as settled, sale.number as sale_number,
             case when c.st <> 'delivered' then 'not_delivered'
                  when c.ps = 'refunded' then 'refunded'
                  when c.bucket = 'online_money' and c.ps <> 'paid' then 'waiting_payment'
                  when c.bucket = 'branch_till' and sale.number is null and s.order_id is null then 'waiting_branch_sale'
                  else 'payable' end as com_state
        from ord c
        left join public.online_commissions oc on oc.order_id = c.id
        left join public.online_settled s on s.order_id = c.id
        left join lateral (select p.number from public.pos_sales p
                            where c.bucket = 'branch_till' and p.branch_id = c.branch_id and p.total_minor = c.total_minor
                              and p.created_at >= c.created_at - interval '1 day' and p.created_at < c.created_at + interval '14 days'
                              and (p.customer_id is null or p.customer_id = c.customer_id)
                            order by p.created_at limit 1) sale on true),
    emp as (
      select e.conf as uid,
             count(*) confirmed_n,
             count(*) filter (where e.st = 'delivered' and e.ps <> 'refunded') delivered_n,
             coalesce(sum(e.total_minor) filter (where e.st = 'delivered' and e.ps <> 'refunded'), 0) delivered_minor,
             coalesce(sum(e.com) filter (where e.com_state in ('payable', 'waiting_payment', 'waiting_branch_sale')), 0) commission_minor,
             coalesce(sum(e.com) filter (where e.com_state = 'payable'), 0) payable_minor
        from x e where e.conf is not null group by e.conf)
    select jsonb_build_object('year', p_year, 'month', p_month,
      'employees', coalesce((select jsonb_agg(jsonb_build_object('user_id', e.uid, 'name', public._ops_name(e.uid), 'confirmed_n', e.confirmed_n, 'delivered_n', e.delivered_n,
                    'delivered_minor', e.delivered_minor, 'commission_minor', e.commission_minor, 'payable_minor', e.payable_minor,
                    'shifts_count', (select count(*) from public.online_shifts s where s.user_id = e.uid and s.opened_at >= v_from and s.opened_at < v_to),
                    'shift_hours', (select coalesce(round((sum(extract(epoch from (coalesce(s.closed_at, now()) - s.opened_at))) / 3600)::numeric, 1), 0) from public.online_shifts s where s.user_id = e.uid and s.opened_at >= v_from and s.opened_at < v_to))
                    order by e.delivered_minor desc) from emp e), '[]'::jsonb),
      'money', coalesce((select jsonb_agg(jsonb_build_object('bucket', m.bucket, 'n', m.n, 'total_minor', m.t, 'counted_again_minor', m.dup)) from (
                    select bucket, count(*) n, coalesce(sum(total_minor), 0) t,
                           coalesce(sum(total_minor) filter (where sale_number is not null), 0) dup
                      from x where st = 'delivered' and ps <> 'refunded' group by bucket) m), '[]'::jsonb),
      'orders', coalesce((select jsonb_agg(jsonb_build_object('reference', c.reference, 'at', c.created_at, 'delivered_at', c.delivered_at, 'status', c.st,
                    'fulfillment', c.ful, 'branch', b.name_ar, 'branch_confirmed', c.branch_confirmed, 'payment_method', c.pm, 'payment_status', c.ps,
                    'bucket', c.bucket, 'total_minor', c.total_minor, 'employee', case when c.conf is null then null else public._ops_name(c.conf) end,
                    'commission_minor', coalesce(c.com, 0), 'commission_state', c.com_state, 'till_sale', c.sale_number, 'settled', c.settled)
                    order by c.created_at)
                    from (select * from x order by created_at limit 5000) c left join public.branches b on b.id = c.branch_id), '[]'::jsonb))
    );
end $$;
revoke all on function public.online_report(int, int) from public, anon;
grant execute on function public.online_report(int, int) to authenticated;
