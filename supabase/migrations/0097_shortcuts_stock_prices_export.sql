-- 0097: the first four "اختصارات" become real:
--   shortcut.goods_receipt  استلام بضاعة من المورد   (adds pieces to the store, optionally straight into a branch)
--   shortcut.stocktake      الجرد                    (count a branch, the system is corrected and the difference is recorded)
--   shortcut.price_edit     تعديل الأسعار             (selling price only, every change is logged)
--   shortcut.export         تصدير البيانات            (CSV: products, counter sales, online orders, customers)
-- Roles: owner gets all four; manager gets receipt + stocktake (only inside his own branch).

update public.permission_catalog set inert = false where permission in ('shortcut.goods_receipt','shortcut.stocktake','shortcut.price_edit','shortcut.export');
insert into public.role_permissions (role, permission) values
 ('owner','shortcut.goods_receipt'),('owner','shortcut.stocktake'),('owner','shortcut.price_edit'),('owner','shortcut.export'),
 ('manager','shortcut.goods_receipt'),('manager','shortcut.stocktake')
on conflict do nothing;

-- ------------------------------------------------------------ tables
create sequence if not exists public.goods_receipt_seq;
create table if not exists public.goods_receipts (
  id uuid primary key default gen_random_uuid(),
  number text not null unique default ('GR-' || lpad(nextval('public.goods_receipt_seq')::text, 5, '0')),
  supplier text not null check (char_length(supplier) between 1 and 120),
  branch_id uuid references public.branches(id),   -- null = the warehouse (not given to a branch yet)
  note text check (note is null or char_length(note) <= 300),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);
create table if not exists public.goods_receipt_items (
  receipt_id uuid not null references public.goods_receipts(id) on delete cascade,
  product_id uuid not null references public.products(id),
  sku text, name_ar text, name_en text,
  qty int not null check (qty > 0),
  cost_minor bigint check (cost_minor is null or cost_minor >= 0),
  primary key (receipt_id, product_id)
);
create sequence if not exists public.stocktake_seq;
create table if not exists public.stocktakes (
  id uuid primary key default gen_random_uuid(),
  number text not null unique default ('ST-' || lpad(nextval('public.stocktake_seq')::text, 5, '0')),
  branch_id uuid not null references public.branches(id),
  note text check (note is null or char_length(note) <= 300),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  lines int not null default 0,
  diff_pieces int not null default 0
);
create table if not exists public.stocktake_items (
  stocktake_id uuid not null references public.stocktakes(id) on delete cascade,
  product_id uuid not null references public.products(id),
  sku text, name_ar text, name_en text,
  expected int not null, counted int not null check (counted >= 0),
  primary key (stocktake_id, product_id)
);
create table if not exists public.price_changes (
  id bigint generated always as identity primary key,
  product_id uuid not null references public.products(id),
  sku text, name_ar text,
  old_price_minor bigint not null, new_price_minor bigint not null,
  old_compare_minor bigint, new_compare_minor bigint,
  changed_by uuid references auth.users(id),
  changed_at timestamptz not null default now()
);
alter table public.goods_receipts enable row level security;
alter table public.goods_receipt_items enable row level security;
alter table public.stocktakes enable row level security;
alter table public.stocktake_items enable row level security;
alter table public.price_changes enable row level security;   -- no policies: only the functions below touch them

create or replace function public._name_of(p_user uuid) returns text
language sql stable security definer set search_path = public as $$
  select coalesce(nullif(btrim(full_name), ''), email, 'موظف') from public.profiles where id = p_user
$$;
revoke all on function public._name_of(uuid) from public, anon, authenticated;

-- ------------------------------------------------------------ product picker (shared by receipt / stocktake / price)
create or replace function public.shortcut_products(p_search text default null, p_branch uuid default null, p_limit int default 40) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_q text := nullif(btrim(coalesce(p_search, '')), '');
begin
  if not (public.has_permission('shortcut.goods_receipt') or public.has_permission('shortcut.stocktake') or public.has_permission('shortcut.price_edit')) then
    raise exception 'FORBIDDEN';
  end if;
  if p_branch is not null and not public._branch_ok(p_branch) then raise exception 'FORBIDDEN'; end if;
  return coalesce((select jsonb_agg(x order by x.name_ar) from (
    select p.id as product_id, p.sku, p.name_ar, p.name_en, p.price_minor, p.compare_at_price_minor as compare_minor, p.stock_quantity as total,
           case when p_branch is null then null else coalesce((select quantity from public.branch_stock bs where bs.branch_id = p_branch and bs.product_id = p.id), 0) end as branch_qty
      from public.products p
     where p.status <> 'archived'
       and (v_q is null or p.name_ar ilike '%' || v_q || '%' or p.name_en ilike '%' || v_q || '%' or p.sku ilike '%' || v_q || '%')
     order by p.name_ar limit least(greatest(coalesce(p_limit, 40), 1), 100)) x), '[]'::jsonb);
