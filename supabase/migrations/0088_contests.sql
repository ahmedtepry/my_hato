-- 0088: contests ("وريّنا شطارتك"): the owner writes 1-3 questions, a motivating text and a prize, picks the audience (team, customers or everyone)
-- and the time (how long the contest runs + how long each person has to answer), publishes it (everyone in the audience gets a notification),
-- watches the entries and announces the winners. Permission contest.manage (owner by default; the owner can give it to others).
-- Answers are graded in the database; the right answers never leave it before the contest ends.

insert into public.permission_catalog (permission, grp, name_ar, name_en, desc_ar, desc_en, sensitive, inert, sort) values
 ('contest.manage', 'team', 'يدير المسابقات', 'Manage contests',
  'يكتب أسئلة المسابقة ونص التحفيز والجايزة، يحدد المدة والجمهور (الفريق أو العملاء)، ينشرها ويبعت الإشعار، يشوف النتايج ويعلن الفايزين',
  'Writes the contest questions, motivating text and prize, sets the time and audience (team or customers), publishes it with a notification, sees the entries and announces the winners', false, false, 98)
on conflict (permission) do update set name_ar = excluded.name_ar, name_en = excluded.name_en, desc_ar = excluded.desc_ar, desc_en = excluded.desc_en;
insert into public.role_permissions (role, permission) values ('owner', 'contest.manage') on conflict do nothing;

