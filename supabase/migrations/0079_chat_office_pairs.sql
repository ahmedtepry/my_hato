-- 0079: office users (owner / manager) can also message each other, and every message knows who sent it.
-- A member <-> office thread stays as before. Between two office users the thread is keyed by the smaller user id (staff_id) with the
-- other one in peer_id, so both see the same conversation and each one's unread count is the messages sent by the other.

alter table public.chat_threads add column if not exists peer_id uuid references auth.users(id) on delete cascade;
create index if not exists chat_threads_peer_idx on public.chat_threads (peer_id) where peer_id is not null;

create or replace function public._chat_is_office(p_user uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.user_roles where user_id = p_user and role in ('owner', 'manager'))
$$;
revoke all on function public._chat_is_office(uuid) from public, anon, authenticated;

create or replace function public._chat_pair_thread(p_a uuid, p_b uuid, p_create boolean) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_lo uuid := least(p_a, p_b); v_hi uuid := greatest(p_a, p_b); v_id uuid; v_op timestamptz;
  v_today timestamptz := date_trunc('day', now() at time zone 'Africa/Cairo') at time zone 'Africa/Cairo';
begin
  select id, opened_at into v_id, v_op from public.chat_threads where staff_id = v_lo and peer_id = v_hi and closed_at is null order by opened_at desc limit 1;
  if v_id is not null and v_op < v_today then update public.chat_threads set closed_at = now() where id = v_id; v_id := null; end if;
  if v_id is null and p_create then
    insert into public.chat_threads (staff_id, peer_id) values (v_lo, v_hi) returning id into v_id;
  end if;
  return v_id;
end $$;
revoke all on function public._chat_pair_thread(uuid, uuid, boolean) from public, anon, authenticated;

-- the thread between the caller and p_other (member thread or office pair)
create or replace function public._chat_thread_with(p_other uuid, p_create boolean) returns uuid
language sql security definer set search_path = public as $$
  select case when public._chat_is_office(p_other) then public._chat_pair_thread(auth.uid(), p_other, p_create) else public._chat_thread_for(p_other, p_create) end
$$;
revoke all on function public._chat_thread_with(uuid, boolean) from public, anon, authenticated;

drop function if exists public._chat_msgs(uuid, timestamptz);
create or replace function public._chat_msgs(p_thread uuid, p_since timestamptz, p_office_view boolean) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(m order by m.created_at), '[]'::jsonb) from (
    select id, from_staff, body, created_at, (read_at is not null) as read, sender_id, public._ops_name(sender_id) as sender_name,
           (sender_id = auth.uid() or (p_office_view and not from_staff)) as mine
      from public.chat_messages
     where thread_id = p_thread and (p_since is null or created_at > p_since) order by created_at desc limit 300) m
$$;
revoke all on function public._chat_msgs(uuid, timestamptz, boolean) from public, anon, authenticated;

create or replace function public.chat_staff_fetch() returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_clr timestamptz;
begin
  perform public.require_permission('chat.use');
  v_id := public._chat_thread_for(auth.uid(), false);
  if v_id is null then return jsonb_build_object('thread_id', null, 'messages', '[]'::jsonb); end if;
  update public.chat_messages set read_at = now() where thread_id = v_id and sender_id <> auth.uid() and read_at is null;
  select staff_cleared_at into v_clr from public.chat_threads where id = v_id;
  return jsonb_build_object('thread_id', v_id, 'messages', public._chat_msgs(v_id, v_clr, false));
end $$;

create or replace function public.chat_unread() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if public.has_permission('chat.manage') then
    return jsonb_build_object('mode', 'manager',
      'count', (select count(*) from public.chat_messages m join public.chat_threads t on t.id = m.thread_id
                 where t.closed_at is null and m.read_at is null and m.sender_id <> auth.uid()
                   and (t.peer_id is null or t.staff_id = auth.uid() or t.peer_id = auth.uid())),
      'staff_id', (select case when t.peer_id is null then t.staff_id else m.sender_id end
                     from public.chat_messages m join public.chat_threads t on t.id = m.thread_id
                    where t.closed_at is null and m.read_at is null and m.sender_id <> auth.uid()
                      and (t.peer_id is null or t.staff_id = auth.uid() or t.peer_id = auth.uid())
                    order by m.created_at desc limit 1));
  elsif public.has_permission('chat.use') then
    return jsonb_build_object('mode', 'staff',
      'count', (select count(*) from public.chat_messages m join public.chat_threads t on t.id = m.thread_id
                 where t.staff_id = auth.uid() and t.peer_id is null and t.closed_at is null and m.sender_id <> auth.uid() and m.read_at is null
                   and (t.staff_cleared_at is null or m.created_at > t.staff_cleared_at)));
  end if;
  return jsonb_build_object('mode', 'none', 'count', 0);
end $$;

