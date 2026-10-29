-- 0092: "المخزن": stock per branch and transfers between branches.
-- The store keeps ONE total per product (products.stock_quantity, what the online shop and the cash desk already use). This adds how that total is spread over
-- the branches (branch_stock); what is not given to a branch yet is "غير موزّع" (= total - sum of the branches). Counter sales take from their own branch,
-- online orders take from the unallocated part first and then from the biggest branch, so the numbers always add up.
-- A transfer takes the pieces out of the sender's branch at once (they are "on the way"), the other branch gets a notification and confirms what it really
-- received; missing pieces go back to the sender. Permissions: stock.view, stock.allocate, stock.transfer, stock.receive (+ inventory.manage that already exists).

insert into public.permission_catalog (permission, grp, name_ar, name_en, desc_ar, desc_en, sensitive, inert, sort) values
 ('stock.view', 'team', 'يشوف المخزن', 'View the stock',
  'يشوف أرصدة المنتجات في مخازن الفروع والتحويلات (فرعه بس، أو كل الفروع لو معاه «يشوف كل الفروع»)',
  'Sees product quantities in the branch stores and the transfers (his own branch, or all branches with "see every branch")', false, false, 110),
 ('stock.allocate', 'team', 'يوزّع المنتجات على الفروع', 'Allocate products to branches',
  'يحدد كمية كل منتج في مخزن كل فرع من الرصيد غير الموزّع',
  'Sets how many pieces of each product sit in each branch store, from the unallocated stock', true, false, 111),
 ('stock.transfer', 'team', 'يحوّل منتجات بين الفروع', 'Transfer products between branches',
  'يبعت منتجات من مخزن فرعه لفرع تاني، ويلغي التحويل قبل ما يتستلم. اسمه بيتسجل في التحويل',
  'Sends products from his branch store to another branch and cancels a transfer before it is received. His name is recorded', true, false, 112),
 ('stock.receive', 'team', 'يستلم التحويلات', 'Receive transfers',
  'يأكد استلام المنتجات اللي اتحولت لفرعه (بالعدد اللي وصل فعلًا) أو يرفضها بسبب',
  'Confirms the products sent to his branch (the quantity that really arrived) or rejects them with a reason', true, false, 113)
on conflict (permission) do update set name_ar = excluded.name_ar, name_en = excluded.name_en, desc_ar = excluded.desc_ar, desc_en = excluded.desc_en;
insert into public.role_permissions (role, permission) values
 ('owner', 'stock.view'), ('owner', 'stock.allocate'), ('owner', 'stock.transfer'), ('owner', 'stock.receive'),
 ('manager', 'stock.view'), ('manager', 'stock.transfer'), ('manager', 'stock.receive'),
 ('sales', 'stock.view'), ('sales', 'stock.transfer'), ('sales', 'stock.receive'),
 ('accountant', 'stock.view')
on conflict do nothing;

