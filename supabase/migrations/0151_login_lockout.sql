-- 0151: login protection. 5 wrong passwords -> 15 min lock; 6-9 wrong -> 1 hour lock; 10 wrong -> the account is BLOCKED until the owner
-- unblocks it. Counted per ACCOUNT (not per typed identifier: email, phone and username all hit the same counter) and enforced in Auth too
-- (banned_until), so guessing straight against the Auth API does not get around it. A correct password resets the counter.
create table if not exists public.login_lockouts (
  subject text primary key,                       -- the user id (real account) or the typed identifier key (unknown account: same behaviour, nothing leaks)
  user_id uuid references auth.users(id) on delete cascade,
  failed_count int not null default 0,
  last_failed_at timestamptz,
  locked_until timestamptz,
  blocked boolean not null default false,
  blocked_at timestamptz,
  suspended boolean not null default false,       -- stopped by the owner
  suspended_at timestamptz,
  unblocked_at timestamptz,
  unblocked_by uuid
);
alter table public.login_lockouts enable row level security;   -- no policies: only the SECURITY DEFINER functions below touch it
create index if not exists login_lockouts_user_idx on public.login_lockouts (user_id);

insert into public.permission_catalog (permission, grp, name_ar, name_en, desc_ar, desc_en, sensitive, inert, sort)
values ('accounts.unblock', 'customers', 'فك حظر الحسابات المحظورة', 'Unblock locked accounts',
        'يشوف الحسابات المحظورة بسبب تخمين الباسورد ويفك حظرها أو يوقفها أو يرجّعها', 'Sees accounts blocked for wrong passwords and can unblock, suspend or restore them', true, false, 60)
on conflict (permission) do update set name_ar = excluded.name_ar, name_en = excluded.name_en, desc_ar = excluded.desc_ar, desc_en = excluded.desc_en;
insert into public.role_permissions (role, permission) values ('owner', 'accounts.unblock') on conflict do nothing;

create or replace function public.login_email_for(p_identifier text, p_password text)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare
  v_id text := lower(trim(coalesce(p_identifier, '')));
  v_phone text;
  v_key text;
  v_uid uuid;
  v_hash text;
  v_email text;
  v_subject text;
  st public.login_lockouts;
  n int;
  v_lock timestamptz;
  v_block boolean;
begin
  if v_id = '' or p_password is null or length(v_id) > 254 or length(p_password) > 200 then
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
    select u.id into v_uid from auth.users u where lower(u.email) = v_id limit 1;   -- staff / owner who sign in with their email
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
    perform extensions.crypt(p_password, extensions.gen_salt('bf', 10));   -- same cost whether or not the account exists
  end if;
  insert into public.auth_login_attempts(key, ok) values (v_key, false);

  n := coalesce(st.failed_count, 0) + 1;
  v_block := n >= 10 and not exists (select 1 from public.user_roles r where r.user_id = v_uid and r.role = 'owner');   -- the owner can be slowed down, never locked out for good
  v_lock := case when v_block then null when n >= 6 then now() + interval '1 hour' when n >= 5 then now() + interval '15 minutes' else null end;
  insert into public.login_lockouts (subject, user_id, failed_count, last_failed_at, locked_until, blocked, blocked_at)
  values (v_subject, v_uid, n, now(), v_lock, v_block, case when v_block then now() end)
  on conflict (subject) do update set failed_count = excluded.failed_count, last_failed_at = now(), locked_until = excluded.locked_until,
        blocked = excluded.blocked, blocked_at = case when excluded.blocked and not public.login_lockouts.blocked then now() else public.login_lockouts.blocked_at end;
  if v_uid is not null and (v_block or v_lock is not null) then
    update auth.users set banned_until = case when v_block then 'infinity'::timestamptz else v_lock end where id = v_uid;
  end if;
  if v_block then raise exception 'ACCOUNT_BLOCKED'; end if;
  return null;
end $$;

-- the owner's list: everything locked, blocked or suspended right now
create or replace function public.staff_blocked_accounts() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_permission('accounts.unblock');
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'user_id', l.user_id,
      'name', coalesce(c.full_name, c.username, tm.login_display, u.email),
      'phone', coalesce(c.phone, u.phone), 'email', u.email, 'code', c.customer_code, 'username', coalesce(c.username, tm.login_name),
      'kind', case when c.user_id is not null then 'customer' else 'staff' end,
      'status', case when l.suspended then 'suspended' when l.blocked then 'blocked' else 'locked' end,
      'failed_count', l.failed_count, 'last_failed_at', l.last_failed_at, 'locked_until', l.locked_until,
      'blocked_at', l.blocked_at, 'suspended_at', l.suspended_at
    ) order by coalesce(l.blocked_at, l.suspended_at, l.last_failed_at) desc nulls last)
    from public.login_lockouts l
    join auth.users u on u.id = l.user_id
    left join public.customers c on c.user_id = l.user_id
    left join public.team_members tm on tm.user_id = l.user_id
    where l.user_id is not null and (l.blocked or l.suspended or (l.locked_until is not null and l.locked_until > now()))
  ), '[]'::jsonb);
end $$;

create or replace function public.staff_account_unblock(p_user_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.require_permission('accounts.unblock');
  update public.login_lockouts set failed_count = 0, locked_until = null, blocked = false, blocked_at = null,
         unblocked_at = now(), unblocked_by = auth.uid() where user_id = p_user_id;
  update auth.users set banned_until = null where id = p_user_id
    and not exists (select 1 from public.login_lockouts l where l.user_id = p_user_id and l.suspended);
  perform public.audit_write('accounts.unblock', 'account', p_user_id::text, '{}'::jsonb);
end $$;

create or replace function public.staff_account_set_suspended(p_user_id uuid, p_suspended boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.require_permission('accounts.unblock');
  if exists (select 1 from public.user_roles r where r.user_id = p_user_id and r.role = 'owner') then raise exception 'FORBIDDEN'; end if;
  insert into public.login_lockouts (subject, user_id, suspended, suspended_at)
  values (p_user_id::text, p_user_id, coalesce(p_suspended, false), case when p_suspended then now() end)
  on conflict (subject) do update set suspended = excluded.suspended, suspended_at = excluded.suspended_at;
  update auth.users set banned_until = case when p_suspended then 'infinity'::timestamptz else null end where id = p_user_id;
  perform public.audit_write('accounts.suspend', 'account', p_user_id::text, jsonb_build_object('suspended', coalesce(p_suspended, false)));
end $$;

revoke all on function public.staff_blocked_accounts(), public.staff_account_unblock(uuid), public.staff_account_set_suspended(uuid, boolean) from public, anon;
grant execute on function public.staff_blocked_accounts(), public.staff_account_unblock(uuid), public.staff_account_set_suspended(uuid, boolean) to authenticated;
