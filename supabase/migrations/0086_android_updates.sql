-- 0086: in-app updates for the Android app too (same table as Windows). Any signed-in member may ask for the newest Android build
-- (customers and team alike); the Windows build is still for team members only.
alter table public.app_releases drop constraint if exists app_releases_platform_check;
alter table public.app_releases add constraint app_releases_platform_check check (platform in ('windows', 'android'));

create or replace function public.latest_app_update(p_platform text default 'windows')
returns table (build int, path text, sha256 text, size_bytes bigint, notes text, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_auth();
  if p_platform not in ('windows', 'android') then raise exception 'INVALID_INPUT'; end if;
  if p_platform = 'windows' and not public.is_staff() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return query select r.build, r.path, r.sha256, r.size_bytes, r.notes, r.created_at
    from public.app_releases r where r.platform = p_platform order by r.build desc limit 1;
end $$;
revoke all on function public.latest_app_update(text) from public, anon;
grant execute on function public.latest_app_update(text) to authenticated;
