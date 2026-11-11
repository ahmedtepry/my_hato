-- Daily target bonus: the owner sets, per employee, a bonus (e.g. 10 EGP) that is earned on every day the employee's real net sales
-- (POS after refunds + delivered online orders he confirmed) reach his daily target (monthly target / days of that month).
-- The bonus is added to the commission shown in "My target", the KPI page and the targets page, so every screen shows the same number.
alter table public.user_targets add column if not exists daily_bonus_minor bigint not null default 0 check (daily_bonus_minor >= 0 and daily_bonus_minor <= 10000000);

create or replace function public._daily_bonus(p_user uuid, p_from timestamptz, p_to timestamptz) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare t record; d date; d_from date; d_to date; d0 timestamptz; d1 timestamptz; dim int; tgt bigint; net bigint; onl bigint; n int := 0;
begin
  select monthly_minor as m, daily_bonus_minor as b into t from public.user_targets where user_id = p_user;
  if t.m is null or t.m <= 0 or t.b <= 0 or p_from is null or p_to is null or p_to <= p_from then return jsonb_build_object('days', 0, 'minor', 0); end if;
  d_from := (p_from at time zone 'Africa/Cairo')::date;
  d_to := (least(p_to, now()) at time zone 'Africa/Cairo')::date;
  if d_to - d_from > 400 then d_from := d_to - 400; end if;
  for d in select generate_series(d_from, d_to, interval '1 day')::date loop
    d0 := d::timestamp at time zone 'Africa/Cairo';
    d1 := (d + 1)::timestamp at time zone 'Africa/Cairo';
    continue when d0 < p_from or d0 >= p_to or d0 > now();
    dim := extract(day from (date_trunc('month', d::timestamp) + interval '1 month - 1 day'))::int;
    tgt := ceil(t.m::numeric / dim)::bigint;
    select coalesce(sum(total_minor - refunded_minor), 0) into net from public.pos_sales where cashier_id = p_user and created_at >= d0 and created_at < d1;
    select value_minor into onl from public._online_done(p_user, d0, d1);
    if net + coalesce(onl, 0) >= tgt then n := n + 1; end if;
  end loop;
  return jsonb_build_object('days', n, 'minor', n * t.b);
end $$;
revoke all on function public._daily_bonus(uuid, timestamptz, timestamptz) from public, anon, authenticated;

create or replace function public.targets_set_daily_bonus(p_user uuid, p_bonus_minor bigint) returns void
language plpgsql security definer set search_path = public as $$
declare v bigint := coalesce(p_bonus_minor, 0);
begin
  perform public.require_permission('targets.manage');
  if v < 0 or v > 10000000 then raise exception 'INVALID_INPUT'; end if;
  if not exists (select 1 from public.user_targets where user_id = p_user) then raise exception 'TARGET_REQUIRED'; end if;
  update public.user_targets set daily_bonus_minor = v, updated_by = auth.uid(), updated_at = now() where user_id = p_user;
  perform public.audit_write('target.daily_bonus', 'user', p_user::text, jsonb_build_object('daily_bonus_minor', v));
end $$;
revoke all on function public.targets_set_daily_bonus(uuid, bigint) from public, anon;
grant execute on function public.targets_set_daily_bonus(uuid, bigint) to authenticated;

do $$
declare d text;
begin
  -- my_target_status
  d := pg_get_functiondef('public.my_target_status()'::regprocedure);
  if position($a$'commission_month_minor', v_com + v_onc, 'commission_today_minor', v_com_d + v_oncd,$a$ in d) = 0 then raise exception 'status pattern'; end if;
  d := replace(d, $a$'commission_month_minor', v_com + v_onc, 'commission_today_minor', v_com_d + v_oncd,$a$,
    $b$'commission_month_minor', v_com + v_onc + coalesce((public._daily_bonus(auth.uid(), v_from, v_to) ->> 'minor')::bigint, 0),
    'commission_today_minor', v_com_d + v_oncd + coalesce((public._daily_bonus(auth.uid(), v_day, v_to) ->> 'minor')::bigint, 0),
    'bonus_today_minor', coalesce((public._daily_bonus(auth.uid(), v_day, v_to) ->> 'minor')::bigint, 0),
    'bonus_month_minor', coalesce((public._daily_bonus(auth.uid(), v_from, v_to) ->> 'minor')::bigint, 0),
    'bonus_days', coalesce((public._daily_bonus(auth.uid(), v_from, v_to) ->> 'days')::int, 0),
    'daily_bonus_minor', coalesce((select daily_bonus_minor from public.user_targets where user_id = auth.uid()), 0),$b$);
  execute d;

  -- kpi_employees (no branch filter: the bonus belongs to the person, not to a branch)
  d := pg_get_functiondef('public.kpi_employees(timestamptz,timestamptz,uuid)'::regprocedure);
  if position($a$'commission_minor', coalesce(c.com, 0) + coalesce(oc.com, 0),$a$ in d) = 0 then raise exception 'kpi pattern'; end if;
  d := replace(d, $a$'commission_minor', coalesce(c.com, 0) + coalesce(oc.com, 0),$a$,
    $b$'commission_minor', coalesce(c.com, 0) + coalesce(oc.com, 0) + case when p_branch is null then coalesce((public._daily_bonus(u.uid, p_from, p_to) ->> 'minor')::bigint, 0) else 0 end,$b$);
  execute d;

  -- targets_overview
  d := pg_get_functiondef('public.targets_overview(date)'::regprocedure);
  if position($a$'commission_minor', case when v_money then coalesce(c.com, 0) else null end) as x$a$ in d) = 0 then raise exception 'overview pattern'; end if;
  d := replace(d, $a$'commission_minor', case when v_money then coalesce(c.com, 0) else null end) as x$a$,
    $b$'commission_minor', case when v_money then coalesce(c.com, 0) + coalesce((public._daily_bonus(u.uid, v_from, v_to) ->> 'minor')::bigint, 0) else null end,
             'daily_bonus_minor', case when v_money then coalesce(ut.daily_bonus_minor, 0) else null end) as x$b$);
  execute d;

  -- my_challenge_today
  d := pg_get_functiondef('public.my_challenge_today()'::regprocedure);
  if position($a$'products', v_prods);$a$ in d) = 0 then raise exception 'challenge pattern'; end if;
  d := replace(d, $a$'products', v_prods);$a$,
    $b$'daily_bonus_minor', coalesce((v_st ->> 'daily_bonus_minor')::bigint, 0),
    'bonus_today_minor', coalesce((v_st ->> 'bonus_today_minor')::bigint, 0),
    'bonus_days', coalesce((v_st ->> 'bonus_days')::int, 0),
    'products', v_prods);$b$);
  execute d;
end $$;
