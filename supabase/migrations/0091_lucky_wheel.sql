-- 0091: the daily lucky wheel ("عجلة الحظ"). The owner (wheel.manage) edits what is on the wheel (points, gifts, "better luck", "spin again"), how hard it is
-- (ease 0..100), how many spins a day, and whether a customer needs at least one order. Everything is decided here, never on the phone: the winning slice is
-- picked by the server, one spin per day per customer, gift limits per day, only verified + approved accounts (fake accounts cannot farm gifts).
-- It disappears for customers when the 'wheel' feature switch (0090) is off. The team can spin as a preview (nothing is recorded or paid).

insert into public.permission_catalog (permission, grp, name_ar, name_en, desc_ar, desc_en, sensitive, inert, sort) values
 ('wheel.manage', 'team', 'يدير عجلة الحظ', 'Manage the lucky wheel',
  'يغيّر خانات العجلة وصعوبتها وعدد اللفّات، ويسلّم الهدايا اللي العملا كسبوها',
  'Edits the wheel slices, its difficulty and spins per day, and hands over the gifts customers won', true, false, 100)
on conflict (permission) do update set name_ar = excluded.name_ar, name_en = excluded.name_en, desc_ar = excluded.desc_ar, desc_en = excluded.desc_en;
insert into public.role_permissions (role, permission) values ('owner', 'wheel.manage') on conflict do nothing;

create table if not exists public.wheel_settings (
  id int primary key default 1 check (id = 1),
  ease int not null default 50 check (ease between 0 and 100),
  spins_per_day int not null default 1 check (spins_per_day between 1 and 5),
  require_order boolean not null default false,
  updated_at timestamptz not null default now()
);
insert into public.wheel_settings (id) values (1) on conflict do nothing;

create table if not exists public.wheel_segments (
  id uuid primary key default gen_random_uuid(),
  position int not null,
  label_ar text not null check (char_length(label_ar) between 1 and 30),
  label_en text not null check (char_length(label_en) between 1 and 30),
  kind text not null check (kind in ('lose', 'points', 'gift', 'again')),
  points int check (points is null or points between 1 and 100000),
  weight int not null default 10 check (weight between 0 and 1000),
  daily_limit int check (daily_limit is null or daily_limit between 0 and 1000),
  active boolean not null default true,
  check (kind <> 'points' or points is not null)
);

