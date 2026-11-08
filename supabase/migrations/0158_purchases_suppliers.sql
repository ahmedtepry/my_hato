-- المشتريات والموردين: suppliers, purchase orders, receiving (adds to stock through goods_receipt_create) and supplier payments.
insert into public.permission_catalog (permission, grp, name_ar, name_en, desc_ar, desc_en, sensitive, inert, sort) values
 ('purchases.view',    'stock', 'يشوف الموردين وأوامر الشراء', 'See suppliers and purchase orders', 'مين المورد وإيه اتطلب وكام المتبقي عليك', 'Who the supplier is, what was ordered and what you still owe', false, false, 60),
 ('purchases.manage',  'stock', 'يعمل أوامر شراء ويدير الموردين', 'Create purchase orders and manage suppliers', 'مورد جديد، أمر شراء، تأكيد أو إلغاء', 'New supplier, purchase order, confirm or cancel', true, false, 61),
 ('purchases.receive', 'stock', 'يستلم أمر الشراء ويزوّد المخزن', 'Receive a purchase order into stock', 'الاستلام بيزوّد المخزن (محتاج صلاحية استلام بضاعة كمان)', 'Receiving adds to stock (also needs the goods-receipt permission)', true, false, 62),
 ('purchases.pay',     'stock', 'يسجّل دفعات للمورد', 'Record supplier payments', 'كام اتدفع للمورد من كل أمر', 'How much was paid to the supplier per order', true, false, 63)
on conflict (permission) do nothing;
insert into public.role_permissions (role, permission) values
 ('owner','purchases.view'),('owner','purchases.manage'),('owner','purchases.receive'),('owner','purchases.pay'),
 ('manager','purchases.view'),('manager','purchases.manage'),('manager','purchases.receive'),
 ('accountant','purchases.view'),('accountant','purchases.pay')
on conflict do nothing;

create sequence if not exists public.purchase_order_seq;
create table if not exists public.suppliers (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(btrim(name)) between 1 and 120),
  phone text check (phone is null or char_length(phone) <= 30),
  note text check (note is null or char_length(note) <= 300),
  is_active boolean not null default true,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);
create unique index if not exists suppliers_name_uq on public.suppliers (lower(btrim(name)));
create table if not exists public.purchase_orders (
  id uuid primary key default gen_random_uuid(),
  number text not null unique default ('PO-' || lpad(nextval('public.purchase_order_seq')::text, 5, '0')),
  supplier_id uuid not null references public.suppliers(id),
  branch_id uuid references public.branches(id),
  status text not null default 'draft' check (status in ('draft','ordered','partial','received','cancelled')),
  expected_date date,
  note text check (note is null or char_length(note) <= 300),
  total_minor bigint not null default 0 check (total_minor >= 0),
  paid_minor bigint not null default 0 check (paid_minor >= 0),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);
create table if not exists public.purchase_order_items (
  id uuid primary key default gen_random_uuid(),
  po_id uuid not null references public.purchase_orders(id) on delete cascade,
  product_id uuid not null references public.products(id),
  qty int not null check (qty between 1 and 100000),
  received_qty int not null default 0 check (received_qty >= 0),
  cost_minor bigint not null check (cost_minor between 0 and 100000000000),
  unique (po_id, product_id),
  check (received_qty <= qty)
);
create table if not exists public.supplier_payments (
  id uuid primary key default gen_random_uuid(),
  po_id uuid not null references public.purchase_orders(id),
  supplier_id uuid not null references public.suppliers(id),
  amount_minor bigint not null check (amount_minor > 0 and amount_minor <= 100000000000),
  method text not null default 'cash' check (method in ('cash','transfer','wallet','cheque')),
  note text check (note is null or char_length(note) <= 200),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);
alter table public.suppliers enable row level security;
alter table public.purchase_orders enable row level security;
alter table public.purchase_order_items enable row level security;
alter table public.supplier_payments enable row level security;
revoke all on public.suppliers, public.purchase_orders, public.purchase_order_items, public.supplier_payments from anon, authenticated, public;

create or replace function public.supplier_save(p_id uuid, p_name text, p_phone text, p_note text, p_active boolean default true)
 returns uuid language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid; v_name text := btrim(coalesce(p_name, ''));
begin
  perform public.require_permission('purchases.manage');
  if char_length(v_name) not between 1 and 120 or char_length(coalesce(p_phone,'')) > 30 or char_length(coalesce(p_note,'')) > 300 then raise exception 'INVALID_INPUT'; end if;
  if p_id is null then
    insert into public.suppliers (name, phone, note, is_active, created_by) values (v_name, nullif(btrim(coalesce(p_phone,'')),''), nullif(btrim(coalesce(p_note,'')),''), coalesce(p_active,true), auth.uid()) returning id into v_id;
  else
    update public.suppliers set name = v_name, phone = nullif(btrim(coalesce(p_phone,'')),''), note = nullif(btrim(coalesce(p_note,'')),''), is_active = coalesce(p_active,true) where id = p_id returning id into v_id;
    if v_id is null then raise exception 'NOT_FOUND'; end if;
  end if;
  perform public.audit_write('supplier.save', 'supplier', v_id::text, jsonb_build_object('name', v_name));
  return v_id;
