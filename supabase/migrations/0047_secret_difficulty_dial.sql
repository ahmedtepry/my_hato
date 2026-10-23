-- 0047: a secret difficulty dial for the owner.
-- One number (loyalty_tuning.multiplier_pct, 100 = normal) scales every point a customer EARNS from now on:
-- missions, orders, reviews, likes and the box reward. Lower = harder, higher = easier.
--   * it applies at the moment points are granted, so a change is live immediately;
--   * old balances are never touched, and reversals take back exactly what was granted;
--   * the owner's manual adjustments are never scaled;
--   * customers cannot read it: the table has no policies. Everything they see (mission points, descriptions, the
--     "+N points" popups, the box reward) already shows the scaled amounts, so what is shown is what is paid.
-- Mission descriptions use {pts} (own points) and {review} (the verified-review points) instead of fixed numbers.

create table if not exists public.loyalty_tuning (
  id int primary key check (id = 1),
  multiplier_pct int not null default 100 check (multiplier_pct between 25 and 300),
  updated_at timestamptz not null default now(),
  updated_by uuid
);
alter table public.loyalty_tuning enable row level security;
revoke all on public.loyalty_tuning from anon, authenticated;
insert into public.loyalty_tuning (id) values (1) on conflict do nothing;

create or replace function public._loy_pct() returns int language sql stable security definer set search_path = public as $$
  select coalesce((select multiplier_pct from public.loyalty_tuning where id = 1), 100) $$;
create or replace function public._loy_scale(p int) returns int language sql stable security definer set search_path = public as $$
  select case when p is null or p <= 0 then p else greatest(round(p * public._loy_pct() / 100.0)::int, 1) end $$;
create or replace function public._loy_text(p_text text, p_points int) returns text language sql stable security definer set search_path = public as $$
  select replace(replace(coalesce(p_text, ''), '{pts}', public._loy_scale(p_points)::text), '{review}',
                 public._loy_scale(coalesce((select points from public.loyalty_missions where key = 'review'), 40))::text) $$;
revoke all on function public._loy_pct(), public._loy_scale(int), public._loy_text(text, int) from public, anon, authenticated;

update public.loyalty_missions set
  desc_ar = 'قيّم منتج اتسلّمك فعلًا واكتب رأيك (١٠ حروف على الأقل) واكسب {pts} نقطة. النقاط بتتضاف تلقائي بعد نشر التقييم.',
  desc_en = 'Review a product you actually received and write your opinion (10+ characters) to earn {pts} points. Points are added automatically once the review is published.'
 where key = 'review';
update public.loyalty_missions set
  desc_ar = 'اكتب رأيك (١٠ حروف على الأقل) في أي منتج واكسب {pts} نقاط، بحد أقصى ٣ تقييمات في الأسبوع. لو المنتج اتسلّمك فعلًا بتكسب {review}.',
  desc_en = 'Write your opinion (10+ characters) on any product and earn {pts} points, up to 3 reviews a week. If you actually received the product you earn {review}.'
 where key = 'review_any';
update public.loyalty_missions set
  desc_ar = 'اعمل لايك على أي تقييم واكسب {pts} نقاط، بحد أقصى ٣ لايكات في اليوم. النقاط بتتضاف تلقائي.',
  desc_en = 'Like any review and earn {pts} points, up to 3 likes a day. Points are added automatically.'
 where key = 'like_review';
update public.loyalty_missions set
  desc_ar = 'دوس على القلب في أي منتج واكسب {pts} نقاط، بحد أقصى ٣ منتجات في اليوم. النقاط بتتضاف تلقائي.',
  desc_en = 'Tap the heart on any product and earn {pts} points, up to 3 products a day. Points are added automatically.'
 where key = 'like_product';

-- the single choke point: every earning is scaled here
create or replace function public._loy_grant(p_user uuid, p_kind text, p_ref text, p_points int, p_vault int)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_n int; v_pts int := p_points; v_vault int := p_vault;
begin
  if p_kind <> 'admin_adjust' then
    v_pts := public._loy_scale(p_points);
    if p_vault > 0 then v_vault := public._loy_scale(p_vault); end if;
  end if;
  insert into public.loyalty_ledger (user_id, kind, ref, points, vault) values (p_user, p_kind, p_ref, v_pts, v_vault)
    on conflict (user_id, kind, ref) do nothing;
  get diagnostics v_n = row_count;
  if v_n = 0 then return false; end if;
  update public.loyalty_profiles set points = greatest(points + v_pts, 0), vault_progress = greatest(vault_progress + v_vault, 0)
   where user_id = p_user;
  if v_pts > 0 then perform public._loy_check_awards(p_user); end if;
  return true;