create table if not exists public.wheel_spins (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  day date not null,
  segment_id uuid references public.wheel_segments(id) on delete set null,
  kind text not null,
  label_ar text not null,
  label_en text not null,
  points int,
  gift_status text check (gift_status is null or gift_status in ('pending', 'delivered')),
  delivered_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists wheel_spins_user_day on public.wheel_spins (user_id, day);
create index if not exists wheel_spins_gifts on public.wheel_spins (gift_status) where gift_status is not null;

alter table public.wheel_settings enable row level security;
alter table public.wheel_segments enable row level security;
alter table public.wheel_spins enable row level security;   -- no policies: only the functions below touch these tables

insert into public.wheel_segments (position, label_ar, label_en, kind, points, weight, daily_limit)
select * from (values
 (1, '50 نقطة', '50 points', 'points', 50, 25, null::int),
 (2, 'حظ أوفر', 'Better luck', 'lose', null::int, 30, null::int),
 (3, 'خصم 10%', '10% off', 'gift', null::int, 10, null::int),
 (4, 'حظ أوفر', 'Better luck', 'lose', null::int, 30, null::int),
 (5, '100 نقطة', '100 points', 'points', 100, 8, null::int),
 (6, 'لفّة تانية', 'Spin again', 'again', null::int, 8, null::int),
 (7, 'شاحن هدية', 'Free charger', 'gift', null::int, 3, 2),
 (8, 'سماعة هدية', 'Free earphones', 'gift', null::int, 1, 1)) v(position, label_ar, label_en, kind, points, weight, daily_limit)
where not exists (select 1 from public.wheel_segments);

create or replace function public._wheel_day() returns date language sql stable as $$ select (now() at time zone public._loy_tz())::date $$;
revoke all on function public._wheel_day() from public, anon, authenticated;

-- why this customer cannot spin (null = can)
create or replace function public._wheel_block(p_user uuid) returns text
language plpgsql stable security definer set search_path = public as $$
declare pr public.profiles; v_review text; s public.wheel_settings;
begin
  select * into pr from public.profiles where id = p_user;
  if not found or not (coalesce(pr.email_verified, false) or coalesce(pr.phone_verified, false)) then return 'NOT_VERIFIED'; end if;
  select review_status into v_review from public.customers where user_id = p_user;
  if coalesce(v_review, 'approved') <> 'approved' then return 'NOT_APPROVED'; end if;
  select * into s from public.wheel_settings where id = 1;
  if s.require_order and not exists (select 1 from public.orders o where o.customer_id = p_user and o.status <> 'cancelled') then return 'NEEDS_ORDER'; end if;
  return null;
end $$;
revoke all on function public._wheel_block(uuid) from public, anon, authenticated;

create or replace function public._wheel_spins_left(p_user uuid) returns int
language sql stable security definer set search_path = public as $$
  select greatest((select spins_per_day from public.wheel_settings where id = 1)
    - (select count(*)::int from public.wheel_spins where user_id = p_user and day = public._wheel_day() and kind <> 'again'), 0)
$$;
revoke all on function public._wheel_spins_left(uuid) from public, anon, authenticated;

-- what the customer screen needs: the slices (no weights, no limits), whether he can spin, and his gifts
create or replace function public.wheel_state() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare u uuid := public.require_auth(); v_staff boolean := coalesce(public.is_staff(), false); v_block text;
begin
  if not public._feature_on('wheel') and not v_staff then raise exception 'FEATURE_OFF'; end if;
  v_block := public._wheel_block(u);
  return jsonb_build_object(
    'enabled', public._feature_on('wheel'),
    'preview', v_staff,
    'block', case when v_staff then null else v_block end,
    'spins_left', case when v_staff then 99 when v_block is not null then 0 else public._wheel_spins_left(u) end,
    'segments', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'label_ar', s.label_ar, 'label_en', s.label_en, 'kind', s.kind) order by s.position)
                            from public.wheel_segments s where s.active), '[]'::jsonb),
    'gifts', coalesce((select jsonb_agg(jsonb_build_object('label_ar', g.label_ar, 'label_en', g.label_en, 'status', g.gift_status, 'created_at', g.created_at) order by g.created_at desc)
                         from (select * from public.wheel_spins w where w.user_id = u and w.gift_status is not null order by w.created_at desc limit 30) g), '[]'::jsonb));
end $$;
revoke all on function public.wheel_state() from public, anon;
grant execute on function public.wheel_state() to authenticated;

create or replace function public.wheel_spin() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := public.require_auth(); v_staff boolean := coalesce(public.is_staff(), false); v_block text; st public.wheel_settings;
        f numeric; v_seg public.wheel_segments; v_id uuid := gen_random_uuid(); v_paid int; v_pts_on boolean := public._feature_on('points'); v_left int;
