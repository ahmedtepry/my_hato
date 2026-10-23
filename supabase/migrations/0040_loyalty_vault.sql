-- 0040: MYHATO SECRET VAULT (loyalty). Everything that gives points / parts / rewards runs inside the database.
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
  perk_ar text, perk_en text
);
create table if not exists public.loyalty_missions (
  key text primary key, kind text not null check (kind in ('checkin','favorite','streak')),
  title_ar text not null, title_en text not null, desc_ar text, desc_en text, icon text default 'star',
  points int not null default 0, vault int not null default 0, component text,   -- component: 'random' or a component key
  repeat text not null default 'daily' check (repeat in ('daily','weekly')),
  is_active boolean not null default true, sort int not null default 100
);
create table if not exists public.loyalty_components (
  key text primary key, name_ar text not null, name_en text not null, icon text, sort int not null default 100
);
create table if not exists public.loyalty_tiers (
  sort int primary key, name_ar text not null, name_en text not null, min_parts int not null
);
create table if not exists public.loyalty_rewards (
  id int generated always as identity primary key, name_ar text not null, name_en text not null,
  points int not null check (points > 0), weight numeric not null default 1 check (weight > 0),
  stock int check (stock is null or stock >= 0), is_active boolean not null default true
);
create table if not exists public.loyalty_claims (
  user_id uuid not null references auth.users(id) on delete cascade, mission_key text not null references public.loyalty_missions(key),
  period_key text not null, claimed_at timestamptz not null default now(),
  primary key (user_id, mission_key, period_key)
);
create table if not exists public.loyalty_user_components (
  user_id uuid not null references auth.users(id) on delete cascade, component_key text not null references public.loyalty_components(key),
  qty int not null default 0 check (qty >= 0), primary key (user_id, component_key)
);
create table if not exists public.loyalty_ledger (          -- every change, once only (idempotency)
  id bigint generated always as identity primary key, user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null, ref text not null, points int not null default 0, vault int not null default 0,
  created_at timestamptz not null default now(), unique (user_id, kind, ref)
);

