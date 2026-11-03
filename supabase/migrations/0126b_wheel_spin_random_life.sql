-- 0126b: spinning a discount slice stores a voucher that lives a random 1..N hours (N = the slice's hours, at most 24).
create or replace function public.wheel_spin() returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := public.require_auth(); v_staff boolean := coalesce(public.is_staff(), false); v_block text; st public.wheel_settings;
        f numeric; v_seg public.wheel_segments; v_id uuid := gen_random_uuid(); v_paid int; v_pts_on boolean := public._feature_on('points'); v_left int;
        v_vid uuid; v_mins int; v_voucher jsonb;
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
      v_mins := 60 + floor(random() * (least(greatest(v_seg.valid_hours, 1), 24) * 60 - 60 + 1))::int;
      insert into public.wheel_vouchers (user_id, spin_id, percent, expires_at)
        values (u, v_id, v_seg.discount_percent, now() + make_interval(mins => v_mins)) returning id into v_vid;
      v_voucher := jsonb_build_object('id', v_vid, 'percent', v_seg.discount_percent, 'minutes', v_mins);
      perform public.notify_user(u, '🏷️ كسبت خصم ' || v_seg.discount_percent || '%', '🏷️ You won ' || v_seg.discount_percent || '% off',
        'الخصم محفوظ في حسابك لفترة قصيرة ويُستخدم مرة واحدة. افتح عجلة الحظ واضغط عليه لتستخدمه في طلبك.',
        'The discount is saved in your account for a short time and works once. Open the lucky wheel and tap it to use it on your order.',
        'system', null, null, '/wheel');
    end if;
  end if;
  v_left := case when v_staff then 99 else public._wheel_spins_left(u) end;
  return jsonb_build_object('segment_id', v_seg.id, 'kind', v_seg.kind, 'label_ar', v_seg.label_ar, 'label_en', v_seg.label_en,
    'points', case when v_staff then v_seg.points else v_paid end, 'spins_left', v_left, 'preview', v_staff,
    'discount_percent', v_seg.discount_percent, 'voucher', v_voucher);
end $$;
revoke all on function public.wheel_spin() from public, anon;
grant execute on function public.wheel_spin() to authenticated;
