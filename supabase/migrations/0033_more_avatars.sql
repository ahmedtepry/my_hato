-- 0033 Eight more avatars: m5–m8 (older men) and f5–f8 (incl. niqab and hijab styles).
alter table public.profiles drop constraint if exists profiles_avatar_id_check;
alter table public.profiles add constraint profiles_avatar_id_check
  check (avatar_id is null or avatar_id ~ '^[mf][1-8]$');
