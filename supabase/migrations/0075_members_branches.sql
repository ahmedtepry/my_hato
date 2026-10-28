-- 0075: which branch(es) each team member works in, for the permissions list.
create or replace function public.staff_members_branches()
returns table (user_id uuid, branches text[])
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_permission('staff.manage');
  return query
    select sb.user_id, array_agg(b.name_ar order by b.is_hq, b.created_at)
      from public.staff_branches sb join public.branches b on b.id = sb.branch_id
     where b.is_active
     group by sb.user_id;
end $$;
revoke all on function public.staff_members_branches() from public, anon;
grant execute on function public.staff_members_branches() to authenticated;