end $$;
revoke all on function public._loy_grant(uuid, text, text, int, int) from public, anon, authenticated;

-- what the customer is told must be what was paid: read the amount back from the ledger
create or replace function public.loyalty_claim(p_mission text) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := public.require_auth(); m public.loyalty_missions%rowtype; p public.loyalty_profiles%rowtype; v_today date := (now() at time zone public._loy_tz())::date;
        v_ref text; v_paid int;
begin
  perform public._loy_ensure(u);
  select * into p from public.loyalty_profiles where user_id = u for update;      -- serialises this user's requests
  select * into m from public.loyalty_missions where key = p_mission and is_active and kind <> 'review';
  if not found then raise exception 'MISSION_NOT_FOUND'; end if;
  if exists (select 1 from public.loyalty_claims where user_id = u and mission_key = m.key and period_key = public._loy_period(m.repeat)) then
    raise exception 'ALREADY_CLAIMED';
  end if;
  if m.kind = 'checkin' then      -- streak moves only on the real server date
    update public.loyalty_profiles set streak = case when last_checkin = v_today - 1 then streak + 1 else 1 end, last_checkin = v_today where user_id = u;
  end if;
  if not public._loy_cond(u, m.kind, m.repeat) then raise exception 'NOT_ELIGIBLE'; end if;
  insert into public.loyalty_claims (user_id, mission_key, period_key) values (u, m.key, public._loy_period(m.repeat));
  v_ref := m.key || ':' || public._loy_period(m.repeat);
  perform public._loy_grant(u, 'mission', v_ref, m.points, m.points);
  select points into v_paid from public.loyalty_ledger where user_id = u and kind = 'mission' and ref = v_ref;
  return jsonb_build_object('points', coalesce(v_paid, m.points));
end $$;

create or replace function public.loyalty_open_vault() returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := public.require_auth(); p public.loyalty_profiles%rowtype; v_req int := public._loy_num('loyalty_vault_required', 100)::int;
        r public.loyalty_rewards%rowtype; v_ref text := gen_random_uuid()::text; v_paid int;
begin
  perform public._loy_ensure(u);
  select * into p from public.loyalty_profiles where user_id = u for update;      -- a second tap waits here, then sees the lower progress
  if p.vault_progress < v_req then raise exception 'VAULT_NOT_READY'; end if;
  select * into r from public.loyalty_rewards where is_active and (stock is null or stock > 0)
    order by -ln(greatest(random(), 1e-12)) / weight limit 1 for update skip locked;
  if not found then raise exception 'REWARD_UNAVAILABLE'; end if;                 -- progress is kept
  if r.stock is not null then update public.loyalty_rewards set stock = stock - 1 where id = r.id; end if;
  perform public._loy_grant(u, 'vault_reward', v_ref, r.points, -p.vault_progress);   -- the next box starts again from 0%
  select points into v_paid from public.loyalty_ledger where user_id = u and kind = 'vault_reward' and ref = v_ref;
  return jsonb_build_object('points', coalesce(v_paid, r.points));
end $$;

