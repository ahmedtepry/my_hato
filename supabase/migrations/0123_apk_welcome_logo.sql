-- 0123: "apk welcome logo": a robot welcome as the customers' opening animation (peek = waves, call = phone call on the M).
-- Switching it on needs the new permission appearance.welcome (owner by default). Stored in the same launch_animation setting,
-- so every customer app that has the new build plays it; older builds ignore the unknown value and keep their animation.
insert into public.permission_catalog (permission, grp, name_ar, name_en, desc_ar, desc_en, sensitive, inert, sort)
values ('appearance.welcome', 'system', 'تفعيل شاشة الترحيب (apk welcome logo)', 'Turn on the APK welcome logo',
        'يفعّل أو يقفل شاشة الترحيب بالروبوت في تطبيق العملاء لكل العملاء',
        'Turns the robot welcome on or off in the customer app for every customer', true, false, 48)
on conflict (permission) do update set name_ar = excluded.name_ar, name_en = excluded.name_en, desc_ar = excluded.desc_ar, desc_en = excluded.desc_en;
insert into public.role_permissions (role, permission) values ('owner', 'appearance.welcome') on conflict do nothing;

create or replace function public.set_appearance(p_palette jsonb, p_animation text, p_icon text)
returns void language plpgsql security definer set search_path = public as $$
declare k text; v_now text;
begin
  perform public.require_permission('appearance.manage');
  if p_animation not in ('classic','zoom','slide','liquid','orbit','phone','neon','pulse','bird','peek','call')
     or not (p_icon in ('default','a','b','c','liquid','orbit','phone','neon','pulse','bird')
             or p_icon ~ '^w([1-9]|10)[nel]$') then
    raise exception 'INVALID_INPUT';
  end if;
  -- the robot welcomes can only be switched on by whoever has appearance.welcome (keeping one that is already on is fine)
  if p_animation in ('peek','call') then
    select value #>> '{}' into v_now from public.application_settings where key = 'launch_animation';
    if v_now is distinct from p_animation then perform public.require_permission('appearance.welcome'); end if;
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

create or replace function public.welcome_logo_set(p_style text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.require_permission('appearance.welcome');
  if p_style not in ('off','peek','call') then raise exception 'INVALID_INPUT'; end if;
  insert into public.application_settings (key, value, updated_by, updated_at)
  values ('launch_animation', to_jsonb(case when p_style = 'off' then 'classic' else p_style end), auth.uid(), now())
  on conflict (key) do update set value = excluded.value, updated_by = excluded.updated_by, updated_at = now();
  perform public.audit_write('appearance.welcome', 'setting', 'launch_animation', jsonb_build_object('style', p_style));
end $$;
revoke all on function public.welcome_logo_set(text) from public, anon;
grant execute on function public.welcome_logo_set(text) to authenticated;
