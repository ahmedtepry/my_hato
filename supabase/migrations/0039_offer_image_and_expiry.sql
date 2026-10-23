-- 0039: offers sent to all customers can carry a picture, and disappear by themselves.
--   * notifications.image_url   optional picture (public 'banners' bucket, folder offers/)
--   * notifications.expires_at  after this moment the customer no longer sees the notification
--   * the read policy hides expired rows, so even older app versions stop showing them
--   * staff_broadcast_offer(title, body, code, image_url): offers expire after 30 minutes by default;
--     change it any time with:  update application_settings set value = '45' where key = 'offer_notification_minutes';
-- Order and repair notifications are untouched (no expiry).

alter table public.notifications add column if not exists image_url text;
alter table public.notifications add column if not exists expires_at timestamptz;
create index if not exists notifications_expiry_idx on public.notifications (expires_at) where expires_at is not null;

alter policy notifications_own_read on public.notifications
  using ((user_id = auth.uid() and cleared_at is null and (expires_at is null or expires_at > now()))
         or public.has_permission('customers.view'));

insert into public.application_settings (key, value, description)
values ('offer_notification_minutes', '30', 'Minutes an offer notification stays in the customer inbox before it disappears')
on conflict (key) do nothing;

-- the old 3-argument version is replaced by one with an optional 4th argument (old app versions keep working)
drop function if exists public.staff_broadcast_offer(text, text, text);
create or replace function public.staff_broadcast_offer(
  p_title text, p_body text, p_coupon_code text default null, p_image_url text default null)
returns int language plpgsql security definer set search_path = public as $$
declare
  v_code text := nullif(upper(trim(coalesce(p_coupon_code, ''))), '');
  v_img text := nullif(trim(coalesce(p_image_url, '')), '');
  v_link text;
  v_n int := 0;
  v_id uuid;
  v_set jsonb;
  v_minutes int := 30;
  r record;
begin
  perform public.require_permission('orders.manage');
  if nullif(trim(p_title), '') is null or nullif(trim(p_body), '') is null or length(p_title) > 120 or length(p_body) > 500 then
    raise exception 'INVALID_INPUT';
  end if;
  -- the picture must be one uploaded to our own offers folder
  if v_img is not null and (length(v_img) > 300
     or v_img !~ '^https://[a-z0-9]+\.supabase\.co/storage/v1/object/public/banners/offers/[A-Za-z0-9._-]+$') then
    raise exception 'INVALID_INPUT';
  end if;
  if v_code is not null and not exists (select 1 from public.coupons where code = v_code and is_active) then
    raise exception 'COUPON_INVALID';
  end if;
  -- at most 5 broadcasts a day, so customers are not spammed
  if (select count(*) from public.audit_logs where action = 'offer.broadcast' and created_at > now() - interval '24 hours') >= 5 then
    raise exception 'RATE_LIMITED';
  end if;
  v_set := public.setting('offer_notification_minutes');
  if v_set is not null and jsonb_typeof(v_set) in ('number', 'string') and (v_set #>> '{}') ~ '^[0-9]{1,5}$' then
    v_minutes := least(greatest((v_set #>> '{}')::int, 1), 10080);
  end if;
  v_link := case when v_code is null then '/' else '/cart?coupon=' || v_code end;
  for r in select p.id from public.profiles p
            where not exists (select 1 from public.user_roles ur where ur.user_id = p.id) loop
    v_id := public.notify_user(r.id, trim(p_title), trim(p_title), trim(p_body), trim(p_body), 'promo', null, v_code, v_link);
    update public.notifications set image_url = v_img, expires_at = now() + make_interval(mins => v_minutes) where id = v_id;
    v_n := v_n + 1;
  end loop;
  perform public.audit_write('offer.broadcast', 'coupon', coalesce(v_code, '-'),
    jsonb_build_object('title', p_title, 'sent', v_n, 'image', v_img is not null, 'expires_minutes', v_minutes));
  return v_n;
end $$;
revoke all on function public.staff_broadcast_offer(text, text, text, text) from public, anon;
grant execute on function public.staff_broadcast_offer(text, text, text, text) to authenticated;
