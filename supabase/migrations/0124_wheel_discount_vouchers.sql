-- 0124: a wheel prize that is a DISCOUNT is no longer a "gift to collect from the shop". It is a one-time voucher kept in the customer's account for a short
-- time (1 to 48 hours, set by the owner per slice). He sees it with a live countdown, taps "use", and it is applied to his order like a coupon.
-- Under the hood each voucher is a personal one-use coupon (random code, only its owner can redeem it), so checkout, totals and the audit trail are the
-- existing coupon path. It disappears once the order that used it is confirmed; if that order is cancelled first, the voucher comes back (until it expires).

alter table public.wheel_segments add column if not exists discount_percent int check (discount_percent is null or discount_percent between 1 and 90);
alter table public.wheel_segments add column if not exists valid_hours int not null default 24 check (valid_hours between 1 and 48);
alter table public.wheel_segments drop constraint if exists wheel_segments_kind_check;
alter table public.wheel_segments add constraint wheel_segments_kind_check check (kind in ('lose', 'points', 'gift', 'again', 'discount'));
alter table public.wheel_segments drop constraint if exists wheel_segments_discount_chk;
alter table public.wheel_segments add constraint wheel_segments_discount_chk check (kind <> 'discount' or discount_percent is not null);

create table if not exists public.wheel_vouchers (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  spin_id uuid references public.wheel_spins(id) on delete set null,
  coupon_code text not null unique references public.coupons(code) on delete cascade,
  created_at timestamptz not null default now()
);
create index if not exists wheel_vouchers_user on public.wheel_vouchers (user_id);
alter table public.wheel_vouchers enable row level security;
revoke all on public.wheel_vouchers from anon, authenticated;

-- a wheel voucher can only be redeemed by the customer who won it
create or replace function public._coupon_discount(p_c public.coupons, p_user uuid, p_subtotal bigint)
returns bigint language plpgsql stable security definer set search_path = public as $$
declare v_mine int;
begin
  if p_c.code is null or not p_c.is_active then raise exception 'COUPON_INVALID'; end if;
  if exists (select 1 from public.wheel_vouchers v where v.coupon_code = p_c.code and v.user_id <> p_user) then raise exception 'COUPON_INVALID'; end if;
  if p_c.starts_at > now() or (p_c.ends_at is not null and p_c.ends_at < now()) then raise exception 'COUPON_EXPIRED'; end if;
  if p_subtotal < p_c.min_order_minor then raise exception 'COUPON_MIN_ORDER:%', p_c.min_order_minor; end if;
  if p_c.max_uses is not null and p_c.uses_count >= p_c.max_uses then raise exception 'COUPON_USED_UP'; end if;
  select count(*) into v_mine from public.coupon_redemptions r join public.orders o on o.id = r.order_id
   where r.coupon_code = p_c.code and r.user_id = p_user and o.status <> 'cancelled';
  if v_mine >= p_c.per_customer_limit then raise exception 'COUPON_ALREADY_USED'; end if;
  return least(p_subtotal,
               coalesce(floor(p_subtotal * p_c.percent_off / 100.0)::bigint, p_c.amount_off_minor));
end $$;
revoke all on function public._coupon_discount(public.coupons, uuid, bigint) from public, anon, authenticated;

-- the existing "10% off" slice becomes a real voucher slice
update public.wheel_segments set kind = 'discount', discount_percent = 10, valid_hours = 24 where kind = 'gift' and label_ar = 'خصم 10%';

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
                         from (select * from public.wheel_spins w where w.user_id = u and w.gift_status is not null order by w.created_at desc limit 30) g), '[]'::jsonb),
    'vouchers', coalesce((select jsonb_agg(jsonb_build_object('code', c.code, 'percent', c.percent_off, 'seconds_left', greatest(extract(epoch from (c.ends_at - now()))::int, 0),
                                  'in_order', ord.id is not null, 'order_ref', ord.reference) order by c.ends_at)
                            from public.wheel_vouchers v
                            join public.coupons c on c.code = v.coupon_code
                            left join lateral (select o.id, o.reference from public.coupon_redemptions r join public.orders o on o.id = r.order_id
                                                where r.coupon_code = c.code and r.user_id = u and o.status = 'pending_confirmation' limit 1) ord on true
                           where v.user_id = u
                             and not exists (select 1 from public.coupon_redemptions r join public.orders o on o.id = r.order_id
                                              where r.coupon_code = c.code and r.user_id = u and o.status not in ('cancelled', 'pending_confirmation'))
                             and (c.ends_at > now() or ord.id is not null)), '[]'::jsonb));
end $$;
revoke all on function public.wheel_state() from public, anon;
grant execute on function public.wheel_state() to authenticated;

create or replace function public.wheel_spin() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := public.require_auth(); v_staff boolean := coalesce(public.is_staff(), false); v_block text; st public.wheel_settings;
        f numeric; v_seg public.wheel_segments; v_id uuid := gen_random_uuid(); v_paid int; v_pts_on boolean := public._feature_on('points'); v_left int;
        v_code text; v_voucher jsonb;
