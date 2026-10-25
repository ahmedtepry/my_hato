-- 0056: the owner controls the look of the app for everyone: five colours, the opening animation and the launcher icon.
-- Stored in application_settings (keys theme_palette, launch_animation, app_icon), readable by customers, changed only through
-- set_appearance(), which needs the new permission appearance.manage (owner by default).
insert into public.role_permissions (role, permission) values ('owner', 'appearance.manage') on conflict do nothing;
insert into public.permission_catalog (permission, grp, name_ar, name_en, desc_ar, desc_en, sensitive, inert, sort)
values ('appearance.manage', 'system', 'يغيّر مظهر التطبيق', 'Change app appearance',
        'يغيّر ألوان التطبيق وأيقونته وحركة فتحه لكل العملاء',
        'Changes the app colours, icon and opening animation for every customer', true, false, 47)
on conflict (permission) do nothing;

insert into public.application_settings (key, value, description) values
  ('theme_palette', '{"primary":"#0B2D5B","accent":"#00A3FF","background":"#F8F9FA","success":"#12B76A","danger":"#D92D20"}'::jsonb, 'App colours (hex), set from the console'),
  ('launch_animation', '"classic"'::jsonb, 'Opening animation: classic | zoom | slide'),
  ('app_icon', '"default"'::jsonb, 'Launcher icon: default | a | b | c')
on conflict (key) do nothing;

alter policy settings_public_read on public.application_settings
  using (key in ('default_currency','default_delivery_fee_minor','free_delivery_threshold_minor',
                 'enabled_payment_methods','repair_requires_approval','supported_locales','used_devices_enabled',
                 'legal_privacy_ar','legal_privacy_en','theme_palette','launch_animation','app_icon') or public.is_staff());

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'application_settings') then
    alter publication supabase_realtime add table public.application_settings;
  end if;
end $$;

create or replace function public.set_appearance(p_palette jsonb, p_animation text, p_icon text)
returns void language plpgsql security definer set search_path = public as $$
declare k text;
begin
  perform public.require_permission('appearance.manage');
  if p_animation not in ('classic','zoom','slide') or p_icon not in ('default','a','b','c') then
    raise exception 'INVALID_INPUT';
  end if;
  if jsonb_typeof(p_palette) is distinct from 'object' then raise exception 'INVALID_INPUT'; end if;
  foreach k in array array['primary','accent','background','success','danger'] loop
    if coalesce(p_palette ->> k, '') !~ '^#[0-9A-Fa-f]{6}$' then raise exception 'INVALID_INPUT'; end if;
  end loop;
  insert into public.application_settings (key, value, updated_by, updated_at) values
    ('theme_palette', jsonb_build_object('primary', upper(p_palette->>'primary'), 'accent', upper(p_palette->>'accent'),
       'background', upper(p_palette->>'background'), 'success', upper(p_palette->>'success'), 'danger', upper(p_palette->>'danger')), auth.uid(), now()),
    ('launch_animation', to_jsonb(p_animation), auth.uid(), now()),
    ('app_icon', to_jsonb(p_icon), auth.uid(), now())
  on conflict (key) do update set value = excluded.value, updated_by = excluded.updated_by, updated_at = now();
end $$;
revoke all on function public.set_appearance(jsonb, text, text) from public, anon;
grant execute on function public.set_appearance(jsonb, text, text) to authenticated;
