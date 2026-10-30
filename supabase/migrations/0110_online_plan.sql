-- 0110: online employees: the owner sets each person's daily shift hours and monthly targets (orders handled and their value).
-- "Handled" = orders the person moved to delivered this month. Notifications arrive at 50 / 75 / 100 percent.
insert into public.permission_catalog (permission, grp, name_ar, name_en, desc_ar, desc_en, sensitive, inert, sort) values
 ('online.manage', 'extras', 'يحدد ساعات وتارجت موظفي الأونلاين', 'Set online employees hours and targets',
  'يحدد عدد ساعات الشيفت اليومي وتارجت الأوردرات وقيمتها لكل موظف أونلاين', 'Sets each online employee daily shift hours and the orders and value targets', true, false, 42),
 ('online.mine', 'orders', 'يشوف تارجته وساعاته (أونلاين)', 'See his own online target and hours',
  'يشوف وصل لكام من تارجت الأوردرات وعدّى كام ساعة من شيفته', 'Sees how far he is from the orders target and how many shift hours passed', false, false, 62)
on conflict (permission) do update set name_ar = excluded.name_ar, name_en = excluded.name_en, desc_ar = excluded.desc_ar, desc_en = excluded.desc_en;
insert into public.role_permissions (role, permission) values ('owner', 'online.manage'), ('owner', 'online.mine'), ('manager', 'online.mine'), ('sales', 'online.mine') on conflict do nothing;

create table if not exists public.online_plan (
  user_id uuid primary key references auth.users (id) on delete cascade,
  daily_hours numeric(4, 1) check (daily_hours is null or (daily_hours > 0 and daily_hours <= 24)),
  orders_monthly integer check (orders_monthly is null or orders_monthly >= 0),
  value_monthly_minor bigint check (value_monthly_minor is null or value_monthly_minor >= 0),
  updated_by uuid references auth.users (id) on delete set null,
  updated_at timestamptz not null default now()
);
alter table public.online_plan enable row level security;
revoke all on public.online_plan from anon, authenticated;

create table if not exists public.online_alerts (
  user_id uuid not null references auth.users (id) on delete cascade,
  month date not null,
  level integer not null,
  created_at timestamptz not null default now(),
  primary key (user_id, month, level)
);
alter table public.online_alerts enable row level security;
revoke all on public.online_alerts from anon, authenticated;

-- what one person handled in a month: orders moved to delivered by him, and their total value
create or replace function public._online_done(p_user uuid, p_from timestamptz, p_to timestamptz, out n integer, out value_minor bigint)
language sql stable security definer set search_path = public as $$
  select count(*)::integer, coalesce(sum(o.total_minor), 0)::bigint
  from public.orders o
  where o.id in (select h.order_id from public.order_status_history h
                  where h.changed_by = p_user and h.to_status = 'delivered' and h.created_at >= p_from and h.created_at < p_to)
$$;
revoke all on function public._online_done(uuid, timestamptz, timestamptz) from public, anon, authenticated;

-- notify at 50 / 75 / 100 percent (the better of the two measures), once per level per month. Checked whenever the employee's robot reads his status.
create or replace function public._online_check_alerts(p_user uuid, p_n integer, p_v bigint) returns void
language plpgsql security definer set search_path = public as $$
declare v_p public.online_plan%rowtype; v_pct numeric; v_month date; v_l integer; v_from timestamptz; v_to timestamptz; v_day timestamptz;
begin
  select * into v_p from public.online_plan where user_id = p_user;
  if not found or (coalesce(v_p.orders_monthly, 0) = 0 and coalesce(v_p.value_monthly_minor, 0) = 0) then return; end if;
  select m_from, m_to, m_day into v_from, v_to, v_day from public._cairo_month(null);
  v_pct := greatest(case when coalesce(v_p.orders_monthly, 0) > 0 then p_n * 100.0 / v_p.orders_monthly else 0 end,
                    case when coalesce(v_p.value_monthly_minor, 0) > 0 then p_v * 100.0 / v_p.value_monthly_minor else 0 end);
  v_month := (v_from at time zone 'Africa/Cairo')::date;
  foreach v_l in array array[50, 75, 100] loop
    if v_pct >= v_l and not exists (select 1 from public.online_alerts where user_id = p_user and month = v_month and level = v_l) then
      insert into public.online_alerts (user_id, month, level) values (p_user, v_month, v_l);
      perform public.notify_user(p_user,
        case when v_l = 100 then 'حققت التارجت!' else 'وصلت ' || v_l || '% من التارجت' end,
        case when v_l = 100 then 'Target reached!' else 'You reached ' || v_l || '% of your target' end,
        'جهّزت ' || p_n || ' أوردر هذا الشهر', 'You handled ' || p_n || ' orders this month', 'system', null, null, null);
    end if;
  end loop;
