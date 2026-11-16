-- Staff codes + "My sales" (owner's request, Odoo-like).
-- 1) Every team member has a 3-digit code: owners from 001, everyone else from 101, given automatically on creation.
--    Only the owner changes a code (staff_code_set). Codes are unique.
-- 2) Every category belongs to a sales group: 'acc' (accessories) or 'brand' (phones / used phones by default).
--    Repairs are their own group ('repair', from delivered repair requests). The owner can move a category.
-- 3) my_sales_report: a member's own sales for any period, split acc / brand / repair, per day or month, top items.
--    With "sales.view" (owner / manager) any member, or everyone together.

alter table public.team_members add column if not exists staff_code text;
do $$ begin
  alter table public.team_members add constraint team_members_staff_code_fmt check (staff_code ~ '^[0-9]{3}$');
exception when duplicate_object then null; end $$;
create unique index if not exists team_members_staff_code_uq on public.team_members(staff_code);

create or replace function public._is_owner_uid(p_uid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.user_roles where user_id = p_uid and role = 'owner')
$$;

create or replace function public._next_staff_code(p_owner boolean) returns text
language sql volatile security definer set search_path = public as $$
  select lpad(min(n)::text, 3, '0')
    from generate_series(case when p_owner then 1 else 101 end, 999) n
   where not exists (select 1 from public.team_members where staff_code = lpad(n::text, 3, '0'))
$$;

create or replace function public._team_member_code() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.staff_code is null then new.staff_code := public._next_staff_code(public._is_owner_uid(new.user_id)); end if;
  return new;
end $$;
drop trigger if exists team_member_code on public.team_members;
create trigger team_member_code before insert on public.team_members for each row execute function public._team_member_code();

-- existing members: the first owner (My Hatō Admin) 001, other owners next, everyone else from 101 by joining date
update public.team_members set staff_code = null;
update public.team_members set staff_code = '001' where user_id = 'ae5b72cc-a64c-45e7-b624-945c6dc22e93';
do $$ declare r record; begin
  for r in select tm.user_id, public._is_owner_uid(tm.user_id) o from public.team_members tm
            where tm.staff_code is null order by public._is_owner_uid(tm.user_id) desc, tm.created_at loop
    update public.team_members set staff_code = public._next_staff_code(r.o) where user_id = r.user_id;
  end loop;
end $$;

