-- 0112: the Online department. Online employee = own shift with NO cash; commission = % of orders HE confirmed that ended delivered (not refunded).
-- The accountant gets an "Online" report: per employee, and per order (branch pickup or delivery, how it was paid, commission).
insert into public.permission_catalog (permission, grp, name_ar, name_en, desc_ar, desc_en, sensitive, inert, sort) values
 ('online.shift', 'orders', 'يفتح ويقفل شيفت الأونلاين', 'Open and close the online shift',
  'شيفت من غير فلوس: بيتحسب فيه الأوردرات اللي أكدها بس', 'A shift with no cash: only the orders he confirmed are counted', false, false, 63),
 ('online.review', 'system', 'يراجع قسم الأونلاين (محاسب)', 'Review the Online department (accountant)',
  'يشوف كل أوردرات الأونلاين وعمولة كل موظف واستلام كل أوردر من فرع أو توصيل', 'Sees every online order, each employee commission and whether it was a branch pickup or delivery', true, false, 43)
on conflict (permission) do update set name_ar = excluded.name_ar, name_en = excluded.name_en, desc_ar = excluded.desc_ar, desc_en = excluded.desc_en;
insert into public.role_permissions (role, permission) values
 ('owner', 'online.shift'), ('owner', 'online.review'),
 ('accountant', 'online.review'), ('accountant', 'online.manage'),
 ('manager', 'online.shift'), ('manager', 'online.review'), ('sales', 'online.shift')
on conflict do nothing;

alter table public.online_plan add column if not exists commission_pct numeric(5, 2) check (commission_pct is null or (commission_pct >= 0 and commission_pct <= 50));

create table if not exists public.online_shifts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  opened_at timestamptz not null default now(),
  closed_at timestamptz,
  closed_by uuid references auth.users (id) on delete set null
);
alter table public.online_shifts enable row level security;
revoke all on public.online_shifts from anon, authenticated;
create unique index if not exists online_shifts_one_open on public.online_shifts (user_id) where closed_at is null;

