-- 0084: profit. Each product can have a COST price (kept in its own table: customers can read products, never costs).
-- The cost is frozen on every sale line when the sale is made (POS and online orders), exactly like the commission.
-- Lines sold before a cost was known are filled from the product's cost when it is loaded, so old invoices get a profit too.
-- Permissions: profit.view (owner / manager / accountant, the owner can switch it per role or per person), cost.manage (owner).

insert into public.permission_catalog (permission, grp, name_ar, name_en, desc_ar, desc_en, sensitive, inert, sort) values
 ('profit.view', 'system', 'يشوف الأرباح', 'See profit',
  'يشوف صافي الربح لكل فاتورة وللفترة (سعر البيع ناقص سعر التكلفة) وأكتر المنتجات ربحًا وخسارة', 'Sees the profit of every invoice and of any period (selling price minus cost) and the best and worst products', true, false, 47),
 ('cost.manage', 'pos', 'يحدد سعر تكلفة المنتجات', 'Set product costs',
  'يكتب سعر التكلفة لكل منتج أو يرفع شيت التكلفة، وده اللي بيتحسب منه الربح', 'Sets each product''s cost, or loads a cost sheet, which profit is computed from', true, false, 98)
on conflict (permission) do update set name_ar = excluded.name_ar, name_en = excluded.name_en, desc_ar = excluded.desc_ar, desc_en = excluded.desc_en, sensitive = true;
insert into public.role_permissions (role, permission) values
 ('owner','profit.view'),('manager','profit.view'),('accountant','profit.view'),('owner','cost.manage')
on conflict do nothing;

create table if not exists public.product_costs (
  product_id uuid primary key references public.products(id) on delete cascade,
  cost_minor bigint not null check (cost_minor >= 0),
  updated_by uuid references auth.users(id),
  updated_at timestamptz not null default now()
);
create table if not exists public.pos_item_costs (
  item_id uuid primary key references public.pos_sale_items(id),
  cost_unit_minor bigint not null check (cost_unit_minor >= 0)
);
create table if not exists public.order_item_costs (
  item_id uuid primary key references public.order_items(id) on delete cascade,
  cost_unit_minor bigint not null check (cost_unit_minor >= 0)
);
alter table public.product_costs enable row level security;
alter table public.pos_item_costs enable row level security;
alter table public.order_item_costs enable row level security;
revoke all on public.product_costs, public.pos_item_costs, public.order_item_costs from public, anon, authenticated;

-- the cost is frozen on the line at the moment of the sale
create or replace function public._freeze_pos_cost() returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.pos_item_costs (item_id, cost_unit_minor) select new.id, c.cost_minor from public.product_costs c where c.product_id = new.product_id
  on conflict do nothing;
  return new;
end $$;
drop trigger if exists pos_sale_items_cost on public.pos_sale_items;
create trigger pos_sale_items_cost after insert on public.pos_sale_items for each row execute function public._freeze_pos_cost();

create or replace function public._freeze_order_cost() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.product_id is not null then
    insert into public.order_item_costs (item_id, cost_unit_minor) select new.id, c.cost_minor from public.product_costs c where c.product_id = new.product_id
    on conflict do nothing;
  end if;
  return new;
end $$;
drop trigger if exists order_items_cost on public.order_items;
create trigger order_items_cost after insert on public.order_items for each row execute function public._freeze_order_cost();

