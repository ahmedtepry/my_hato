-- The Windows team app may check for a new build on the sign-in screen, but only on a computer where a team member
-- already signed in (it holds a quick-login device key, see 0182). Applied live.
create or replace function public.latest_windows_update_for_device(p_key text)
returns table(build integer, path text, sha256 text, size_bytes bigint, notes text, created_at timestamptz)
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  if p_key is null or length(p_key) < 32 or length(p_key) > 200 or not exists (
    select 1 from public.staff_quick_devices d join public.team_members tm on tm.user_id = d.user_id
     where d.key_hash = encode(digest(p_key, 'sha256'), 'hex') and d.revoked_at is null and tm.suspended_at is null) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return query select r.build, r.path, r.sha256, r.size_bytes, r.notes, r.created_at
    from public.app_releases r where r.platform = 'windows' order by r.build desc limit 1;
end $$;
revoke all on function public.latest_windows_update_for_device(text) from public;
grant execute on function public.latest_windows_update_for_device(text) to anon, authenticated;
