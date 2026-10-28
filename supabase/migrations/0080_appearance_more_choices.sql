-- Six more icon + opening-animation choices: liquid, orbit, phone, neon, pulse, bird.
create or replace function public.set_appearance(p_palette jsonb, p_animation text, p_icon text)
returns void language plpgsql security definer set search_path = public as $$
declare k text;
begin
  perform public.require_permission('appearance.manage');
  if p_animation not in ('classic','zoom','slide','liquid','orbit','phone','neon','pulse','bird')
     or p_icon not in ('default','a','b','c','liquid','orbit','phone','neon','pulse','bird') then
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
