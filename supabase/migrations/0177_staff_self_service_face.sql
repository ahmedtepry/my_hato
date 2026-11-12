-- 0177: the employee's own profile (name, PIN, face) and recognition by face.
--   * The owner turns "self service" on per member (team_members.self_service). Only then can the member change
--     their display name and PIN, and record or delete their face.
--   * A face is kept as numeric face prints (vectors from the face model), never as a photo. Up to 5 per member.
--   * Matching happens here on the server (pgvector cosine distance), so a changed app cannot claim to be someone else
--     without that person's print, and prints are never readable from the app (no policies, RPC only).
--   * face_scan_style: the recognition animation the owner picks for everyone (default: the Hatō wave).

create extension if not exists vector with schema extensions;

alter table public.team_members add column if not exists self_service boolean not null default false;

create table if not exists public.staff_faces (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  print extensions.vector not null,
  model text not null,
  created_at timestamptz not null default now()
);
create index if not exists staff_faces_user on public.staff_faces(user_id);
alter table public.staff_faces enable row level security;
revoke all on public.staff_faces from anon, authenticated;

-- failed face tries per caller, to slow down guessing
create table if not exists public.staff_face_tries (
  caller uuid not null,
  at timestamptz not null default now(),
  ok boolean not null
);
create index if not exists staff_face_tries_caller on public.staff_face_tries(caller, at);
alter table public.staff_face_tries enable row level security;
revoke all on public.staff_face_tries from anon, authenticated;

-- ---------------------------------------------------------------- owner switches
create or replace function public.staff_self_service_set(p_user uuid, p_on boolean) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  perform public.require_auth();
  if not public.has_role('owner') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  update public.team_members set self_service = coalesce(p_on, false) where user_id = p_user;
  if not found then raise exception 'NOT_FOUND'; end if;
  perform public.audit_write('staff.self_service', 'user', p_user::text, jsonb_build_object('on', coalesce(p_on, false)));
end $$;

create or replace function public.staff_face_clear(p_user uuid) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  perform public.require_auth();
  if not public.has_role('owner') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  delete from public.staff_faces where user_id = p_user;
  perform public.audit_write('staff.face_cleared', 'user', p_user::text, '{}'::jsonb);
end $$;