end $$;
revoke all on function public.shortcut_products(text, uuid, int) from public, anon;
grant execute on function public.shortcut_products(text, uuid, int) to authenticated;

-- ------------------------------------------------------------ 1) goods receipt
create or replace function public.goods_receipt_create(p_supplier text, p_branch uuid, p_items jsonb, p_note text default null) returns text
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := public.require_auth(); v_id uuid; v_num text; it jsonb; p public.products; v_pid uuid; v_q int; v_cost bigint;
        v_seen uuid[] := '{}'; v_total int := 0; v_sup text := btrim(coalesce(p_supplier, '')); v_u uuid; v_bn text;
begin
  perform public.require_permission('shortcut.goods_receipt');
  if char_length(v_sup) not between 1 and 120 or (p_note is not null and char_length(p_note) > 300) then raise exception 'INVALID_INPUT'; end if;
  if p_branch is null then
    if not public.has_permission('stock.allocate') then raise exception 'FORBIDDEN'; end if;      -- the warehouse is the allocator's
  elsif not public._branch_ok(p_branch) then raise exception 'FORBIDDEN';
  end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 50 then raise exception 'INVALID_INPUT'; end if;
  insert into public.goods_receipts (supplier, branch_id, note, created_by) values (v_sup, p_branch, nullif(btrim(coalesce(p_note, '')), ''), v_uid) returning id, number into v_id, v_num;
  for it in select * from jsonb_array_elements(p_items) loop
    v_pid := (it ->> 'product_id')::uuid; v_q := (it ->> 'qty')::int; v_cost := nullif(it ->> 'cost_minor', '')::bigint;
    if v_q is null or v_q < 1 or v_q > 100000 or v_pid = any (v_seen) or (v_cost is not null and (v_cost < 0 or v_cost > 100000000000)) then raise exception 'INVALID_INPUT'; end if;
    v_seen := v_seen || v_pid;
    select * into p from public.products where id = v_pid for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    perform set_config('myhato.stock_ctx', 'receipt', true);
    update public.products set stock_quantity = stock_quantity + v_q where id = v_pid;
    perform set_config('myhato.stock_ctx', '', true);
    insert into public.inventory_movements (product_id, delta, reason, note, created_by) values (v_pid, v_q, 'restock', left('استلام ' || v_num || ' من ' || v_sup, 300), v_uid);
    if p_branch is not null then perform public._branch_stock_add(p_branch, v_pid, v_q); end if;
    insert into public.goods_receipt_items (receipt_id, product_id, sku, name_ar, name_en, qty, cost_minor) values (v_id, v_pid, p.sku, p.name_ar, p.name_en, v_q, v_cost);
    if v_cost is not null and public.has_permission('cost.manage') then
      insert into public.product_costs (product_id, cost_minor, updated_by) values (v_pid, v_cost, v_uid)
      on conflict (product_id) do update set cost_minor = excluded.cost_minor, updated_by = excluded.updated_by, updated_at = now();
    end if;
    v_total := v_total + v_q;
  end loop;
  perform public.audit_write('goods.receipt', 'goods_receipt', v_id::text, jsonb_build_object('number', v_num, 'supplier', v_sup, 'branch', p_branch, 'pieces', v_total));
  select name_ar into v_bn from public.branches where id = p_branch;
  for v_u in select user_id from public.user_roles where role = 'owner' loop
    if v_u <> v_uid then
      perform public.notify_user(v_u, '📥 بضاعة جديدة اتسجلت', '📥 Goods received',
        public._name_of(v_uid) || ' سجّل استلام ' || v_total || ' قطعة من ' || v_sup || ' (' || v_num || ') ' || coalesce('في فرع ' || v_bn, 'في المخزن الرئيسي') || '.',
        public._name_of(v_uid) || ' recorded ' || v_total || ' pieces from ' || v_sup || ' (' || v_num || ').', 'system', null, v_num, '/');
    end if;
  end loop;
  return v_num;
