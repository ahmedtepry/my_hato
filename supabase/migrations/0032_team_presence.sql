-- 0032 Team accounts, part 2.
--  * Team members sign in with any login name the owner chooses (Arabic, spaces, digits …) + password.
--  * Live presence: the app sends a heartbeat while a member uses it -> online / away / offline,
--    last seen, device, what they are doing; plus last sign-in, actions today and an activity log.
--  * The owner can suspend a member instantly (permissions stop at once; sign-in blocked in Auth).
--  * Repair team (technician) can manage all repairs, not only assigned ones.

create table public.team_members (
  user_id uuid primary key references auth.users(id) on delete cascade,
  login_name text unique,                       -- normalized (see _team_login_norm); null = signs in like a customer
  login_display text,
  suspended_at timestamptz,
  last_seen_at timestamptz,
  online boolean not null default false,
  platform text,
  app_version text,
  area text,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);
alter table public.team_members enable row level security;
revoke all on public.team_members from anon, authenticated;

create or replace function public._team_login_norm(p text)
returns text language sql immutable as $$
  select regexp_replace(lower(trim(coalesce(p, ''))), '\s+', ' ', 'g')
$$;

-- a suspended member loses every permission immediately
create or replace function public.has_permission(p_permission text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.user_roles ur
    join public.role_permissions rp on rp.role = ur.role
    where ur.user_id = auth.uid() and rp.permission = p_permission
  ) and not exists (select 1 from public.team_members tm where tm.user_id = auth.uid() and tm.suspended_at is not null)
$$;

create or replace function public.is_staff()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.user_roles where user_id = auth.uid())
     and not exists (select 1 from public.team_members tm where tm.user_id = auth.uid() and tm.suspended_at is not null)
$$;

create or replace function public.my_staff_context()
returns jsonb language sql stable security definer set search_path = public as $$
  select case when exists (select 1 from public.team_members where user_id = auth.uid() and suspended_at is not null)
    then jsonb_build_object('roles', '[]'::jsonb, 'permissions', '[]'::jsonb, 'suspended', true)
    else jsonb_build_object(
      'roles', coalesce((select jsonb_agg(role) from public.user_roles where user_id = auth.uid()), '[]'),
      'permissions', coalesce((select jsonb_agg(distinct rp.permission) from public.user_roles ur
                                join public.role_permissions rp on rp.role = ur.role where ur.user_id = auth.uid()), '[]'))
  end
$$;

-- repair team handles every repair
insert into public.role_permissions(role, permission) values ('technician', 'repairs.manage') on conflict do nothing;

-- a team login name cannot be taken by a customer username later
create or replace function public._customer_username_free() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.username is not null and exists (select 1 from public.team_members where login_name = public._team_login_norm(new.username)
                                                                              and user_id <> new.user_id) then
    raise exception 'USERNAME_TAKEN';
  end if;
  return new;
end $$;
create trigger customers_username_free before insert or update of username on public.customers
  for each row execute function public._customer_username_free();

-- sign-in: customers by email / phone / username, team members also by their login name
create or replace function public.login_email_for(p_identifier text, p_password text)
returns text language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_id text := lower(trim(coalesce(p_identifier, '')));
  v_phone text;
  v_key text;
  v_uid uuid;
  v_hash text;
  v_email text;
  v_since timestamptz;