exception when unique_violation then raise exception 'SUPPLIER_EXISTS';
end $$;

create or replace function public.suppliers_list()
 returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
begin
  perform public.require_permission('purchases.view');
  return coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'phone', s.phone, 'note', s.note, 'is_active', s.is_active,
      'orders', coalesce(t.n, 0), 'total_minor', coalesce(t.total, 0), 'paid_minor', coalesce(t.paid, 0), 'owed_minor', coalesce(t.total, 0) - coalesce(t.paid, 0)) order by s.is_active desc, lower(s.name))
    from public.suppliers s
    left join lateral (select count(*) n, sum(total_minor) total, sum(paid_minor) paid from public.purchase_orders o where o.supplier_id = s.id and o.status <> 'cancelled') t on true), '[]'::jsonb);
end $$;

create or replace function public.purchase_save(p_id uuid, p_supplier uuid, p_branch uuid, p_expected date, p_note text, p_items jsonb)
 returns uuid language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid; it jsonb; v_total bigint := 0; v_seen uuid[] := '{}'; v_pid uuid; v_q int; v_c bigint; st text;
begin
  perform public.require_permission('purchases.manage');
  if not exists (select 1 from public.suppliers where id = p_supplier and is_active) then raise exception 'NOT_FOUND'; end if;
  if p_branch is not null and not public._branch_ok(p_branch) then raise exception 'FORBIDDEN'; end if;
  if p_note is not null and char_length(p_note) > 300 then raise exception 'INVALID_INPUT'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 60 then raise exception 'INVALID_INPUT'; end if;
  if p_id is null then
    insert into public.purchase_orders (supplier_id, branch_id, expected_date, note, created_by) values (p_supplier, p_branch, p_expected, nullif(btrim(coalesce(p_note,'')),''), auth.uid()) returning id into v_id;
  else
    select status into st from public.purchase_orders where id = p_id for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    if st <> 'draft' then raise exception 'NOT_DRAFT'; end if;
    v_id := p_id;
    update public.purchase_orders set supplier_id = p_supplier, branch_id = p_branch, expected_date = p_expected, note = nullif(btrim(coalesce(p_note,'')),'') where id = v_id;
    delete from public.purchase_order_items where po_id = v_id;
  end if;
  for it in select * from jsonb_array_elements(p_items) loop
    v_pid := (it ->> 'product_id')::uuid; v_q := (it ->> 'qty')::int; v_c := (it ->> 'cost_minor')::bigint;
    if v_q is null or v_q < 1 or v_q > 100000 or v_c is null or v_c < 0 or v_c > 100000000000 or v_pid = any (v_seen) then raise exception 'INVALID_INPUT'; end if;
    if not exists (select 1 from public.products where id = v_pid) then raise exception 'NOT_FOUND'; end if;
    v_seen := v_seen || v_pid;
    insert into public.purchase_order_items (po_id, product_id, qty, cost_minor) values (v_id, v_pid, v_q, v_c);
    v_total := v_total + v_q * v_c;
  end loop;
  update public.purchase_orders set total_minor = v_total where id = v_id;
  perform public.audit_write('purchase.save', 'purchase_order', v_id::text, jsonb_build_object('total_minor', v_total, 'supplier', p_supplier));
  return v_id;
end $$;

create or replace function public.purchase_set_status(p_id uuid, p_status text)
 returns void language plpgsql security definer set search_path to 'public' as $$
declare o public.purchase_orders;
begin
  perform public.require_permission('purchases.manage');
  if p_status not in ('ordered','cancelled') then raise exception 'INVALID_INPUT'; end if;
  select * into o from public.purchase_orders where id = p_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if p_status = 'ordered' and o.status <> 'draft' then raise exception 'INVALID_STATE'; end if;
  if p_status = 'cancelled' and (o.status not in ('draft','ordered') or o.paid_minor > 0) then raise exception 'INVALID_STATE'; end if;
  update public.purchase_orders set status = p_status where id = p_id;
  perform public.audit_write('purchase.' || p_status, 'purchase_order', p_id::text, jsonb_build_object('number', o.number));
end $$;

create or replace function public.purchase_receive(p_id uuid, p_items jsonb)
 returns text language plpgsql security definer set search_path to 'public' as $$
