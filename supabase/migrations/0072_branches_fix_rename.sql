-- 0072: (1) fixes "assign a branch to a team member" (the insert listed three columns but supplied two values, so every save failed),
--       (2) the store has four branches: فرع ١ … فرع ٤ (+ الإدارة), (3) permission branches.rename: change a branch name
--       (the owner has it and can give it to a manager, who can give it on).

create or replace function public.staff_set_branches(p_user uuid, p_branches uuid[]) returns void
language plpgsql security definer set search_path = public as $$
declare b uuid;
begin
  perform public.require_permission('staff.manage');
  if not exists (select 1 from public.user_roles where user_id = p_user) then raise exception 'NOT_FOUND'; end if;
  if exists (select 1 from public.user_roles where user_id = p_user and role = 'owner') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_user = auth.uid() and not public.has_role('owner') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  foreach b in array coalesce(p_branches, '{}') loop
    if not public._branch_view_ok(b) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  end loop;
  delete from public.staff_branches where user_id = p_user and (public.has_role('owner') or public._branch_view_ok(branch_id));
  insert into public.staff_branches (user_id, branch_id, granted_by)
    select p_user, x, auth.uid() from (select distinct unnest(coalesce(p_branches, '{}')) as x) q
     where exists (select 1 from public.branches br where br.id = q.x)
    on conflict do nothing;
  perform public.audit_write('staff.branches', 'user', p_user::text, jsonb_build_object('branches', to_jsonb(p_branches)));
end $$;
revoke all on function public.staff_set_branches(uuid, uuid[]) from public, anon;
grant execute on function public.staff_set_branches(uuid, uuid[]) to authenticated;

-- four branches
update public.branches set name_ar = 'فرع ١', name_en = 'Branch 1'
 where id = (select id from public.branches where not is_hq order by created_at limit 1)
   and name_ar = 'فرع My Hatō الرئيسي';
insert into public.branches (name_ar, name_en, address_ar, address_en, is_hq)
select 'فرع ' || n::text, 'Branch ' || n::text, 'فرع ' || n::text, 'Branch ' || n::text, false
  from (values (1, '١'), (2, '٢'), (3, '٣'), (4, '٤')) v(n, ar)
 where (select count(*) from public.branches where not is_hq) < v.n
   and not exists (select 1 from public.branches where name_ar = 'فرع ' || v.ar);
update public.branches set name_ar = 'فرع ' || replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(substring(name_ar from 5), '0','٠'),'1','١'),'2','٢'),'3','٣'),'4','٤'),'5','٥'),'6','٦'),'7','٧'),'8','٨'),'9','٩')
 where not is_hq and name_ar ~ '^فرع [0-9]$';

-- renaming
insert into public.permission_catalog (permission, grp, name_ar, name_en, desc_ar, desc_en, sensitive, inert, sort) values
 ('branches.rename', 'system', 'يعدّل أسماء الفروع', 'Rename branches', 'يغيّر اسم أي فرع (فرع ١ … ٤) والإدارة', 'Changes the name of any branch and of head office', false, false, 73)
on conflict (permission) do update set name_ar = excluded.name_ar, name_en = excluded.name_en, desc_ar = excluded.desc_ar, desc_en = excluded.desc_en, inert = false;
insert into public.role_permissions (role, permission) values ('owner', 'branches.rename') on conflict do nothing;

create or replace function public.staff_rename_branch(p_branch uuid, p_name_ar text, p_name_en text default null) returns void
language plpgsql security definer set search_path = public as $$
declare v_ar text := btrim(coalesce(p_name_ar, '')); v_en text := nullif(btrim(coalesce(p_name_en, '')), '');
begin
  perform public.require_permission('branches.rename');
  if char_length(v_ar) not between 1 and 40 or (v_en is not null and char_length(v_en) > 40) then raise exception 'INVALID_INPUT'; end if;
  update public.branches set name_ar = v_ar, name_en = coalesce(v_en, v_ar), address_ar = case when address_ar = name_ar then v_ar else address_ar end
   where id = p_branch;
  if not found then raise exception 'NOT_FOUND'; end if;
  perform public.audit_write('branch.rename', 'branch', p_branch::text, jsonb_build_object('name_ar', v_ar, 'name_en', v_en));
end $$;
revoke all on function public.staff_rename_branch(uuid, text, text) from public, anon;
grant execute on function public.staff_rename_branch(uuid, text, text) to authenticated;