end $$;
revoke all on function public.goods_receipt_create(text, uuid, jsonb, text) from public, anon;
grant execute on function public.goods_receipt_create(text, uuid, jsonb, text) to authenticated;

create or replace function public.goods_receipts_list(p_limit int default 30) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_cost boolean;
begin
  perform public.require_permission('shortcut.goods_receipt');
  v_cost := public.has_permission('cost.manage');
  return coalesce((select jsonb_agg(x order by x.created_at desc) from (
    select r.id, r.number, r.supplier, r.note, r.created_at, r.branch_id, b.name_ar as branch_name, public._name_of(r.created_by) as created_by_name,
           (select jsonb_agg(jsonb_build_object('name_ar', i.name_ar, 'sku', i.sku, 'qty', i.qty, 'cost_minor', case when v_cost then i.cost_minor end) order by i.name_ar)
              from public.goods_receipt_items i where i.receipt_id = r.id) as items
      from public.goods_receipts r left join public.branches b on b.id = r.branch_id
     where (r.branch_id is null and public.has_permission('stock.allocate')) or (r.branch_id is not null and public._branch_view_ok(r.branch_id)) or r.created_by = auth.uid()
     order by r.created_at desc limit least(greatest(coalesce(p_limit, 30), 1), 100)) x), '[]'::jsonb);
end $$;
revoke all on function public.goods_receipts_list(int) from public, anon;
grant execute on function public.goods_receipts_list(int) to authenticated;

