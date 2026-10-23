-- 0031 Team accounts: the owner (staff.manage) manages the team from the console.
--   staff_team()                    – team members with their role, contact details and last sign-in
--   staff_find_customer(query)      – find an existing app account (phone / username / email / MHC code) to add
--   staff_assign_role(user, role)   – give a member exactly one role (replaces any previous role)
--   staff_remove_member(user)       – remove all team roles (the account goes back to a normal customer)
-- New team accounts with a username + password are created by the admin-staff Edge Function.
-- Guards: nobody changes or removes their own role, and the last owner can never be removed.
-- Every change is audited and the member gets a notification.

create or replace function public._role_label_ar(p_role public.app_role)
returns text language sql immutable as $$
  select case p_role when 'owner' then 'مالك' when 'manager' then 'مدير' when 'sales' then 'مبيعات'
                     when 'technician' then 'فني صيانة' else 'خدمة عملاء' end
$$;

create or replace function public.staff_team()
returns table (user_id uuid, full_name text, username text, phone text, email text, role text,
               granted_at timestamptz, last_sign_in_at timestamptz, is_me boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_permission('staff.manage');
  return query
    select ur.user_id, coalesce(nullif(p.full_name, ''), c.full_name), c.username, coalesce(c.phone, p.contact_phone),
           coalesce(c.email, p.email),
           (array_agg(ur.role::text order by array_position(array['owner','manager','sales','technician','support'], ur.role::text)))[1],
           min(ur.created_at), max(u.last_sign_in_at), ur.user_id = auth.uid()
      from public.user_roles ur
      left join public.profiles p on p.id = ur.user_id
      left join public.customers c on c.user_id = ur.user_id
      left join auth.users u on u.id = ur.user_id
     group by ur.user_id, p.full_name, c.full_name, c.username, c.phone, p.contact_phone, c.email, p.email
     order by min(array_position(array['owner','manager','sales','technician','support'], ur.role::text)), 2;
end $$;

create or replace function public.staff_find_customer(p_query text)
returns table (user_id uuid, customer_code text, full_name text, username text, phone text, email text)
language plpgsql stable security definer set search_path = public as $$
declare
  v_q text := lower(trim(coalesce(p_query, '')));
  v_phone text := public.normalize_eg_mobile(p_query);
begin
  perform public.require_permission('staff.manage');
  if length(v_q) < 3 then return; end if;
  return query
    select c.user_id, c.customer_code, coalesce(nullif(c.full_name, ''), p.full_name), c.username,
           coalesce(c.phone, p.contact_phone, p.phone), c.email
      from public.customers c
      left join public.profiles p on p.id = c.user_id
     where not exists (select 1 from public.user_roles ur where ur.user_id = c.user_id)
       and ((v_phone is not null and v_phone in (c.phone, p.contact_phone, public.normalize_eg_mobile(p.phone)))
            or c.username = ltrim(v_q, '@') or c.email = v_q or lower(c.customer_code) = v_q)
     limit 5;
end $$;

create or replace function public._assert_owner_kept(p_user_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_user_id = auth.uid() then raise exception 'CANNOT_CHANGE_OWN_ROLE'; end if;
  if exists (select 1 from public.user_roles where user_id = p_user_id and role = 'owner')
     and (select count(distinct user_id) from public.user_roles where role = 'owner') <= 1 then
    raise exception 'LAST_OWNER';
  end if;
end $$;

create or replace function public.staff_assign_role(p_user_id uuid, p_role public.app_role)
returns void language plpgsql security definer set search_path = public as $$
declare v_old text; r record;
begin
  perform public.require_permission('staff.manage');
  if not exists (select 1 from public.profiles where id = p_user_id) then raise exception 'NOT_FOUND'; end if;
  select string_agg(role::text, ',') into v_old from public.user_roles where user_id = p_user_id;
  if v_old is not null and p_role <> 'owner' then perform public._assert_owner_kept(p_user_id); end if;
  if p_user_id = auth.uid() then raise exception 'CANNOT_CHANGE_OWN_ROLE'; end if;
  -- other roles go through the audited staff_set_role (0005)
  for r in select role from public.user_roles where user_id = p_user_id and role <> p_role loop
    perform public.staff_set_role(p_user_id, r.role, false);
  end loop;
  insert into public.user_roles(user_id, role, granted_by) values (p_user_id, p_role, auth.uid()) on conflict do nothing;
  perform public.audit_write('staff.assign', 'user', p_user_id::text, jsonb_build_object('role', p_role, 'previous', v_old));
  perform public.notify_user(p_user_id,
    '👔 ' || case when v_old is null then 'انضممت لفريق My Hatō' else 'اتغيّرت صلاحيتك' end,
    '👔 ' || case when v_old is null then 'You joined the My Hatō team' else 'Your team role changed' end,
    'دورك: ' || public._role_label_ar(p_role) || ' — ادخل لوحة الفريق من التطبيق.',
    'Your role: ' || p_role::text, 'system', null, null, '/hato-console');
end $$;

create or replace function public.staff_remove_member(p_user_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_old text; r record;
begin
  perform public.require_permission('staff.manage');
  perform public._assert_owner_kept(p_user_id);
  select string_agg(role::text, ',') into v_old from public.user_roles where user_id = p_user_id;
  if v_old is null then raise exception 'NOT_FOUND'; end if;
  for r in select role from public.user_roles where user_id = p_user_id loop
    perform public.staff_set_role(p_user_id, r.role, false);
  end loop;
  perform public.audit_write('staff.remove', 'user', p_user_id::text, jsonb_build_object('previous', v_old));
end $$;

revoke all on function public._assert_owner_kept(uuid) from public, anon, authenticated;
revoke all on function public.staff_team() from public, anon;
grant execute on function public.staff_team() to authenticated;
revoke all on function public.staff_find_customer(text) from public, anon;
grant execute on function public.staff_find_customer(text) to authenticated;
revoke all on function public.staff_assign_role(uuid, public.app_role) from public, anon;
grant execute on function public.staff_assign_role(uuid, public.app_role) to authenticated;
revoke all on function public.staff_remove_member(uuid) from public, anon;
grant execute on function public.staff_remove_member(uuid) to authenticated;