create or replace function public.chat_directory() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_permission('chat.manage');
  return coalesce((select jsonb_agg(x order by x.unread desc, x.last_at desc nulls last, x.name) from (
    select ur.user_id as staff_id, public._ops_name(ur.user_id) as name, (array_agg(ur.role::text))[1] as role,
           (tm.online and tm.last_seen_at > now() - interval '2 minutes') as online,
           coalesce((select count(*) from public.chat_messages m join public.chat_threads t on t.id = m.thread_id
                      where t.closed_at is null and m.read_at is null and m.sender_id <> auth.uid()
                        and ((t.peer_id is null and t.staff_id = ur.user_id)
                          or (t.peer_id is not null and ((t.staff_id = auth.uid() and t.peer_id = ur.user_id) or (t.staff_id = ur.user_id and t.peer_id = auth.uid()))))), 0) as unread,
           (select max(m.created_at) from public.chat_messages m join public.chat_threads t on t.id = m.thread_id
             where t.closed_at is null and ((t.peer_id is null and t.staff_id = ur.user_id)
                or (t.peer_id is not null and ((t.staff_id = auth.uid() and t.peer_id = ur.user_id) or (t.staff_id = ur.user_id and t.peer_id = auth.uid()))))) as last_at
      from public.user_roles ur left join public.team_members tm on tm.user_id = ur.user_id
     where ur.user_id <> auth.uid() and (tm.suspended_at is null)
     group by ur.user_id, tm.online, tm.last_seen_at) x), '[]'::jsonb);
end $$;

create or replace function public.chat_manager_fetch(p_staff uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_pair boolean;
begin
  perform public.require_permission('chat.manage');
  v_pair := public._chat_is_office(p_staff);
  v_id := public._chat_thread_with(p_staff, false);
  if v_id is null then return jsonb_build_object('thread_id', null, 'name', public._ops_name(p_staff), 'messages', '[]'::jsonb); end if;
  update public.chat_messages set read_at = now() where thread_id = v_id and sender_id <> auth.uid() and read_at is null;
  return jsonb_build_object('thread_id', v_id, 'name', public._ops_name(p_staff), 'messages', public._chat_msgs(v_id, null, not v_pair),
    'shift_id', (select shift_id from public.chat_threads where id = v_id));
end $$;

create or replace function public.chat_manager_send(p_staff uuid, p_body text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_body text := btrim(coalesce(p_body, '')); v_from_staff boolean;
begin
  perform public.require_permission('chat.manage');
  if char_length(v_body) < 1 or char_length(v_body) > 1000 then raise exception 'INVALID_INPUT'; end if;
  if p_staff = auth.uid() or not exists (select 1 from public.user_roles where user_id = p_staff) then raise exception 'INVALID_INPUT'; end if;
  v_id := public._chat_thread_with(p_staff, true);
  v_from_staff := exists (select 1 from public.chat_threads where id = v_id and peer_id is not null and staff_id = auth.uid());
  insert into public.chat_messages (thread_id, sender_id, from_staff, body) values (v_id, auth.uid(), v_from_staff, v_body);
  return jsonb_build_object('ok', true, 'thread_id', v_id);
end $$;

drop function if exists public.chat_thread_messages(uuid);
create or replace function public.chat_thread_messages(p_thread uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_permission('chat.logs');
  return public._chat_msgs(p_thread, null, false);
end $$;

create or replace function public.chat_logs(p_staff uuid default null, p_limit int default 200) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_permission('chat.logs');
  return coalesce((select jsonb_agg(x order by x.opened_at desc) from (
    select t.id, t.staff_id, public._ops_name(t.staff_id) as staff_name, t.peer_id, case when t.peer_id is null then null else public._ops_name(t.peer_id) end as peer_name,
           t.shift_id, b.name_ar as branch_name_ar, t.opened_at, t.closed_at,
           (select count(*) from public.chat_messages m where m.thread_id = t.id) as msg_count,
           (select left(m.body, 80) from public.chat_messages m where m.thread_id = t.id order by m.created_at desc limit 1) as last_body
      from public.chat_threads t left join public.branches b on b.id = t.branch_id
     where (p_staff is null or t.staff_id = p_staff or t.peer_id = p_staff) and exists (select 1 from public.chat_messages m where m.thread_id = t.id)
     order by t.opened_at desc limit least(greatest(coalesce(p_limit, 200), 1), 500)) x), '[]'::jsonb);
end $$;

revoke all on function public.chat_staff_fetch(), public.chat_unread(), public.chat_directory(), public.chat_manager_fetch(uuid), public.chat_manager_send(uuid, text),
  public.chat_thread_messages(uuid), public.chat_logs(uuid, int) from public, anon;
grant execute on function public.chat_staff_fetch(), public.chat_unread(), public.chat_directory(), public.chat_manager_fetch(uuid), public.chat_manager_send(uuid, text),
  public.chat_thread_messages(uuid), public.chat_logs(uuid, int) to authenticated;
