-- 0131: the owner adds a branch from the app. It works like every other branch at once: stock rows appear when stock is allocated to it,
-- POS / transfers / reports / targets list it, and the team members who work in all the other branches get it too (the owner always sees every branch).
create or replace function public.staff_add_branch(p_name_ar text, p_name_en text default null, p_address_ar text default null, p_phone text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_ar text := btrim(coalesce(p_name_ar, '')); v_en text := coalesce(nullif(btrim(coalesce(p_name_en, '')), ''), btrim(coalesce(p_name_ar, '')));
        v_addr text := coalesce(nullif(btrim(coalesce(p_address_ar, '')), ''), btrim(coalesce(p_name_ar, ''))); v_id uuid; v_n int;
begin
  perform public.require_permission('branches.manage');
  if char_length(v_ar) not between 1 and 40 or char_length(v_en) > 40 or char_length(v_addr) > 200 or char_length(coalesce(p_phone, '')) > 30 then raise exception 'INVALID_INPUT'; end if;
  if exists (select 1 from public.branches where lower(name_ar) = lower(v_ar)) then raise exception 'ALREADY_EXISTS'; end if;
  select count(*) into v_n from public.branches where is_active and not is_hq;
  insert into public.branches (name_ar, name_en, address_ar, address_en, phone, is_hq)
  values (v_ar, v_en, v_addr, v_addr, nullif(btrim(coalesce(p_phone, '')), ''), false) returning id into v_id;
  -- staff who work in every existing branch get the new one too (people limited to some branches stay as they are)
  insert into public.staff_branches (user_id, branch_id, granted_by)
  select sb.user_id, v_id, auth.uid()
    from public.staff_branches sb join public.branches b on b.id = sb.branch_id and b.is_active and not b.is_hq
   group by sb.user_id having count(*) = v_n and v_n > 0
  on conflict do nothing;
  perform public.audit_write('branch.add', 'branch', v_id::text, jsonb_build_object('name_ar', v_ar));
  return v_id;
end $$;
revoke all on function public.staff_add_branch(text, text, text, text) from public, anon;
grant execute on function public.staff_add_branch(text, text, text, text) to authenticated;