-- who has what (owner's team screen)
create or replace function public.staff_bio_overview() returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
begin
  perform public.require_auth();
  if not public.has_role('owner') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return coalesce((select jsonb_object_agg(tm.user_id, jsonb_build_object(
            'self_service', tm.self_service,
            'faces', (select count(*) from public.staff_faces f where f.user_id = tm.user_id),
            'pin', exists (select 1 from public.staff_pins sp where sp.user_id = tm.user_id)))
          from public.team_members tm), '{}'::jsonb);
end $$;

create or replace function public.face_scan_style_set(p_style text) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  perform public.require_auth();
  if not public.has_role('owner') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_style not in ('wave','ring','mesh','fog','laser') then raise exception 'INVALID_INPUT'; end if;
  insert into public.application_settings (key, value, updated_by, updated_at)
  values ('face_scan_style', jsonb_build_object('style', p_style), auth.uid(), now())
  on conflict (key) do update set value = excluded.value, updated_by = excluded.updated_by, updated_at = now();
  perform public.audit_write('appearance.face_style', 'setting', 'face_scan_style', jsonb_build_object('style', p_style));
end $$;

-- ---------------------------------------------------------------- the member's own profile
create or replace function public._self_service_ok(p_uid uuid) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select public.has_role('owner') or exists (select 1 from public.team_members where user_id = p_uid and self_service and suspended_at is null)
$$;

create or replace function public.my_profile() returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare v_uid uuid := public.require_auth();
begin
  return (select jsonb_build_object(
      'id', v_uid,
      'name', coalesce(tm.login_display, p.full_name, ''),
      'login', tm.login_name,
      'allowed', public._self_service_ok(v_uid),
      'pin', exists (select 1 from public.staff_pins sp where sp.user_id = v_uid),
      'faces', (select count(*) from public.staff_faces f where f.user_id = v_uid))
    from public.profiles p left join public.team_members tm on tm.user_id = p.id where p.id = v_uid);
end $$;

create or replace function public.my_name_set(p_name text) returns void
language plpgsql security definer set search_path to 'public' as $$
declare v_uid uuid := public.require_auth(); v text := btrim(coalesce(p_name, ''));
begin
  if not public._self_service_ok(v_uid) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if length(v) < 2 or length(v) > 40 then raise exception 'INVALID_INPUT'; end if;
  update public.team_members set login_display = v where user_id = v_uid;
  update public.profiles set full_name = v, updated_at = now() where id = v_uid;
  perform public.audit_write('staff.name_self', 'user', v_uid::text, jsonb_build_object('name', v));
end $$;

create or replace function public.my_pin_set(p_old text, p_new text) returns jsonb
language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare v_uid uuid := public.require_auth(); sp public.staff_pins%rowtype;
begin
  if not public._self_service_ok(v_uid) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_new is null or p_new !~ '^[0-9]{4}$' then raise exception 'INVALID_INPUT'; end if;
  select * into sp from public.staff_pins where user_id = v_uid for update;
  if found then
    if sp.locked_until is not null and sp.locked_until > now() then
      return jsonb_build_object('ok', false, 'error', 'PIN_LOCKED', 'seconds', ceil(extract(epoch from sp.locked_until - now()))::int);
    end if;
    if p_old is null or sp.pin_hash <> crypt(p_old, sp.pin_hash) then
      update public.staff_pins set fails = case when fails + 1 >= 5 then 0 else fails + 1 end,
             locked_until = case when fails + 1 >= 5 then now() + interval '5 minutes' end where user_id = v_uid;
      return jsonb_build_object('ok', false, 'error', 'BAD_PIN');
    end if;
  end if;
  insert into public.staff_pins (user_id, pin_hash) values (v_uid, crypt(p_new, gen_salt('bf')))
    on conflict (user_id) do update set pin_hash = excluded.pin_hash, fails = 0, locked_until = null, updated_at = now();
  perform public.audit_write('staff.pin_self', 'user', v_uid::text, '{}'::jsonb);
  return jsonb_build_object('ok', true);
end $$;

-- p_prints: a JSON array of arrays of numbers (one per captured angle). Replaces the member's earlier prints.
create or replace function public.my_face_enroll(p_prints jsonb, p_model text) returns jsonb
language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare v_uid uuid := public.require_auth(); n int; e jsonb; d int;
begin
  if not public._self_service_ok(v_uid) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if jsonb_typeof(p_prints) <> 'array' then raise exception 'INVALID_INPUT'; end if;
  n := jsonb_array_length(p_prints);
  if n < 1 or n > 5 or coalesce(p_model, '') = '' then raise exception 'INVALID_INPUT'; end if;
  for e in select * from jsonb_array_elements(p_prints) loop
    d := jsonb_array_length(e);
    if d not in (128, 192, 512) then raise exception 'INVALID_INPUT'; end if;
  end loop;
  delete from public.staff_faces where user_id = v_uid;
  insert into public.staff_faces (user_id, print, model)
    select v_uid, (e::text)::extensions.vector, p_model from jsonb_array_elements(p_prints) e;
  perform public.audit_write('staff.face_enrolled', 'user', v_uid::text, jsonb_build_object('prints', n, 'model', p_model));
  return jsonb_build_object('ok', true, 'faces', n);
end $$;

create or replace function public.my_face_clear() returns void
language plpgsql security definer set search_path to 'public' as $$
declare v_uid uuid := public.require_auth();
begin
  delete from public.staff_faces where user_id = v_uid;
  perform public.audit_write('staff.face_cleared', 'user', v_uid::text, '{}'::jsonb);
end $$;

-- ---------------------------------------------------------------- recognition
-- The closest member among p_candidates (null = every member with self service on) whose best print is within the
-- threshold. Distances are cosine (0 = identical). Too many tries in a minute are refused.
create or replace function public._face_match(p_caller uuid, p_print text, p_model text, p_candidates uuid[]) returns jsonb
language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare v extensions.vector; v_user uuid; v_dist float8 := 9; v_second float8 := 9; v_thr float8;
begin
  if (select count(*) from public.staff_face_tries where caller = p_caller and at > now() - interval '1 minute' and not ok) >= 20 then
    return jsonb_build_object('ok', false, 'error', 'TOO_MANY');
  end if;
  begin v := p_print::extensions.vector; exception when others then raise exception 'INVALID_INPUT'; end;
  v_thr := coalesce((select (value ->> 'threshold')::float8 from public.application_settings where key = 'face_match'), 0.40);
  with best as (
    select f.user_id, min(f.print <=> v) dist
      from public.staff_faces f join public.team_members tm on tm.user_id = f.user_id
     where f.model = p_model and vector_dims(f.print) = vector_dims(v)
       and tm.suspended_at is null and (tm.self_service or exists (select 1 from public.user_roles ur where ur.user_id = f.user_id and ur.role = 'owner'))
       and (p_candidates is null or f.user_id = any(p_candidates))
     group by f.user_id)
  select b.user_id, b.dist, coalesce((select min(b2.dist) from best b2 where b2.user_id <> b.user_id), 9) into v_user, v_dist, v_second from best b order by b.dist limit 1;
  -- refuse when nobody is close enough, or when two people are almost equally close
  if v_user is null or v_dist > v_thr or v_second - v_dist < 0.05 then
    insert into public.staff_face_tries (caller, ok) values (p_caller, false);
    return jsonb_build_object('ok', false, 'error', 'NO_MATCH');
  end if;
  insert into public.staff_face_tries (caller, ok) values (p_caller, true);
  delete from public.staff_face_tries where at < now() - interval '1 day';
  return jsonb_build_object('ok', true, 'id', v_user, 'score', round((1 - v_dist)::numeric, 3),
    'name', (select coalesce(tm.login_display, p.full_name, '—') from public.profiles p left join public.team_members tm on tm.user_id = p.id where p.id = v_user));
end $$;
revoke all on function public._face_match(uuid, text, text, uuid[]) from public, anon, authenticated;

-- "is this really me?" (opening / closing a shift by face): the signed-in member must match their own prints
create or replace function public.my_face_check(p_print text, p_model text) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_uid uuid := public.require_auth(); m jsonb;
begin
  m := public._face_match(v_uid, p_print, p_model, array[v_uid]);
  if (m ->> 'ok')::boolean then perform public.audit_write('staff.face_ok', 'user', v_uid::text, jsonb_build_object('score', m -> 'score')); end if;
  return m;
end $$;

-- switch the seller on the till by face (same rules as the PIN switch)
create or replace function public.pos_switch_seller_face(p_shift uuid, p_print text, p_model text) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_uid uuid := public.require_auth(); sh public.shifts%rowtype; v_old uuid; m jsonb; v_to uuid; v_cands uuid[];
begin
  perform public.require_permission('pos.sell');
  select * into sh from public.shifts where id = p_shift;
  if not found or sh.cashier_id <> v_uid or sh.status <> 'open' then raise exception 'NO_OPEN_SHIFT'; end if;
  select array_agg(distinct f.user_id) into v_cands from public.staff_faces f where public._seller_ok(p_shift, f.user_id);
  if v_cands is null then return jsonb_build_object('ok', false, 'error', 'NO_MATCH'); end if;
  m := public._face_match(v_uid, p_print, p_model, v_cands);
  if not (m ->> 'ok')::boolean then return m; end if;
  v_to := (m ->> 'id')::uuid;
  select user_id into v_old from public.shift_sellers where shift_id = p_shift;
  insert into public.shift_sellers (shift_id, user_id) values (p_shift, v_to)
    on conflict (shift_id) do update set user_id = excluded.user_id, since = now();
  perform public.audit_write('pos.seller_switch', 'shift', p_shift::text,
    jsonb_build_object('from', coalesce(v_old, sh.cashier_id), 'to', v_to, 'branch_id', sh.branch_id, 'by', 'face', 'score', m -> 'score'));
  return m;
end $$;

do $$
declare f text;
begin
  foreach f in array array['staff_self_service_set(uuid,boolean)','staff_face_clear(uuid)','staff_bio_overview()','face_scan_style_set(text)',
    '_self_service_ok(uuid)','my_profile()','my_name_set(text)','my_pin_set(text,text)','my_face_enroll(jsonb,text)','my_face_clear()',
    'my_face_check(text,text)','pos_switch_seller_face(uuid,text,text)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
