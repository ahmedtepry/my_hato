-- Quick sign-in on the Windows team app: by face or by fingerprint (Windows Hello).
-- A face alone never signs anyone in. After a normal password sign-in the app keeps a random device key for that
-- member (Windows Credential Manager); the server keeps only its SHA-256. Signing in later needs that key PLUS
-- either a face that matches one of the members who have a key on this computer, or (if the member turned it on
-- for this computer) a Windows Hello fingerprint, which unlocks the key locally.
-- The member must be allowed self service by the owner (or be the owner), not suspended, not blocked/locked.

create table if not exists public.staff_quick_devices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  key_hash text not null unique,
  label text,
  hello boolean not null default false,
  created_at timestamptz not null default now(),
  last_used_at timestamptz,
  revoked_at timestamptz
);
create index if not exists staff_quick_devices_user on public.staff_quick_devices(user_id);
alter table public.staff_quick_devices enable row level security;
revoke all on public.staff_quick_devices from anon, authenticated;

-- Called by the signed-in member right after a password sign-in (and from "My profile" to turn the fingerprint on/off).
create or replace function public.quick_login_register(p_key text, p_label text, p_hello boolean default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_uid uuid := auth.uid(); v_hash text; v_owner uuid;
begin
  if v_uid is null or not exists (select 1 from public.team_members where user_id = v_uid and suspended_at is null)
     and not public.has_role('owner') then
    raise exception 'FORBIDDEN';
  end if;
  if p_key is null or length(p_key) < 32 or length(p_key) > 200 then raise exception 'INVALID_INPUT'; end if;
  v_hash := encode(digest(p_key, 'sha256'), 'hex');
  select user_id into v_owner from public.staff_quick_devices where key_hash = v_hash;
  if v_owner is not null and v_owner <> v_uid then raise exception 'FORBIDDEN'; end if;
  insert into public.staff_quick_devices (user_id, key_hash, label, hello)
  values (v_uid, v_hash, left(p_label, 80), coalesce(p_hello, false))
  on conflict (key_hash) do update
     set label = coalesce(left(excluded.label, 80), public.staff_quick_devices.label),
         hello = coalesce(p_hello, public.staff_quick_devices.hello),
         revoked_at = null;
  return jsonb_build_object('ok', true, 'self_service', public._self_service_ok(v_uid));
end $$;

create or replace function public.quick_login_forget(p_key text)
returns void language sql security definer set search_path = public, extensions as $$
  update public.staff_quick_devices set revoked_at = now()
   where key_hash = encode(digest(p_key, 'sha256'), 'hex') and user_id = auth.uid();
$$;

-- Server only (the staff-quick-login edge function). p_print null = fingerprint sign-in with exactly one key.
create or replace function public.quick_login_check(p_keys text[], p_print text, p_model text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_devs uuid[]; v_users uuid[]; v_dev uuid; v_uid uuid; r jsonb; v_email text;
begin
  if p_keys is null or cardinality(p_keys) = 0 or cardinality(p_keys) > 20 then return jsonb_build_object('ok', false, 'error', 'NO_DEVICE'); end if;
  select array_agg(d.id), array_agg(distinct d.user_id) into v_devs, v_users
    from public.staff_quick_devices d
    join public.team_members tm on tm.user_id = d.user_id
   where d.key_hash = any (select encode(digest(k, 'sha256'), 'hex') from unnest(p_keys) k)
     and d.revoked_at is null and tm.suspended_at is null
     and (tm.self_service or exists (select 1 from public.user_roles ur where ur.user_id = d.user_id and ur.role = 'owner'))
     and (p_print is not null or d.hello)
     and not exists (select 1 from public.login_lockouts l where l.user_id = d.user_id
                      and (l.suspended or l.blocked or (l.locked_until is not null and l.locked_until > now())));
  if v_devs is null then return jsonb_build_object('ok', false, 'error', 'NO_DEVICE'); end if;
  v_dev := v_devs[1];
  if (select count(*) from public.staff_face_tries where caller = any(v_devs) and not ok and at > now() - interval '10 minutes') >= 8 then
    return jsonb_build_object('ok', false, 'error', 'TOO_MANY');
  end if;
  if p_print is null then
    if cardinality(p_keys) <> 1 then return jsonb_build_object('ok', false, 'error', 'INVALID_INPUT'); end if;
    v_uid := v_users[1];
  else
    r := public._face_match(v_dev, p_print, p_model, v_users);
    if (r ->> 'ok')::boolean is not true then return r; end if;
    v_uid := (r ->> 'id')::uuid;
  end if;
  select email into v_email from auth.users where id = v_uid and (banned_until is null or banned_until < now());
  if v_email is null then return jsonb_build_object('ok', false, 'error', 'NO_DEVICE'); end if;
  update public.staff_quick_devices set last_used_at = now() where id = any(v_devs) and user_id = v_uid;
  return jsonb_build_object('ok', true, 'id', v_uid, 'email', v_email,
    'name', (select coalesce(tm.login_display, p.full_name, '—') from public.profiles p left join public.team_members tm on tm.user_id = p.id where p.id = v_uid));
end $$;

revoke all on function public.quick_login_check(text[], text, text) from public, anon, authenticated;
grant execute on function public.quick_login_check(text[], text, text) to service_role;
revoke all on function public.quick_login_register(text, text, boolean) from public, anon;
grant execute on function public.quick_login_register(text, text, boolean) to authenticated;
revoke all on function public.quick_login_forget(text) from public, anon;
grant execute on function public.quick_login_forget(text) to authenticated;