begin
  if not public._feature_on('wheel') and not v_staff then raise exception 'FEATURE_OFF'; end if;
  perform pg_advisory_xact_lock(hashtextextended('lucky-wheel', 0));
  if not v_staff then
    v_block := public._wheel_block(u);
    if v_block is not null then raise exception '%', v_block; end if;
    if public._wheel_spins_left(u) <= 0 then raise exception 'NO_SPINS_LEFT'; end if;
  end if;
  select * into st from public.wheel_settings where id = 1;
  f := 0.25 + 1.5 * st.ease / 100.0;          -- 0.25x (hard) .. 1.75x (easy) on everything that is not "better luck"
  select x.* into v_seg from (
    select s.*, sum(w) over (order by s.position, s.id) as cum, sum(w) over () as tot
      from (select s.*, case
              when not s.active then 0
              when s.kind = 'points' and not v_pts_on then 0
              when s.daily_limit is not null and (select count(*) from public.wheel_spins sp where sp.segment_id = s.id and sp.day = public._wheel_day()) >= s.daily_limit then 0
              when s.kind = 'lose' then s.weight
              else s.weight * f end as w
              from public.wheel_segments s) s where s.w > 0) x
   where x.cum > random() * x.tot order by x.cum limit 1;
  if v_seg.id is null then raise exception 'WHEEL_EMPTY'; end if;

  if not v_staff then
    insert into public.wheel_spins (id, user_id, day, segment_id, kind, label_ar, label_en, points, gift_status)
      values (v_id, u, public._wheel_day(), v_seg.id, v_seg.kind, v_seg.label_ar, v_seg.label_en, v_seg.points, case when v_seg.kind = 'gift' then 'pending' end);
    if v_seg.kind = 'points' then
      perform public._loy_ensure(u);
      perform public._loy_grant(u, 'wheel', v_id::text, v_seg.points, v_seg.points);
      select points into v_paid from public.loyalty_ledger where user_id = u and kind = 'wheel' and ref = v_id::text;
      update public.wheel_spins set points = coalesce(v_paid, 0) where id = v_id;
    end if;
    if v_seg.kind = 'gift' then
      perform public.notify_user(u, '🎁 كسبت هدية من عجلة الحظ', '🎁 You won a gift from the lucky wheel',
        'كسبت «' || v_seg.label_ar || '». هنكلّمك لتسليمها، أو تعالى استلمها من المحل.', 'You won "' || v_seg.label_en || '". We will contact you to hand it over, or pick it up from the shop.',
        'system', null, null, '/');
    end if;
  end if;
  v_left := case when v_staff then 99 else public._wheel_spins_left(u) end;
  return jsonb_build_object('segment_id', v_seg.id, 'kind', v_seg.kind, 'label_ar', v_seg.label_ar, 'label_en', v_seg.label_en,
    'points', case when v_staff then v_seg.points else v_paid end, 'spins_left', v_left, 'preview', v_staff);
end $$;
revoke all on function public.wheel_spin() from public, anon;
grant execute on function public.wheel_spin() to authenticated;

-- ---------- the owner ----------
create or replace function public.wheel_admin_get() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare st public.wheel_settings;
begin
  perform public.require_permission('wheel.manage');
  select * into st from public.wheel_settings where id = 1;
  return jsonb_build_object(
    'ease', st.ease, 'spins_per_day', st.spins_per_day, 'require_order', st.require_order,
    'enabled', public._feature_on('wheel'),
    'spins_today', (select count(*) from public.wheel_spins where day = public._wheel_day()),
    'gifts_pending', (select count(*) from public.wheel_spins where gift_status = 'pending'),
    'segments', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'label_ar', s.label_ar, 'label_en', s.label_en, 'kind', s.kind, 'points', s.points,
         'weight', s.weight, 'daily_limit', s.daily_limit, 'active', s.active,
         'given_today', (select count(*) from public.wheel_spins sp where sp.segment_id = s.id and sp.day = public._wheel_day())) order by s.position)
       from public.wheel_segments s), '[]'::jsonb));
end $$;
revoke all on function public.wheel_admin_get() from public, anon;
grant execute on function public.wheel_admin_get() to authenticated;