create table if not exists public.branch_stock (
  branch_id uuid not null references public.branches(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  quantity int not null default 0 check (quantity >= 0),
  updated_at timestamptz not null default now(),
  primary key (branch_id, product_id)
);
create sequence if not exists public.stock_transfer_seq;
create table if not exists public.stock_transfers (
  id uuid primary key default gen_random_uuid(),
  number text not null unique default ('TR-' || lpad(nextval('public.stock_transfer_seq')::text, 5, '0')),
  from_branch uuid not null references public.branches(id),
  to_branch uuid not null references public.branches(id),
  status text not null default 'pending' check (status in ('pending', 'received', 'partial', 'rejected', 'cancelled')),
  note text check (note is null or char_length(note) <= 300),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  decided_by uuid references auth.users(id),
  decided_at timestamptz,
  reject_kind text check (reject_kind is null or reject_kind in ('not_received', 'other')),
  reject_reason text check (reject_reason is null or char_length(reject_reason) <= 300),
  check (from_branch <> to_branch)
);
create table if not exists public.stock_transfer_items (
  transfer_id uuid not null references public.stock_transfers(id) on delete cascade,
  product_id uuid not null references public.products(id),
  sku text,
  name_ar text,
  name_en text,
  qty_sent int not null check (qty_sent > 0),
  qty_received int check (qty_received is null or qty_received >= 0),
  primary key (transfer_id, product_id)
);
create index if not exists stock_transfers_to on public.stock_transfers (to_branch, status);
create index if not exists stock_transfers_from on public.stock_transfers (from_branch, status);
alter table public.branch_stock enable row level security;
alter table public.stock_transfers enable row level security;
alter table public.stock_transfer_items enable row level security;   -- no policies: only the functions below touch these tables

-- ---------- keeping the numbers honest ----------
create or replace function public._branch_stock_add(p_branch uuid, p_product uuid, p_delta int) returns void
language sql security definer set search_path = public as $$
  insert into public.branch_stock (branch_id, product_id, quantity) values (p_branch, p_product, greatest(p_delta, 0))
  on conflict (branch_id, product_id) do update set quantity = greatest(public.branch_stock.quantity + p_delta, 0), updated_at = now()
$$;
revoke all on function public._branch_stock_add(uuid, uuid, int) from public, anon, authenticated;

-- unallocated = what the store has minus what the branches hold
create or replace function public._stock_unallocated(p_product uuid) returns int
language sql stable security definer set search_path = public as $$
  select (select stock_quantity from public.products where id = p_product) - coalesce((select sum(quantity) from public.branch_stock where product_id = p_product), 0)
$$;
revoke all on function public._stock_unallocated(uuid) from public, anon, authenticated;

-- the branches can never hold more than the store has: take the excess from the biggest branch
create or replace function public._stock_rebalance(p_product uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_excess int := -public._stock_unallocated(p_product); r record; v_take int;
begin
  if v_excess <= 0 then return; end if;
  for r in select branch_id, quantity from public.branch_stock where product_id = p_product and quantity > 0 order by quantity desc, branch_id loop
    v_take := least(r.quantity, v_excess);
    update public.branch_stock set quantity = quantity - v_take, updated_at = now() where branch_id = r.branch_id and product_id = p_product;
    v_excess := v_excess - v_take;
    exit when v_excess <= 0;
  end loop;
end $$;
revoke all on function public._stock_rebalance(uuid) from public, anon, authenticated;

create or replace function public._stock_movement_sync() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_branch uuid; v_have int; v_take int;
begin
  if new.reason = 'pos_sale' and new.pos_sale_id is not null and new.delta < 0 then
    select branch_id into v_branch from public.pos_sales where id = new.pos_sale_id;
    select quantity into v_have from public.branch_stock where branch_id = v_branch and product_id = new.product_id;
    v_take := least(-new.delta, coalesce(v_have, 0));
    if v_take > 0 then perform public._branch_stock_add(v_branch, new.product_id, -v_take); end if;
  elsif new.reason = 'pos_refund' and new.pos_sale_id is not null and new.delta > 0 then
    select branch_id into v_branch from public.pos_sales where id = new.pos_sale_id;
    v_take := least(new.delta, greatest(public._stock_unallocated(new.product_id), 0));
    if v_take > 0 then perform public._branch_stock_add(v_branch, new.product_id, v_take); end if;
  end if;
  if new.delta < 0 then perform public._stock_rebalance(new.product_id); end if;
  return null;
end $$;
drop trigger if exists inventory_movements_branch_sync on public.inventory_movements;
create trigger inventory_movements_branch_sync after insert on public.inventory_movements
  for each row execute function public._stock_movement_sync();

-- people to tell: members of a branch who may receive/send transfers + the owners
create or replace function public._stock_people(p_branch uuid, p_permission text) returns setof uuid
language sql stable security definer set search_path = public as $$
  select distinct u from (
    select sb.user_id u from public.staff_branches sb
      join public.user_roles ur on ur.user_id = sb.user_id
      join public.role_permissions rp on rp.role = ur.role and rp.permission = p_permission
     where sb.branch_id = p_branch
    union
    select user_id from public.user_roles where role = 'owner') x
   where not exists (select 1 from public.team_members tm where tm.user_id = x.u and tm.suspended_at is not null)
$$;
revoke all on function public._stock_people(uuid, text) from public, anon, authenticated;

-- ---------- reading ----------
create or replace function public.stock_overview(p_branch uuid default null, p_search text default null, p_limit int default 60) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_q text := nullif(btrim(coalesce(p_search, '')), '');
begin
  perform public.require_permission('stock.view');
  if p_branch is not null and not public._branch_view_ok(p_branch) then raise exception 'FORBIDDEN'; end if;
  return coalesce((select jsonb_agg(x order by x.name_ar) from (
    select p.id as product_id, p.sku, p.name_ar, p.name_en, p.stock_quantity as total,
           greatest(public._stock_unallocated(p.id), 0) as unallocated,
           coalesce((select jsonb_agg(jsonb_build_object('branch_id', bs.branch_id, 'qty', bs.quantity))
                       from public.branch_stock bs where bs.product_id = p.id and bs.quantity > 0 and public._branch_view_ok(bs.branch_id)), '[]'::jsonb) as branches
      from public.products p
     where p.status <> 'archived'
       and (v_q is null or p.name_ar ilike '%' || v_q || '%' or p.name_en ilike '%' || v_q || '%' or p.sku ilike '%' || v_q || '%')
       and (p_branch is null or v_q is not null or exists (select 1 from public.branch_stock bs where bs.product_id = p.id and bs.branch_id = p_branch and bs.quantity > 0))
     order by p.name_ar limit least(greatest(coalesce(p_limit, 60), 1), 200)) x), '[]'::jsonb);
end $$;
revoke all on function public.stock_overview(uuid, text, int) from public, anon;
grant execute on function public.stock_overview(uuid, text, int) to authenticated;

create or replace function public.stock_transfers_list(p_limit int default 40) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_can_recv boolean; v_can_send boolean;
begin
  perform public.require_permission('stock.view');
  v_can_recv := public.has_permission('stock.receive'); v_can_send := public.has_permission('stock.transfer');
  return coalesce((select jsonb_agg(x order by x.created_at desc) from (
    select t.id, t.number, t.status, t.note, t.created_at, t.decided_at, t.reject_kind, t.reject_reason,
           t.from_branch, t.to_branch, fb.name_ar as from_name, tb.name_ar as to_name,
           coalesce(nullif(btrim(cp.full_name), ''), cp.email, 'موظف') as created_by_name,
           coalesce(nullif(btrim(dp.full_name), ''), dp.email) as decided_by_name,
           (v_can_recv and t.status = 'pending' and public._branch_ok(t.to_branch)) as can_receive,
           (v_can_send and t.status = 'pending' and (t.created_by = auth.uid() or public._branch_ok(t.from_branch))) as can_cancel,
           (select jsonb_agg(jsonb_build_object('product_id', i.product_id, 'sku', i.sku, 'name_ar', i.name_ar, 'qty_sent', i.qty_sent, 'qty_received', i.qty_received) order by i.name_ar)
              from public.stock_transfer_items i where i.transfer_id = t.id) as items
      from public.stock_transfers t
      join public.branches fb on fb.id = t.from_branch join public.branches tb on tb.id = t.to_branch
      left join public.profiles cp on cp.id = t.created_by left join public.profiles dp on dp.id = t.decided_by
     where public._branch_view_ok(t.from_branch) or public._branch_view_ok(t.to_branch)
     order by t.created_at desc limit least(greatest(coalesce(p_limit, 40), 1), 200)) x), '[]'::jsonb);
end $$;
revoke all on function public.stock_transfers_list(int) from public, anon;
grant execute on function public.stock_transfers_list(int) to authenticated;

-- ---------- allocating ----------
create or replace function public.stock_allocate(p_branch uuid, p_product uuid, p_qty int) returns void
language plpgsql security definer set search_path = public as $$
declare v_old int; v_free int;
begin
  perform public.require_permission('stock.allocate');
  if not public._branch_view_ok(p_branch) or p_qty is null or p_qty < 0 or p_qty > 1000000 then raise exception 'INVALID_INPUT'; end if;
  perform 1 from public.products where id = p_product for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  select coalesce((select quantity from public.branch_stock where branch_id = p_branch and product_id = p_product), 0) into v_old;
  v_free := public._stock_unallocated(p_product);
  if p_qty - v_old > v_free then raise exception 'NOT_ENOUGH_UNALLOCATED'; end if;
  perform public._branch_stock_add(p_branch, p_product, p_qty - v_old);
  perform public.audit_write('stock.allocate', 'product', p_product::text, jsonb_build_object('branch', p_branch, 'from', v_old, 'to', p_qty));
end $$;
revoke all on function public.stock_allocate(uuid, uuid, int) from public, anon;
grant execute on function public.stock_allocate(uuid, uuid, int) to authenticated;

-- ---------- transfers ----------
create or replace function public.stock_transfer_create(p_from uuid, p_to uuid, p_items jsonb, p_note text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := public.require_auth(); v_id uuid; it jsonb; p public.products; v_have int; v_n int := 0; v_seen uuid[] := '{}'; v_pid uuid; v_q int;
        v_from text; v_to text; v_me text; v_num text; v_u uuid;
begin
  perform public.require_permission('stock.transfer');
  if p_from is null or p_to is null or p_from = p_to or not public._branch_ok(p_from) then raise exception 'FORBIDDEN'; end if;
  if not exists (select 1 from public.branches where id = p_to and is_active) or not exists (select 1 from public.branches where id = p_from and is_active) then raise exception 'INVALID_INPUT'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 30 then raise exception 'INVALID_INPUT'; end if;
  if p_note is not null and char_length(p_note) > 300 then raise exception 'INVALID_INPUT'; end if;
  insert into public.stock_transfers (from_branch, to_branch, note, created_by) values (p_from, p_to, nullif(btrim(coalesce(p_note, '')), ''), v_uid) returning id, number into v_id, v_num;
  for it in select * from jsonb_array_elements(p_items) loop
    v_pid := (it ->> 'product_id')::uuid; v_q := (it ->> 'qty')::int;
    if v_q is null or v_q < 1 or v_q > 100000 or v_pid = any (v_seen) then raise exception 'INVALID_INPUT'; end if;
    v_seen := v_seen || v_pid;
    select * into p from public.products where id = v_pid for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    select quantity into v_have from public.branch_stock where branch_id = p_from and product_id = v_pid for update;
    if coalesce(v_have, 0) < v_q then raise exception 'INSUFFICIENT_STOCK:%', p.name_ar; end if;
    perform public._branch_stock_add(p_from, v_pid, -v_q);
    insert into public.stock_transfer_items (transfer_id, product_id, sku, name_ar, name_en, qty_sent) values (v_id, v_pid, p.sku, p.name_ar, p.name_en, v_q);
    v_n := v_n + v_q;
  end loop;
  select name_ar into v_from from public.branches where id = p_from;
  select name_ar into v_to from public.branches where id = p_to;
  select coalesce(nullif(btrim(full_name), ''), email, 'موظف') into v_me from public.profiles where id = v_uid;
  for v_u in select * from public._stock_people(p_to, 'stock.receive') loop
    if v_u <> v_uid then
      perform public.notify_user(v_u, '📦 تحويل جديد لفرعك', '📦 New transfer to your branch',
        v_me || ' حوّل ' || v_n || ' قطعة من فرع ' || v_from || ' إلى فرع ' || v_to || ' (' || v_num || '). افتح «مخزن» وأكّد استلامك.',
        v_me || ' sent ' || v_n || ' pieces from ' || v_from || ' to ' || v_to || ' (' || v_num || '). Open Stock and confirm.',
        'system', null, v_num, '/');
    end if;
  end loop;
  perform public.audit_write('stock.transfer', 'stock_transfer', v_id::text, jsonb_build_object('from', p_from, 'to', p_to, 'pieces', v_n));
  return v_id;
end $$;
revoke all on function public.stock_transfer_create(uuid, uuid, jsonb, text) from public, anon;
grant execute on function public.stock_transfer_create(uuid, uuid, jsonb, text) to authenticated;

-- put every piece of a pending transfer back in the sender's store (cancel / reject)
create or replace function public._stock_transfer_return(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t public.stock_transfers; i record;
begin
  select * into t from public.stock_transfers where id = p_id;
  for i in select * from public.stock_transfer_items where transfer_id = p_id loop
    perform public._branch_stock_add(t.from_branch, i.product_id, i.qty_sent);
    update public.stock_transfer_items set qty_received = 0 where transfer_id = p_id and product_id = i.product_id;
  end loop;
end $$;
revoke all on function public._stock_transfer_return(uuid) from public, anon, authenticated;

create or replace function public.stock_transfer_receive(p_id uuid, p_items jsonb, p_kind text default null, p_reason text default null) returns text
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := public.require_auth(); t public.stock_transfers; i record; e jsonb; v_q int; v_short boolean := false; v_all0 boolean := true;
        v_status text; v_me text; v_got int := 0; v_sent int := 0; v_reason text := nullif(btrim(coalesce(p_reason, '')), ''); v_to text; v_num text;
begin
  perform public.require_permission('stock.receive');
  select * into t from public.stock_transfers where id = p_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if t.status <> 'pending' then raise exception 'ALREADY_DECIDED'; end if;
  if not public._branch_ok(t.to_branch) then raise exception 'FORBIDDEN'; end if;
  if jsonb_typeof(p_items) <> 'array' then raise exception 'INVALID_INPUT'; end if;
  -- what really arrived, per product (a product that is not listed counts as 0)
  for i in select * from public.stock_transfer_items where transfer_id = p_id loop
    select (x ->> 'qty')::int into v_q from jsonb_array_elements(p_items) x where (x ->> 'product_id')::uuid = i.product_id;
    v_q := coalesce(v_q, 0);
    if v_q < 0 or v_q > i.qty_sent then raise exception 'INVALID_INPUT'; end if;
    if v_q < i.qty_sent then v_short := true; end if;
    if v_q > 0 then v_all0 := false; end if;
    v_got := v_got + v_q; v_sent := v_sent + i.qty_sent;
  end loop;
  if v_all0 then raise exception 'USE_REJECT'; end if;
  if v_short then
    if p_kind is null or p_kind not in ('not_received', 'other') then raise exception 'REASON_REQUIRED'; end if;
    if p_kind = 'other' and (v_reason is null or char_length(v_reason) < 3) then raise exception 'REASON_REQUIRED'; end if;
  end if;
  for i in select * from public.stock_transfer_items where transfer_id = p_id loop
    select (x ->> 'qty')::int into v_q from jsonb_array_elements(p_items) x where (x ->> 'product_id')::uuid = i.product_id;
    v_q := coalesce(v_q, 0);
    if v_q > 0 then perform public._branch_stock_add(t.to_branch, i.product_id, v_q); end if;
    if v_q < i.qty_sent then perform public._branch_stock_add(t.from_branch, i.product_id, i.qty_sent - v_q); end if;   -- the missing pieces go back
    update public.stock_transfer_items set qty_received = v_q where transfer_id = p_id and product_id = i.product_id;
  end loop;
  v_status := case when v_short then 'partial' else 'received' end;
  update public.stock_transfers set status = v_status, decided_by = v_uid, decided_at = now(),
         reject_kind = case when v_short then p_kind end, reject_reason = case when v_short then v_reason end where id = p_id;
  select coalesce(nullif(btrim(full_name), ''), email, 'موظف') into v_me from public.profiles where id = v_uid;
  select name_ar into v_to from public.branches where id = t.to_branch;
  v_num := t.number;
  perform public.notify_user(t.created_by, case when v_short then '📦 تحويلك اتستلم جزئيًا' else '✅ تحويلك اتستلم' end,
    case when v_short then '📦 Your transfer was partly received' else '✅ Your transfer was received' end,
    v_me || ' في فرع ' || v_to || case when v_short then ' استلم ' || v_got || ' من ' || v_sent || ' قطعة (' || v_num || ')' || case when p_kind = 'other' then ': ' || v_reason else ': القطع الباقية ما وصلتش' end || '. الباقي رجع لمخزنك.'
                                         else ' استلم التحويل ' || v_num || ' بالكامل (' || v_got || ' قطعة).' end,
    v_me || ' (' || v_to || ') received ' || v_got || ' of ' || v_sent || ' pieces (' || v_num || ').', 'system', null, v_num, '/');
  perform public.audit_write('stock.receive', 'stock_transfer', p_id::text, jsonb_build_object('status', v_status, 'received', v_got, 'sent', v_sent, 'kind', p_kind));
  return v_status;
end $$;
revoke all on function public.stock_transfer_receive(uuid, jsonb, text, text) from public, anon;
grant execute on function public.stock_transfer_receive(uuid, jsonb, text, text) to authenticated;

create or replace function public.stock_transfer_reject(p_id uuid, p_kind text, p_reason text default null) returns void
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := public.require_auth(); t public.stock_transfers; v_reason text := nullif(btrim(coalesce(p_reason, '')), ''); v_me text; v_to text;
begin
  perform public.require_permission('stock.receive');
  if p_kind is null or p_kind not in ('not_received', 'other') or (p_kind = 'other' and (v_reason is null or char_length(v_reason) < 3)) or char_length(coalesce(v_reason, '')) > 300 then raise exception 'REASON_REQUIRED'; end if;
  select * into t from public.stock_transfers where id = p_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if t.status <> 'pending' then raise exception 'ALREADY_DECIDED'; end if;
  if not public._branch_ok(t.to_branch) then raise exception 'FORBIDDEN'; end if;
  perform public._stock_transfer_return(p_id);
  update public.stock_transfers set status = 'rejected', decided_by = v_uid, decided_at = now(), reject_kind = p_kind, reject_reason = v_reason where id = p_id;
  select coalesce(nullif(btrim(full_name), ''), email, 'موظف') into v_me from public.profiles where id = v_uid;
  select name_ar into v_to from public.branches where id = t.to_branch;
  perform public.notify_user(t.created_by, '❌ تحويلك اترفض', '❌ Your transfer was rejected',
    v_me || ' في فرع ' || v_to || ' رفض التحويل ' || t.number || ': ' || case when p_kind = 'other' then v_reason else 'ما استلمهوش' end || '. القطع رجعت لمخزنك.',
    v_me || ' (' || v_to || ') rejected ' || t.number || '. The pieces are back in your store.', 'system', null, t.number, '/');
  perform public.audit_write('stock.reject', 'stock_transfer', p_id::text, jsonb_build_object('kind', p_kind, 'reason', v_reason));
end $$;
revoke all on function public.stock_transfer_reject(uuid, text, text) from public, anon;
grant execute on function public.stock_transfer_reject(uuid, text, text) to authenticated;

create or replace function public.stock_transfer_cancel(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := public.require_auth(); t public.stock_transfers; v_u uuid;
begin
  perform public.require_permission('stock.transfer');
  select * into t from public.stock_transfers where id = p_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if t.status <> 'pending' then raise exception 'ALREADY_DECIDED'; end if;
  if t.created_by <> v_uid and not public._branch_ok(t.from_branch) then raise exception 'FORBIDDEN'; end if;
  perform public._stock_transfer_return(p_id);
  update public.stock_transfers set status = 'cancelled', decided_by = v_uid, decided_at = now() where id = p_id;
  for v_u in select * from public._stock_people(t.to_branch, 'stock.receive') loop
    if v_u <> v_uid then
      perform public.notify_user(v_u, '↩️ التحويل اتلغى', '↩️ Transfer cancelled', 'التحويل ' || t.number || ' اتلغى من المُرسِل، ما تستلمش حاجة.', 'Transfer ' || t.number || ' was cancelled by the sender.', 'system', null, t.number, '/');
    end if;
  end loop;
  perform public.audit_write('stock.cancel', 'stock_transfer', p_id::text, '{}'::jsonb);
end $$;
revoke all on function public.stock_transfer_cancel(uuid) from public, anon;
grant execute on function public.stock_transfer_cancel(uuid) to authenticated;
