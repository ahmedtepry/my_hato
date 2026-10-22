-- 0021 Built-in cartoon avatars: the customer picks one of 8 (m1–m4, f1–f4) instead of uploading a photo.
alter table public.profiles add column if not exists avatar_id text
  check (avatar_id is null or avatar_id in ('m1','m2','m3','m4','f1','f2','f3','f4'));
grant update (avatar_id) on public.profiles to authenticated;
