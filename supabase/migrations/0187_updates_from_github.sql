-- Update files are downloaded from GitHub Releases (free, no download limit) instead of Supabase Storage, which put
-- the project over the Free plan (4.7 GB of installers, Nov 2026). app_releases.url = the GitHub download link;
-- apps from this version on use it. Older apps still read `path` (a Supabase copy of the newest build only).
alter table public.app_releases add column if not exists url text;
update public.app_releases set url = case platform
    when 'windows' then 'https://github.com/ahmedtepry/my_hato/releases/download/team-win-' || build || '/MyHatoTeam-Setup.exe'
    when 'android' then 'https://github.com/ahmedtepry/my_hato/releases/download/build-' || build || '/myhato-release.apk'
    when 'android_owner' then 'https://github.com/ahmedtepry/my_hato/releases/download/owner-' || build || '/MyHatoOwner.apk' end
 where url is null;

drop function if exists public.latest_android_update();
create function public.latest_android_update()
returns table(build integer, path text, sha256 text, size_bytes bigint, notes text, created_at timestamptz, url text)
language sql stable security definer set search_path = public as $$
  select r.build, r.path, r.sha256, r.size_bytes, r.notes, r.created_at, r.url
  from public.app_releases r where r.platform = 'android' order by r.build desc limit 1
$$;
grant execute on function public.latest_android_update() to anon, authenticated;

drop function if exists public.latest_owner_update();
create function public.latest_owner_update()
returns table(build integer, path text, sha256 text, size_bytes bigint, notes text, created_at timestamptz, url text)
language sql stable security definer set search_path = public as $$
  select r.build, r.path, r.sha256, r.size_bytes, r.notes, r.created_at, r.url
  from public.app_releases r where r.platform = 'android_owner' order by r.build desc limit 1
$$;
grant execute on function public.latest_owner_update() to anon, authenticated;

drop function if exists public.latest_app_update(text);
create function public.latest_app_update(p_platform text default 'windows')
returns table(build integer, path text, sha256 text, size_bytes bigint, notes text, created_at timestamptz, url text)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_auth();
  if p_platform not in ('windows', 'android') then raise exception 'INVALID_INPUT'; end if;
  if p_platform = 'windows' and not public.is_staff() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return query select r.build, r.path, r.sha256, r.size_bytes, r.notes, r.created_at, r.url
    from public.app_releases r where r.platform = p_platform order by r.build desc limit 1;
end $$;
revoke all on function public.latest_app_update(text) from public, anon;
grant execute on function public.latest_app_update(text) to authenticated;

drop function if exists public.latest_windows_update_for_device(text);
create function public.latest_windows_update_for_device(p_key text)
returns table(build integer, path text, sha256 text, size_bytes bigint, notes text, created_at timestamptz, url text)
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  if p_key is null or length(p_key) < 32 or length(p_key) > 200 or not exists (
    select 1 from public.staff_quick_devices d join public.team_members tm on tm.user_id = d.user_id
     where d.key_hash = encode(digest(p_key, 'sha256'), 'hex') and d.revoked_at is null and tm.suspended_at is null) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return query select r.build, r.path, r.sha256, r.size_bytes, r.notes, r.created_at, r.url
    from public.app_releases r where r.platform = 'windows' order by r.build desc limit 1;
end $$;
revoke all on function public.latest_windows_update_for_device(text) from public;
grant execute on function public.latest_windows_update_for_device(text) to anon, authenticated;
