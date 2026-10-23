-- 0045: the owner edits levels (name, points needed, planned gift) and adjusts any customer's points.
-- Owner only (permissions.manage). Every change is written to the audit log.
--   owner_loyalty_set_level(sort, name_ar, name_en, min_points, plan_ar, plan_en)
--   owner_loyalty_adjust_points(user, delta, note)      + or - points, never below 0
--   owner_loyalty_customers(q)                          search any account (name or email); empty q = top 50

create or replace function public.owner_loyalty_set_level(p_sort int, p_name_ar text, p_name_en text, p_min_points int, p_plan_ar text, p_plan_en text)
returns void language plpgsql security definer set search_path = public as $$
declare v_prev int; v_next int; v_old public.loyalty_levels%rowtype; r record;
begin
  perform public.require_permission('permissions.manage');
  select * into v_old from public.loyalty_levels where sort = p_sort;
  if not found then raise exception 'NOT_FOUND'; end if;
  if nullif(trim(coalesce(p_name_ar, '')), '') is null or length(p_name_ar) > 40 or length(coalesce(p_name_en, '')) > 40
     or length(coalesce(p_plan_ar, '')) > 120 or length(coalesce(p_plan_en, '')) > 120 then
    raise exception 'INVALID_INPUT';
  end if;
  if p_min_points is null or p_min_points < 0 or p_min_points > 10000000 or (p_sort = 1 and p_min_points <> 0) then
    raise exception 'INVALID_POINTS';
  end if;
  -- thresholds must stay in order: each level needs more points than the one before it
  select max(min_points) into v_prev from public.loyalty_levels where sort < p_sort;
  select min(min_points) into v_next from public.loyalty_levels where sort > p_sort;
  if (v_prev is not null and p_min_points <= v_prev) or (v_next is not null and p_min_points >= v_next) then
    raise exception 'LEVEL_ORDER';
  end if;
  update public.loyalty_levels
     set name_ar = trim(p_name_ar), name_en = coalesce(nullif(trim(coalesce(p_name_en, '')), ''), trim(p_name_ar)),
         min_points = p_min_points, plan_ar = nullif(trim(coalesce(p_plan_ar, '')), ''), plan_en = nullif(trim(coalesce(p_plan_en, '')), '')
   where sort = p_sort;
  perform public.audit_write('loyalty.level', 'loyalty_level', p_sort::text,
    jsonb_build_object('name', p_name_ar, 'min_points', p_min_points, 'was_min_points', v_old.min_points, 'plan', p_plan_ar));
  -- a lowered threshold may already be reached: create those awards now (the owner gets the usual notice)
  if p_sort > 1 and p_min_points < v_old.min_points then
    for r in select user_id from public.loyalty_profiles where points >= p_min_points loop
      perform public._loy_check_awards(r.user_id);
    end loop;
  end if;
end $$;
revoke all on function public.owner_loyalty_set_level(int, text, text, int, text, text) from public, anon;
grant execute on function public.owner_loyalty_set_level(int, text, text, int, text, text) to authenticated;

drop function if exists public.owner_loyalty_adjust_points(uuid, int, text);
create or replace function public.owner_loyalty_adjust_points(p_user uuid, p_delta int, p_note text default null, p_notify boolean default true)
returns int language plpgsql security definer set search_path = public as $$
declare v_before int; v_after int;
begin
  perform public.require_permission('permissions.manage');
  if p_delta is null or p_delta = 0 or abs(p_delta) > 1000000 then raise exception 'INVALID_INPUT'; end if;
  if not exists (select 1 from public.profiles where id = p_user) then raise exception 'NOT_FOUND'; end if;
  perform public._loy_ensure(p_user);
  select points into v_before from public.loyalty_profiles where user_id = p_user;
  -- points only: the box progress is not touched. Positive changes may unlock levels (and notify the owner).
  perform public._loy_grant(p_user, 'admin_adjust', gen_random_uuid()::text, p_delta, 0);
  select points into v_after from public.loyalty_profiles where user_id = p_user;
  perform public.audit_write('loyalty.adjust', 'loyalty_profile', p_user::text,
    jsonb_build_object('delta', p_delta, 'before', v_before, 'after', v_after, 'note', left(coalesce(p_note, ''), 200)));
  -- the customer hears about it straight away and sees the new balance when the rewards page opens
  if p_notify then
    perform public.notify_user(p_user, case when p_delta > 0 then 'اتضافلك نقاط 🎉' else 'اتعدّل رصيد نقاطك' end,
      case when p_delta > 0 then 'Points added 🎉' else 'Your points were updated' end,
      case when p_delta > 0 then 'اتضاف ' || p_delta || ' نقطة لرصيدك. رصيدك دلوقتي ' || v_after || ' نقطة.'
           else 'اتعدّل رصيدك. رصيدك دلوقتي ' || v_after || ' نقطة.' end,
      case when p_delta > 0 then p_delta || ' points were added. Your balance is now ' || v_after || '.'
           else 'Your balance was updated. It is now ' || v_after || ' points.' end,
      'promo', null, null, '/loyalty');
  end if;
  return v_after;
end $$;
revoke all on function public.owner_loyalty_adjust_points(uuid, int, text, boolean) from public, anon;
grant execute on function public.owner_loyalty_adjust_points(uuid, int, text, boolean) to authenticated;

create or replace function public.owner_loyalty_customers(p_q text default null)
returns jsonb language plpgsql security definer stable set search_path = public as $$
declare v_q text := lower(trim(coalesce(p_q, '')));
begin
  perform public.require_permission('gifts.manage');
  if length(v_q) > 60 then raise exception 'INVALID_INPUT'; end if;
  return (select coalesce(jsonb_agg(x order by (x->>'points')::int desc), '[]'::jsonb) from (
    select jsonb_build_object('user_id', pr.id, 'customer', coalesce(nullif(pr.full_name, ''), pr.email), 'email', pr.email,
             'points', coalesce(lp.points, 0),
             'level_ar', (select name_ar from public.loyalty_levels l where l.min_points <= coalesce(lp.points, 0) order by l.sort desc limit 1)) as x
      from public.profiles pr left join public.loyalty_profiles lp on lp.user_id = pr.id
     where (v_q = '' and lp.user_id is not null)
        or (v_q <> '' and (position(v_q in lower(coalesce(pr.full_name, ''))) > 0 or position(v_q in lower(coalesce(pr.email, ''))) > 0))
     order by coalesce(lp.points, 0) desc limit 50) s);
end $$;
revoke all on function public.owner_loyalty_customers(text) from public, anon;
grant execute on function public.owner_loyalty_customers(text) to authenticated;
