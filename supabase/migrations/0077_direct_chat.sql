-- 0077: direct chat between a team member and the office.
-- One conversation ("thread") per member per shift; it closes together with the shift. The member sees only the open one
-- (and can clear his own view); the owner keeps every thread in the logs until he deletes it (selected, or all closed ones).
-- Permissions: chat.use (talk to the office), chat.manage (answer members), chat.logs (read the logs), chat.purge (delete logs).

insert into public.permission_catalog (permission, grp, name_ar, name_en, desc_ar, desc_en, sensitive, inert, sort) values
 ('chat.use', 'system', 'شات مباشر مع الإدارة', 'Direct chat with the office', 'يبعت رسالة مباشرة للمدير (خصم أو أي حاجة سريعة) وهي بتتقفل مع الوردية', 'Sends the manager a direct message (a discount, anything quick); it closes with the shift', false, false, 73),
 ('chat.manage', 'system', 'الرسايل المباشرة مع الموظفين', 'Direct messages with members', 'يرد على الموظفين ويبدأ رسالة مع أي موظف', 'Answers members and starts a message with any member', true, false, 74),
 ('chat.logs', 'system', 'سجل الرسايل المباشرة', 'Direct message logs', 'يرجع لكل المحادثات المسجلة (للتقفيلات والفلوس)', 'Reads every recorded conversation (for closings and money)', true, false, 75),
 ('chat.purge', 'system', 'مسح سجل الرسايل', 'Delete message logs', 'يمسح محادثات محددة أو كل المقفولة عشان المساحة', 'Deletes chosen conversations or every closed one to save space', true, false, 76)
on conflict (permission) do update set name_ar = excluded.name_ar, name_en = excluded.name_en, desc_ar = excluded.desc_ar, desc_en = excluded.desc_en, sensitive = excluded.sensitive, inert = false;

insert into public.role_permissions (role, permission)
select r, 'chat.use' from unnest(array['cashier','accountant','sales','technician','support','manager']::public.app_role[]) r
on conflict do nothing;
insert into public.role_permissions (role, permission) values
 ('owner', 'chat.manage'), ('manager', 'chat.manage'), ('owner', 'chat.logs'), ('owner', 'chat.purge')
on conflict do nothing;

create table if not exists public.chat_threads (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references auth.users(id) on delete cascade,
  shift_id uuid references public.shifts(id) on delete set null,
  branch_id uuid,
  opened_at timestamptz not null default now(),
  closed_at timestamptz,
  staff_cleared_at timestamptz
);
create index if not exists chat_threads_staff_idx on public.chat_threads (staff_id, closed_at);
create index if not exists chat_threads_shift_idx on public.chat_threads (shift_id);
create table if not exists public.chat_messages (
  id uuid primary key default gen_random_uuid(),
  thread_id uuid not null references public.chat_threads(id) on delete cascade,
  sender_id uuid not null,
  from_staff boolean not null,
  body text not null check (char_length(body) between 1 and 1000),
  created_at timestamptz not null default now(),
  read_at timestamptz
);
create index if not exists chat_messages_thread_idx on public.chat_messages (thread_id, created_at);
alter table public.chat_threads enable row level security;
alter table public.chat_messages enable row level security;
revoke all on public.chat_threads, public.chat_messages from public, anon, authenticated;

-- the open thread of a member (created on demand); a thread with no shift ends at midnight (Cairo), one with a shift ends with it
create or replace function public._chat_thread_for(p_staff uuid, p_create boolean) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_sh uuid; v_op timestamptz; v_today timestamptz := date_trunc('day', now() at time zone 'Africa/Cairo') at time zone 'Africa/Cairo';
  v_shift uuid; v_branch uuid;
begin
  select id, shift_id, opened_at into v_id, v_sh, v_op from public.chat_threads where staff_id = p_staff and closed_at is null order by opened_at desc limit 1;
  if v_id is not null and v_sh is null and v_op < v_today then
    update public.chat_threads set closed_at = now() where id = v_id; v_id := null;
  end if;
  select id, branch_id into v_shift, v_branch from public.shifts where cashier_id = p_staff and status = 'open' order by opened_at desc limit 1;
  if v_id is not null and v_sh is null and v_shift is not null then
    update public.chat_threads set shift_id = v_shift, branch_id = v_branch where id = v_id;
  end if;
  if v_id is null and p_create then
    insert into public.chat_threads (staff_id, shift_id, branch_id) values (p_staff, v_shift, v_branch) returning id into v_id;
  end if;
  return v_id;
