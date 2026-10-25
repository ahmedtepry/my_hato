-- 0057: the owner can rename the app everywhere inside it, instantly. Only the owner account can do it (the app also asks for the password first).
-- Stored as application_settings.app_name = {"ar": "...", "en": "..."}; customers can read it.
insert into public.application_settings (key, value, description)
values ('app_name', '{"ar":"My Hatō","en":"My Hatō"}'::jsonb, 'Name of the app shown inside it, set by the owner')
on conflict (key) do nothing;

alter policy settings_public_read on public.application_settings
  using (key in ('default_currency','default_delivery_fee_minor','free_delivery_threshold_minor',
                 'enabled_payment_methods','repair_requires_approval','supported_locales','used_devices_enabled',
                 'legal_privacy_ar','legal_privacy_en','theme_palette','launch_animation','app_icon','app_name') or public.is_staff());

create or replace function public.set_app_name(p_ar text, p_en text)
returns void language plpgsql security definer set search_path = public as $$
declare v_ar text := btrim(coalesce(p_ar, '')); v_en text := btrim(coalesce(p_en, ''));
begin
  perform public.require_permission('appearance.manage');
  if not public.has_role('owner') then raise exception 'FORBIDDEN'; end if;
  if char_length(v_ar) not between 1 and 30 or char_length(v_en) not between 1 and 30
     or v_ar ~ '[[:cntrl:]]' or v_en ~ '[[:cntrl:]]' then
    raise exception 'INVALID_INPUT';
  end if;
  insert into public.application_settings (key, value, updated_by, updated_at)
  values ('app_name', jsonb_build_object('ar', v_ar, 'en', v_en), auth.uid(), now())
  on conflict (key) do update set value = excluded.value, updated_by = excluded.updated_by, updated_at = now();
end $$;
revoke all on function public.set_app_name(text, text) from public, anon;
grant execute on function public.set_app_name(text, text) to authenticated;
