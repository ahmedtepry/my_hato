-- 0015 Repair tracking without an account: repair number + the mobile number on the request.
--
-- Both must match. Only non-sensitive status data is returned (guest_repair_public_view: status,
-- device model, costs, timeline) — never name, address, IMEI, photos or notes. A miss returns the
-- same answer whether or not the repair number exists. Attempts are limited per repair number
-- (6 / 15 min) and per client IP (30 / hour) through the existing rate_limits table.
-- Replaces the SMS-code flow, which needed an SMS provider.

create or replace function public.guest_repair_lookup(p_reference text, p_phone text)
returns jsonb language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_digits text := regexp_replace(translate(coalesce(p_reference, ''), '٠١٢٣٤٥٦٧٨٩', '0123456789'), '[^0-9]', '', 'g');
  v_ref text;
  v_phone text := public.normalize_eg_mobile(p_phone);
  v_ip text;
  v_id uuid;
begin
  if v_digits = '' or length(v_digits) > 10 or v_phone is null then
    return jsonb_build_object('found', false, 'error', 'INVALID_INPUT');
  end if;
  v_ref := 'MY-HATO' || (v_digits::bigint)::text;   -- "75", "MY-HATO075", "my hato 75" -> MY-HATO75

  v_ip := coalesce(split_part(coalesce(current_setting('request.headers', true)::json ->> 'x-forwarded-for', ''), ',', 1), '');
  if not public.hit_rate_limit('guest_lookup_ref', encode(digest(v_ref, 'sha256'), 'hex'), 900, 6)
     or not public.hit_rate_limit('guest_lookup_ip', encode(digest('ip:' || v_ip, 'sha256'), 'hex'), 3600, 30) then
    return jsonb_build_object('found', false, 'error', 'RATE_LIMITED');
  end if;

  select r.id into v_id
    from public.repair_requests r
    left join public.customers c on c.user_id = r.customer_id
    left join public.profiles p on p.id = r.customer_id
   where r.reference = v_ref
     and (public.normalize_eg_mobile(r.contact_phone) = v_phone
          or c.phone = v_phone
          or (p.phone_verified and public.normalize_eg_mobile(p.phone) = v_phone));
  if v_id is null then
    return jsonb_build_object('found', false);
  end if;
  return jsonb_build_object('found', true, 'repair', public.guest_repair_public_view(v_ref));
end $$;

revoke all on function public.guest_repair_lookup(text, text) from public;
grant execute on function public.guest_repair_lookup(text, text) to anon, authenticated;