end $$;
revoke all on function public._chat_thread_for(uuid, boolean) from public, anon, authenticated;

create or replace function public._chat_close_with_shift() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'closed' and old.status is distinct from 'closed' then
    update public.chat_threads set closed_at = now() where shift_id = new.id and closed_at is null;
  end if;
  return new;
end $$;
revoke all on function public._chat_close_with_shift() from public, anon, authenticated;
drop trigger if exists chat_close_with_shift on public.shifts;
create trigger chat_close_with_shift after update of status on public.shifts for each row execute function public._chat_close_with_shift();

create or replace function public._chat_msgs(p_thread uuid, p_since timestamptz) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(m order by m.created_at), '[]'::jsonb) from (
    select id, from_staff, body, created_at, (read_at is not null) as read from public.chat_messages
     where thread_id = p_thread and (p_since is null or created_at > p_since) order by created_at desc limit 300) m
$$;
revoke all on function public._chat_msgs(uuid, timestamptz) from public, anon, authenticated;

-- ---- the member's side
create or replace function public.chat_staff_fetch() returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_clr timestamptz;
begin
  perform public.require_permission('chat.use');
  v_id := public._chat_thread_for(auth.uid(), false);
  if v_id is null then return jsonb_build_object('thread_id', null, 'messages', '[]'::jsonb); end if;
  update public.chat_messages set read_at = now() where thread_id = v_id and not from_staff and read_at is null;
  select staff_cleared_at into v_clr from public.chat_threads where id = v_id;
  return jsonb_build_object('thread_id', v_id, 'messages', public._chat_msgs(v_id, v_clr));
end $$;

