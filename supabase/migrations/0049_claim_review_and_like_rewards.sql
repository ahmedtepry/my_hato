-- 0049: review and like rewards are COLLECTED by the customer (a button), not paid automatically.
--   * a published review / a like creates a pending reward; the mission card turns "ready" and the customer taps Claim
--   * claiming pays every pending reward of that mission at once (the secret dial applies at that moment)
--   * the daily / weekly limits count rewards created, claimed or not
--   * a removed review loses its pending reward; a claimed one is taken back as before
--   * the "review a product you bought" mission (40 points) is retired: any published review now earns the normal review reward
--   * orders still pay automatically when delivered

create table if not exists public.loyalty_pending (
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null,
  ref text not null,
  base_points int not null,
  created_at timestamptz not null default now(),
  claimed_at timestamptz,
  primary key (user_id, kind, ref)
);
alter table public.loyalty_pending enable row level security;
revoke all on public.loyalty_pending from anon, authenticated;

update public.loyalty_missions set is_active = false where key = 'review';
update public.loyalty_missions set
  desc_ar = 'اكتب رأيك (١٠ حروف على الأقل) في أي منتج، وبعد ما يتنشر دوس «استلم» واكسب {pts} نقاط. بحد أقصى ٣ تقييمات في الأسبوع.',
  desc_en = 'Write your opinion (10+ characters) on any product. Once it is published, tap Claim to earn {pts} points. Up to 3 reviews a week.'
 where key = 'review_any';
update public.loyalty_missions set
  desc_ar = 'اعمل لايك على أي تقييم، وبعدها دوس «استلم» واكسب {pts} نقاط. بحد أقصى ٣ لايكات في اليوم.',
  desc_en = 'Like any review, then tap Claim to earn {pts} points. Up to 3 likes a day.'
 where key = 'like_review';
update public.loyalty_missions set
  desc_ar = 'دوس على القلب في أي منتج، وبعدها دوس «استلم» واكسب {pts} نقاط. بحد أقصى ٣ منتجات في اليوم.',
  desc_en = 'Tap the heart on any product, then tap Claim to earn {pts} points. Up to 3 products a day.'
 where key = 'like_product';