begin
  if not public._feature_on('wheel') and not v_staff then raise exception 'FEATURE_OFF'; end if;
  perform pg_advisory_xact_lock(hashtextextended('lucky-wheel', 0));
  if not v_staff then
    v_block := public._wheel_block(u);
    if v_block is not null then raise exception '%', v_block; end if;
    if public._wheel_spins_left(u) <= 0 then raise exception 'NO_SPINS_LEFT'; end if;
  end if;
  select * into st from public.wheel_settings where id = 1;
  f := 0.25 + 1.5 * st.ease / 100.0;
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
    if v_seg.kind = 'discount' then
      v_code := 'W' || upper(substr(md5(gen_random_uuid()::text), 1, 9));
      insert into public.coupons (code, title_ar, percent_off, min_order_minor, max_uses, per_customer_limit, starts_at, ends_at, is_active, created_by)
        values (v_code, 'خصم من عجلة الحظ', v_seg.discount_percent, 0, null, 1, now(), now() + make_interval(hours => v_seg.valid_hours), true, u);
      insert into public.wheel_vouchers (user_id, spin_id, coupon_code) values (u, v_id, v_code);
      v_voucher := jsonb_build_object('code', v_code, 'percent', v_seg.discount_percent, 'hours', v_seg.valid_hours);
      perform public.notify_user(u, '🏷️ كسبت خصم ' || v_seg.discount_percent || '%', '🏷️ You won ' || v_seg.discount_percent || '% off',
        'الخصم محفوظ في حسابك لمدة ' || v_seg.valid_hours || ' ساعة ويُستخدم مرة واحدة. افتح عجلة الحظ واضغط «استخدمه» في طلبك.',
        'The discount is saved in your account for ' || v_seg.valid_hours || ' hours and works once. Open the lucky wheel and tap "Use it" for your order.',
        'system', null, null, '/wheel');
    end if;
  end if;
  v_left := case when v_staff then 99 else public._wheel_spins_left(u) end;
  return jsonb_build_object('segment_id', v_seg.id, 'kind', v_seg.kind, 'label_ar', v_seg.label_ar, 'label_en', v_seg.label_en,
    'points', case when v_staff then v_seg.points else v_paid end, 'spins_left', v_left, 'preview', v_staff,
    'discount_percent', v_seg.discount_percent, 'valid_hours', v_seg.valid_hours, 'voucher', v_voucher);
end $$;
revoke all on function public.wheel_spin() from public, anon;
grant execute on function public.wheel_spin() to authenticated;

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
         'discount_percent', s.discount_percent, 'valid_hours', s.valid_hours,
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
    if v_kind not in ('lose', 'points', 'gift', 'again', 'discount') or char_length(btrim(coalesce(s->>'label_ar', ''))) not between 1 and 30 then raise exception 'INVALID_INPUT'; end if;
    if v_kind = 'points' and coalesce((s->>'points')::int, 0) not between 1 and 100000 then raise exception 'INVALID_INPUT'; end if;
    if v_kind = 'discount' and (coalesce((s->>'discount_percent')::int, 0) not between 1 and 90 or coalesce((s->>'valid_hours')::int, 24) not between 1 and 48) then raise exception 'INVALID_INPUT'; end if;
    if coalesce((s->>'weight')::int, 0) not between 0 and 1000 then raise exception 'INVALID_INPUT'; end if;
    if coalesce((s->>'active')::boolean, true) then v_active := v_active + 1; v_total := v_total + coalesce((s->>'weight')::int, 0); end if;
  end loop;
  if v_active < 3 or v_total <= 0 then raise exception 'INVALID_INPUT'; end if;
  update public.wheel_settings set ease = coalesce((p->>'ease')::int, 50), spins_per_day = coalesce((p->>'spins_per_day')::int, 1),
         require_order = coalesce((p->>'require_order')::boolean, false), updated_at = now() where id = 1;
  delete from public.wheel_segments;
  for s in select * from jsonb_array_elements(p->'segments') loop
    i := i + 1;
    insert into public.wheel_segments (position, label_ar, label_en, kind, points, discount_percent, valid_hours, weight, daily_limit, active)
    values (i, btrim(s->>'label_ar'), coalesce(nullif(btrim(s->>'label_en'), ''), btrim(s->>'label_ar')), s->>'kind',
            case when s->>'kind' = 'points' then (s->>'points')::int end,
            case when s->>'kind' = 'discount' then (s->>'discount_percent')::int end,
            case when s->>'kind' = 'discount' then coalesce((s->>'valid_hours')::int, 24) else 24 end,
            (s->>'weight')::int,
            case when s->>'kind' in ('gift', 'points', 'discount') then nullif(s->>'daily_limit', '')::int end, coalesce((s->>'active')::boolean, true));
  end loop;
  perform public.audit_write('wheel.save', 'wheel', '1', jsonb_build_object('segments', v_active, 'ease', p->'ease'));
end $$;
revoke all on function public.wheel_admin_save(jsonb) from public, anon;
grant execute on function public.wheel_admin_save(jsonb) to authenticated;
