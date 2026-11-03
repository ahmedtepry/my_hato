-- 0126c: tapping the voucher creates the customer's own one-time code (valid until the voucher expires) and returns it.
create or replace function public.wheel_voucher_claim(p_id uuid) returns text
language plpgsql security definer set search_path = public as $$
declare u uuid := public.require_auth(); v public.wheel_vouchers; v_code text;
begin
  select * into v from public.wheel_vouchers where id = p_id and user_id = u for update;
  if not found then raise exception 'COUPON_INVALID'; end if;
  if v.coupon_code is not null then
    if exists (select 1 from public.coupon_redemptions r join public.orders o on o.id = r.order_id
                where r.coupon_code = v.coupon_code and r.user_id = u and o.status <> 'cancelled' and o.status <> 'pending_confirmation') then
      raise exception 'COUPON_ALREADY_USED';
    end if;
    return v.coupon_code;
  end if;
  if v.expires_at is null or v.expires_at <= now() then raise exception 'COUPON_EXPIRED'; end if;
  v_code := 'W' || upper(substr(md5(gen_random_uuid()::text), 1, 9));
  insert into public.coupons (code, title_ar, percent_off, min_order_minor, max_uses, per_customer_limit, starts_at, ends_at, is_active, created_by)
    values (v_code, 'خصم من عجلة الحظ', v.percent, 0, null, 1, now(), v.expires_at, true, u);
  update public.wheel_vouchers set coupon_code = v_code where id = v.id;
  return v_code;
end $$;
revoke all on function public.wheel_voucher_claim(uuid) from public, anon;
grant execute on function public.wheel_voucher_claim(uuid) to authenticated;
