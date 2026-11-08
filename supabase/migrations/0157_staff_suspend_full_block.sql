-- Stopping an employee (or an employee who left) must shut every door at once, even if he still has a copy of the program:
--  * permissions stop (team_members.suspended_at)  * login refuses him with a clear message (login_lockouts.suspended)
--  * Auth refuses new sign-ins / refresh (banned_until)  * every open session is killed.
create or replace function public.staff_set_suspended(p_user_id uuid, p_suspended boolean)
 returns void language plpgsql security definer set search_path to 'public' as $function$
begin
  perform public.require_permission('staff.manage');
  if p_user_id = auth.uid() then raise exception 'CANNOT_CHANGE_OWN_ROLE'; end if;
  if not exists (select 1 from public.user_roles where user_id = p_user_id) then raise exception 'NOT_FOUND'; end if;
  if exists (select 1 from public.user_roles r where r.user_id = p_user_id and r.role = 'owner') then raise exception 'FORBIDDEN'; end if;
  insert into public.team_members(user_id, suspended_at, online)
  values (p_user_id, case when p_suspended then now() end, false)
  on conflict (user_id) do update set suspended_at = case when p_suspended then now() end,
     online = case when p_suspended then false else team_members.online end;
  insert into public.login_lockouts (subject, user_id, suspended, suspended_at)
  values (p_user_id::text, p_user_id, coalesce(p_suspended, false), case when p_suspended then now() end)
  on conflict (subject) do update set suspended = excluded.suspended, suspended_at = excluded.suspended_at;
  update auth.users set banned_until = case when p_suspended then 'infinity'::timestamptz else null end where id = p_user_id;
  if p_suspended then delete from auth.sessions where user_id = p_user_id; end if;
  perform public.audit_write(case when p_suspended then 'staff.suspend' else 'staff.resume' end, 'user', p_user_id::text, '{}');
end $function$;

create or replace function public.staff_account_set_suspended(p_user_id uuid, p_suspended boolean)
 returns void language plpgsql security definer set search_path to 'public' as $function$
begin
  perform public.require_permission('accounts.unblock');
  if exists (select 1 from public.user_roles r where r.user_id = p_user_id and r.role = 'owner') then raise exception 'FORBIDDEN'; end if;
  insert into public.login_lockouts (subject, user_id, suspended, suspended_at)
  values (p_user_id::text, p_user_id, coalesce(p_suspended, false), case when p_suspended then now() end)
  on conflict (subject) do update set suspended = excluded.suspended, suspended_at = excluded.suspended_at;
  if exists (select 1 from public.user_roles where user_id = p_user_id) then
    insert into public.team_members(user_id, suspended_at, online)
    values (p_user_id, case when p_suspended then now() end, false)
    on conflict (user_id) do update set suspended_at = case when p_suspended then now() end,
       online = case when p_suspended then false else team_members.online end;
  end if;
  update auth.users set banned_until = case when p_suspended then 'infinity'::timestamptz else null end where id = p_user_id;
  if p_suspended then delete from auth.sessions where user_id = p_user_id; end if;
  perform public.audit_write('accounts.suspend', 'account', p_user_id::text, jsonb_build_object('suspended', coalesce(p_suspended, false)));
end $function$;

-- members already stopped before this change get the same treatment
insert into public.login_lockouts (subject, user_id, suspended, suspended_at)
select tm.user_id::text, tm.user_id, true, tm.suspended_at from public.team_members tm where tm.suspended_at is not null
on conflict (subject) do update set suspended = true, suspended_at = coalesce(public.login_lockouts.suspended_at, excluded.suspended_at);
update auth.users set banned_until = 'infinity'::timestamptz where id in (select user_id from public.team_members where suspended_at is not null);
delete from auth.sessions where user_id in (select user_id from public.team_members where suspended_at is not null);
