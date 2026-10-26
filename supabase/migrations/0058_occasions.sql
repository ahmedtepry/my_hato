-- 0058: occasions (Ramadan, Eid al-Fitr, Eid al-Adha, 6 October). The owner (or a team member the owner gives the permission to)
-- puts a small stamp on the app logo for everyone, then sends a greeting with a new discount code or loyalty coins.
-- Permission occasions.manage: the owner has it and can give it to a role or one account from the permissions screen.
insert into public.role_permissions (role, permission) values ('owner', 'occasions.manage') on conflict do nothing;
insert into public.permission_catalog (permission, grp, name_ar, name_en, desc_ar, desc_en, sensitive, inert, sort)
values ('occasions.manage', 'system', 'يدير المناسبات', 'Manage occasions',
        'يضيف ختم المناسبة على شعار التطبيق عند كل العملاء، ويبعت التهنئة بكود خصم أو كوينات',
        'Puts the occasion stamp on the app logo for every customer and sends the greeting with a discount code or coins', true, false, 48)
on conflict (permission) do nothing;

insert into public.application_settings (key, value, description)
values ('active_occasion', '{}'::jsonb, 'The occasion running now: {"key": ramadan|fitr|adha|oct6, "stamp": ...}. Empty when none.')
on conflict (key) do nothing;

alter policy settings_public_read on public.application_settings
  using (key in ('default_currency','default_delivery_fee_minor','free_delivery_threshold_minor',
                 'enabled_payment_methods','repair_requires_approval','supported_locales','used_devices_enabled',
                 'legal_privacy_ar','legal_privacy_en','theme_palette','launch_animation','app_icon','app_name','active_occasion') or public.is_staff());

-- turns an occasion on (with the chosen stamp) or off (empty key)
create or replace function public.set_occasion(p_key text, p_stamp text)
returns void language plpgsql security definer set search_path = public as $$
declare v_key text := coalesce(p_key, '');
begin
  perform public.require_permission('occasions.manage');
  if v_key = '' then
    insert into public.application_settings (key, value, updated_by, updated_at) values ('active_occasion', '{}'::jsonb, auth.uid(), now())
    on conflict (key) do update set value = '{}'::jsonb, updated_by = excluded.updated_by, updated_at = now();
    perform public.audit_write('occasion.end', 'occasion', '-', '{}'::jsonb);
    return;
  end if;
  if not ((v_key = 'ramadan' and p_stamp in ('crescent','lantern','both'))
       or (v_key = 'fitr'    and p_stamp in ('crescent_star','lantern','stars'))
       or (v_key = 'adha'    and p_stamp in ('crescent_star','crescent','stars'))
       or (v_key = 'oct6'    and p_stamp in ('flag','bunting','star'))) then
    raise exception 'INVALID_INPUT';
  end if;
  insert into public.application_settings (key, value, updated_by, updated_at)
  values ('active_occasion', jsonb_build_object('key', v_key, 'stamp', p_stamp), auth.uid(), now())
  on conflict (key) do update set value = excluded.value, updated_by = excluded.updated_by, updated_at = now();
  perform public.audit_write('occasion.start', 'occasion', v_key, jsonb_build_object('stamp', p_stamp));
end $$;
revoke all on function public.set_occasion(text, text) from public, anon;
grant execute on function public.set_occasion(text, text) to authenticated;

-- sends the greeting. p_gift: 'code' (creates a discount code), 'coins' (adds loyalty points, once per customer per occasion and year), or 'none'.
-- Returns how many customers received the notification.
create or replace function public.occasion_send(p_key text, p_year int, p_title text, p_body text, p_gift text,
  p_code text default null, p_percent int default null, p_valid_days int default 7, p_coins int default null, p_scope text default 'all')
returns int language plpgsql security definer set search_path = public as $$
declare
  v_code text := nullif(upper(trim(coalesce(p_code, ''))), '');
  v_n int := 0; v_id uuid; v_link text := '/'; r record;
begin
  perform public.require_permission('occasions.manage');
  if p_key not in ('ramadan','fitr','adha','oct6') or p_year not between 2026 and 2100 or p_gift not in ('code','coins','none')
     or nullif(trim(coalesce(p_title, '')), '') is null or nullif(trim(coalesce(p_body, '')), '') is null
     or length(p_title) > 120 or length(p_body) > 500 or p_scope not in ('all','active') then
    raise exception 'INVALID_INPUT';
  end if;
  if (select count(*) from public.audit_logs where action in ('offer.broadcast','occasion.send') and created_at > now() - interval '24 hours') >= 5 then
    raise exception 'RATE_LIMITED';
  end if;
  if p_gift = 'code' then
    if v_code is null or v_code !~ '^[A-Z0-9_-]{3,24}$' or p_percent is null or p_percent not between 1 and 90
       or p_valid_days is null or p_valid_days not between 1 and 90 then
      raise exception 'INVALID_INPUT';
    end if;
    insert into public.coupons(code, title_ar, percent_off, min_order_minor, per_customer_limit, ends_at, is_active, created_by)
    values (v_code, left(trim(p_title), 60), p_percent, 0, 1, now() + make_interval(days => p_valid_days), true, auth.uid())
    on conflict (code) do update set percent_off = excluded.percent_off, ends_at = excluded.ends_at, is_active = true, title_ar = excluded.title_ar;
    v_link := '/cart?coupon=' || v_code;
  elsif p_gift = 'coins' then
    if p_coins is null or p_coins not between 1 and 5000 then raise exception 'INVALID_INPUT'; end if;
    v_code := null;
  else
    v_code := null;
  end if;
  for r in select p.id from public.profiles p
            where not exists (select 1 from public.user_roles ur where ur.user_id = p.id)
              and (p_scope = 'all' or exists (select 1 from public.orders o where o.customer_id = p.id and o.created_at > now() - interval '90 days')) loop
    if p_gift = 'coins' then
      perform public._loy_ensure(r.id);
      perform public._loy_grant(r.id, 'occasion', p_key || '-' || p_year, p_coins, 0);   -- adds to the account level only, never the vault; once per occasion per year
    end if;
    v_id := public.notify_user(r.id, trim(p_title), trim(p_title), trim(p_body), trim(p_body), 'promo', null, v_code, v_link);
    update public.notifications set expires_at = now() + interval '3 days' where id = v_id;
    v_n := v_n + 1;
  end loop;
  perform public.audit_write('occasion.send', 'occasion', p_key, jsonb_build_object('year', p_year, 'gift', p_gift, 'sent', v_n, 'coins', p_coins, 'scope', p_scope));
  return v_n;
end $$;
revoke all on function public.occasion_send(text, int, text, text, text, text, int, int, int, text) from public, anon;
grant execute on function public.occasion_send(text, int, text, text, text, text, int, int, int, text) to authenticated;
