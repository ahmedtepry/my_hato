-- 0078: a product commission can have a start and an end date ("today only", a week...), and the accountant gets a log of
-- employee commissions + KPIs (permission commission.view: owner, manager, accountant).

insert into public.permission_catalog (permission, grp, name_ar, name_en, desc_ar, desc_en, sensitive, inert, sort) values
 ('commission.view', 'pos', 'عمولات و KPI الموظفين', 'Employee commissions & KPIs',
  'يشوف سجل عمولات كل موظف ومبيعاته وعدد فواتيره ومتوسط الفاتورة والمرتجعات والبقشيش، لأي فترة', 'Sees every employee''s commission log, sales, invoices, average ticket, refunds and tips for any period', true, false, 96)
on conflict (permission) do update set name_ar = excluded.name_ar, name_en = excluded.name_en, desc_ar = excluded.desc_ar, desc_en = excluded.desc_en, sensitive = true, inert = false;
insert into public.role_permissions (role, permission) values ('owner', 'commission.view'), ('manager', 'commission.view'), ('accountant', 'commission.view') on conflict do nothing;

alter table public.product_commissions add column if not exists starts_on date;
alter table public.product_commissions add column if not exists ends_on date;
alter table public.product_commissions drop constraint if exists product_commissions_dates_ok;
alter table public.product_commissions add constraint product_commissions_dates_ok check (starts_on is null or ends_on is null or ends_on >= starts_on);

-- the commission frozen on a sale line is the one that is running TODAY (Cairo) when the sale is made
create or replace function public._item_commission() returns trigger language plpgsql security definer set search_path = public as $$
declare v_today date := (now() at time zone 'Africa/Cairo')::date;
begin
  new.commission_unit_minor := coalesce((select amount_minor from public.product_commissions
                                          where product_id = new.product_id
                                            and (starts_on is null or starts_on <= v_today) and (ends_on is null or ends_on >= v_today)), 0);
  return new;
end $$;

drop function if exists public.commission_set(uuid, bigint);
create or replace function public.commission_set(p_product uuid, p_amount_minor bigint, p_from date default null, p_to date default null) returns void
language plpgsql security definer set search_path = public as $$
declare v_price bigint;
begin
  perform public.require_permission('commission.set');
  select price_minor into v_price from public.products where id = p_product;
  if not found then raise exception 'NOT_FOUND'; end if;
  if p_from is not null and p_to is not null and p_to < p_from then raise exception 'INVALID_INPUT'; end if;
  if p_amount_minor is null or p_amount_minor = 0 then
    delete from public.product_commissions where product_id = p_product;
  else
    if p_amount_minor < 0 or p_amount_minor > v_price then raise exception 'INVALID_INPUT'; end if;
    insert into public.product_commissions (product_id, amount_minor, starts_on, ends_on, updated_by) values (p_product, p_amount_minor, p_from, p_to, auth.uid())
    on conflict (product_id) do update set amount_minor = excluded.amount_minor, starts_on = excluded.starts_on, ends_on = excluded.ends_on, updated_by = auth.uid(), updated_at = now();
  end if;
  perform public.audit_write('commission.set', 'product', p_product::text,
    jsonb_build_object('amount_minor', coalesce(p_amount_minor, 0), 'from', p_from, 'to', p_to));
end $$;

