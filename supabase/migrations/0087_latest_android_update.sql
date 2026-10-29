-- 0087: the Android app asks for the newest build when it opens, before anyone signs in (the build info is public: the bucket is public).
create or replace function public.latest_android_update()
returns table (build int, path text, sha256 text, size_bytes bigint, notes text, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select r.build, r.path, r.sha256, r.size_bytes, r.notes, r.created_at
  from public.app_releases r where r.platform = 'android' order by r.build desc limit 1
$$;
revoke all on function public.latest_android_update() from public;
grant execute on function public.latest_android_update() to anon, authenticated;
