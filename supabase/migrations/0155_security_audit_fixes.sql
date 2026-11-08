-- Security audit fixes
-- 1) login_lockouts was created with the default table grants: any signed-in user could TRUNCATE it
--    (TRUNCATE ignores row-level security) and so wipe every lockout and block. Lock it to the server only.
revoke all on public.login_lockouts from anon, authenticated, public;
revoke all on public.auth_login_attempts from anon, authenticated, public;
-- 2) New tables must not hand out the dangerous privileges by default.
alter default privileges in schema public revoke truncate, references, trigger on tables from anon, authenticated;

-- 3) login_email_for: per-IP throttle so one machine cannot flood the lockout tables or hammer passwords.
create or replace function public.login_email_for(p_identifier text, p_password text)
 returns text language plpgsql security definer set search_path to 'public', 'extensions' as $function$
declare
  v_id text := lower(trim(coalesce(p_identifier, '')));
  v_phone text;
  v_key text;
  v_uid uuid;
  v_hash text;
  v_email text;
  v_subject text;
  v_ip text;
  st public.login_lockouts;
  n int;
  v_lock timestamptz;
  v_block boolean;
begin
  if v_id = '' or p_password is null or length(v_id) > 254 or length(p_password) > 200 then
    return null;
  end if;
  v_ip := coalesce(split_part(coalesce(nullif(current_setting('request.headers', true), '')::json ->> 'x-forwarded-for', ''), ',', 1), '');
  if not public.hit_rate_limit('login_ip', encode(digest('ip:' || v_ip, 'sha256'), 'hex'), 600, 60) then
    return null;
  end if;
  v_phone := public.normalize_eg_mobile(v_id);
  v_key := case when position('@' in v_id) > 0 then 'e:' || v_id
                when v_phone is not null then 'p:' || v_phone
                else 'u:' || public._team_login_norm(v_id) end;

  select c.user_id into v_uid from public.customers c
   where case left(v_key, 2) when 'e:' then c.email = v_id
                             when 'p:' then c.phone = v_phone
                             else c.username = v_id end
   limit 1;
  if v_uid is null and left(v_key, 2) = 'u:' then
    select tm.user_id into v_uid from public.team_members tm where tm.login_name = public._team_login_norm(v_id);
  end if;
  if v_uid is null and left(v_key, 2) = 'e:' then
    select u.id into v_uid from auth.users u where lower(u.email) = v_id limit 1;
  end if;

  v_subject := coalesce(v_uid::text, v_key);
  select * into st from public.login_lockouts where subject = v_subject;
  if found then
    if st.suspended then raise exception 'ACCOUNT_SUSPENDED'; end if;
    if st.blocked then raise exception 'ACCOUNT_BLOCKED'; end if;
    if st.locked_until is not null and st.locked_until > now() then
      raise exception 'ACCOUNT_LOCKED:%', ceil(extract(epoch from (st.locked_until - now())))::int;
    end if;
  end if;

  if v_uid is not null then
    select encrypted_password, email into v_hash, v_email from auth.users where id = v_uid;
  end if;

  if v_hash is not null and v_hash <> '' and v_hash = extensions.crypt(p_password, v_hash) then
    insert into public.auth_login_attempts(key, ok) values (v_key, true);
    insert into public.login_lockouts (subject, user_id, failed_count) values (v_subject, v_uid, 0)
      on conflict (subject) do update set failed_count = 0, locked_until = null, last_failed_at = null;
    return v_email;
  end if;

  if v_hash is null or v_hash = '' then
    perform extensions.crypt(p_password, extensions.gen_salt('bf', 10));
  end if;
  insert into public.auth_login_attempts(key, ok) values (v_key, false);

  n := coalesce(st.failed_count, 0) + 1;
  v_block := n >= 10 and not exists (select 1 from public.user_roles r where r.user_id = v_uid and r.role = 'owner');
  v_lock := case when v_block then null when n >= 6 then now() + interval '1 hour' when n >= 5 then now() + interval '15 minutes' else null end;
  insert into public.login_lockouts (subject, user_id, failed_count, last_failed_at, locked_until, blocked, blocked_at)
  values (v_subject, v_uid, n, now(), v_lock, v_block, case when v_block then now() end)
  on conflict (subject) do update set failed_count = excluded.failed_count, last_failed_at = now(), locked_until = excluded.locked_until,
        blocked = excluded.blocked, blocked_at = case when excluded.blocked and not public.login_lockouts.blocked then now() else public.login_lockouts.blocked_at end;
  if v_uid is not null and (v_block or v_lock is not null) then
    update auth.users set banned_until = case when v_block then 'infinity'::timestamptz else v_lock end where id = v_uid;
  end if;
  if v_block then return '!blocked'; end if;
  if v_lock is not null then return '!locked:' || ceil(extract(epoch from (v_lock - now())))::int; end if;
  return null;
end $function$;

-- 4) signup_check: anyone could enumerate usernames and phone numbers without limit. Throttle per IP.
create or replace function public.signup_check(p_username text, p_phone text)
 returns jsonb language plpgsql volatile security definer set search_path to 'public', 'extensions' as $function$
declare
  v_u text := nullif(lower(trim(p_username)), '');
  v_p text := public.normalize_eg_mobile(p_phone);
  v_ip text := coalesce(split_part(coalesce(nullif(current_setting('request.headers', true), '')::json ->> 'x-forwarded-for', ''), ',', 1), '');
  stale constant text := '24 hours';
begin
  if not public.hit_rate_limit('signup_check_ip', encode(digest('ip:' || v_ip, 'sha256'), 'hex'), 600, 60) then
    return jsonb_build_object('username_valid', v_u is not null and v_u ~ '^[a-z0-9_.]{3,20}$', 'username_available', false,
                              'phone_valid', v_p is not null, 'phone_available', false, 'phone', v_p, 'rate_limited', true);
  end if;
  return jsonb_build_object(
    'username_valid', v_u is not null and v_u ~ '^[a-z0-9_.]{3,20}$',
    'username_available', v_u is not null and not exists (
      select 1 from public.customers c join auth.users u on u.id = c.user_id
       where c.username = v_u
         and (u.email_confirmed_at is not null or u.phone_confirmed_at is not null or u.created_at > now() - stale::interval)),
    'phone_valid', v_p is not null,
    'phone_available', v_p is not null and not exists (
      select 1 from public.customers c join auth.users u on u.id = c.user_id
       where c.phone = v_p
         and (u.email_confirmed_at is not null or u.phone_confirmed_at is not null or u.created_at > now() - stale::interval)),
    'phone', v_p);
end $function$;