create or replace function public.commission_get_full(p_product uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_permission('commission.set');
  return (select jsonb_build_object('amount_minor', amount_minor, 'starts_on', starts_on, 'ends_on', ends_on) from public.product_commissions where product_id = p_product);
end $$;

-- ---- the accountant's view
create or replace function public.kpi_employees(p_from timestamptz, p_to timestamptz, p_branch uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_permission('commission.view');
  if p_from is null or p_to is null or p_to <= p_from or p_to - p_from > interval '400 days' then raise exception 'INVALID_INPUT'; end if;
  return jsonb_build_object('from', p_from, 'to', p_to, 'employees', coalesce((select jsonb_agg(x order by (x ->> 'net_minor')::bigint desc) from (
    select jsonb_build_object('user_id', u.uid, 'name', public._ops_name(u.uid),
             'role', (select ur.role::text from public.user_roles ur where ur.user_id = u.uid limit 1),
             'sales_count', s.n, 'gross_minor', s.gross, 'refunds_minor', s.refunds, 'net_minor', s.gross - s.refunds,
             'discount_minor', s.disc, 'tips_minor', s.tips,
             'avg_ticket_minor', case when s.n > 0 then round((s.gross - s.refunds)::numeric / s.n) else 0 end,
             'commission_minor', coalesce(c.com, 0), 'shifts_count', coalesce(sh.n, 0), 'target_minor', ut.monthly_minor) as x
      from (select distinct cashier_id as uid from public.pos_sales
             where created_at >= p_from and created_at < p_to and (p_branch is null or branch_id = p_branch) and public._branch_view_ok(branch_id)) u
      join lateral (select count(*) as n, coalesce(sum(p.total_minor), 0) as gross, coalesce(sum(p.refunded_minor), 0) as refunds,
                           coalesce(sum(p.discount_minor), 0) as disc, coalesce(sum(p.tip_minor), 0) as tips
                      from public.pos_sales p where p.cashier_id = u.uid and p.created_at >= p_from and p.created_at < p_to
                       and (p_branch is null or p.branch_id = p_branch) and public._branch_view_ok(p.branch_id)) s on true
      left join lateral (select sum(i.commission_unit_minor * (i.quantity - i.refunded_qty)) as com
                           from public.pos_sale_items i join public.pos_sales p on p.id = i.sale_id
                          where p.cashier_id = u.uid and p.created_at >= p_from and p.created_at < p_to
                            and (p_branch is null or p.branch_id = p_branch) and public._branch_view_ok(p.branch_id)) c on true
      left join lateral (select count(*) as n from public.shifts h where h.cashier_id = u.uid and h.opened_at >= p_from and h.opened_at < p_to
                            and (p_branch is null or h.branch_id = p_branch) and public._branch_view_ok(h.branch_id)) sh on true
      left join public.user_targets ut on ut.user_id = u.uid) q), '[]'::jsonb));
end $$;

create or replace function public.kpi_commission_log(p_user uuid, p_from timestamptz, p_to timestamptz, p_limit int default 300) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_permission('commission.view');
  if p_from is null or p_to is null or p_to <= p_from or p_to - p_from > interval '400 days' then raise exception 'INVALID_INPUT'; end if;
  return coalesce((select jsonb_agg(r order by r.created_at desc) from (
    select p.number as sale_number, p.created_at, b.name_ar as branch_name_ar, i.name_ar as product_name_ar, i.quantity, i.refunded_qty,
           i.commission_unit_minor as unit_minor, i.commission_unit_minor * (i.quantity - i.refunded_qty) as total_minor
      from public.pos_sale_items i join public.pos_sales p on p.id = i.sale_id join public.branches b on b.id = p.branch_id
     where p.cashier_id = p_user and p.created_at >= p_from and p.created_at < p_to and i.commission_unit_minor > 0 and public._branch_view_ok(p.branch_id)
     order by p.created_at desc limit least(greatest(coalesce(p_limit, 300), 1), 1000)) r), '[]'::jsonb);
end $$;

revoke all on function public.commission_set(uuid, bigint, date, date), public.commission_get_full(uuid), public.kpi_employees(timestamptz, timestamptz, uuid),
  public.kpi_commission_log(uuid, timestamptz, timestamptz, int) from public, anon;
grant execute on function public.commission_set(uuid, bigint, date, date), public.commission_get_full(uuid), public.kpi_employees(timestamptz, timestamptz, uuid),
  public.kpi_commission_log(uuid, timestamptz, timestamptz, int) to authenticated;
