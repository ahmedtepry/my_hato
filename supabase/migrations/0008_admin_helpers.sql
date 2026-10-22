-- =====================================================================
-- My Hatō — 0008 admin dashboard helpers
-- =====================================================================

create or replace function public.staff_list_technicians()
returns table (user_id uuid, full_name text, email text, roles text[])
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_permission('repairs.manage');
  return query
    select ur.user_id, p.full_name, p.email, array_agg(ur.role::text order by ur.role)
      from public.user_roles ur left join public.profiles p on p.id = ur.user_id
     where ur.role in ('technician','manager','owner')
     group by ur.user_id, p.full_name, p.email
     order by p.full_name;
end $$;

create or replace function public.staff_list_staff()
returns table (user_id uuid, full_name text, email text, roles text[])
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_permission('staff.manage');
  return query
    select ur.user_id, p.full_name, p.email, array_agg(ur.role::text order by ur.role)
      from public.user_roles ur left join public.profiles p on p.id = ur.user_id
     group by ur.user_id, p.full_name, p.email
     order by p.full_name;
end $$;

-- the signed-in staff member's own roles + permissions (used to build the dashboard menu;
-- the database still enforces every action independently)
create or replace function public.my_staff_context()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'roles', coalesce((select jsonb_agg(role) from public.user_roles where user_id = auth.uid()), '[]'),
    'permissions', coalesce((select jsonb_agg(distinct rp.permission) from public.user_roles ur
                              join public.role_permissions rp on rp.role = ur.role where ur.user_id = auth.uid()), '[]'))
$$;

revoke execute on function public.staff_list_technicians() from public, anon;
revoke execute on function public.staff_list_staff() from public, anon;
revoke execute on function public.my_staff_context() from public, anon;

-- First owner bootstrap (run ONCE manually in the SQL editor after the owner signs up):
--   insert into public.user_roles(user_id, role)
--   select id, 'owner' from auth.users where email = 'OWNER_EMAIL_HERE';