-- likes: create the pending reward (the customer collects it from the Missions tab)
create or replace function public._loy_like_reward(p_user uuid, p_kind text, p_ref text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_pts int; v_cap int := public._loy_num('loyalty_like_daily_cap', 3)::int; v_today int; v_first boolean; v_new boolean := false; v_n int;
begin
  select points into v_pts from public.loyalty_missions where key = p_kind and is_active;
  if v_pts is null then return jsonb_build_object('points', 0, 'first', false, 'remaining', 0, 'cap', v_cap); end if;
  perform public._loy_ensure(p_user);
  v_first := not exists (select 1 from public.loyalty_pending where user_id = p_user and kind = p_kind)
         and not exists (select 1 from public.loyalty_ledger where user_id = p_user and kind = p_kind);
  select count(*) into v_today from (
    select ref from public.loyalty_pending where user_id = p_user and kind = p_kind and created_at >= public._loy_period_start('daily')
    union
    select ref from public.loyalty_ledger where user_id = p_user and kind = p_kind and created_at >= public._loy_period_start('daily')) x;
  if v_today < v_cap
     and not exists (select 1 from public.loyalty_pending where user_id = p_user and kind = p_kind and ref = p_ref)
     and not exists (select 1 from public.loyalty_ledger where user_id = p_user and kind = p_kind and ref = p_ref) then
    insert into public.loyalty_pending (user_id, kind, ref, base_points) values (p_user, p_kind, p_ref, v_pts) on conflict do nothing;
    get diagnostics v_n = row_count;
    if v_n > 0 then v_new := true; v_today := v_today + 1; end if;
  end if;
  return jsonb_build_object('points', case when v_new then public._loy_scale(v_pts) else 0 end, 'first', v_first and v_new,
                            'remaining', greatest(v_cap - v_today, 0), 'cap', v_cap, 'per', public._loy_scale(v_pts), 'pending', true);
end $$;
revoke all on function public._loy_like_reward(uuid, text, text) from public, anon, authenticated;

-- orders pay at once; reviews only create pending rewards
create or replace function public._loy_sync_orders(p_user uuid) returns void language plpgsql security definer set search_path = public as $$
declare o record; v_ra int; v_pts int; v_left int; v_per numeric := public._loy_num('loyalty_order_points_per_10egp', 1);
begin
  for o in select id, total_minor from public.orders
            where customer_id = p_user and status = 'delivered' and payment_status not in ('refunded','partially_refunded','failed')
              and not exists (select 1 from public.loyalty_ledger l where l.user_id = p_user and l.kind = 'order' and l.ref = orders.id::text)
            order by created_at limit 50 loop
    v_pts := floor(o.total_minor / 1000.0 * v_per)::int;
    perform public._loy_grant(p_user, 'order', o.id::text, v_pts, v_pts);
  end loop;
  for o in select l.ref, l.points, l.vault from public.loyalty_ledger l join public.orders r on r.id::text = l.ref
            where l.user_id = p_user and l.kind = 'order'
              and (r.status = 'cancelled' or r.payment_status in ('refunded','partially_refunded'))
              and not exists (select 1 from public.loyalty_ledger x where x.user_id = p_user and x.kind = 'order_reversal' and x.ref = l.ref) loop
    perform public._loy_grant(p_user, 'order_reversal', o.ref, -o.points, -o.vault);
  end loop;

  select points into v_ra from public.loyalty_missions where key = 'review_any' and is_active;
  if v_ra is not null then
    v_left := public._loy_num('loyalty_review_any_weekly_cap', 3)::int - (select count(*) from (
        select ref from public.loyalty_pending where user_id = p_user and kind = 'review_any' and created_at >= public._loy_period_start('weekly')
        union
        select ref from public.loyalty_ledger where user_id = p_user and kind = 'review_any' and created_at >= public._loy_period_start('weekly')) x)::int;
    for o in select r.id from public.product_reviews r
              where r.user_id = p_user and r.status = 'published' and length(trim(coalesce(r.comment, ''))) >= 10
                and not exists (select 1 from public.loyalty_ledger l where l.user_id = p_user and l.kind in ('review', 'review_any') and l.ref = r.id::text)
                and not exists (select 1 from public.loyalty_pending pd where pd.user_id = p_user and pd.kind = 'review_any' and pd.ref = r.id::text)
              order by r.created_at limit 20 loop
      exit when v_left <= 0;
      insert into public.loyalty_pending (user_id, kind, ref, base_points) values (p_user, 'review_any', o.id::text, v_ra) on conflict do nothing;
      v_left := v_left - 1;
    end loop;
  end if;
  -- a removed review loses a reward nobody collected yet
  delete from public.loyalty_pending pd using public.product_reviews r
   where pd.user_id = p_user and pd.kind = 'review_any' and pd.claimed_at is null and r.id::text = pd.ref and r.status = 'removed';
  -- ... and a collected one is taken back, once
  for o in select l.ref, l.points, l.vault from public.loyalty_ledger l join public.product_reviews r on r.id::text = l.ref
            where l.user_id = p_user and l.kind in ('review', 'review_any') and r.status = 'removed'
              and not exists (select 1 from public.loyalty_ledger x where x.user_id = p_user and x.kind = 'review_reversal' and x.ref = l.ref) loop
    perform public._loy_grant(p_user, 'review_reversal', o.ref, -o.points, -o.vault);
  end loop;
end $$;
revoke all on function public._loy_sync_orders(uuid) from public, anon, authenticated;

-- claim: daily/weekly missions as before; review and like missions collect everything pending
create or replace function public.loyalty_claim(p_mission text) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := public.require_auth(); m public.loyalty_missions%rowtype; p public.loyalty_profiles%rowtype; v_today date := (now() at time zone public._loy_tz())::date;
        v_ref text; v_paid int; v_total int := 0; v_n int := 0; r record;
begin
  perform public._loy_ensure(u);
  select * into p from public.loyalty_profiles where user_id = u for update;      -- serialises this user's requests
  select * into m from public.loyalty_missions where key = p_mission and is_active;
  if not found then raise exception 'MISSION_NOT_FOUND'; end if;
  if m.kind = 'review' then
    for r in select ref, base_points from public.loyalty_pending where user_id = u and kind = m.key and claimed_at is null order by created_at for update loop
      if public._loy_grant(u, m.key, r.ref, r.base_points, r.base_points) then
        select points into v_paid from public.loyalty_ledger where user_id = u and kind = m.key and ref = r.ref;
        v_total := v_total + coalesce(v_paid, 0); v_n := v_n + 1;
      end if;
      update public.loyalty_pending set claimed_at = now() where user_id = u and kind = m.key and ref = r.ref;
    end loop;
    if v_n = 0 then raise exception 'NOT_ELIGIBLE'; end if;
    return jsonb_build_object('points', v_total, 'count', v_n);
  end if;
  if exists (select 1 from public.loyalty_claims where user_id = u and mission_key = m.key and period_key = public._loy_period(m.repeat)) then
    raise exception 'ALREADY_CLAIMED';
  end if;
  if m.kind = 'checkin' then
    update public.loyalty_profiles set streak = case when last_checkin = v_today - 1 then streak + 1 else 1 end, last_checkin = v_today where user_id = u;
  end if;
  if not public._loy_cond(u, m.kind, m.repeat) then raise exception 'NOT_ELIGIBLE'; end if;
  insert into public.loyalty_claims (user_id, mission_key, period_key) values (u, m.key, public._loy_period(m.repeat));
  v_ref := m.key || ':' || public._loy_period(m.repeat);
  perform public._loy_grant(u, 'mission', v_ref, m.points, m.points);
  select points into v_paid from public.loyalty_ledger where user_id = u and kind = 'mission' and ref = v_ref;
  return jsonb_build_object('points', coalesce(v_paid, m.points));
end $$;
revoke all on function public.loyalty_claim(text) from public, anon;
grant execute on function public.loyalty_claim(text) to authenticated;

-- dashboard: review / like missions show "ready" (with a count) while something is waiting to be collected
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
    -- the journey: names appear only for the levels already reached; the next ones stay hidden (no names, no points)
    'levels', (select coalesce(jsonb_agg(jsonb_build_object('sort', l.sort,
                  'state', case when l.min_points > p.points then 'locked'
                                when l.sort = (select max(x.sort) from public.loyalty_levels x where x.min_points <= p.points) then 'current' else 'passed' end,
                  'name_ar', case when l.min_points <= p.points then l.name_ar end,
                  'name_en', case when l.min_points <= p.points then l.name_en end) order by l.sort), '[]')
               from public.loyalty_levels l),
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
                     'pending', (select count(*) from public.loyalty_pending pd where pd.user_id = u and pd.kind = m.key and pd.claimed_at is null),
                     'kind', m.kind,
                     'status', case when m.kind = 'review' then (case when exists (select 1 from public.loyalty_pending pd where pd.user_id = u and pd.kind = m.key and pd.claimed_at is null) then 'ready' else 'todo' end) when exists (select 1 from public.loyalty_claims c where c.user_id = u and c.mission_key = m.key and c.period_key = public._loy_period(m.repeat))
                                    then 'claimed' when public._loy_cond(u, m.kind, m.repeat) then 'ready' else 'todo' end) order by m.sort), '[]')
                 from public.loyalty_missions m where m.is_active),
    'history', (select coalesce(jsonb_agg(jsonb_build_object('points', l.points, 'at', l.created_at) order by l.created_at desc), '[]')
                from (select points, created_at from public.loyalty_ledger where user_id = u and kind = 'vault_reward'
                      order by created_at desc limit 30) l));
end $$;
revoke all on function public.loyalty_dashboard() from public, anon;
grant execute on function public.loyalty_dashboard() to authenticated;