declare o public.purchase_orders; it jsonb; r public.purchase_order_items; v_q int; v_lines jsonb := '[]'::jsonb; v_sup text; v_num text; v_all boolean; v_seen uuid[] := '{}'; v_iid uuid;
begin
  perform public.require_permission('purchases.receive');
  if not public.has_permission('shortcut.goods_receipt') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 60 then raise exception 'INVALID_INPUT'; end if;
  select * into o from public.purchase_orders where id = p_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if o.status not in ('ordered','partial') then raise exception 'INVALID_STATE'; end if;
  select name into v_sup from public.suppliers where id = o.supplier_id;
  for it in select * from jsonb_array_elements(p_items) loop
    v_iid := (it ->> 'item_id')::uuid; v_q := (it ->> 'qty')::int;
    if v_q is null or v_q < 1 or v_iid = any (v_seen) then raise exception 'INVALID_INPUT'; end if;
    v_seen := v_seen || v_iid;
    select * into r from public.purchase_order_items where id = v_iid and po_id = p_id for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    if v_q > r.qty - r.received_qty then raise exception 'RECEIVE_EXCEEDS_ORDER'; end if;
    update public.purchase_order_items set received_qty = received_qty + v_q where id = r.id;
    v_lines := v_lines || jsonb_build_array(jsonb_build_object('product_id', r.product_id, 'qty', v_q, 'cost_minor', r.cost_minor));
  end loop;
  v_num := public.goods_receipt_create(v_sup, o.branch_id, v_lines, 'أمر شراء ' || o.number);
  select bool_and(received_qty = qty) into v_all from public.purchase_order_items where po_id = p_id;
  update public.purchase_orders set status = case when v_all then 'received' else 'partial' end where id = p_id;
  perform public.audit_write('purchase.receive', 'purchase_order', p_id::text, jsonb_build_object('number', o.number, 'receipt', v_num));
  return v_num;
end $$;

create or replace function public.purchase_pay(p_id uuid, p_amount_minor bigint, p_method text, p_note text)
 returns void language plpgsql security definer set search_path to 'public' as $$
declare o public.purchase_orders;
begin
  perform public.require_permission('purchases.pay');
  if p_amount_minor is null or p_amount_minor < 1 or p_method not in ('cash','transfer','wallet','cheque') or char_length(coalesce(p_note,'')) > 200 then raise exception 'INVALID_INPUT'; end if;
  select * into o from public.purchase_orders where id = p_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if o.status = 'cancelled' or o.status = 'draft' then raise exception 'INVALID_STATE'; end if;
  if o.paid_minor + p_amount_minor > o.total_minor then raise exception 'OVERPAY'; end if;
  insert into public.supplier_payments (po_id, supplier_id, amount_minor, method, note, created_by) values (p_id, o.supplier_id, p_amount_minor, p_method, nullif(btrim(coalesce(p_note,'')),''), auth.uid());
  update public.purchase_orders set paid_minor = paid_minor + p_amount_minor where id = p_id;
  perform public.audit_write('purchase.pay', 'purchase_order', p_id::text, jsonb_build_object('number', o.number, 'amount_minor', p_amount_minor, 'method', p_method));
end $$;

create or replace function public.purchases_list(p_status text default null)
 returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
begin
  perform public.require_permission('purchases.view');
  return coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'number', o.number, 'status', o.status, 'supplier', s.name, 'supplier_id', o.supplier_id,
      'branch_id', o.branch_id, 'expected_date', o.expected_date, 'total_minor', o.total_minor, 'paid_minor', o.paid_minor, 'created_at', o.created_at,
      'items', (select count(*) from public.purchase_order_items i where i.po_id = o.id)) order by o.created_at desc)
    from public.purchase_orders o join public.suppliers s on s.id = o.supplier_id
    where (p_status is null or o.status = p_status)), '[]'::jsonb);
end $$;

create or replace function public.purchase_get(p_id uuid)
 returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare o public.purchase_orders;
begin
  perform public.require_permission('purchases.view');
  select * into o from public.purchase_orders where id = p_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  return jsonb_build_object('order', to_jsonb(o), 'supplier', (select to_jsonb(s) from public.suppliers s where s.id = o.supplier_id),
    'items', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'product_id', i.product_id, 'name_ar', p.name_ar, 'name_en', p.name_en, 'sku', p.sku, 'qty', i.qty, 'received_qty', i.received_qty, 'cost_minor', i.cost_minor) order by p.name_ar)
        from public.purchase_order_items i join public.products p on p.id = i.product_id where i.po_id = p_id), '[]'::jsonb),
    'payments', coalesce((select jsonb_agg(jsonb_build_object('amount_minor', amount_minor, 'method', method, 'note', note, 'created_at', created_at) order by created_at desc) from public.supplier_payments where po_id = p_id), '[]'::jsonb));
end $$;

revoke execute on function public.supplier_save, public.suppliers_list, public.purchase_save, public.purchase_set_status, public.purchase_receive, public.purchase_pay, public.purchases_list, public.purchase_get from anon, public;
grant execute on function public.supplier_save, public.suppliers_list, public.purchase_save, public.purchase_set_status, public.purchase_receive, public.purchase_pay, public.purchases_list, public.purchase_get to authenticated;
