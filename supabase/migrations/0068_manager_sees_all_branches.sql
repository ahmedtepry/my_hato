-- 0068: the manager sees every branch and head office by default (the owner can still switch it off for a role or a person).
insert into public.role_permissions (role, permission) values ('manager', 'branches.all') on conflict do nothing;

-- Team app colour theme. Every employee picks his own on his own device (nothing stored here);
-- only the owner can set one for everybody, and only through the app (this function).
insert into public.application_settings (key, value, description)
values ('team_theme', '{"theme":"default","v":0}'::jsonb, 'Colour theme of the team app for everyone (set by the owner from the app)')
on conflict (key) do nothing;

create or replace function public.team_theme_get() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_staff() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return coalesce((select value from public.application_settings where key = 'team_theme'), '{"theme":"default","v":0}'::jsonb);
end $$;

create or replace function public.owner_set_team_theme(p_theme text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_v bigint := (extract(epoch from clock_timestamp()) * 1000)::bigint; v_val jsonb;
begin
  perform public.require_auth();
  if not public.has_role('owner') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_theme is null or p_theme !~ '^[a-z0-9_]{1,24}$' then raise exception 'INVALID_INPUT'; end if;
  v_val := jsonb_build_object('theme', p_theme, 'v', v_v);
  insert into public.application_settings (key, value, description, updated_by, updated_at)
  values ('team_theme', v_val, 'Colour theme of the team app for everyone (set by the owner from the app)', auth.uid(), now())
  on conflict (key) do update set value = excluded.value, updated_by = auth.uid(), updated_at = now();
  perform public.audit_write('team_theme.set', 'settings', 'team_theme', jsonb_build_object('theme', p_theme));
  return v_val;
end $$;
revoke all on function public.team_theme_get(), public.owner_set_team_theme(text) from public, anon;
grant execute on function public.team_theme_get(), public.owner_set_team_theme(text) to authenticated;
