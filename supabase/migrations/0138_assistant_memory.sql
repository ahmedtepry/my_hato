-- The owner's assistant remembers him: facts he asked it to keep and a rolling list of his recent requests.
-- Only the edge function (service role) reads/writes it.
create table if not exists public.assistant_memory (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null check (kind in ('fact','request')),
  content text not null check (char_length(content) between 1 and 600),
  created_at timestamptz not null default now()
);
create index if not exists assistant_memory_user_idx on public.assistant_memory (user_id, kind, created_at desc);
alter table public.assistant_memory enable row level security;
revoke all on public.assistant_memory from anon, authenticated;
