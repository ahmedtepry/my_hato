-- 0054: each team member arranges their own console: the order of the sections and which ones (up to 4) sit in the bottom bar.
-- It is stored on the account, so it follows the member to any phone, and nobody can see or change another member's layout.
create table if not exists public.staff_console_prefs (
  user_id uuid primary key references auth.users(id) on delete cascade,
  section_order text[] not null default '{}',
  pinned text[] not null default '{}',
  updated_at timestamptz not null default now()
);
alter table public.staff_console_prefs enable row level security;
drop policy if exists console_prefs_own on public.staff_console_prefs;
create policy console_prefs_own on public.staff_console_prefs for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
revoke all on public.staff_console_prefs from anon;
grant select, insert, update on public.staff_console_prefs to authenticated;