create or replace function public.chat_staff_send(p_body text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_body text := btrim(coalesce(p_body, ''));
begin
  perform public.require_permission('chat.use');
  if char_length(v_body) < 1 or char_length(v_body) > 1000 then raise exception 'INVALID_INPUT'; end if;
  v_id := public._chat_thread_for(auth.uid(), true);
  insert into public.chat_messages (thread_id, sender_id, from_staff, body) values (v_id, auth.uid(), true, v_body);
  return jsonb_build_object('ok', true, 'thread_id', v_id);
end $$;

create or replace function public.chat_staff_clear() returns void
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  perform public.require_permission('chat.use');
  v_id := public._chat_thread_for(auth.uid(), false);
  if v_id is not null then update public.chat_threads set staff_cleared_at = now() where id = v_id; end if;
end $$;

-- how many new messages are waiting (for the badge and for opening the panel by itself)
create or replace function public.chat_unread() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if public.has_permission('chat.manage') then
    return jsonb_build_object('mode', 'manager',
      'count', (select count(*) from public.chat_messages m join public.chat_threads t on t.id = m.thread_id where t.closed_at is null and m.from_staff and m.read_at is null),
      'staff_id', (select t.staff_id from public.chat_messages m join public.chat_threads t on t.id = m.thread_id
                    where t.closed_at is null and m.from_staff and m.read_at is null order by m.created_at desc limit 1));
  elsif public.has_permission('chat.use') then
    return jsonb_build_object('mode', 'staff',
      'count', (select count(*) from public.chat_messages m join public.chat_threads t on t.id = m.thread_id
                 where t.staff_id = auth.uid() and t.closed_at is null and not m.from_staff and m.read_at is null
                   and (t.staff_cleared_at is null or m.created_at > t.staff_cleared_at)));
  end if;
  return jsonb_build_object('mode', 'none', 'count', 0);
end $$;

-- ---- the office's side
create or replace function public.chat_directory() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_permission('chat.manage');
  return coalesce((select jsonb_agg(x order by x.unread desc, x.last_at desc nulls last, x.name) from (
    select ur.user_id as staff_id, public._ops_name(ur.user_id) as name, (array_agg(ur.role::text))[1] as role,
           (tm.online and tm.last_seen_at > now() - interval '2 minutes') as online,
           coalesce((select count(*) from public.chat_messages m join public.chat_threads t on t.id = m.thread_id
                      where t.staff_id = ur.user_id and t.closed_at is null and m.from_staff and m.read_at is null), 0) as unread,
           (select max(m.created_at) from public.chat_messages m join public.chat_threads t on t.id = m.thread_id where t.staff_id = ur.user_id and t.closed_at is null) as last_at
      from public.user_roles ur left join public.team_members tm on tm.user_id = ur.user_id
     where ur.user_id <> auth.uid() and (tm.suspended_at is null)
     group by ur.user_id, tm.online, tm.last_seen_at) x), '[]'::jsonb);
end $$;

create or replace function public.chat_manager_fetch(p_staff uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  perform public.require_permission('chat.manage');
  v_id := public._chat_thread_for(p_staff, false);
  if v_id is null then return jsonb_build_object('thread_id', null, 'name', public._ops_name(p_staff), 'messages', '[]'::jsonb); end if;
  update public.chat_messages set read_at = now() where thread_id = v_id and from_staff and read_at is null;
  return jsonb_build_object('thread_id', v_id, 'name', public._ops_name(p_staff), 'messages', public._chat_msgs(v_id, null),
    'shift_id', (select shift_id from public.chat_threads where id = v_id));
end $$;

create or replace function public.chat_manager_send(p_staff uuid, p_body text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_body text := btrim(coalesce(p_body, ''));
begin
  perform public.require_permission('chat.manage');
  if char_length(v_body) < 1 or char_length(v_body) > 1000 then raise exception 'INVALID_INPUT'; end if;
  if p_staff = auth.uid() or not exists (select 1 from public.user_roles where user_id = p_staff) then raise exception 'INVALID_INPUT'; end if;
  v_id := public._chat_thread_for(p_staff, true);
  insert into public.chat_messages (thread_id, sender_id, from_staff, body) values (v_id, auth.uid(), false, v_body);
  return jsonb_build_object('ok', true, 'thread_id', v_id);
end $$;

-- ---- logs
create or replace function public.chat_logs(p_staff uuid default null, p_limit int default 200) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_permission('chat.logs');
  return coalesce((select jsonb_agg(x order by x.opened_at desc) from (
    select t.id, t.staff_id, public._ops_name(t.staff_id) as staff_name, t.shift_id, b.name_ar as branch_name_ar, t.opened_at, t.closed_at,
           (select count(*) from public.chat_messages m where m.thread_id = t.id) as msg_count,
           (select left(m.body, 80) from public.chat_messages m where m.thread_id = t.id order by m.created_at desc limit 1) as last_body
      from public.chat_threads t left join public.branches b on b.id = t.branch_id
     where (p_staff is null or t.staff_id = p_staff) and exists (select 1 from public.chat_messages m where m.thread_id = t.id)
     order by t.opened_at desc limit least(greatest(coalesce(p_limit, 200), 1), 500)) x), '[]'::jsonb);
end $$;

create or replace function public.chat_thread_messages(p_thread uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_permission('chat.logs');
  return public._chat_msgs(p_thread, null);
end $$;

-- deletes the chosen conversations; "all" deletes every CLOSED one (a conversation still open is live and stays)
create or replace function public.chat_logs_delete(p_threads uuid[] default null, p_all boolean default false) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  perform public.require_permission('chat.purge');
  with d as (
    delete from public.chat_threads where (p_all and closed_at is not null) or id = any(coalesce(p_threads, '{}'::uuid[])) returning id
  ) select count(*) into n from d;
  perform public.audit_write('chat.purge', 'chat', null, jsonb_build_object('count', n, 'all', coalesce(p_all, false)));
  return n;
end $$;

revoke all on function public.chat_staff_fetch(), public.chat_staff_send(text), public.chat_staff_clear(), public.chat_unread(), public.chat_directory(),
  public.chat_manager_fetch(uuid), public.chat_manager_send(uuid, text), public.chat_logs(uuid, int), public.chat_thread_messages(uuid), public.chat_logs_delete(uuid[], boolean) from public, anon;
grant execute on function public.chat_staff_fetch(), public.chat_staff_send(text), public.chat_staff_clear(), public.chat_unread(), public.chat_directory(),
  public.chat_manager_fetch(uuid), public.chat_manager_send(uuid, text), public.chat_logs(uuid, int), public.chat_thread_messages(uuid), public.chat_logs_delete(uuid[], boolean) to authenticated;
