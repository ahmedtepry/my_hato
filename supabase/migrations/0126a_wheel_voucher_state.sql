-- 0126a: a won wheel discount is a voucher with a random life of 1..24 hours (the owner's "hours" is the maximum).
-- The personal one-time code is created only when the customer taps it (wheel_voucher_claim, in 0126c).
alter table public.wheel_vouchers alter column coupon_code drop not null;
alter table public.wheel_vouchers add column if not exists expires_at timestamptz;
alter table public.wheel_vouchers add column if not exists percent int;

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
    'vouchers', coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'code', v.coupon_code, 'percent', v.percent,
                                  'seconds_left', greatest(extract(epoch from (v.expires_at - now()))::int, 0),
                                  'in_order', ord.id is not null, 'order_ref', ord.reference) order by v.expires_at)
                            from public.wheel_vouchers v
                            left join lateral (select o.id, o.reference from public.coupon_redemptions r join public.orders o on o.id = r.order_id
                                                where v.coupon_code is not null and r.coupon_code = v.coupon_code and r.user_id = u and o.status = 'pending_confirmation' limit 1) ord on true
                           where v.user_id = u and v.expires_at is not null
                             and not (v.coupon_code is not null and exists (select 1 from public.coupon_redemptions r join public.orders o on o.id = r.order_id
                                              where r.coupon_code = v.coupon_code and r.user_id = u and o.status not in ('cancelled', 'pending_confirmation')))
                             and (v.expires_at > now() or ord.id is not null)), '[]'::jsonb));
end $$;