-- fills the lines that have no cost yet from the product's cost (never touches a cost already frozen)
create or replace function public._costs_backfill(p_product uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_pos int; v_ord int;
begin
  with ins as (
    insert into public.pos_item_costs (item_id, cost_unit_minor)
    select i.id, c.cost_minor from public.pos_sale_items i join public.product_costs c on c.product_id = i.product_id
    where (p_product is null or i.product_id = p_product) and not exists (select 1 from public.pos_item_costs x where x.item_id = i.id)
    on conflict do nothing returning 1) select count(*) into v_pos from ins;
  with ins as (
    insert into public.order_item_costs (item_id, cost_unit_minor)
    select i.id, c.cost_minor from public.order_items i join public.product_costs c on c.product_id = i.product_id
    where (p_product is null or i.product_id = p_product) and not exists (select 1 from public.order_item_costs x where x.item_id = i.id)
    on conflict do nothing returning 1) select count(*) into v_ord from ins;
  return jsonb_build_object('pos_lines', v_pos, 'order_lines', v_ord);
end $$;
revoke all on function public._costs_backfill(uuid), public._freeze_pos_cost(), public._freeze_order_cost() from public, anon, authenticated;

create or replace function public.cost_get(p_product uuid) returns bigint
language plpgsql stable security definer set search_path = public as $$
begin
  if not (public.has_permission('cost.manage') or public.has_permission('profit.view')) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return (select cost_minor from public.product_costs where product_id = p_product);
end $$;

create or replace function public.cost_set(p_product uuid, p_cost_minor bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_fill jsonb := '{}'::jsonb;
begin
  perform public.require_permission('cost.manage');
  if not exists (select 1 from public.products where id = p_product) then raise exception 'NOT_FOUND'; end if;
  if p_cost_minor is null then
    delete from public.product_costs where product_id = p_product;
  else
    if p_cost_minor < 0 then raise exception 'INVALID_INPUT'; end if;
    insert into public.product_costs (product_id, cost_minor, updated_by) values (p_product, p_cost_minor, auth.uid())
    on conflict (product_id) do update set cost_minor = excluded.cost_minor, updated_by = auth.uid(), updated_at = now();
    v_fill := public._costs_backfill(p_product);
  end if;
  perform public.audit_write('cost.set', 'product', p_product::text, jsonb_build_object('cost_minor', p_cost_minor));
  return v_fill;
end $$;

-- rows: [{"sku": "...", "cost_minor": 1234}, ...]  (the sheet import)
create or replace function public.cost_set_bulk(p_rows jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r jsonb; v_id uuid; v_ok int := 0; v_missing jsonb := '[]'::jsonb; v_fill jsonb;
begin
  perform public.require_permission('cost.manage');
  if jsonb_typeof(p_rows) is distinct from 'array' or jsonb_array_length(p_rows) > 5000 then raise exception 'INVALID_INPUT'; end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    select id into v_id from public.products where sku = (r ->> 'sku');
    if v_id is null or (r ->> 'cost_minor') is null or (r ->> 'cost_minor')::bigint < 0 then
      v_missing := v_missing || to_jsonb(coalesce(r ->> 'sku', '?'));
      continue;
    end if;
    insert into public.product_costs (product_id, cost_minor, updated_by) values (v_id, (r ->> 'cost_minor')::bigint, auth.uid())
    on conflict (product_id) do update set cost_minor = excluded.cost_minor, updated_by = auth.uid(), updated_at = now();
    v_ok := v_ok + 1;
  end loop;
  v_fill := public._costs_backfill(null);
  perform public.audit_write('cost.import', 'products', 'bulk', jsonb_build_object('updated', v_ok, 'not_found', jsonb_array_length(v_missing)));
  return jsonb_build_object('updated', v_ok, 'not_found', v_missing, 'filled', v_fill);
end $$;

-- the profit report: POS sales (by invoice date) + delivered online orders (by delivery date), Cairo days.
-- A sale counts in the profit only when EVERY line has a cost; the others are listed apart so the total is never guessed.
create or replace function public.profit_report(p_from timestamptz, p_to timestamptz) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_tz constant text := 'Africa/Cairo'; v_sales jsonb; v_tot jsonb; v_series jsonb; v_top jsonb; v_worst jsonb; v_nocost int;
begin
  perform public.require_permission('profit.view');
  if p_from is null or p_to is null or p_to <= p_from or p_to - p_from > interval '400 days' then raise exception 'INVALID_INPUT'; end if;

  drop table if exists pg_temp._pf;
  create temp table _pf on commit drop as
  select 'pos'::text as kind, s.number as ref, s.created_at as at, public._ops_name(s.cashier_id) as who,
         sum(i.net_line_minor - i.refunded_amount_minor)::bigint as revenue,
         sum(coalesce(c.cost_unit_minor, 0) * (i.quantity - i.refunded_qty))::bigint as cost,
         count(*) filter (where c.item_id is null and i.quantity - i.refunded_qty > 0)::int as missing
  from public.pos_sales s join public.pos_sale_items i on i.sale_id = s.id left join public.pos_item_costs c on c.item_id = i.id
  where s.created_at >= p_from and s.created_at < p_to group by s.id
  union all
  select 'online', o.reference, d.delivered_at, o.customer_name,
         o.subtotal_minor::bigint,
         sum(coalesce(c.cost_unit_minor, 0) * i.quantity)::bigint,
         count(*) filter (where c.item_id is null)::int
  from public._delivered_orders d join public.orders o on o.id = d.id join public.order_items i on i.order_id = o.id left join public.order_item_costs c on c.item_id = i.id
  where d.delivered_at >= p_from and d.delivered_at < p_to group by o.id, d.delivered_at;

  select jsonb_build_object(
    'revenue_minor', coalesce(sum(revenue) filter (where missing = 0), 0), 'cost_minor', coalesce(sum(cost) filter (where missing = 0), 0),
    'profit_minor', coalesce(sum(revenue - cost) filter (where missing = 0), 0),
    'sales_counted', count(*) filter (where missing = 0), 'sales_uncosted', count(*) filter (where missing > 0),
    'revenue_uncosted_minor', coalesce(sum(revenue) filter (where missing > 0), 0),
    'pos_profit_minor', coalesce(sum(revenue - cost) filter (where missing = 0 and kind = 'pos'), 0),
    'online_profit_minor', coalesce(sum(revenue - cost) filter (where missing = 0 and kind = 'online'), 0),
    'losing_sales', count(*) filter (where missing = 0 and revenue - cost < 0)) into v_tot from _pf;

  select coalesce(jsonb_agg(x order by (x ->> 'at') desc), '[]'::jsonb) into v_sales from (
    select jsonb_build_object('kind', kind, 'ref', ref, 'at', at, 'who', who, 'revenue_minor', revenue, 'cost_minor', cost,
             'profit_minor', case when missing = 0 then revenue - cost end, 'missing_lines', missing) as x
    from _pf order by at desc limit 300) t;

  select coalesce(jsonb_agg(jsonb_build_object('day', day, 'profit_minor', p) order by day), '[]'::jsonb) into v_series from (
    select (at at time zone v_tz)::date as day, sum(revenue - cost)::bigint as p from _pf where missing = 0 group by 1) t;

  drop table if exists pg_temp._pl;
  create temp table _pl on commit drop as
  select coalesce(i.name_ar, '—') as name, i.quantity - i.refunded_qty as q, i.net_line_minor - i.refunded_amount_minor as rev, c.cost_unit_minor * (i.quantity - i.refunded_qty) as cst
  from public.pos_sales s join public.pos_sale_items i on i.sale_id = s.id join public.pos_item_costs c on c.item_id = i.id
  where s.created_at >= p_from and s.created_at < p_to and i.quantity - i.refunded_qty > 0
  union all
  select i.name_ar, i.quantity, i.line_total_minor, c.cost_unit_minor * i.quantity
  from public._delivered_orders d join public.order_items i on i.order_id = d.id join public.order_item_costs c on c.item_id = i.id
  where d.delivered_at >= p_from and d.delivered_at < p_to;
  select coalesce(jsonb_agg(x), '[]'::jsonb) into v_top from (
    select jsonb_build_object('name', name, 'qty', sum(q), 'revenue_minor', sum(rev), 'cost_minor', sum(cst), 'profit_minor', sum(rev - cst)) as x
    from _pl group by name order by sum(rev - cst) desc limit 8) t;
  select coalesce(jsonb_agg(x), '[]'::jsonb) into v_worst from (
    select jsonb_build_object('name', name, 'qty', sum(q), 'revenue_minor', sum(rev), 'cost_minor', sum(cst), 'profit_minor', sum(rev - cst)) as x
    from _pl group by name having sum(rev - cst) < 0 order by sum(rev - cst) limit 8) t;

  select count(*) into v_nocost from public.products p where p.status = 'published' and not exists (select 1 from public.product_costs c where c.product_id = p.id);
  return jsonb_build_object('from', p_from, 'to', p_to, 'totals', v_tot, 'sales', v_sales, 'series', v_series, 'top', v_top, 'worst', v_worst, 'products_without_cost', v_nocost);
end $$;

revoke all on function public.cost_get(uuid), public.cost_set(uuid, bigint), public.cost_set_bulk(jsonb), public.profit_report(timestamptz, timestamptz) from public, anon;
grant execute on function public.cost_get(uuid), public.cost_set(uuid, bigint), public.cost_set_bulk(jsonb), public.profit_report(timestamptz, timestamptz) to authenticated;

-- every product cost by SKU, for the Excel export
create or replace function public.cost_list() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (public.has_permission('cost.manage') or public.has_permission('profit.view')) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return coalesce((select jsonb_object_agg(p.sku, c.cost_minor) from public.product_costs c join public.products p on p.id = c.product_id), '{}'::jsonb);
end $$;
revoke all on function public.cost_list() from public, anon;
grant execute on function public.cost_list() to authenticated;