-- like rewards (0046) report the scaled amount
create or replace function public._loy_like_reward(p_user uuid, p_kind text, p_ref text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_pts int; v_cap int := public._loy_num('loyalty_like_daily_cap', 3)::int; v_today int; v_first boolean; v_paid int := 0;
begin
  select points into v_pts from public.loyalty_missions where key = p_kind and is_active;
  if v_pts is null then return jsonb_build_object('points', 0, 'first', false, 'remaining', 0, 'cap', v_cap); end if;
  perform public._loy_ensure(p_user);
  v_first := not exists (select 1 from public.loyalty_ledger where user_id = p_user and kind = p_kind);
  select count(*) into v_today from public.loyalty_ledger where user_id = p_user and kind = p_kind and created_at >= public._loy_period_start('daily');
  if v_today < v_cap and not exists (select 1 from public.loyalty_ledger where user_id = p_user and kind = p_kind and ref = p_ref) then
    if public._loy_grant(p_user, p_kind, p_ref, v_pts, v_pts) then v_paid := public._loy_scale(v_pts); v_today := v_today + 1; end if;
  end if;
  return jsonb_build_object('points', v_paid, 'first', v_first and v_paid > 0, 'remaining', greatest(v_cap - v_today, 0), 'cap', v_cap, 'per', public._loy_scale(v_pts));
end $$;
revoke all on function public._loy_like_reward(uuid, text, text) from public, anon, authenticated;

-- dashboard: mission points and texts are the scaled ones
create or replace function public.loyalty_dashboard() returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := public.require_auth(); p public.loyalty_profiles%rowtype; v_req int := public._loy_num('loyalty_vault_required', 100)::int;
begin
  perform public._loy_ensure(u);
  perform public._loy_sync_orders(u);
  select * into p from public.loyalty_profiles where user_id = u;
  insert into public.loyalty_awards (user_id, level_sort, code)
    select u, l.sort, public._loy_gift_code()
      from public.loyalty_levels l where l.min_points <= p.points and l.sort > 1
    on conflict do nothing;
  return jsonb_build_object(
    'points', p.points, 'streak', p.streak, 'boxes_opened', (select count(*) from public.loyalty_ledger where user_id = u and kind = 'vault_reward'), 'vault_progress', p.vault_progress, 'vault_required', v_req,
    'level', (select jsonb_build_object('sort', l.sort, 'name_ar', l.name_ar, 'name_en', l.name_en) from public.loyalty_levels l where l.min_points <= p.points order by l.sort desc limit 1),
    'awards', (select coalesce(jsonb_agg(jsonb_build_object('level_sort', a.level_sort, 'name_ar', l.name_ar, 'name_en', l.name_en,
                  'code', a.code, 'awarded_at', a.awarded_at, 'new', a.seen_at is null, 'status', a.status, 'delivered', a.status = 'delivered',
                  'status_ar', coalesce(a.status_note_ar, t.ar), 'status_en', coalesce(a.status_note_en, a.status_note_ar, t.en),
                  'prize_ar', case when a.revealed_at is not null then a.prize_ar end, 'prize_en', case when a.revealed_at is not null then a.prize_en end)
                  order by a.level_sort), '[]')
               from public.loyalty_awards a join public.loyalty_levels l on l.sort = a.level_sort
               join public.loyalty_gift_status t on t.key = a.status where a.user_id = u),
    'missions', (select coalesce(jsonb_agg(jsonb_build_object('key', m.key, 'title_ar', m.title_ar, 'title_en', m.title_en,
                     'desc_ar', public._loy_text(m.desc_ar, m.points), 'desc_en', public._loy_text(m.desc_en, m.points), 'icon', m.icon, 'points', public._loy_scale(m.points),
                     'repeat', m.repeat,
                     'kind', m.kind,
                     'status', case when m.kind = 'review' then 'auto' when exists (select 1 from public.loyalty_claims c where c.user_id = u and c.mission_key = m.key and c.period_key = public._loy_period(m.repeat))
                                    then 'claimed' when public._loy_cond(u, m.kind, m.repeat) then 'ready' else 'todo' end) order by m.sort), '[]')
                 from public.loyalty_missions m where m.is_active),
    'history', (select coalesce(jsonb_agg(jsonb_build_object('points', l.points, 'at', l.created_at) order by l.created_at desc), '[]')
                from (select points, created_at from public.loyalty_ledger where user_id = u and kind = 'vault_reward'
                      order by created_at desc limit 30) l));
end $$;

-- ---------------------------------------------------------------- owner only (permissions.manage)
create or replace function public.owner_loyalty_get_tuning() returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_permission('permissions.manage');
  return jsonb_build_object(
    'pct', public._loy_pct(),
    'updated_at', (select updated_at from public.loyalty_tuning where id = 1),
    'order_per_10egp', public._loy_num('loyalty_order_points_per_10egp', 1),
    'missions', (select coalesce(jsonb_agg(jsonb_build_object('title_ar', title_ar, 'title_en', title_en, 'points', points, 'repeat', repeat) order by sort), '[]')
                   from public.loyalty_missions where is_active),
    'rewards', (select coalesce(jsonb_agg(points order by points), '[]') from public.loyalty_rewards where is_active));
end $$;

create or replace function public.owner_loyalty_set_tuning(p_pct int) returns int language plpgsql security definer set search_path = public as $$
declare v_old int;
begin
  perform public.require_permission('permissions.manage');
  if p_pct is null or p_pct < 25 or p_pct > 300 then raise exception 'INVALID_INPUT'; end if;
  v_old := public._loy_pct();
  update public.loyalty_tuning set multiplier_pct = p_pct, updated_at = now(), updated_by = auth.uid() where id = 1;
  perform public.audit_write('loyalty.tuning', 'loyalty_tuning', '1', jsonb_build_object('from', v_old, 'to', p_pct));
  return p_pct;
end $$;
revoke all on function public.owner_loyalty_get_tuning(), public.owner_loyalty_set_tuning(int) from public, anon;
grant execute on function public.owner_loyalty_get_tuning(), public.owner_loyalty_set_tuning(int) to authenticated;
revoke all on function public.loyalty_dashboard(), public.loyalty_claim(text), public.loyalty_open_vault() from public, anon;
grant execute on function public.loyalty_dashboard(), public.loyalty_claim(text), public.loyalty_open_vault() to authenticated;