-- who confirmed the order (first time it moved to confirmed)
create or replace function public._online_confirmer(p_order uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select h.changed_by from public.order_status_history h where h.order_id = p_order and h.to_status = 'confirmed' order by h.created_at, h.id limit 1
$$;
revoke all on function public._online_confirmer(uuid) from public, anon, authenticated;

-- what one person earned in a period: delivered orders HE confirmed
create or replace function public._online_done(p_user uuid, p_from timestamptz, p_to timestamptz, out n integer, out value_minor bigint)
language sql stable security definer set search_path = public as $$
  select count(*)::integer, coalesce(sum(o.total_minor), 0)::bigint
  from public.orders o
  where o.status = 'delivered' and o.payment_status <> 'refunded' and public._online_confirmer(o.id) = p_user
    and o.id in (select h.order_id from public.order_status_history h where h.to_status = 'delivered' and h.created_at >= p_from and h.created_at < p_to)
$$;

create or replace function public.online_shift_state() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s public.online_shifts%rowtype;
begin
  perform public.require_permission('online.shift');
  select * into s from public.online_shifts where user_id = auth.uid() and closed_at is null;
  return jsonb_build_object('open', found, 'opened_at', s.opened_at);
end $$;
revoke all on function public.online_shift_state() from public, anon;
grant execute on function public.online_shift_state() to authenticated;

create or replace function public.online_shift_open() returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.require_permission('online.shift');
  if exists (select 1 from public.online_shifts where user_id = auth.uid() and closed_at is null) then return; end if;
  insert into public.online_shifts (user_id) values (auth.uid());
  perform public.audit_write('online.shift_open', 'user', auth.uid()::text, '{}'::jsonb);
end $$;
revoke all on function public.online_shift_open() from public, anon;
grant execute on function public.online_shift_open() to authenticated;

create or replace function public.online_shift_close() returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.online_shifts%rowtype; v_n integer; v_v bigint;
begin
  perform public.require_permission('online.shift');
  select * into s from public.online_shifts where user_id = auth.uid() and closed_at is null for update;
  if not found then raise exception 'NO_OPEN_SHIFT'; end if;
  update public.online_shifts set closed_at = now(), closed_by = auth.uid() where id = s.id;
  select n, value_minor into v_n, v_v from public._online_done(auth.uid(), s.opened_at, now());
  perform public.audit_write('online.shift_close', 'user', auth.uid()::text, jsonb_build_object('orders', v_n, 'value_minor', v_v));
  return jsonb_build_object('orders', v_n, 'value_minor', v_v, 'opened_at', s.opened_at, 'closed_at', now());
end $$;
revoke all on function public.online_shift_close() from public, anon;
grant execute on function public.online_shift_close() to authenticated;

create or replace function public.online_commission_set(p_user uuid, p_pct numeric) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.require_permission('online.manage');
  if not exists (select 1 from public.user_roles where user_id = p_user) then raise exception 'NOT_FOUND'; end if;
  if p_pct is not null and (p_pct < 0 or p_pct > 50) then raise exception 'INVALID_INPUT'; end if;
  insert into public.online_plan (user_id, commission_pct, updated_by) values (p_user, p_pct, auth.uid())
  on conflict (user_id) do update set commission_pct = excluded.commission_pct, updated_by = auth.uid(), updated_at = now();
  perform public.audit_write('online.commission', 'user', p_user::text, jsonb_build_object('pct', p_pct));
end $$;
revoke all on function public.online_commission_set(uuid, numeric) from public, anon;
grant execute on function public.online_commission_set(uuid, numeric) to authenticated;

-- the employee's own status now also carries the commission and the shift
create or replace function public.my_online_status() returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_from timestamptz; v_to timestamptz; v_day timestamptz; v_p public.online_plan%rowtype; v_n integer; v_v bigint; v_nd integer; v_vd bigint; v_sh timestamptz;
begin
  perform public.require_permission('online.mine');
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
    'commission_pct', v_p.commission_pct,
    'commission_minor', case when v_p.commission_pct is null then null else round(v_v * v_p.commission_pct / 100) end,
    'commission_today_minor', case when v_p.commission_pct is null then null else round(v_vd * v_p.commission_pct / 100) end,
    'shift_opened_at', v_sh, 'at', now());
end $$;
revoke all on function public.my_online_status() from public, anon;
grant execute on function public.my_online_status() to authenticated;

-- owner overview now also shows the commission percentage
create or replace function public.online_overview() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_from timestamptz; v_to timestamptz; v_day timestamptz;
begin
  perform public.require_permission('online.manage');
  select m_from, m_to, m_day into v_from, v_to, v_day from public._cairo_month(null);
  return jsonb_build_object('employees', coalesce((select jsonb_agg(x order by x ->> 'name') from (
    select jsonb_build_object('user_id', u.uid, 'name', coalesce(tm.login_display, pr.full_name, '—'),
           'daily_hours', p.daily_hours, 'orders_target', p.orders_monthly, 'value_target_minor', p.value_monthly_minor, 'commission_pct', p.commission_pct,
           'orders_done', d.n, 'value_done_minor', d.value_minor) as x
    from (select ur.user_id as uid from public.user_roles ur where ur.role in ('sales', 'manager')
          union select user_id from public.online_plan) u
    left join public.online_plan p on p.user_id = u.uid
    left join public.team_members tm on tm.user_id = u.uid
    left join public.profiles pr on pr.id = u.uid
    left join lateral public._online_done(u.uid, v_from, v_to) d on true) q), '[]'::jsonb));
end $$;
revoke all on function public.online_overview() from public, anon;
grant execute on function public.online_overview() to authenticated;

