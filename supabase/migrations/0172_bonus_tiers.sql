-- 0172: daily target bonus in tiers — 100% / 120% / 150% of the daily target, each with a bigger bonus set by the owner.
-- A day pays the highest tier reached (not the sum), so selling past the target keeps paying.

alter table public.user_targets
  add column if not exists bonus_120_minor bigint not null default 0,
  add column if not exists bonus_150_minor bigint not null default 0;

create or replace function public._daily_bonus(p_user uuid, p_from timestamptz, p_to timestamptz)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare t record; d date; d_from date; d_to date; d0 timestamptz; d1 timestamptz; dim int; tgt bigint; got bigint; net bigint; onl bigint;
        n int := 0; n100 int := 0; n120 int := 0; n150 int := 0; v bigint := 0;
begin
  select monthly_minor as m, daily_bonus_minor as b, bonus_120_minor as b2, bonus_150_minor as b3 into t from public.user_targets where user_id = p_user;
  if t.m is null or t.m <= 0 or greatest(t.b, t.b2, t.b3) <= 0 or p_from is null or p_to is null or p_to <= p_from then
    return jsonb_build_object('days', 0, 'minor', 0, 'days_100', 0, 'days_120', 0, 'days_150', 0);
  end if;
  d_from := (p_from at time zone 'Africa/Cairo')::date;
  d_to := (least(p_to, now()) at time zone 'Africa/Cairo')::date;
  if d_to - d_from > 400 then d_from := d_to - 400; end if;
  for d in select generate_series(d_from, d_to, interval '1 day')::date loop
    d0 := d::timestamp at time zone 'Africa/Cairo';
    d1 := (d + 1)::timestamp at time zone 'Africa/Cairo';
    continue when d0 < p_from or d0 >= p_to or d0 > now();
    dim := extract(day from (date_trunc('month', d::timestamp) + interval '1 month - 1 day'))::int;
    tgt := ceil(t.m::numeric / dim)::bigint;
    select coalesce(sum(total_minor - refunded_minor), 0) into net from public.pos_sales where coalesce(seller_id, cashier_id) = p_user and created_at >= d0 and created_at < d1;
    select value_minor into onl from public._online_done(p_user, d0, d1);
    got := net + coalesce(onl, 0);
    if t.b3 > 0 and got >= ceil(tgt * 1.5) then v := v + t.b3; n150 := n150 + 1; n := n + 1;
    elsif t.b2 > 0 and got >= ceil(tgt * 1.2) then v := v + t.b2; n120 := n120 + 1; n := n + 1;
    elsif t.b > 0 and got >= tgt then v := v + t.b; n100 := n100 + 1; n := n + 1;
    end if;
  end loop;
  return jsonb_build_object('days', n, 'minor', v, 'days_100', n100, 'days_120', n120, 'days_150', n150);
end $$;

drop function if exists public.targets_set_daily_bonus(uuid, bigint);
create function public.targets_set_daily_bonus(p_user uuid, p_bonus_minor bigint, p_bonus_120 bigint default null, p_bonus_150 bigint default null)
returns void language plpgsql security definer set search_path to 'public' as $$
declare v bigint := coalesce(p_bonus_minor, 0); v2 bigint; v3 bigint;
begin
  perform public.require_permission('targets.manage');
  if not exists (select 1 from public.user_targets where user_id = p_user) then raise exception 'TARGET_REQUIRED'; end if;
  select coalesce(p_bonus_120, bonus_120_minor), coalesce(p_bonus_150, bonus_150_minor) into v2, v3 from public.user_targets where user_id = p_user;
  if v < 0 or v2 < 0 or v3 < 0 or greatest(v, v2, v3) > 10000000 then raise exception 'INVALID_INPUT'; end if;
  -- a higher tier never pays less than a lower one (0 = tier not used)
  if (v2 > 0 and v2 < v) or (v3 > 0 and v3 < greatest(v, v2)) then raise exception 'TIERS_ORDER'; end if;
  update public.user_targets set daily_bonus_minor = v, bonus_120_minor = v2, bonus_150_minor = v3, updated_by = auth.uid(), updated_at = now() where user_id = p_user;
  perform public.audit_write('target.daily_bonus', 'user', p_user::text, jsonb_build_object('daily_bonus_minor', v, 'bonus_120_minor', v2, 'bonus_150_minor', v3));
end $$;
revoke all on function public.targets_set_daily_bonus(uuid, bigint, bigint, bigint) from public, anon;
grant execute on function public.targets_set_daily_bonus(uuid, bigint, bigint, bigint) to authenticated;

create or replace function pg_temp.pf(p_fn regprocedure, p_old text, p_new text) returns void language plpgsql as $$
declare d text;
begin
  d := pg_get_functiondef(p_fn);
  if position(p_old in d) = 0 then raise exception 'patch miss [%] in %', p_old, p_fn; end if;
  execute replace(d, p_old, p_new);
end $$;

select pg_temp.pf('public.my_target_status(uuid)'::regprocedure,
  $q$'daily_bonus_minor', coalesce((select daily_bonus_minor from public.user_targets where user_id = v_u), 0),$q$,
  $q$'daily_bonus_minor', coalesce((select daily_bonus_minor from public.user_targets where user_id = v_u), 0),
    'bonus_120_minor', coalesce((select bonus_120_minor from public.user_targets where user_id = v_u), 0),
    'bonus_150_minor', coalesce((select bonus_150_minor from public.user_targets where user_id = v_u), 0),$q$);
select pg_temp.pf('public.my_challenge_today(uuid)'::regprocedure,
  $q$'daily_bonus_minor', coalesce((v_st ->> 'daily_bonus_minor')::bigint, 0),$q$,
  $q$'daily_bonus_minor', coalesce((v_st ->> 'daily_bonus_minor')::bigint, 0),
    'bonus_120_minor', coalesce((v_st ->> 'bonus_120_minor')::bigint, 0),
    'bonus_150_minor', coalesce((v_st ->> 'bonus_150_minor')::bigint, 0),$q$);
select pg_temp.pf('public.targets_overview(date)'::regprocedure,
  $q$'daily_bonus_minor', case when v_money then coalesce(ut.daily_bonus_minor, 0) else null end)$q$,
  $q$'daily_bonus_minor', case when v_money then coalesce(ut.daily_bonus_minor, 0) else null end,
    'bonus_120_minor', case when v_money then coalesce(ut.bonus_120_minor, 0) else null end,
    'bonus_150_minor', case when v_money then coalesce(ut.bonus_150_minor, 0) else null end)$q$);