create table if not exists public.contests (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(title) between 3 and 80),
  intro text check (intro is null or char_length(intro) <= 500),
  audience text not null default 'all' check (audience in ('team', 'customers', 'all')),
  duration_minutes int not null default 60 check (duration_minutes between 1 and 10080),
  answer_seconds int check (answer_seconds is null or answer_seconds between 10 and 3600),
  winners_count int not null default 1 check (winners_count between 1 and 50),
  prize text check (prize is null or char_length(prize) <= 200),
  reveal_answers boolean not null default true,
  status text not null default 'draft' check (status in ('draft', 'live', 'closed')),
  starts_at timestamptz,
  ends_at timestamptz,
  notified_at timestamptz,
  announced_at timestamptz,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table if not exists public.contest_questions (
  id uuid primary key default gen_random_uuid(),
  contest_id uuid not null references public.contests(id) on delete cascade,
  position int not null check (position between 1 and 3),
  body text not null check (char_length(body) between 3 and 400),
  kind text not null default 'text' check (kind in ('text', 'choice')),
  options text[] not null default '{}',
  correct text check (correct is null or char_length(correct) <= 200),   -- text: accepted answers separated by | ; choice: the right option
  unique (contest_id, position)
);
create table if not exists public.contest_entries (
  id uuid primary key default gen_random_uuid(),
  contest_id uuid not null references public.contests(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  started_at timestamptz not null default now(),
  submitted_at timestamptz,
  answers jsonb not null default '{}',
  correct_count int not null default 0,
  graded_total int not null default 0,
  is_winner boolean not null default false,
  unique (contest_id, user_id)
);
create index if not exists contest_entries_contest_idx on public.contest_entries (contest_id);
alter table public.contests enable row level security;
alter table public.contest_questions enable row level security;
alter table public.contest_entries enable row level security;
revoke all on public.contests, public.contest_questions, public.contest_entries from anon, authenticated;

-- same wording on both sides: lower case, no diacritics, أإآ=ا ة=ه ى=ي, Arabic digits = Latin digits, one space between words
create or replace function public._contest_norm(t text) returns text
language sql immutable as $$
  select btrim(regexp_replace(lower(translate(
    regexp_replace(coalesce(t, ''), '[ً-ْـ]', '', 'g'),
    'أإآٱةى٠١٢٣٤٥٦٧٨٩', 'اااايي0123456789')), '\s+', ' ', 'g'))
$$;

create or replace function public._contest_is_team(p_user uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.user_roles where user_id = p_user)
$$;
revoke all on function public._contest_is_team(uuid) from public, anon, authenticated;

create or replace function public._contest_visible(p_aud text, p_user uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select p_aud = 'all' or (p_aud = 'team' and public._contest_is_team(p_user)) or (p_aud = 'customers' and not public._contest_is_team(p_user))
$$;
revoke all on function public._contest_visible(text, uuid) from public, anon, authenticated;

-- ---------- owner side ----------
create or replace function public.contest_admin_list() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_permission('contest.manage');
  return coalesce((select jsonb_agg(x order by x.created_at desc) from (
    select c.id, c.title, c.audience, c.status, c.duration_minutes, c.answer_seconds, c.winners_count, c.prize, c.starts_at, c.ends_at, c.announced_at, c.created_at,
      case when c.status = 'live' and now() < c.ends_at then 'running' when c.status = 'live' then 'ended' else c.status end as state,
      (select count(*) from public.contest_questions q where q.contest_id = c.id) as questions,
      (select count(*) from public.contest_entries e where e.contest_id = c.id) as entries,
      (select count(*) from public.contest_entries e where e.contest_id = c.id and e.submitted_at is not null) as submitted
    from public.contests c order by c.created_at desc limit 100) x), '[]'::jsonb);
end $$;
revoke all on function public.contest_admin_list() from public, anon;
grant execute on function public.contest_admin_list() to authenticated;

create or replace function public.contest_admin_get(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  perform public.require_permission('contest.manage');
  select to_jsonb(c) || jsonb_build_object(
      'questions', coalesce((select jsonb_agg(jsonb_build_object('id', q.id, 'position', q.position, 'body', q.body, 'kind', q.kind, 'options', q.options, 'correct', q.correct) order by q.position)
                             from public.contest_questions q where q.contest_id = c.id), '[]'::jsonb),
      'entries', (select count(*) from public.contest_entries e where e.contest_id = c.id))
    into v from public.contests c where c.id = p_id;
  if v is null then raise exception 'NOT_FOUND'; end if;
  return v;
end $$;
revoke all on function public.contest_admin_get(uuid) from public, anon;
grant execute on function public.contest_admin_get(uuid) to authenticated;

-- create (p_id null) or edit a contest and its 1-3 questions. Once someone has entered, the questions are locked (copy it as a new contest instead).
create or replace function public.contest_save(p_id uuid, p_data jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid := p_id; q jsonb; v_pos int := 0; v_kind text; v_opts text[]; v_correct text; v_n int;
begin
  perform public.require_permission('contest.manage');
  if jsonb_typeof(p_data -> 'questions') <> 'array' then raise exception 'INVALID_INPUT'; end if;
  v_n := jsonb_array_length(p_data -> 'questions');
  if v_n not between 1 and 3 then raise exception 'INVALID_INPUT'; end if;
  if nullif(btrim(p_data ->> 'title'), '') is null then raise exception 'INVALID_INPUT'; end if;
  if v_id is not null then
    if not exists (select 1 from public.contests where id = v_id) then raise exception 'NOT_FOUND'; end if;
    if exists (select 1 from public.contest_entries where contest_id = v_id) then raise exception 'HAS_ENTRIES'; end if;
    update public.contests set
      title = btrim(p_data ->> 'title'), intro = nullif(btrim(coalesce(p_data ->> 'intro', '')), ''),
      audience = coalesce(p_data ->> 'audience', 'all'), duration_minutes = coalesce((p_data ->> 'duration_minutes')::int, 60),
      answer_seconds = nullif(p_data ->> 'answer_seconds', '')::int, winners_count = coalesce((p_data ->> 'winners_count')::int, 1),
      prize = nullif(btrim(coalesce(p_data ->> 'prize', '')), ''), reveal_answers = coalesce((p_data ->> 'reveal_answers')::boolean, true),
      updated_at = now()
    where id = v_id;
    delete from public.contest_questions where contest_id = v_id;
  else
    insert into public.contests (title, intro, audience, duration_minutes, answer_seconds, winners_count, prize, reveal_answers, created_by)
    values (btrim(p_data ->> 'title'), nullif(btrim(coalesce(p_data ->> 'intro', '')), ''), coalesce(p_data ->> 'audience', 'all'),
      coalesce((p_data ->> 'duration_minutes')::int, 60), nullif(p_data ->> 'answer_seconds', '')::int, coalesce((p_data ->> 'winners_count')::int, 1),
      nullif(btrim(coalesce(p_data ->> 'prize', '')), ''), coalesce((p_data ->> 'reveal_answers')::boolean, true), auth.uid())
    returning id into v_id;
  end if;
  for q in select * from jsonb_array_elements(p_data -> 'questions') loop
    v_pos := v_pos + 1;
    v_kind := coalesce(q ->> 'kind', 'text');
    if v_kind not in ('text', 'choice') then raise exception 'INVALID_INPUT'; end if;
    v_opts := '{}';
    if v_kind = 'choice' then
      select coalesce(array_agg(btrim(o)), '{}') into v_opts from jsonb_array_elements_text(coalesce(q -> 'options', '[]'::jsonb)) o where btrim(o) <> '';
      if coalesce(array_length(v_opts, 1), 0) not between 2 and 4 then raise exception 'INVALID_INPUT'; end if;
    end if;
    v_correct := nullif(btrim(coalesce(q ->> 'correct', '')), '');
    if v_kind = 'choice' and v_correct is not null and not (v_correct = any (v_opts)) then raise exception 'INVALID_INPUT'; end if;
    insert into public.contest_questions (contest_id, position, body, kind, options, correct)
    values (v_id, v_pos, btrim(q ->> 'body'), v_kind, v_opts, v_correct);
  end loop;
  perform public.audit_write('contest.save', 'contest', v_id::text, jsonb_build_object('title', p_data ->> 'title', 'questions', v_n));
  return v_id;
end $$;
revoke all on function public.contest_save(uuid, jsonb) from public, anon;
grant execute on function public.contest_save(uuid, jsonb) to authenticated;

-- publish: the contest starts now, lasts duration_minutes, and everyone in the audience is notified (once, unless p_notify is true again)
create or replace function public.contest_publish(p_id uuid, p_notify boolean default true) returns int
language plpgsql security definer set search_path = public as $$
declare c public.contests; v_n int := 0; r record; v_id uuid; v_body text;
begin
  perform public.require_permission('contest.manage');
  select * into c from public.contests where id = p_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if c.status = 'closed' then raise exception 'INVALID_INPUT'; end if;
  if not exists (select 1 from public.contest_questions where contest_id = p_id) then raise exception 'INVALID_INPUT'; end if;
  if c.status = 'draft' or c.ends_at is null or now() >= c.ends_at then
    update public.contests set status = 'live', starts_at = now(), ends_at = now() + make_interval(mins => c.duration_minutes), updated_at = now() where id = p_id;
  end if;
  select * into c from public.contests where id = p_id;
  if p_notify then
    v_body := coalesce(c.intro, 'شارك في المسابقة وورّينا شطارتك.') || case when c.prize is not null then ' 🎁 ' || c.prize else '' end;
    for r in select p.id from public.profiles p
              where p.deletion_requested_at is null and public._contest_visible(c.audience, p.id) loop
      v_id := public.notify_user(r.id, '🏆 ' || c.title, '🏆 ' || c.title, v_body, v_body, 'promo', null, null, '/');
      update public.notifications set expires_at = c.ends_at where id = v_id;
      v_n := v_n + 1;
    end loop;
    update public.contests set notified_at = now() where id = p_id;
  end if;
  perform public.audit_write('contest.publish', 'contest', p_id::text, jsonb_build_object('notified', v_n, 'audience', c.audience));
  return v_n;
end $$;
revoke all on function public.contest_publish(uuid, boolean) from public, anon;
grant execute on function public.contest_publish(uuid, boolean) to authenticated;

-- stop it early (closed) or take it back to a draft (only while nobody has entered)
create or replace function public.contest_set_status(p_id uuid, p_status text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.require_permission('contest.manage');
  if p_status not in ('draft', 'closed') then raise exception 'INVALID_INPUT'; end if;
  if p_status = 'draft' and exists (select 1 from public.contest_entries where contest_id = p_id) then raise exception 'HAS_ENTRIES'; end if;
  update public.contests set status = p_status, ends_at = case when p_status = 'closed' then least(coalesce(ends_at, now()), now()) else ends_at end, updated_at = now() where id = p_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  perform public.audit_write('contest.status', 'contest', p_id::text, jsonb_build_object('status', p_status));
end $$;
revoke all on function public.contest_set_status(uuid, text) from public, anon;
grant execute on function public.contest_set_status(uuid, text) to authenticated;

-- give a running contest more time
create or replace function public.contest_extend(p_id uuid, p_minutes int) returns timestamptz
language plpgsql security definer set search_path = public as $$
declare v_end timestamptz;
begin
  perform public.require_permission('contest.manage');
  if p_minutes is null or p_minutes not between 1 and 10080 then raise exception 'INVALID_INPUT'; end if;
  update public.contests set status = 'live', ends_at = greatest(coalesce(ends_at, now()), now()) + make_interval(mins => p_minutes), updated_at = now()
   where id = p_id and status in ('live', 'closed') returning ends_at into v_end;
  if v_end is null then raise exception 'NOT_FOUND'; end if;
  perform public.audit_write('contest.extend', 'contest', p_id::text, jsonb_build_object('minutes', p_minutes));
  return v_end;
end $$;
revoke all on function public.contest_extend(uuid, int) from public, anon;
grant execute on function public.contest_extend(uuid, int) to authenticated;

create or replace function public.contest_delete(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.require_permission('contest.manage');
  delete from public.contests where id = p_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  perform public.audit_write('contest.delete', 'contest', p_id::text, '{}'::jsonb);
end $$;
revoke all on function public.contest_delete(uuid) from public, anon;
grant execute on function public.contest_delete(uuid) to authenticated;

-- the entries, best first (most right answers, then fastest)
create or replace function public.contest_results(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  perform public.require_permission('contest.manage');
  if not exists (select 1 from public.contests where id = p_id) then raise exception 'NOT_FOUND'; end if;
  select coalesce(jsonb_agg(x order by x.correct_count desc, x.seconds asc nulls last, x.started_at), '[]'::jsonb) into v from (
    select e.id as entry_id, e.user_id, coalesce(nullif(btrim(p.full_name), ''), p.email, p.phone, 'عميل') as name, p.phone,
           public._contest_is_team(e.user_id) as is_team, e.correct_count, e.graded_total, e.is_winner, e.started_at, e.submitted_at, e.answers,
           case when e.submitted_at is not null then extract(epoch from (e.submitted_at - e.started_at))::int end as seconds
      from public.contest_entries e left join public.profiles p on p.id = e.user_id where e.contest_id = p_id) x;
  return v;
end $$;
revoke all on function public.contest_results(uuid) from public, anon;
grant execute on function public.contest_results(uuid) to authenticated;

create or replace function public.contest_set_winner(p_entry uuid, p_win boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.require_permission('contest.manage');
  update public.contest_entries set is_winner = coalesce(p_win, false) where id = p_entry;
  if not found then raise exception 'NOT_FOUND'; end if;
end $$;
revoke all on function public.contest_set_winner(uuid, boolean) from public, anon;
grant execute on function public.contest_set_winner(uuid, boolean) to authenticated;

-- closes the contest and tells the winners. Winners = the ones the owner ticked; if none ticked, the best graded entries (up to winners_count, at least one right answer).
create or replace function public.contest_announce(p_id uuid) returns int
language plpgsql security definer set search_path = public as $$
declare c public.contests; v_n int := 0; r record; v_id uuid; v_body text;
begin
  perform public.require_permission('contest.manage');
  select * into c from public.contests where id = p_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if not exists (select 1 from public.contest_entries where contest_id = p_id and is_winner) then
    update public.contest_entries set is_winner = true
     where id in (select id from public.contest_entries where contest_id = p_id and submitted_at is not null and correct_count > 0
                   order by correct_count desc, (submitted_at - started_at) asc limit c.winners_count);
  end if;
  update public.contests set status = 'closed', ends_at = least(coalesce(ends_at, now()), now()), announced_at = now(), updated_at = now() where id = p_id;
  v_body := 'مبروك! فزت في مسابقة «' || c.title || '»' || case when c.prize is not null then '. جايزتك: ' || c.prize else '' end;
  for r in select user_id from public.contest_entries where contest_id = p_id and is_winner loop
    v_id := public.notify_user(r.user_id, '🏆 مبروك، إنت من الفايزين!', '🏆 Congratulations, you won!', v_body, v_body, 'system', null, null, '/');
    v_n := v_n + 1;
  end loop;
  perform public.audit_write('contest.announce', 'contest', p_id::text, jsonb_build_object('winners', v_n));
  return v_n;
end $$;
revoke all on function public.contest_announce(uuid) from public, anon;
grant execute on function public.contest_announce(uuid) to authenticated;

-- ---------- participant side (team and customers) ----------
-- the contests this member can enter right now
create or replace function public.contest_active() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_me uuid := auth.uid();
begin
  perform public.require_auth();
  return coalesce((select jsonb_agg(x order by x.ends_at) from (
    select c.id, c.title, c.intro, c.prize, c.ends_at, c.answer_seconds,
      case when e.id is null then 'new'
           when e.submitted_at is not null then 'done'
           when c.answer_seconds is not null and now() > e.started_at + make_interval(secs => c.answer_seconds + 3) then 'missed'
           else 'running' end as state,
      case when e.id is not null and e.submitted_at is null then least(c.ends_at, case when c.answer_seconds is null then c.ends_at else e.started_at + make_interval(secs => c.answer_seconds) end) end as my_deadline
    from public.contests c left join public.contest_entries e on e.contest_id = c.id and e.user_id = v_me
    where c.status = 'live' and now() between c.starts_at and c.ends_at and public._contest_visible(c.audience, v_me)) x), '[]'::jsonb);
end $$;
revoke all on function public.contest_active() from public, anon;
grant execute on function public.contest_active() to authenticated;

-- opens the contest for this member: starts his personal clock the first time and returns the questions (never the right answers)
create or replace function public.contest_open(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := auth.uid(); c public.contests; e public.contest_entries; v_deadline timestamptz; v_state text;
  v_q jsonb; v_reveal jsonb := null;
begin
  perform public.require_auth();
  select * into c from public.contests where id = p_id;
  if not found or c.status = 'draft' or not public._contest_visible(c.audience, v_me) then raise exception 'NOT_FOUND'; end if;
  select * into e from public.contest_entries where contest_id = p_id and user_id = v_me;
  if not found then
    if c.status <> 'live' or now() not between c.starts_at and c.ends_at then raise exception 'CONTEST_CLOSED'; end if;
    insert into public.contest_entries (contest_id, user_id) values (p_id, v_me) returning * into e;
  end if;
  v_deadline := least(c.ends_at, case when c.answer_seconds is null then c.ends_at else e.started_at + make_interval(secs => c.answer_seconds) end);
  v_state := case when e.submitted_at is not null then 'done' when now() > v_deadline + interval '3 seconds' then 'missed' else 'running' end;
  select coalesce(jsonb_agg(jsonb_build_object('id', q.id, 'position', q.position, 'body', q.body, 'kind', q.kind, 'options', q.options) order by q.position), '[]'::jsonb)
    into v_q from public.contest_questions q where q.contest_id = p_id;
  if v_state <> 'running' and c.reveal_answers and (c.status = 'closed' or now() > c.ends_at) then
    select jsonb_object_agg(q.id::text, q.correct) into v_reveal from public.contest_questions q where q.contest_id = p_id and q.correct is not null;
  end if;
  return jsonb_build_object('id', c.id, 'title', c.title, 'intro', c.intro, 'prize', c.prize, 'state', v_state, 'ends_at', c.ends_at,
    'deadline', v_deadline, 'now', now(), 'questions', case when v_state = 'running' then v_q else '[]'::jsonb end,
    'correct_count', e.correct_count, 'graded_total', e.graded_total, 'my_answers', case when v_state = 'running' then null else e.answers end,
    'answers_reveal', v_reveal, 'is_winner', e.is_winner);
end $$;
revoke all on function public.contest_open(uuid) from public, anon;
grant execute on function public.contest_open(uuid) to authenticated;

create or replace function public.contest_submit(p_id uuid, p_answers jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := auth.uid(); c public.contests; e public.contest_entries; v_deadline timestamptz;
  q record; v_a text; v_ok int := 0; v_tot int := 0; v_clean jsonb := '{}'::jsonb;
begin
  perform public.require_auth();
  select * into c from public.contests where id = p_id;
  if not found or not public._contest_visible(c.audience, v_me) then raise exception 'NOT_FOUND'; end if;
  select * into e from public.contest_entries where contest_id = p_id and user_id = v_me for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if e.submitted_at is not null then raise exception 'ALREADY_SUBMITTED'; end if;
  v_deadline := least(c.ends_at, case when c.answer_seconds is null then c.ends_at else e.started_at + make_interval(secs => c.answer_seconds) end);
  if c.status <> 'live' or now() > v_deadline + interval '5 seconds' then raise exception 'TIME_UP'; end if;
  for q in select * from public.contest_questions where contest_id = p_id order by position loop
    v_a := left(btrim(coalesce(p_answers ->> q.id::text, '')), 300);
    v_clean := v_clean || jsonb_build_object(q.id::text, v_a);
    if q.correct is not null then
      v_tot := v_tot + 1;
      if public._contest_norm(v_a) <> '' and public._contest_norm(v_a) = any (select public._contest_norm(x) from unnest(string_to_array(q.correct, '|')) x) then v_ok := v_ok + 1; end if;
    end if;
  end loop;
  update public.contest_entries set answers = v_clean, submitted_at = now(), correct_count = v_ok, graded_total = v_tot where id = e.id;
  return jsonb_build_object('correct_count', v_ok, 'graded_total', v_tot, 'seconds', extract(epoch from (now() - e.started_at))::int);
end $$;
revoke all on function public.contest_submit(uuid, jsonb) from public, anon;
grant execute on function public.contest_submit(uuid, jsonb) to authenticated;
