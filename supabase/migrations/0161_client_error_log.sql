-- Automatic error log from the apps: when a screen breaks, the app reports it here (rate limited, trimmed, no personal data).
create table if not exists public.client_errors (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  user_id uuid,
  platform text,
  build int,
  message text not null,
  stack text
);
alter table public.client_errors enable row level security;
revoke all on public.client_errors from anon, authenticated;
create index if not exists client_errors_created_idx on public.client_errors (created_at desc);

create or replace function public.log_client_error(p_message text, p_stack text, p_platform text, p_build int)
returns void
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare v_ip text;
begin
  if coalesce(p_message, '') = '' then return; end if;
  v_ip := coalesce(split_part(coalesce(nullif(current_setting('request.headers', true), '')::json ->> 'x-forwarded-for', ''), ',', 1), '');
  if not public.hit_rate_limit('client_error', encode(digest('ip:' || v_ip, 'sha256'), 'hex'), 3600, 40) then return; end if;
  insert into public.client_errors(user_id, platform, build, message, stack)
  values (auth.uid(), left(p_platform, 20), p_build, left(p_message, 600), left(p_stack, 2500));
  -- keep the log small
  delete from public.client_errors where created_at < now() - interval '30 days';
end $$;
revoke all on function public.log_client_error(text, text, text, int) from public;
grant execute on function public.log_client_error(text, text, text, int) to anon, authenticated;