create or replace function public.staff_code_set(p_user uuid, p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v text := btrim(coalesce(p_code, ''));
begin
  if not public.has_role('owner') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if v ~ '^[0-9]{1,3}$' then v := lpad(v, 3, '0'); end if;
  if v !~ '^[0-9]{3}$' or v = '000' then raise exception 'INVALID_INPUT'; end if;
  if exists (select 1 from public.team_members where staff_code = v and user_id <> p_user) then raise exception 'CODE_TAKEN'; end if;
  update public.team_members set staff_code = v where user_id = p_user;
  if not found then raise exception 'NOT_FOUND'; end if;
  perform public.audit_write('staff.code_set', 'user', p_user::text, jsonb_build_object('code', v));
  return jsonb_build_object('ok', true, 'code', v);
end $$;

-- codes for the team screens (any team member may see the list of codes and names)
create or replace function public.staff_codes() returns table(user_id uuid, code text, name text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_staff() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return query select tm.user_id, tm.staff_code, coalesce(tm.login_display, p.full_name, tm.login_name, '—')
    from public.team_members tm left join public.profiles p on p.id = tm.user_id
   where tm.suspended_at is null order by tm.staff_code;
end $$;

-- sales groups per category
alter table public.categories add column if not exists sales_group text;
update public.categories set sales_group = case when kind in ('phones', 'used') then 'brand' else 'acc' end where sales_group is null;
alter table public.categories alter column sales_group set default 'acc';
do $$ begin
  alter table public.categories add constraint categories_sales_group_chk check (sales_group in ('acc', 'brand'));
exception when duplicate_object then null; end $$;

create or replace function public.category_sales_group_set(p_category uuid, p_group text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.has_role('owner') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_group not in ('acc', 'brand') then raise exception 'INVALID_INPUT'; end if;
  update public.categories set sales_group = p_group where id = p_category;
  if not found then raise exception 'NOT_FOUND'; end if;
end $$;

create or replace function public.category_sales_groups() returns table(id uuid, name_ar text, name_en text, sales_group text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_staff() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return query select c.id, c.name_ar, c.name_en, c.sales_group from public.categories c where c.is_active order by c.sort_order, c.name_ar;
end $$;

insert into public.permission_catalog (permission, grp, name_ar, name_en, desc_ar, desc_en, sensitive, inert, sort)
values ('sales.mine', 'pos', 'يشوف مبيعاته', 'See his own sales',
        'يشوف اللي باعه باسمه: اليوم أو الشهر أو السنة، مقسّم إكسسوارات وبراند وصيانة',
        'Sees what he sold under his name: day, month or year, split accessories, brand and repairs', false, false, 93)
on conflict (permission) do nothing;
insert into public.role_permissions (role, permission)
select r::public.app_role, 'sales.mine' from unnest(array['owner', 'manager', 'sales', 'cashier']) r
on conflict do nothing;

-- p_user null = me; p_all = everyone together (needs sales.view). Dates are Cairo calendar days, both ends included.
create or replace function public.my_sales_report(p_from date, p_to date, p_user uuid default null, p_all boolean default false,
                                                  p_branch uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_me uuid := public.require_auth();
  v_uid uuid := coalesce(p_user, v_me);
  v_all boolean := coalesce(p_all, false);
  v_from timestamptz; v_to timestamptz; v_monthly boolean;
  r jsonb;
begin
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 1100 then raise exception 'INVALID_INPUT'; end if;
  if v_all or v_uid <> v_me then
    if not public.has_permission('sales.view') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  elsif not (public.has_permission('sales.mine') or public.has_permission('sales.view')) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  v_from := (p_from::timestamp) at time zone 'Africa/Cairo';
  v_to := ((p_to + 1)::timestamp) at time zone 'Africa/Cairo';
  v_monthly := p_to - p_from > 62;

  with lines as (
    select s.id sale_id, (s.created_at at time zone 'Africa/Cairo')::date d,
           coalesce(c.sales_group, 'acc') g,
           coalesce(i.name_ar, '—') name_ar, coalesce(i.name_en, i.name_ar, '—') name_en,
           greatest(i.quantity - coalesce(i.refunded_qty, 0), 0) qty,
           coalesce(i.net_line_minor, i.line_total_minor) - coalesce(i.refunded_amount_minor, 0) amt
      from public.pos_sales s
      join public.pos_sale_items i on i.sale_id = s.id
      left join public.products pr on pr.id = i.product_id
      left join public.categories c on c.id = pr.category_id
     where s.created_at >= v_from and s.created_at < v_to
       and (v_all or coalesce(s.seller_id, s.cashier_id) = v_uid)
       and (p_branch is null or s.branch_id = p_branch)
    union all
    select null, (coalesce(q.closed_at, q.updated_at) at time zone 'Africa/Cairo')::date, 'repair',
           'صيانة ' || coalesce(q.device_brand || ' ', '') || coalesce(q.device_model, ''),
           'Repair ' || coalesce(q.device_brand || ' ', '') || coalesce(q.device_model, ''),
           1, coalesce(q.approved_cost_minor, q.estimated_cost_minor, 0)
      from public.repair_requests q
     where q.status = 'delivered'
       and coalesce(q.closed_at, q.updated_at) >= v_from and coalesce(q.closed_at, q.updated_at) < v_to
       and (v_all or coalesce(q.closed_by, q.assigned_technician_id) = v_uid)
       and (p_branch is null or q.branch_id = p_branch)
  ),
  buckets as (
    select case when v_monthly then date_trunc('month', d)::date else d end b, g, sum(amt) amt from lines group by 1, 2
  )
  select jsonb_build_object(
    'from', p_from, 'to', p_to, 'monthly', v_monthly,
    'user', case when v_all then null else v_uid end,
    'code', case when v_all then null else (select staff_code from public.team_members where user_id = v_uid) end,
    'name', case when v_all then null else (select coalesce(tm.login_display, p.full_name, '—') from public.team_members tm left join public.profiles p on p.id = tm.user_id where tm.user_id = v_uid) end,
    'total', coalesce((select sum(amt) from lines), 0),
    'groups', jsonb_build_object(
       'acc', jsonb_build_object('amount', coalesce((select sum(amt) from lines where g = 'acc'), 0), 'qty', coalesce((select sum(qty) from lines where g = 'acc'), 0)),
       'brand', jsonb_build_object('amount', coalesce((select sum(amt) from lines where g = 'brand'), 0), 'qty', coalesce((select sum(qty) from lines where g = 'brand'), 0)),
       'repair', jsonb_build_object('amount', coalesce((select sum(amt) from lines where g = 'repair'), 0), 'qty', coalesce((select sum(qty) from lines where g = 'repair'), 0))),
    'invoices', (select count(distinct sale_id) from lines where sale_id is not null),
    'series', coalesce((select jsonb_agg(jsonb_build_object('b', b, 'acc', acc, 'brand', brand, 'repair', repair) order by b)
                          from (select b, coalesce(sum(amt) filter (where g = 'acc'), 0) acc, coalesce(sum(amt) filter (where g = 'brand'), 0) brand,
                                       coalesce(sum(amt) filter (where g = 'repair'), 0) repair from buckets group by b) x), '[]'::jsonb),
    'top', coalesce((select jsonb_agg(t order by (t ->> 'amount')::bigint desc) from (
               select jsonb_build_object('name_ar', name_ar, 'name_en', name_en, 'group', g, 'qty', sum(qty), 'amount', sum(amt)) t
                 from lines group by name_ar, name_en, g order by sum(amt) desc limit 10) y), '[]'::jsonb),
    'can_others', public.has_permission('sales.view'),
    'can_edit_groups', public.has_role('owner')
  ) into r;
  return r;
end $$;

revoke all on function public.my_sales_report(date, date, uuid, boolean, uuid) from public, anon;
grant execute on function public.my_sales_report(date, date, uuid, boolean, uuid) to authenticated;
revoke all on function public.staff_code_set(uuid, text) from public, anon;
grant execute on function public.staff_code_set(uuid, text) to authenticated;
revoke all on function public.staff_codes() from public, anon;
grant execute on function public.staff_codes() to authenticated;
revoke all on function public.category_sales_group_set(uuid, text) from public, anon;
grant execute on function public.category_sales_group_set(uuid, text) to authenticated;
revoke all on function public.category_sales_groups() from public, anon;
grant execute on function public.category_sales_groups() to authenticated;
revoke all on function public._next_staff_code(boolean) from public, anon, authenticated;
revoke all on function public._is_owner_uid(uuid) from public, anon, authenticated;

-- adding a member: suggest the next free code (101+), check a typed one, set it by login right after creation
create or replace function public.staff_code_next() returns text
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_staff() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return (select lpad(min(n)::text, 3, '0') from generate_series(101, 999) n
           where not exists (select 1 from public.team_members where staff_code = lpad(n::text, 3, '0')));
end $$;

create or replace function public.staff_code_free(p_code text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare v text := btrim(coalesce(p_code, ''));
begin
  if not public.is_staff() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if v ~ '^[0-9]{1,3}$' then v := lpad(v, 3, '0'); end if;
  return v ~ '^[0-9]{3}$' and v <> '000' and not exists (select 1 from public.team_members where staff_code = v);
end $$;

create or replace function public.staff_code_set_login(p_login text, p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_uid uuid;
begin
  select user_id into v_uid from public.team_members where login_name = public._team_login_norm(p_login);
  if v_uid is null then raise exception 'NOT_FOUND'; end if;
  return public.staff_code_set(v_uid, p_code);
end $$;

revoke all on function public.staff_code_next() from public, anon;
grant execute on function public.staff_code_next() to authenticated;
revoke all on function public.staff_code_free(text) from public, anon;
grant execute on function public.staff_code_free(text) to authenticated;
revoke all on function public.staff_code_set_login(text, text) from public, anon;
grant execute on function public.staff_code_set_login(text, text) to authenticated;