begin
  if v_id = '' or p_password is null or length(v_id) > 254 or length(p_password) > 200 then
    return null;
  end if;
  v_phone := public.normalize_eg_mobile(v_id);
  v_key := case when position('@' in v_id) > 0 then 'e:' || v_id
                when v_phone is not null then 'p:' || v_phone
                else 'u:' || public._team_login_norm(v_id) end;

  select greatest(now() - interval '15 minutes', coalesce(max(created_at) filter (where ok), '-infinity'))
    into v_since from public.auth_login_attempts where key = v_key;
  if (select count(*) from public.auth_login_attempts
       where key = v_key and not ok and created_at > coalesce(v_since, now() - interval '15 minutes')) >= 8 then
    raise exception 'RATE_LIMITED';
  end if;

  select c.user_id into v_uid from public.customers c
   where case left(v_key, 2) when 'e:' then c.email = v_id
                             when 'p:' then c.phone = v_phone
                             else c.username = v_id end
   limit 1;
  if v_uid is null and left(v_key, 2) = 'u:' then
    select tm.user_id into v_uid from public.team_members tm where tm.login_name = public._team_login_norm(v_id);
  end if;
  if v_uid is not null then
    select encrypted_password, email into v_hash, v_email from auth.users where id = v_uid;
  end if;

  if v_hash is not null and v_hash <> '' and v_hash = extensions.crypt(p_password, v_hash) then
    insert into public.auth_login_attempts(key, ok) values (v_key, true);
    return v_email;
  end if;

  if v_hash is null or v_hash = '' then
    perform extensions.crypt(p_password, extensions.gen_salt('bf', 10));
  end if;
  insert into public.auth_login_attempts(key, ok) values (v_key, false);
  return null;
end $$;
grant execute on function public.login_email_for(text, text) to anon, authenticated;

-- called by the admin-staff Edge Function (as the owner) right after it creates the Auth user
create or replace function public.staff_register_login(p_user_id uuid, p_login text)
returns void language plpgsql security definer set search_path = public as $$
declare v_norm text := public._team_login_norm(p_login);
begin
  perform public.require_permission('staff.manage');
  if length(v_norm) < 2 or length(v_norm) > 40 or position('@' in v_norm) > 0 then raise exception 'INVALID_USERNAME'; end if;
  if exists (select 1 from public.team_members where login_name = v_norm and user_id <> p_user_id)
     or exists (select 1 from public.customers where username = v_norm and user_id <> p_user_id) then
    raise exception 'USERNAME_TAKEN';
  end if;
  insert into public.team_members(user_id, login_name, login_display, created_by)
  values (p_user_id, v_norm, trim(p_login), auth.uid())
  on conflict (user_id) do update set login_name = excluded.login_name, login_display = excluded.login_display;
end $$;

create or replace function public.staff_login_available(p_login text)
returns boolean language sql stable security definer set search_path = public as $$
  select public.has_permission('staff.manage')
     and length(public._team_login_norm(p_login)) between 2 and 40
     and position('@' in p_login) = 0
     and not exists (select 1 from public.team_members where login_name = public._team_login_norm(p_login))
     and not exists (select 1 from public.customers where username = public._team_login_norm(p_login))
$$;