do $$ declare t text; begin
  foreach t in array array['loyalty_profiles','loyalty_levels','loyalty_missions','loyalty_components','loyalty_tiers',
                           'loyalty_rewards','loyalty_claims','loyalty_user_components','loyalty_ledger'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
  end loop;
  foreach t in array array['loyalty_profiles','loyalty_claims','loyalty_user_components','loyalty_ledger'] loop
    execute format('drop policy if exists own_read on public.%I', t);
    execute format('create policy own_read on public.%I for select to authenticated using (user_id = auth.uid() or public.has_permission(''settings.manage''))', t);
  end loop;
  foreach t in array array['loyalty_levels','loyalty_missions','loyalty_components','loyalty_tiers'] loop
    execute format('drop policy if exists cfg_read on public.%I', t);
    execute format('create policy cfg_read on public.%I for select to authenticated using (true)', t);
  end loop;
  drop policy if exists staff_read on public.loyalty_rewards;
  create policy staff_read on public.loyalty_rewards for select to authenticated using (public.has_permission('settings.manage'));
end $$;

insert into public.loyalty_levels (sort, name_ar, name_en, min_points, perk_ar, perk_en) values
 (1,'مستكشف','Explorer',0,'ابدأ تجمع نقاط','Start collecting points'),
 (2,'برو','Pro',200,'أولوية في العروض','Priority on offers'),
 (3,'إيليت','Elite',600,'مكافآت أكبر في الخزنة','Bigger vault rewards'),
 (4,'ماستر','Master',1500,'عروض حصرية','Exclusive offers'),
 (5,'أسطورة','Legend',3500,'أعلى مستوى','Top level')
on conflict do nothing;
insert into public.loyalty_missions (key, kind, title_ar, title_en, desc_ar, desc_en, icon, points, vault, component, repeat, sort) values
 ('checkin','checkin','تسجيل حضور يومي','Daily check-in','ادخل كل يوم واكسب نقاط','Come back every day for points','event_available',5,10,null,'daily',10),
 ('favorite','favorite','ضيف منتج للمفضلة','Favorite a product','ضيف أي منتج للمفضلة النهاردة','Add any product to favorites today','favorite',5,10,null,'daily',20),
 ('streak7','streak','٧ أيام ورا بعض','7-day streak','سجّل حضور ٧ أيام ورا بعض واكسب جزء موبايل','Check in 7 days in a row to win a phone part','local_fire_department',30,30,'random','weekly',30)
on conflict do nothing;
insert into public.loyalty_components (key, name_ar, name_en, icon, sort) values
 ('screen','الشاشة','Screen','smartphone',1),('battery','البطارية','Battery','battery_charging_full',2),
 ('camera','الكاميرا','Camera','photo_camera',3),('processor','المعالج','Processor','memory',4)
on conflict do nothing;
insert into public.loyalty_tiers (sort, name_ar, name_en, min_parts) values
 (1,'أساسي','Basic',0),(2,'جالاكسي','Galaxy',2),(3,'برو','Pro',3),(4,'ألتميت','Ultimate',4)
on conflict do nothing;
insert into public.loyalty_rewards (name_ar, name_en, points, weight) values
 ('٢٠ نقطة','20 points',20,10),('٥٠ نقطة','50 points',50,5),('١٠٠ نقطة','100 points',100,3),('٢٥٠ نقطة','250 points',250,1)
on conflict do nothing;
insert into public.application_settings (key, value, description) values
 ('loyalty_vault_required','100','Vault progress needed to open it'),
 ('loyalty_order_points_per_10egp','1','Points per 10 EGP on a delivered, paid order'),
 ('loyalty_order_vault','25','Vault progress per delivered order'),
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

create or replace function public._loy_grant(p_user uuid, p_kind text, p_ref text, p_points int, p_vault int, p_comp text)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_comp text := p_comp; v_n int;
begin
  insert into public.loyalty_ledger (user_id, kind, ref, points, vault) values (p_user, p_kind, p_ref, p_points, p_vault)
    on conflict (user_id, kind, ref) do nothing;
  get diagnostics v_n = row_count;
  if v_n = 0 then return false; end if;
  update public.loyalty_profiles set points = greatest(points + p_points, 0), vault_progress = greatest(vault_progress + p_vault, 0)
   where user_id = p_user;
  if v_comp = 'random' then
    select key into v_comp from public.loyalty_components order by md5(key || p_user::text || p_ref) limit 1;
  end if;
  if v_comp is not null then
    insert into public.loyalty_user_components (user_id, component_key, qty) values (p_user, v_comp, 1)
      on conflict (user_id, component_key) do update set qty = public.loyalty_user_components.qty + 1;
  end if;
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
declare o record; v_pts int; v_per numeric := public._loy_num('loyalty_order_points_per_10egp', 1); v_vault int := public._loy_num('loyalty_order_vault', 25)::int;
begin
  for o in select id, total_minor from public.orders
            where customer_id = p_user and status = 'delivered' and payment_status not in ('refunded','partially_refunded','failed')
              and not exists (select 1 from public.loyalty_ledger l where l.user_id = p_user and l.kind = 'order' and l.ref = orders.id::text)
            order by created_at limit 50 loop
    v_pts := floor(o.total_minor / 1000.0 * v_per)::int;
    perform public._loy_grant(p_user, 'order', o.id::text, v_pts, v_vault, 'random');
  end loop;
  for o in select l.ref, l.points, l.vault from public.loyalty_ledger l join public.orders r on r.id::text = l.ref
            where l.user_id = p_user and l.kind = 'order'
              and (r.status = 'cancelled' or r.payment_status in ('refunded','partially_refunded'))
              and not exists (select 1 from public.loyalty_ledger x where x.user_id = p_user and x.kind = 'order_reversal' and x.ref = l.ref) loop
    perform public._loy_grant(p_user, 'order_reversal', o.ref, -o.points, -o.vault, null);
  end loop;
end $$;

create or replace function public._loy_ensure(p_user uuid) returns void language sql security definer set search_path = public as $$
  insert into public.loyalty_profiles (user_id) values (p_user) on conflict do nothing $$;
revoke all on function public._loy_num(text, numeric), public._loy_tz(), public._loy_period(text), public._loy_period_start(text),
  public._loy_grant(uuid, text, text, int, int, text), public._loy_cond(uuid, text, text), public._loy_sync_orders(uuid), public._loy_ensure(uuid)
  from public, anon, authenticated;

-- ---------- what the app calls ----------
create or replace function public.loyalty_dashboard() returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := public.require_auth(); p public.loyalty_profiles%rowtype; v_parts int; v_req int := public._loy_num('loyalty_vault_required', 100)::int;
begin
  perform public._loy_ensure(u);
  perform public._loy_sync_orders(u);
  select * into p from public.loyalty_profiles where user_id = u;
  select count(*) into v_parts from public.loyalty_user_components where user_id = u and qty > 0;
  return jsonb_build_object(
    'points', p.points, 'streak', p.streak, 'vault_progress', p.vault_progress, 'vault_required', v_req,
    'level', (select to_jsonb(l) from public.loyalty_levels l where l.min_points <= p.points order by l.sort desc limit 1),
    'next_level', (select to_jsonb(l) from public.loyalty_levels l where l.min_points > p.points order by l.sort limit 1),
    'tier', (select to_jsonb(t) from public.loyalty_tiers t where t.min_parts <= v_parts order by t.sort desc limit 1),
    'next_tier', (select to_jsonb(t) from public.loyalty_tiers t where t.min_parts > v_parts order by t.sort limit 1),
    'parts_owned', v_parts,
    'components', (select coalesce(jsonb_agg(jsonb_build_object('key', c.key, 'name_ar', c.name_ar, 'name_en', c.name_en, 'icon', c.icon,
                     'qty', coalesce(uc.qty, 0)) order by c.sort), '[]')
                   from public.loyalty_components c left join public.loyalty_user_components uc on uc.user_id = u and uc.component_key = c.key),
    'missions', (select coalesce(jsonb_agg(jsonb_build_object('key', m.key, 'title_ar', m.title_ar, 'title_en', m.title_en,
                     'desc_ar', m.desc_ar, 'desc_en', m.desc_en, 'icon', m.icon, 'points', m.points, 'vault', m.vault,
                     'component', m.component, 'repeat', m.repeat,
                     'status', case when exists (select 1 from public.loyalty_claims c where c.user_id = u and c.mission_key = m.key and c.period_key = public._loy_period(m.repeat))
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
  select * into m from public.loyalty_missions where key = p_mission and is_active;
  if not found then raise exception 'MISSION_NOT_FOUND'; end if;
  if exists (select 1 from public.loyalty_claims where user_id = u and mission_key = m.key and period_key = public._loy_period(m.repeat)) then
    raise exception 'ALREADY_CLAIMED';
  end if;
  if m.kind = 'checkin' then      -- streak moves only on the real server date
    update public.loyalty_profiles set streak = case when last_checkin = v_today - 1 then streak + 1 else 1 end, last_checkin = v_today where user_id = u;
  end if;
  if not public._loy_cond(u, m.kind, m.repeat) then raise exception 'NOT_ELIGIBLE'; end if;
  insert into public.loyalty_claims (user_id, mission_key, period_key) values (u, m.key, public._loy_period(m.repeat));
  perform public._loy_grant(u, 'mission', m.key || ':' || public._loy_period(m.repeat), m.points, m.vault, m.component);
  return jsonb_build_object('points', m.points, 'vault', m.vault, 'component', m.component);
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
  perform public._loy_grant(u, 'vault_reward', v_ref, r.points, -v_req, null);
  return jsonb_build_object('points', r.points, 'name_ar', r.name_ar, 'name_en', r.name_en);
end $$;

revoke all on function public.loyalty_dashboard(), public.loyalty_claim(text), public.loyalty_open_vault() from public, anon;
grant execute on function public.loyalty_dashboard(), public.loyalty_claim(text), public.loyalty_open_vault() to authenticated;