-- the accountant's "Online" page: one month
create or replace function public.online_report(p_year int, p_month int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_from timestamptz; v_to timestamptz;
begin
  perform public.require_permission('online.review');
  if p_year is null or p_month is null or p_year not between 2024 and 2100 or p_month not between 1 and 12 then raise exception 'INVALID_INPUT'; end if;
  v_from := make_timestamptz(p_year, p_month, 1, 0, 0, 0, 'Africa/Cairo');
  v_to := v_from + interval '1 month';
  perform public.audit_write('online.report', 'system', 'online', jsonb_build_object('year', p_year, 'month', p_month));
  return (with ord as (
      select o.id, o.reference, o.created_at, o.status::text st, o.fulfillment::text ful, o.payment_method::text pm, o.payment_status::text ps, o.total_minor,
             o.branch_id, o.branch_confirmed, public._online_confirmer(o.id) as conf,
             (select min(h.created_at) from public.order_status_history h where h.order_id = o.id and h.to_status = 'delivered') as delivered_at
        from public.orders o where o.created_at >= v_from and o.created_at < v_to and o.status <> 'cancelled'),
    emp as (
      select c.conf as uid, coalesce(p.commission_pct, 0) pct,
             count(*) filter (where true) confirmed_n,
             count(*) filter (where c.st = 'delivered' and c.ps <> 'refunded') delivered_n,
             coalesce(sum(c.total_minor) filter (where c.st = 'delivered' and c.ps <> 'refunded'), 0) delivered_minor
        from ord c left join public.online_plan p on p.user_id = c.conf where c.conf is not null group by c.conf, p.commission_pct)
    select jsonb_build_object('year', p_year, 'month', p_month,
      'employees', coalesce((select jsonb_agg(jsonb_build_object('user_id', e.uid, 'name', public._ops_name(e.uid), 'confirmed_n', e.confirmed_n, 'delivered_n', e.delivered_n,
                    'delivered_minor', e.delivered_minor, 'commission_pct', e.pct, 'commission_minor', round(e.delivered_minor * e.pct / 100),
                    'shifts_count', (select count(*) from public.online_shifts s where s.user_id = e.uid and s.opened_at >= v_from and s.opened_at < v_to),
                    'shift_hours', (select coalesce(round((sum(extract(epoch from (coalesce(s.closed_at, now()) - s.opened_at))) / 3600)::numeric, 1), 0) from public.online_shifts s where s.user_id = e.uid and s.opened_at >= v_from and s.opened_at < v_to))
                    order by e.delivered_minor desc) from emp e), '[]'::jsonb),
      'channels', coalesce((select jsonb_agg(jsonb_build_object('fulfillment', x.ful, 'payment_method', x.pm, 'n', x.n, 'total_minor', x.t) order by x.ful, x.pm)
                    from (select ful, pm, count(*) n, coalesce(sum(total_minor), 0) t from ord where st = 'delivered' group by ful, pm) x), '[]'::jsonb),
      'orders', coalesce((select jsonb_agg(jsonb_build_object('reference', c.reference, 'at', c.created_at, 'delivered_at', c.delivered_at, 'status', c.st,
                    'fulfillment', c.ful, 'branch', coalesce(b.name_ar, case when c.ful = 'pickup' then null end), 'branch_confirmed', c.branch_confirmed,
                    'payment_method', c.pm, 'payment_status', c.ps, 'total_minor', c.total_minor, 'employee', case when c.conf is null then null else public._ops_name(c.conf) end,
                    'commission_minor', case when c.st = 'delivered' and c.ps <> 'refunded' and c.conf is not null then round(c.total_minor * coalesce((select pp.commission_pct from public.online_plan pp where pp.user_id = c.conf), 0) / 100) else 0 end)
                    order by c.created_at)
                    from (select * from ord order by created_at limit 5000) c left join public.branches b on b.id = c.branch_id), '[]'::jsonb))
    );
end $$;
revoke all on function public.online_report(int, int) from public, anon;
grant execute on function public.online_report(int, int) to authenticated;