create or replace function public.wheel_admin_save(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare s jsonb; i int := 0; v_kind text; v_active int := 0; v_total int := 0;
begin
  perform public.require_permission('wheel.manage');
  if jsonb_typeof(p->'segments') <> 'array' or jsonb_array_length(p->'segments') not between 3 and 12 then raise exception 'INVALID_INPUT'; end if;
  if coalesce((p->>'ease')::int, 50) not between 0 and 100 or coalesce((p->>'spins_per_day')::int, 1) not between 1 and 5 then raise exception 'INVALID_INPUT'; end if;
  for s in select * from jsonb_array_elements(p->'segments') loop
    v_kind := s->>'kind';
    if v_kind not in ('lose', 'points', 'gift', 'again') or char_length(btrim(coalesce(s->>'label_ar', ''))) not between 1 and 30 then raise exception 'INVALID_INPUT'; end if;
    if v_kind = 'points' and coalesce((s->>'points')::int, 0) not between 1 and 100000 then raise exception 'INVALID_INPUT'; end if;
    if coalesce((s->>'weight')::int, 0) not between 0 and 1000 then raise exception 'INVALID_INPUT'; end if;
    if coalesce((s->>'active')::boolean, true) then v_active := v_active + 1; v_total := v_total + coalesce((s->>'weight')::int, 0); end if;
  end loop;
  if v_active < 3 or v_total <= 0 then raise exception 'INVALID_INPUT'; end if;
  update public.wheel_settings set ease = coalesce((p->>'ease')::int, 50), spins_per_day = coalesce((p->>'spins_per_day')::int, 1),
         require_order = coalesce((p->>'require_order')::boolean, false), updated_at = now() where id = 1;
  delete from public.wheel_segments;
  for s in select * from jsonb_array_elements(p->'segments') loop
    i := i + 1;
    insert into public.wheel_segments (position, label_ar, label_en, kind, points, weight, daily_limit, active)
    values (i, btrim(s->>'label_ar'), coalesce(nullif(btrim(s->>'label_en'), ''), btrim(s->>'label_ar')), s->>'kind',
            case when s->>'kind' = 'points' then (s->>'points')::int end, (s->>'weight')::int,
            case when s->>'kind' in ('gift', 'points') then nullif(s->>'daily_limit', '')::int end, coalesce((s->>'active')::boolean, true));
  end loop;
  perform public.audit_write('wheel.save', 'wheel', '1', jsonb_build_object('segments', v_active, 'ease', p->'ease'));
end $$;
revoke all on function public.wheel_admin_save(jsonb) from public, anon;
grant execute on function public.wheel_admin_save(jsonb) to authenticated;

-- the gifts customers won (to hand over), newest first
create or replace function public.wheel_gifts_list(p_status text default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_permission('wheel.manage');
  return coalesce((select jsonb_agg(x order by x.created_at desc) from (
    select w.id, w.label_ar, w.gift_status as status, w.created_at, w.delivered_at, w.user_id,
           coalesce(nullif(btrim(p.full_name), ''), p.email, p.phone, 'عميل') as name, p.phone, p.email
      from public.wheel_spins w left join public.profiles p on p.id = w.user_id
     where w.gift_status is not null and (p_status is null or w.gift_status = p_status)
     order by w.created_at desc limit 100) x), '[]'::jsonb);
end $$;
revoke all on function public.wheel_gifts_list(text) from public, anon;
grant execute on function public.wheel_gifts_list(text) to authenticated;

create or replace function public.wheel_gift_set_status(p_spin uuid, p_status text) returns void
language plpgsql security definer set search_path = public as $$
declare w public.wheel_spins;
begin
  perform public.require_permission('wheel.manage');
  if p_status not in ('pending', 'delivered') then raise exception 'INVALID_INPUT'; end if;
  select * into w from public.wheel_spins where id = p_spin and gift_status is not null for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  update public.wheel_spins set gift_status = p_status, delivered_at = case when p_status = 'delivered' then now() end where id = p_spin;
  if p_status = 'delivered' and w.gift_status <> 'delivered' then
    perform public.notify_user(w.user_id, '🎁 هديتك اتسلّمت', '🎁 Your gift was handed over', 'هديتك «' || w.label_ar || '» اتسلّمت. نورتنا!', 'Your gift "' || w.label_en || '" was handed over. Thank you!', 'system', null, null, '/');
  end if;
  perform public.audit_write('wheel.gift', 'wheel_spin', p_spin::text, jsonb_build_object('status', p_status));
end $$;
revoke all on function public.wheel_gift_set_status(uuid, text) from public, anon;
grant execute on function public.wheel_gift_set_status(uuid, text) to authenticated;
