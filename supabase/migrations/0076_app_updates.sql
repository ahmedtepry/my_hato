-- 0076: in-app updates for the Windows team app. Every build is uploaded (by CI, through the app-update Edge Function)
-- to a public bucket and registered here; the app asks for the newest build and installs it when the member taps "update".

insert into storage.buckets (id, name, public, file_size_limit)
values ('app-updates', 'app-updates', true, 524288000)
on conflict (id) do update set public = true;

create table if not exists public.app_releases (
  id bigint generated always as identity primary key,
  platform text not null check (platform in ('windows')),
  build int not null,
  path text not null,
  sha256 text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  size_bytes bigint,
  notes text,
  created_at timestamptz not null default now(),
  unique (platform, build)
);
alter table public.app_releases enable row level security;
revoke all on public.app_releases from anon, authenticated;

-- the newest build for a platform (readable by every signed-in member of the team app)
create or replace function public.latest_app_update(p_platform text default 'windows')
returns table (build int, path text, sha256 text, size_bytes bigint, notes text, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_auth();
  if not public.is_staff() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return query select r.build, r.path, r.sha256, r.size_bytes, r.notes, r.created_at
    from public.app_releases r where r.platform = p_platform order by r.build desc limit 1;
end $$;
revoke all on function public.latest_app_update(text) from public, anon;
grant execute on function public.latest_app_update(text) to authenticated;

-- the build pipeline proves itself with a secret; only its SHA-256 is kept here
create table if not exists public.app_update_keys (key_hash text primary key check (key_hash ~ '^[0-9a-f]{64}$'), created_at timestamptz not null default now());
alter table public.app_update_keys enable row level security;
revoke all on public.app_update_keys from anon, authenticated;
insert into public.app_update_keys (key_hash) values ('f86e798ee2613c05d63c5e0aea1432694808680f1af6c55674001969f4381714') on conflict do nothing;
