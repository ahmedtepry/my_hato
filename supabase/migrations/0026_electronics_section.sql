-- 0026 "Electronics" section (computer accessories, storage, smart home, small electronics) replaces "Used".
alter table public.categories drop constraint if exists categories_kind_check;
alter table public.categories add constraint categories_kind_check
  check (kind in ('phones','accessories','used','electronics'));
