-- 0067: head office as a branch of its own, accountant sees every branch, per-branch sales export data.

-- 1) head office ("الإدارة"): a branch row that is never shown to customers
alter table public.branches add column if not exists is_hq boolean not null default false;
insert into public.branches (name_ar, name_en, address_ar, address_en, is_hq)
select 'الإدارة', 'Head office', 'الإدارة', 'Head office', true
 where not exists (select 1 from public.branches where is_hq);
drop policy if exists branches_read on public.branches;
create policy branches_read on public.branches for select to anon, authenticated
  using ((is_active and not is_hq) or public.is_staff());

-- 2) permission "see the accounts of every branch" (accountant gets it; the owner can give it to anyone, or take it away)
insert into public.permission_catalog (permission, grp, name_ar, name_en, desc_ar, desc_en, sensitive, inert, sort) values
  ('branches.all', 'system', 'يشوف حسابات كل الفروع', 'See the accounts of every branch',
   'يشوف الورديات والمبيعات والتقارير لكل الفروع والإدارة، مش فرعه بس', 'See shifts, sales and reports of every branch and head office, not only his own', false, false, 71)
on conflict (permission) do update set name_ar = excluded.name_ar, name_en = excluded.name_en, desc_ar = excluded.desc_ar, desc_en = excluded.desc_en, inert = false;
insert into public.role_permissions (role, permission) values ('owner', 'branches.all'), ('accountant', 'branches.all') on conflict do nothing;

-- looking at a branch (reports, lists) vs working in it (selling, opening a shift) are separate questions
create or replace function public._branch_view_ok(p_branch uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select p_branch is not null and (public._branch_ok(p_branch) or public.has_permission('branches.all'))
$$;
revoke all on function public._branch_view_ok(uuid) from public, anon;
grant execute on function public._branch_view_ok(uuid) to authenticated;

-- the read-only functions use the wider check; selling, opening shifts, approvals and refunds keep the strict one
create or replace function public._use_view_scope(p_sig text) returns void language plpgsql as $$
declare v_fn regprocedure := to_regprocedure(p_sig); d text;
begin
  if v_fn is null then return; end if; -- not present in this database: nothing to widen
  d := pg_get_functiondef(v_fn);
  if position('_branch_ok(' in d) = 0 then return; end if;
  execute replace(d, '_branch_ok(', '_branch_view_ok(');
end $$;
select public._use_view_scope('public.pos_add_shift_correction(uuid,bigint,text)');
select public._use_view_scope('public.pos_branch_report(timestamptz,timestamptz)');
select public._use_view_scope('public.pos_find_sale(text)');
select public._use_view_scope('public.pos_sale_get(uuid)');
select public._use_view_scope('public.pos_shift_list(uuid,timestamptz,timestamptz,integer)');
select public._use_view_scope('public.pos_shift_report_get(uuid)');
select public._use_view_scope('public.pos_shift_report_list(uuid,timestamptz,timestamptz,integer)');
select public._use_view_scope('public.pos_shift_summary(uuid)');
drop function public._use_view_scope(text);

drop policy if exists shifts_read on public.shifts;
create policy shifts_read on public.shifts for select to authenticated
  using (cashier_id = auth.uid() or (public.has_permission('shifts.review') and public._branch_view_ok(branch_id)));
drop policy if exists pos_sales_read on public.pos_sales;
create policy pos_sales_read on public.pos_sales for select to authenticated
  using (cashier_id = auth.uid() or (public.has_permission('shifts.review') and public._branch_view_ok(branch_id)));
drop policy if exists pos_refunds_read on public.pos_refunds;
create policy pos_refunds_read on public.pos_refunds for select to authenticated
  using (requested_by = auth.uid() or (public.has_permission('shifts.review') and public._branch_view_ok(branch_id)));

-- 3) branch lists, head office last
drop function if exists public.staff_my_branches();
create or replace function public.staff_my_branches()
returns table (id uuid, name_ar text, name_en text, is_hq boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_auth();
  return query select b.id, b.name_ar, b.name_en, b.is_hq from public.branches b
    where b.is_active and (public.has_role('owner') or exists (select 1 from public.staff_branches sb where sb.user_id = auth.uid() and sb.branch_id = b.id))
    order by b.is_hq, b.created_at;
end $$;
-- the branches a person may LOOK at (every branch for the owner and for "see every branch")
create or replace function public.staff_view_branches()
returns table (id uuid, name_ar text, name_en text, is_hq boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_auth();
  return query select b.id, b.name_ar, b.name_en, b.is_hq from public.branches b
    where b.is_active and (public.has_role('owner') or public.has_permission('branches.all')
          or exists (select 1 from public.staff_branches sb where sb.user_id = auth.uid() and sb.branch_id = b.id))
    order by b.is_hq, b.created_at;
end $$;
revoke all on function public.staff_my_branches(), public.staff_view_branches() from public, anon;
grant execute on function public.staff_my_branches(), public.staff_view_branches() to authenticated;

-- 4) every sale of a branch (or of all), for the accountant's Excel/PDF
create or replace function public.books_sales(p_branch uuid default null, p_from timestamptz default null, p_to timestamptz default null, p_limit int default 5000)
returns table (number text, created_at timestamptz, branch_id uuid, branch_name_ar text, cashier_name text, subtotal_minor bigint, discount_minor bigint,
               total_minor bigint, refunded_minor bigint, shift_id uuid)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_auth();
  if not (public.has_permission('sales.view') or public.has_permission('shifts.review')) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return query
    select s.number, s.created_at, s.branch_id, b.name_ar, coalesce(tm.login_display, p.full_name, '—'),
           s.subtotal_minor, s.discount_minor, s.total_minor, s.refunded_minor, s.shift_id
      from public.pos_sales s
      join public.branches b on b.id = s.branch_id
      left join public.team_members tm on tm.user_id = s.cashier_id
      left join public.profiles p on p.id = s.cashier_id
     where public._branch_view_ok(s.branch_id)
       and (p_branch is null or s.branch_id = p_branch)
       and (p_from is null or s.created_at >= p_from) and (p_to is null or s.created_at < p_to)
     order by s.created_at desc limit least(greatest(coalesce(p_limit, 5000), 1), 20000);
end $$;
revoke all on function public.books_sales(uuid, timestamptz, timestamptz, int) from public, anon;
grant execute on function public.books_sales(uuid, timestamptz, timestamptz, int) to authenticated;
