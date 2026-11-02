-- 0125: the owner picks the look of the Windows team login (permission appearance.login, owner by default).
-- The login is shown before anyone is signed in, so the key must be readable by anon like the other look settings.
insert into public.permission_catalog (permission, grp, name_ar, name_en, desc_ar, desc_en, sensitive, inert, sort)
values ('appearance.login', 'system', 'شكل شاشة دخول الفريق (ويندوز)', 'Windows team login look',
        'يغيّر شكل شاشة الدخول في برنامج الويندوز لكل الفريق', 'Changes the sign-in screen of the Windows app for the whole team', false, false, 49)
on conflict (permission) do update set name_ar = excluded.name_ar, name_en = excluded.name_en, desc_ar = excluded.desc_ar, desc_en = excluded.desc_en;
insert into public.role_permissions (role, permission) values ('owner', 'appearance.login') on conflict do nothing;

drop policy if exists settings_public_read on public.application_settings;
create policy settings_public_read on public.application_settings for select to anon, authenticated using (
  key = any (array['default_currency','default_delivery_fee_minor','free_delivery_threshold_minor','enabled_payment_methods','repair_requires_approval',
                   'supported_locales','used_devices_enabled','legal_privacy_ar','legal_privacy_en','theme_palette','launch_animation','app_icon',
                   'app_name','active_occasion','team_login_style'])
  or public.is_staff());

create or replace function public.team_login_set(p_style text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.require_permission('appearance.login');
  if p_style not in ('split','hello','classic') then raise exception 'INVALID_INPUT'; end if;
  insert into public.application_settings (key, value, updated_by, updated_at)
  values ('team_login_style', to_jsonb(p_style), auth.uid(), now())
  on conflict (key) do update set value = excluded.value, updated_by = excluded.updated_by, updated_at = now();
  perform public.audit_write('appearance.login', 'setting', 'team_login_style', jsonb_build_object('style', p_style));
end $$;
revoke all on function public.team_login_set(text) from public, anon;
grant execute on function public.team_login_set(text) to authenticated;