-- ------------------------------------------------------------ 2) stocktake
-- p_items = [{product_id, counted}] for the products he really counted. For each one the branch store is set to the counted number
-- and the store total moves by the same difference (movement reason 'correction').
create or replace function public.stocktake_apply(p_branch uuid, p_items jsonb, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := public.require_auth(); v_id uuid; v_num text; it jsonb; p public.products; v_pid uuid; v_c int; v_exp int; v_diff int;
        v_seen uuid[] := '{}'; v_lines int := 0; v_sum int := 0; v_changed int := 0; v_u uuid; v_bn text; v_out jsonb := '[]'::jsonb;
begin
  perform public.require_permission('shortcut.stocktake');
  if p_branch is null or not public._branch_ok(p_branch) then raise exception 'FORBIDDEN'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 300 or (p_note is not null and char_length(p_note) > 300) then raise exception 'INVALID_INPUT'; end if;
  insert into public.stocktakes (branch_id, note, created_by) values (p_branch, nullif(btrim(coalesce(p_note, '')), ''), v_uid) returning id, number into v_id, v_num;
  for it in select * from jsonb_array_elements(p_items) loop
    v_pid := (it ->> 'product_id')::uuid; v_c := (it ->> 'counted')::int;
    if v_c is null or v_c < 0 or v_c > 1000000 or v_pid = any (v_seen) then raise exception 'INVALID_INPUT'; end if;
    v_seen := v_seen || v_pid;
    select * into p from public.products where id = v_pid for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    v_exp := coalesce((select quantity from public.branch_stock where branch_id = p_branch and product_id = v_pid), 0);
    v_diff := v_c - v_exp;
    insert into public.stocktake_items (stocktake_id, product_id, sku, name_ar, name_en, expected, counted) values (v_id, v_pid, p.sku, p.name_ar, p.name_en, v_exp, v_c);
    v_lines := v_lines + 1;
    if v_diff <> 0 then
      perform public._branch_stock_add(p_branch, v_pid, v_diff);
      perform set_config('myhato.stock_ctx', 'stocktake', true);
      update public.products set stock_quantity = stock_quantity + v_diff where id = v_pid;
      perform set_config('myhato.stock_ctx', '', true);
      insert into public.inventory_movements (product_id, delta, reason, note, created_by) values (v_pid, v_diff, 'correction', 'جرد ' || v_num, v_uid);
      v_sum := v_sum + v_diff; v_changed := v_changed + 1;
      v_out := v_out || jsonb_build_object('name_ar', p.name_ar, 'expected', v_exp, 'counted', v_c, 'diff', v_diff);
    end if;
  end loop;
  update public.stocktakes set lines = v_lines, diff_pieces = v_sum where id = v_id;
  perform public.audit_write('stocktake.apply', 'stocktake', v_id::text, jsonb_build_object('number', v_num, 'branch', p_branch, 'lines', v_lines, 'changed', v_changed, 'diff', v_sum));
  if v_changed > 0 then
    select name_ar into v_bn from public.branches where id = p_branch;
    for v_u in select user_id from public.user_roles where role = 'owner' loop
      if v_u <> v_uid then
        perform public.notify_user(v_u, '🧮 جرد فرع ' || v_bn, '🧮 Stocktake: ' || v_bn,
          public._name_of(v_uid) || ' جرد فرع ' || v_bn || ' (' || v_num || '): ' || v_changed || ' منتج فيه فرق، إجمالي الفرق ' || v_sum || ' قطعة.',
          public._name_of(v_uid) || ' counted ' || v_bn || ' (' || v_num || '): ' || v_changed || ' products differ, net ' || v_sum || ' pieces.', 'system', null, v_num, '/');
      end if;
    end loop;
  end if;
  return jsonb_build_object('number', v_num, 'lines', v_lines, 'changed', v_changed, 'diff_pieces', v_sum, 'differences', v_out);
end $$;
revoke all on function public.stocktake_apply(uuid, jsonb, text) from public, anon;
grant execute on function public.stocktake_apply(uuid, jsonb, text) to authenticated;

create or replace function public.stocktakes_list(p_limit int default 30) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_permission('shortcut.stocktake');
  return coalesce((select jsonb_agg(x order by x.created_at desc) from (
    select s.id, s.number, s.note, s.created_at, s.lines, s.diff_pieces, b.name_ar as branch_name, public._name_of(s.created_by) as created_by_name,
           (select jsonb_agg(jsonb_build_object('name_ar', i.name_ar, 'expected', i.expected, 'counted', i.counted) order by i.name_ar)
              from public.stocktake_items i where i.stocktake_id = s.id and i.expected <> i.counted) as differences
      from public.stocktakes s join public.branches b on b.id = s.branch_id
     where public._branch_view_ok(s.branch_id) or s.created_by = auth.uid()
     order by s.created_at desc limit least(greatest(coalesce(p_limit, 30), 1), 100)) x), '[]'::jsonb);
end $$;
revoke all on function public.stocktakes_list(int) from public, anon;
grant execute on function public.stocktakes_list(int) to authenticated;

-- ------------------------------------------------------------ 3) price edit
create or replace function public.product_price_set(p_product uuid, p_price_minor bigint, p_compare_minor bigint default null) returns void
language plpgsql security definer set search_path = public as $$
declare p public.products;
begin
  perform public.require_permission('shortcut.price_edit');
  if p_price_minor is null or p_price_minor < 0 or p_price_minor > 100000000000 then raise exception 'INVALID_INPUT'; end if;
  if p_compare_minor is not null and p_compare_minor <= p_price_minor then raise exception 'INVALID_COMPARE'; end if;
  select * into p from public.products where id = p_product for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if p.price_minor = p_price_minor and p.compare_at_price_minor is not distinct from p_compare_minor then return; end if;
  update public.products set price_minor = p_price_minor, compare_at_price_minor = p_compare_minor where id = p_product;
  insert into public.price_changes (product_id, sku, name_ar, old_price_minor, new_price_minor, old_compare_minor, new_compare_minor, changed_by)
  values (p_product, p.sku, p.name_ar, p.price_minor, p_price_minor, p.compare_at_price_minor, p_compare_minor, auth.uid());
  perform public.audit_write('price.edit', 'product', p_product::text, jsonb_build_object('from', p.price_minor, 'to', p_price_minor, 'compare_from', p.compare_at_price_minor, 'compare_to', p_compare_minor));
end $$;
revoke all on function public.product_price_set(uuid, bigint, bigint) from public, anon;
grant execute on function public.product_price_set(uuid, bigint, bigint) to authenticated;

create or replace function public.price_changes_list(p_limit int default 30) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_permission('shortcut.price_edit');
  return coalesce((select jsonb_agg(x order by x.changed_at desc) from (
    select c.id, c.sku, c.name_ar, c.old_price_minor, c.new_price_minor, c.old_compare_minor, c.new_compare_minor, c.changed_at, public._name_of(c.changed_by) as changed_by_name
      from public.price_changes c order by c.changed_at desc limit least(greatest(coalesce(p_limit, 30), 1), 100)) x), '[]'::jsonb);