-- heartbeat from the app (every ~45 s while open; p_online = false when the app goes to background / signs out)
create or replace function public.staff_heartbeat(p_online boolean default true, p_area text default null,
                                                  p_platform text default null, p_version text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not exists (select 1 from public.user_roles where user_id = auth.uid()) then return; end if;
  insert into public.team_members(user_id, last_seen_at, online, area, platform, app_version)
  values (auth.uid(), now(), coalesce(p_online, true), left(p_area, 40), left(p_platform, 20), left(p_version, 20))
  on conflict (user_id) do update set last_seen_at = now(), online = coalesce(p_online, true),
     area = coalesce(left(p_area, 40), team_members.area), platform = coalesce(left(p_platform, 20), team_members.platform),
     app_version = coalesce(left(p_version, 20), team_members.app_version);
end $$;

-- suspend / resume (the Edge Function also blocks sign-in in Auth)
create or replace function public.staff_set_suspended(p_user_id uuid, p_suspended boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.require_permission('staff.manage');
  if p_user_id = auth.uid() then raise exception 'CANNOT_CHANGE_OWN_ROLE'; end if;
  if not exists (select 1 from public.user_roles where user_id = p_user_id) then raise exception 'NOT_FOUND'; end if;
  insert into public.team_members(user_id, suspended_at, online)
  values (p_user_id, case when p_suspended then now() end, false)
  on conflict (user_id) do update set suspended_at = case when p_suspended then now() end,
     online = case when p_suspended then false else team_members.online end;
  perform public.audit_write(case when p_suspended then 'staff.suspend' else 'staff.resume' end, 'user', p_user_id::text, '{}');
end $$;

-- the team list with presence + activity (staff_team() from 0031 stays for older app versions)
create or replace function public.staff_team_live()
returns table (user_id uuid, full_name text, username text, phone text, email text, role text,
               granted_at timestamptz, last_sign_in_at timestamptz, is_me boolean,
               presence text, last_seen_at timestamptz, platform text, app_version text, area text,
               suspended boolean, actions_today int, last_action text, last_action_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_permission('staff.manage');
  return query
    with m as (
      select ur.user_id,
             (array_agg(ur.role::text order by array_position(array['owner','manager','sales','technician','support'], ur.role::text)))[1] as role,
             min(ur.created_at) as granted_at
        from public.user_roles ur group by ur.user_id
    )
    select m.user_id, coalesce(nullif(p.full_name, ''), c.full_name), coalesce(tm.login_display, c.username),
           coalesce(c.phone, p.contact_phone), case when tm.login_name is not null then null else coalesce(c.email, p.email) end,
           m.role, m.granted_at, u.last_sign_in_at, m.user_id = auth.uid(),
           case when tm.suspended_at is not null then 'suspended'
                when m.user_id = auth.uid() then 'online'
                when tm.online and tm.last_seen_at > now() - interval '2 minutes' then 'online'
                when tm.last_seen_at > now() - interval '15 minutes' then 'away'
                else 'offline' end,
           tm.last_seen_at, tm.platform, tm.app_version, tm.area, tm.suspended_at is not null,
           (select count(*)::int from public.audit_logs a where a.actor_id = m.user_id
                and a.created_at >= date_trunc('day', now() at time zone 'Africa/Cairo') at time zone 'Africa/Cairo'),
           la.action, la.created_at
      from m
      left join public.profiles p on p.id = m.user_id
      left join public.customers c on c.user_id = m.user_id
      left join public.team_members tm on tm.user_id = m.user_id
      left join auth.users u on u.id = m.user_id
      left join lateral (select a.action, a.created_at from public.audit_logs a where a.actor_id = m.user_id
                          order by a.created_at desc limit 1) la on true
     order by m.user_id <> auth.uid(),
              case when tm.suspended_at is not null then 3
                   when tm.online and tm.last_seen_at > now() - interval '2 minutes' then 0
                   when tm.last_seen_at > now() - interval '15 minutes' then 1 else 2 end,
              array_position(array['owner','manager','sales','technician','support'], m.role), 2;
end $$;

-- one member's recent activity (what they did in the console)
create or replace function public.staff_member_activity(p_user_id uuid)
returns table (action text, entity_type text, entity_id text, details jsonb, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_permission('staff.manage');
  return query
    select a.action, a.entity_type, a.entity_id, a.details, a.created_at
      from public.audit_logs a where a.actor_id = p_user_id
     order by a.created_at desc limit 50;
end $$;

revoke all on function public._customer_username_free() from public, anon, authenticated;
revoke all on function public.staff_register_login(uuid, text) from public, anon;
grant execute on function public.staff_register_login(uuid, text) to authenticated;
revoke all on function public.staff_login_available(text) from public, anon;
grant execute on function public.staff_login_available(text) to authenticated;
revoke all on function public.staff_heartbeat(boolean, text, text, text) from public, anon;
grant execute on function public.staff_heartbeat(boolean, text, text, text) to authenticated;
revoke all on function public.staff_set_suspended(uuid, boolean) from public, anon;
grant execute on function public.staff_set_suspended(uuid, boolean) to authenticated;
revoke all on function public.staff_team_live() from public, anon;
grant execute on function public.staff_team_live() to authenticated;
revoke all on function public.staff_member_activity(uuid) from public, anon;
grant execute on function public.staff_member_activity(uuid) to authenticated;
