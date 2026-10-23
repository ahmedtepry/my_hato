-- 0040: MYHATO SECRET VAULT (loyalty). Everything that gives points / rewards runs inside the database.
-- The app can only READ its own rows and call 3 functions: loyalty_dashboard, loyalty_claim, loyalty_open_vault.
-- Vault rewards are POINTS only (no money value is ever stated). History of openings is read from the ledger.
-- Wording, missions, levels, rewards and numbers are plain tables: edit them in Supabase, no new APK needed.

create table if not exists public.loyalty_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  points int not null default 0 check (points >= 0),        -- lifetime points = membership progress
  streak int not null default 0,
  last_checkin date,
  vault_progress int not null default 0 check (vault_progress >= 0),
  created_at timestamptz not null default now()
);
create table if not exists public.loyalty_levels (
  sort int primary key, name_ar text not null, name_en text not null, min_points int not null,
  plan_ar text, plan_en text              -- PRIVATE owner notes: the gift planned for this level (customers never see it)
);
create table if not exists public.loyalty_missions (
  key text primary key, kind text not null check (kind in ('checkin','favorite','streak','review')),
  title_ar text not null, title_en text not null, desc_ar text, desc_en text, icon text default 'star',
  points int not null default 0,                           -- one number: it adds to the balance AND fills the vault
  repeat text not null default 'daily' check (repeat in ('daily','weekly')),
  is_active boolean not null default true, sort int not null default 100
);
create table if not exists public.loyalty_rewards (
  id int generated always as identity primary key,
  points int not null check (points > 0), weight numeric not null default 1 check (weight > 0),
  stock int check (stock is null or stock >= 0), is_active boolean not null default true
);
create table if not exists public.loyalty_claims (
  user_id uuid not null references auth.users(id) on delete cascade, mission_key text not null references public.loyalty_missions(key),
  period_key text not null, claimed_at timestamptz not null default now(),
  primary key (user_id, mission_key, period_key)
);
create table if not exists public.loyalty_awards (        -- one level prize per customer per level, never repeated
  user_id uuid not null references auth.users(id) on delete cascade, level_sort int not null references public.loyalty_levels(sort),
  code text not null unique, awarded_at timestamptz not null default now(),
  seen_at timestamptz,                                     -- congratulation screen shown
  prize_ar text, prize_en text, revealed_at timestamptz,   -- set by the owner; the customer sees the prize only after revealed_at
  delivered_at timestamptz, delivered_note text,           -- staff fills these when the prize is handed over
  primary key (user_id, level_sort)
);
create table if not exists public.loyalty_ledger (          -- every change, once only (idempotency)
  id bigint generated always as identity primary key, user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null, ref text not null, points int not null default 0, vault int not null default 0,
  created_at timestamptz not null default now(), unique (user_id, kind, ref)
);