end $$;
revoke all on function public.price_changes_list(int) from public, anon;
grant execute on function public.price_changes_list(int) to authenticated;

-- ------------------------------------------------------------ 4) export
-- returns {headers:[...], rows:[[...]]}; the app turns it into a CSV file. Counter sales are limited to the branches he may view.
create or replace function public.export_data(p_kind text, p_from date default null, p_to date default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_h jsonb; v_r jsonb; v_from date := coalesce(p_from, current_date - 30); v_to date := coalesce(p_to, current_date); v_cost boolean;
begin
  perform public.require_permission('shortcut.export');
  if p_kind not in ('products', 'pos_sales', 'orders', 'customers') then raise exception 'INVALID_INPUT'; end if;
  if v_to < v_from or v_to - v_from > 400 then raise exception 'INVALID_INPUT'; end if;
  if p_kind = 'products' then
    v_cost := public.has_permission('cost.manage');
    v_h := case when v_cost then '["SKU","الاسم","Name","السعر","السعر قبل الخصم","الكمية","الحالة","التكلفة"]' else '["SKU","الاسم","Name","السعر","السعر قبل الخصم","الكمية","الحالة"]' end::jsonb;
    select coalesce(jsonb_agg(case when v_cost then base || jsonb_build_array(c.cost) else base end order by p.name_ar), '[]'::jsonb) into v_r from (
      select p.id, p.name_ar, jsonb_build_array(p.sku, p.name_ar, p.name_en, round(p.price_minor / 100.0, 2), round(p.compare_at_price_minor / 100.0, 2), p.stock_quantity, p.status::text) as base
        from public.products p where p.status <> 'archived' limit 20000) p
      left join lateral (select round(pc.cost_minor / 100.0, 2) as cost from public.product_costs pc where pc.product_id = p.id) c on true;
  elsif p_kind = 'pos_sales' then
    v_h := '["رقم الفاتورة","التاريخ","الفرع","الكاشير","الإجمالي","الخصم","المرتجع"]'::jsonb;
    select coalesce(jsonb_agg(jsonb_build_array(s.number, to_char(s.created_at at time zone 'Africa/Cairo', 'YYYY-MM-DD HH24:MI'), b.name_ar, public._name_of(s.cashier_id),
             round(s.total_minor / 100.0, 2), round(s.discount_minor / 100.0, 2), round(s.refunded_minor / 100.0, 2)) order by s.created_at), '[]'::jsonb) into v_r
      from public.pos_sales s join public.branches b on b.id = s.branch_id
     where (s.created_at at time zone 'Africa/Cairo')::date between v_from and v_to and public._branch_view_ok(s.branch_id);
  elsif p_kind = 'orders' then
    perform public.require_permission('orders.view');
    v_h := '["رقم الطلب","التاريخ","الحالة","الدفع","الإجمالي"]'::jsonb;
    select coalesce(jsonb_agg(jsonb_build_array(o.reference, to_char(o.created_at at time zone 'Africa/Cairo', 'YYYY-MM-DD HH24:MI'), o.status::text, o.payment_method::text,
             round(o.total_minor / 100.0, 2)) order by o.created_at), '[]'::jsonb) into v_r
      from public.orders o where (o.created_at at time zone 'Africa/Cairo')::date between v_from and v_to;
  else
    perform public.require_permission('orders.view');
    v_h := '["الاسم","الموبايل","الإيميل","تاريخ التسجيل"]'::jsonb;
    select coalesce(jsonb_agg(jsonb_build_array(pr.full_name, pr.phone, pr.email, to_char(pr.created_at at time zone 'Africa/Cairo', 'YYYY-MM-DD')) order by pr.created_at), '[]'::jsonb) into v_r
      from public.profiles pr where not exists (select 1 from public.user_roles ur where ur.user_id = pr.id);
  end if;
  perform public.audit_write('data.export', 'export', p_kind, jsonb_build_object('from', v_from, 'to', v_to, 'rows', jsonb_array_length(v_r)));
  return jsonb_build_object('headers', v_h, 'rows', v_r);
end $$;
revoke all on function public.export_data(text, date, date) from public, anon;
grant execute on function public.export_data(text, date, date) to authenticated;
