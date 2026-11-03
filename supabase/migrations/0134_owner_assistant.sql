-- 0134: the owner's chat assistant (Android app "MyHato Owner" -> Edge Function owner-assistant).
-- Writes are two steps: the assistant proposes (stored here), the owner confirms in a LATER message, then it runs as the owner (all permission checks apply).
create table if not exists public.assistant_pending (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  turn text not null,
  tool text not null,
  args jsonb not null default '{}'::jsonb,
  summary text not null,
  created_at timestamptz not null default now()
);
create index if not exists assistant_pending_user on public.assistant_pending (user_id, created_at desc);
alter table public.assistant_pending enable row level security;
revoke all on public.assistant_pending from anon, authenticated;

-- one audit line per action the assistant performed (the action itself is also audited by its own function)
create or replace function public.assistant_audit(p_tool text, p_summary text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.user_roles where user_id = auth.uid() and role = 'owner') then raise exception 'FORBIDDEN'; end if;
  perform public.audit_write('owner_ai.action', 'system', coalesce(p_tool, ''), jsonb_build_object('summary', left(coalesce(p_summary, ''), 500)));
end $$;
revoke all on function public.assistant_audit(text, text) from public, anon;
grant execute on function public.assistant_audit(text, text) to authenticated;