do $$ declare t text; begin
  foreach t in array array['loyalty_profiles','loyalty_levels','loyalty_missions',
                           'loyalty_rewards','loyalty_claims','loyalty_ledger','loyalty_awards'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
  end loop;
  foreach t in array array['loyalty_profiles','loyalty_claims','loyalty_ledger','loyalty_awards'] loop
    execute format('drop policy if exists own_read on public.%I', t);
    execute format('create policy own_read on public.%I for select to authenticated using (user_id = auth.uid() or public.has_permission(''settings.manage''))', t);
  end loop;
  foreach t in array array['loyalty_missions'] loop
    execute format('drop policy if exists cfg_read on public.%I', t);
    execute format('create policy cfg_read on public.%I for select to authenticated using (true)', t);
  end loop;
  drop policy if exists staff_read on public.loyalty_levels;
  create policy staff_read on public.loyalty_levels for select to authenticated using (public.has_permission('permissions.manage'));
  drop policy if exists staff_read on public.loyalty_rewards;
  create policy staff_read on public.loyalty_rewards for select to authenticated using (public.has_permission('settings.manage'));
end $$;

-- Levels are SECRET: customers cannot read this table and never see thresholds or gifts.
-- plan_* is only the owner's private note. A gift is shown to a customer only after the owner reveals it (owner page in the app).
insert into public.loyalty_levels (sort, name_ar, name_en, min_points, plan_ar, plan_en) values
 (1,'مستكشف','Explorer',0,null,null),
 (2,'برونز','Bronze',300,'اسكرينة + كفر','Screen protector + case'),
 (3,'فضي','Silver',700,'سماعة سلك','Wired earphones'),
 (4,'ذهبي','Gold',1500,'شاحن سريع','Fast charger'),
 (5,'بلاتينيوم','Platinum',3000,'سماعة بلوتوث','Bluetooth headset'),
 (6,'إيليت','Elite',5500,'باور بانك','Power bank'),
 (7,'ماستر','Master',9000,'سماعة بلوتوث بريميوم','Premium Bluetooth earbuds'),
 (8,'جراند ماستر','Grand Master',14000,'ساعة ذكية','Smart watch'),
 (9,'أسطورة','Legend',22000,'هدية كبيرة','A big gift'),
 (10,'عرش الأساطير','Mythic',35000,'الجايزة الكبرى','The grand prize')
on conflict do nothing;
insert into public.loyalty_missions (key, kind, title_ar, title_en, desc_ar, desc_en, icon, points, repeat, sort) values
 ('checkin','checkin','تسجيل حضور يومي','Daily check-in','ادخل كل يوم واكسب نقاط','Come back every day for points','event_available',5,'daily',10),
 ('review','review','قيّم منتج اشتريته','Review a product you bought','اكتب رأيك (١٠ حروف على الأقل) في منتج اتسلّمك، والمكافأة بتتضاف تلقائي بعد ما التقييم يتنشر','Write your opinion (10+ characters) on a product you received. The reward is added automatically once the review is published','rate_review',40,'weekly',20),
 ('streak7','streak','٧ أيام ورا بعض','7-day streak','سجّل حضور ٧ أيام ورا بعض واكسب مكافأة','Check in 7 days in a row for a bonus','local_fire_department',30,'weekly',30)
on conflict do nothing;
insert into public.loyalty_rewards (points, weight) values (20,10),(50,5),(100,3),(250,1)   -- the app always shows exactly this number
on conflict do nothing;
insert into public.application_settings (key, value, description) values
 ('loyalty_vault_required','100','Vault progress needed to open it'),
 ('loyalty_order_points_per_10egp','1','Points per 10 EGP on a delivered, paid order'),
 ('loyalty_timezone','"Africa/Cairo"','Day boundary for daily missions')
on conflict (key) do nothing;

-- ---------- helpers (not callable by the app) ----------
create or replace function public._loy_num(p_key text, p_def numeric) returns numeric language sql stable as $$
  select coalesce((public.setting(p_key) #>> '{}')::numeric, p_def) $$;
create or replace function public._loy_tz() returns text language sql stable as $$
  select coalesce(public.setting('loyalty_timezone') #>> '{}', 'Africa/Cairo') $$;
create or replace function public._loy_period(p_repeat text) returns text language sql stable as $$
  select case p_repeat when 'weekly' then to_char(now() at time zone public._loy_tz(), 'IYYY-"W"IW')
                       else to_char(now() at time zone public._loy_tz(), 'YYYY-MM-DD') end $$;
create or replace function public._loy_period_start(p_repeat text) returns timestamptz language sql stable as $$
  select date_trunc(case p_repeat when 'weekly' then 'week' else 'day' end, now() at time zone public._loy_tz()) at time zone public._loy_tz() $$;

create or replace function public._loy_grant(p_user uuid, p_kind text, p_ref text, p_points int, p_vault int)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  insert into public.loyalty_ledger (user_id, kind, ref, points, vault) values (p_user, p_kind, p_ref, p_points, p_vault)
    on conflict (user_id, kind, ref) do nothing;
  get diagnostics v_n = row_count;
  if v_n = 0 then return false; end if;
  update public.loyalty_profiles set points = greatest(points + p_points, 0), vault_progress = greatest(vault_progress + p_vault, 0)
   where user_id = p_user;
  return true;
end $$;

create or replace function public._loy_cond(p_user uuid, p_kind text, p_repeat text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare p public.loyalty_profiles%rowtype;
begin
  select * into p from public.loyalty_profiles where user_id = p_user;
  if p_kind = 'checkin' then return true; end if;
  if p_kind = 'favorite' then
    return exists (select 1 from public.product_favorites where user_id = p_user and created_at >= public._loy_period_start(p_repeat));
  end if;
  if p_kind = 'streak' then
    return p.streak >= 7 and p.last_checkin >= (now() at time zone public._loy_tz())::date - 1;
  end if;
  return false;
end $$;

-- paid + delivered orders give points once; cancelled / refunded ones take them back (once)
create or replace function public._loy_sync_orders(p_user uuid) returns void language plpgsql security definer set search_path = public as $$
declare o record; v_rp int; v_pts int; v_per numeric := public._loy_num('loyalty_order_points_per_10egp', 1);
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
  -- verified, published reviews with a real comment give the 'review' mission reward once; removed reviews take it back
  select points into v_rp from public.loyalty_missions where key = 'review' and is_active;
  if found then
    for o in select r.id from public.product_reviews r
              where r.user_id = p_user and r.status = 'published' and r.verified_purchase and length(trim(coalesce(r.comment, ''))) >= 10
                and not exists (select 1 from public.loyalty_ledger l where l.user_id = p_user and l.kind = 'review' and l.ref = r.id::text)
              limit 20 loop
      perform public._loy_grant(p_user, 'review', o.id::text, v_rp, v_rp);
    end loop;
    for o in select l.ref, l.points, l.vault from public.loyalty_ledger l join public.product_reviews r on r.id::text = l.ref
              where l.user_id = p_user and l.kind = 'review' and r.status = 'removed'
                and not exists (select 1 from public.loyalty_ledger x where x.user_id = p_user and x.kind = 'review_reversal' and x.ref = l.ref) loop
      perform public._loy_grant(p_user, 'review_reversal', o.ref, -o.points, -o.vault);
    end loop;
  end if;
end $$;

-- Gift codes: 12 consonants in 3 groups (KRTV-PXMB-QHZD). No digits, no prefix: nothing like order (MH-...) or repair (MY-HATO...) codes.
create or replace function public._loy_gift_code() returns text language plpgsql volatile as $$
declare a constant text := 'BCDFGHJKMNPQRSTVWXZ'; c text;
begin
  loop
    c := '';
    for i in 1..12 loop
      c := c || substr(a, 1 + floor(random() * length(a))::int, 1);
      if i in (4, 8) then c := c || '-'; end if;
    end loop;
    exit when not exists (select 1 from public.loyalty_awards where code = c);
  end loop;
  return c;
end $$;

create or replace function public._loy_ensure(p_user uuid) returns void language sql security definer set search_path = public as $$
  insert into public.loyalty_profiles (user_id) values (p_user) on conflict do nothing $$;
revoke all on function public._loy_num(text, numeric), public._loy_tz(), public._loy_period(text), public._loy_period_start(text),
  public._loy_grant(uuid, text, text, int, int), public._loy_gift_code(), public._loy_cond(uuid, text, text), public._loy_sync_orders(uuid), public._loy_ensure(uuid)
  from public, anon, authenticated;

-- ---------- what the app calls ----------
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
    'points', p.points, 'streak', p.streak, 'vault_progress', p.vault_progress, 'vault_required', v_req,
    'level', (select jsonb_build_object('sort', l.sort, 'name_ar', l.name_ar, 'name_en', l.name_en) from public.loyalty_levels l where l.min_points <= p.points order by l.sort desc limit 1),
    'awards', (select coalesce(jsonb_agg(jsonb_build_object('level_sort', a.level_sort, 'name_ar', l.name_ar, 'name_en', l.name_en,
                  'code', a.code, 'awarded_at', a.awarded_at, 'new', a.seen_at is null, 'delivered', a.delivered_at is not null,
                  'prize_ar', case when a.revealed_at is not null then a.prize_ar end, 'prize_en', case when a.revealed_at is not null then a.prize_en end)
                  order by a.level_sort), '[]')
               from public.loyalty_awards a join public.loyalty_levels l on l.sort = a.level_sort where a.user_id = u),
    'missions', (select coalesce(jsonb_agg(jsonb_build_object('key', m.key, 'title_ar', m.title_ar, 'title_en', m.title_en,
                     'desc_ar', m.desc_ar, 'desc_en', m.desc_en, 'icon', m.icon, 'points', m.points,
                     'repeat', m.repeat,
                     'kind', m.kind,
                     'status', case when m.kind = 'review' then 'auto' when exists (select 1 from public.loyalty_claims c where c.user_id = u and c.mission_key = m.key and c.period_key = public._loy_period(m.repeat))
                                    then 'claimed' when public._loy_cond(u, m.kind, m.repeat) then 'ready' else 'todo' end) order by m.sort), '[]')
                 from public.loyalty_missions m where m.is_active),
    'history', (select coalesce(jsonb_agg(jsonb_build_object('points', l.points, 'at', l.created_at) order by l.created_at desc), '[]')
                from (select points, created_at from public.loyalty_ledger where user_id = u and kind = 'vault_reward'
                      order by created_at desc limit 30) l));
end $$;

create or replace function public.loyalty_claim(p_mission text) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := public.require_auth(); m public.loyalty_missions%rowtype; p public.loyalty_profiles%rowtype; v_today date := (now() at time zone public._loy_tz())::date;
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
  perform public._loy_grant(u, 'mission', m.key || ':' || public._loy_period(m.repeat), m.points, m.points);
  return jsonb_build_object('points', m.points);
end $$;

create or replace function public.loyalty_open_vault() returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := public.require_auth(); p public.loyalty_profiles%rowtype; v_req int := public._loy_num('loyalty_vault_required', 100)::int;
        r public.loyalty_rewards%rowtype; v_ref text := gen_random_uuid()::text;
begin
  perform public._loy_ensure(u);
  select * into p from public.loyalty_profiles where user_id = u for update;      -- a second tap waits here, then sees the lower progress
  if p.vault_progress < v_req then raise exception 'VAULT_NOT_READY'; end if;
  select * into r from public.loyalty_rewards where is_active and (stock is null or stock > 0)
    order by -ln(greatest(random(), 1e-12)) / weight limit 1 for update skip locked;
  if not found then raise exception 'REWARD_UNAVAILABLE'; end if;                 -- progress is kept
  if r.stock is not null then update public.loyalty_rewards set stock = stock - 1 where id = r.id; end if;
  perform public._loy_grant(u, 'vault_reward', v_ref, r.points, -v_req);
  return jsonb_build_object('points', r.points);
end $$;

create or replace function public.loyalty_ack_awards() returns void language sql security definer set search_path = public as $$
  update public.loyalty_awards set seen_at = now() where user_id = public.require_auth() and seen_at is null $$;

-- ---------- owner only (permissions.manage = the owner) ----------
create or replace function public.owner_loyalty_overview() returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_permission('permissions.manage');
  return jsonb_build_object(
    'awards', (select coalesce(jsonb_agg(jsonb_build_object('code', a.code, 'level_sort', a.level_sort, 'level_ar', l.name_ar, 'level_en', l.name_en,
                  'plan_ar', l.plan_ar, 'customer', coalesce(nullif(pr.full_name, ''), pr.email), 'email', pr.email, 'points', lp.points,
                  'awarded_at', a.awarded_at, 'prize_ar', a.prize_ar, 'prize_en', a.prize_en, 'revealed', a.revealed_at is not null,
                  'delivered', a.delivered_at is not null) order by a.delivered_at is not null, a.awarded_at desc), '[]')
               from (select * from public.loyalty_awards order by awarded_at desc limit 300) a
               join public.loyalty_levels l on l.sort = a.level_sort
               left join public.profiles pr on pr.id = a.user_id left join public.loyalty_profiles lp on lp.user_id = a.user_id),
    'customers', (select coalesce(jsonb_agg(jsonb_build_object('customer', coalesce(nullif(pr.full_name, ''), pr.email), 'email', pr.email, 'points', lp.points,
                  'level_ar', (select name_ar from public.loyalty_levels x where x.min_points <= lp.points order by x.sort desc limit 1)) order by lp.points desc), '[]')
               from (select * from public.loyalty_profiles order by points desc limit 100) lp left join public.profiles pr on pr.id = lp.user_id),
    'levels', (select coalesce(jsonb_agg(to_jsonb(l) order by l.sort), '[]') from public.loyalty_levels l));
end $$;

create or replace function public.owner_loyalty_set_award(p_code text, p_prize_ar text, p_prize_en text, p_reveal boolean, p_delivered boolean)
returns void language plpgsql security definer set search_path = public as $$
declare a public.loyalty_awards%rowtype;
begin
  perform public.require_permission('permissions.manage');
  select * into a from public.loyalty_awards where code = upper(trim(p_code)) for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if length(coalesce(p_prize_ar, '')) > 120 or length(coalesce(p_prize_en, '')) > 120 then raise exception 'INVALID_INPUT'; end if;
  if (p_reveal or a.revealed_at is not null) and nullif(trim(coalesce(p_prize_ar, a.prize_ar, '')), '') is null then raise exception 'INVALID_INPUT'; end if;
  update public.loyalty_awards set
    prize_ar = nullif(trim(coalesce(p_prize_ar, '')), ''), prize_en = nullif(trim(coalesce(p_prize_en, '')), ''),
    revealed_at = case when p_reveal then coalesce(revealed_at, now()) else null end,
    delivered_at = case when p_delivered then coalesce(delivered_at, now()) else null end
   where code = a.code;
  perform public.audit_write('loyalty.award', 'loyalty_award', a.code,
    jsonb_build_object('level', a.level_sort, 'revealed', p_reveal, 'delivered', p_delivered, 'prize', p_prize_ar));
end $$;
revoke all on function public.owner_loyalty_overview(), public.owner_loyalty_set_award(text, text, text, boolean, boolean) from public, anon;
grant execute on function public.owner_loyalty_overview(), public.owner_loyalty_set_award(text, text, text, boolean, boolean) to authenticated;

revoke all on function public.loyalty_dashboard(), public.loyalty_claim(text), public.loyalty_open_vault(), public.loyalty_ack_awards() from public, anon;
grant execute on function public.loyalty_dashboard(), public.loyalty_claim(text), public.loyalty_open_vault(), public.loyalty_ack_awards() to authenticated;