end $$;
revoke all on function public._online_check_alerts(uuid, integer, bigint) from public, anon, authenticated;

-- the employee: his own hours and progress
create or replace function public.my_online_status() returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_from timestamptz; v_to timestamptz; v_day timestamptz; v_p public.online_plan%rowtype; v_n integer; v_v bigint; v_nd integer; v_vd bigint;
begin
  perform public.require_permission('online.mine');
  select m_from, m_to, m_day into v_from, v_to, v_day from public._cairo_month(null);
  select * into v_p from public.online_plan where user_id = auth.uid();
  select n, value_minor into v_n, v_v from public._online_done(auth.uid(), v_from, v_to);
  select n, value_minor into v_nd, v_vd from public._online_done(auth.uid(), v_day, v_to);
  perform public._online_check_alerts(auth.uid(), v_n, v_v);
  return jsonb_build_object('daily_hours', v_p.daily_hours, 'orders_target', v_p.orders_monthly, 'value_target_minor', v_p.value_monthly_minor,
    'orders_done', v_n, 'value_done_minor', v_v, 'orders_today', v_nd, 'value_today_minor', v_vd,
    'orders_pct', case when coalesce(v_p.orders_monthly, 0) > 0 then round(v_n * 100.0 / v_p.orders_monthly, 1) end,
    'value_pct', case when coalesce(v_p.value_monthly_minor, 0) > 0 then round(v_v * 100.0 / v_p.value_monthly_minor, 1) end,
    'at', now());
end $$;
revoke all on function public.my_online_status() from public, anon;
grant execute on function public.my_online_status() to authenticated;

-- the owner: everyone who handles orders, with plan and progress
create or replace function public.online_overview() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_from timestamptz; v_to timestamptz; v_day timestamptz;
begin
  perform public.require_permission('online.manage');
  select m_from, m_to, m_day into v_from, v_to, v_day from public._cairo_month(null);
  return jsonb_build_object('employees', coalesce((select jsonb_agg(x order by x ->> 'name') from (
    select jsonb_build_object('user_id', u.uid, 'name', coalesce(tm.login_display, pr.full_name, '—'),
           'daily_hours', p.daily_hours, 'orders_target', p.orders_monthly, 'value_target_minor', p.value_monthly_minor,
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

create or replace function public.online_plan_set(p_user uuid, p_daily_hours numeric, p_orders integer, p_value_minor bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.require_permission('online.manage');
  if not exists (select 1 from public.user_roles where user_id = p_user) then raise exception 'NOT_FOUND'; end if;
  if (p_daily_hours is not null and (p_daily_hours <= 0 or p_daily_hours > 24)) or coalesce(p_orders, 0) < 0 or coalesce(p_value_minor, 0) < 0 or coalesce(p_value_minor, 0) > 100000000000 then
    raise exception 'INVALID_INPUT';
  end if;
  insert into public.online_plan (user_id, daily_hours, orders_monthly, value_monthly_minor, updated_by)
  values (p_user, p_daily_hours, p_orders, p_value_minor, auth.uid())
  on conflict (user_id) do update set daily_hours = excluded.daily_hours, orders_monthly = excluded.orders_monthly,
    value_monthly_minor = excluded.value_monthly_minor, updated_by = auth.uid(), updated_at = now();
  perform public.audit_write('online.plan', 'user', p_user::text, jsonb_build_object('hours', p_daily_hours, 'orders', p_orders, 'value_minor', p_value_minor));
end $$;
revoke all on function public.online_plan_set(uuid, numeric, integer, bigint) from public, anon;
grant execute on function public.online_plan_set(uuid, numeric, integer, bigint) to authenticated;
