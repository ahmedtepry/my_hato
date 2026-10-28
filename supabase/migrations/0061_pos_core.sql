-- 0061: in-store cashier (POS) with the controls the owner asked for.
--   1) Double approval: a big discount or a refund above the owner's limits needs ANOTHER person to approve it (never the requester).
--   2) Tamper-evident log: every audit row is chained to the one before it (hash), updates/deletes/truncate are blocked, and
--      audit_verify() proves nothing was changed. Stock movements can no longer be edited or deleted.
--   3) Cash shifts: open with a float, close by counting the drawer; the difference (short / over) is recorded and the owner is told.
--   4) Branch separation: an employee only sees the data of the branches the owner assigned to him; the owner compares branches.
--   5) Backup helper: owner_data_snapshot() gives counts + the log head hash to compare after a restore test.
-- Invoices are never edited or deleted: a mistake is fixed with a refund. Everything is cash only.

-- ============================================================ permissions
insert into public.role_permissions (role, permission) values
  ('owner','pos.sell'),('manager','pos.sell'),('sales','pos.sell'),
  ('owner','pos.shift'),('manager','pos.shift'),('sales','pos.shift'),
  ('owner','pos.discount'),('manager','pos.discount'),
  ('owner','pos.refund'),('manager','pos.refund'),
  ('owner','pos.approve'),('manager','pos.approve'),
  ('owner','shifts.review'),('manager','shifts.review')
on conflict do nothing;

insert into public.permission_catalog (permission, grp, name_ar, name_en, desc_ar, desc_en, sensitive, inert, sort) values
  ('pos.sell','pos','يبيع من الكاشير','Sell at the cashier','يفتح شاشة الكاشير ويعمل فاتورة بيع نقدي','Opens the cashier and makes cash sales',false,false,60),
  ('pos.shift','pos','يفتح ويقفل الوردية','Open and close his shift','يبدأ الوردية بعهدة ويقفلها بعد عدّ الدرج','Starts a shift with a float and closes it after counting the drawer',false,false,61),
  ('pos.discount','pos','يدّي خصم من الكاشير','Give discounts','يدّي خصم لحد النسبة اللي المالك محددها من غير موافقة','Gives a discount up to the owner limit without approval',true,false,62),
  ('pos.refund','pos','يعمل مرتجع','Make refunds','يرجّع فلوس للعميل (فوق الحد لازم موافقة)','Returns money to the customer (above the limit it needs approval)',true,false,63),
  ('pos.approve','pos','يوافق على الخصم والمرتجع','Approve discounts and refunds','يوافق أو يرفض طلبات زملاءه (مش طلباته هو)','Approves or rejects other people requests (never his own)',true,false,64),
  ('shifts.review','pos','يراجع الورديات','Review shifts','يشوف ورديات الفرع وفروق الدرج','Sees branch shifts and cash differences',true,false,65)
on conflict (permission) do nothing;

-- ============================================================ owner-editable limits
insert into public.application_settings (key, value, description) values
  ('pos_discount_approval_pct', '10', 'Cashier discount above this % of the invoice needs another person''s approval'),
  ('pos_refund_approval_minor', '50000', 'A refund above this amount (minor units) needs another person''s approval'),
  ('pos_allow_negative_stock', 'false', 'true = the cashier may sell more than the stock shows')
on conflict (key) do nothing;

create or replace function public._pos_num(p_key text, p_default numeric)
returns numeric language sql stable security definer set search_path = public as $$
  select coalesce((select (value #>> '{}')::numeric from public.application_settings
                    where key = p_key and jsonb_typeof(value) = 'number'), p_default)
$$;
revoke all on function public._pos_num(text, numeric) from public, anon, authenticated;

-- ============================================================ branch scope
create table if not exists public.staff_branches (
  user_id uuid not null references auth.users(id) on delete cascade,
  branch_id uuid not null references public.branches(id) on delete cascade,
  granted_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  primary key (user_id, branch_id)
);
alter table public.staff_branches enable row level security;
drop policy if exists staff_branches_read on public.staff_branches;
create policy staff_branches_read on public.staff_branches for select to authenticated
  using (user_id = auth.uid() or public.has_permission('staff.manage'));
revoke all on public.staff_branches from anon, authenticated;
grant select on public.staff_branches to authenticated;

-- today's team keeps working: everyone gets the branches that exist now (the owner can narrow it per person)
insert into public.staff_branches (user_id, branch_id)
select ur.user_id, b.id from public.user_roles ur cross join public.branches b where ur.role <> 'owner'
on conflict do nothing;

create or replace function public._branch_ok(p_branch uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select p_branch is not null and (
    public.has_role('owner')
    or exists (select 1 from public.staff_branches sb where sb.user_id = auth.uid() and sb.branch_id = p_branch))
$$;
revoke all on function public._branch_ok(uuid) from public, anon;
grant execute on function public._branch_ok(uuid) to authenticated;

-- ============================================================ tables
create table if not exists public.approvals (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('discount','refund')),
  branch_id uuid not null references public.branches(id),
  requested_by uuid not null references auth.users(id),
  amount_minor bigint not null check (amount_minor >= 0),
  reason text not null check (char_length(btrim(reason)) between 3 and 300),
  payload jsonb not null default '{}'::jsonb,
  status text not null default 'pending' check (status in ('pending','approved','rejected','used')),
  decided_by uuid references auth.users(id),
  decided_at timestamptz,
  decision_note text,
  used_at timestamptz,
  created_at timestamptz not null default now(),
  constraint approvals_never_self check (decided_by is null or decided_by <> requested_by)
);
create index if not exists approvals_pending_idx on public.approvals (branch_id, status, created_at desc);

create table if not exists public.shifts (
  id uuid primary key default gen_random_uuid(),
  branch_id uuid not null references public.branches(id),
  cashier_id uuid not null references auth.users(id),
  opened_at timestamptz not null default now(),
  opening_cash_minor bigint not null check (opening_cash_minor >= 0),
  status text not null default 'open' check (status in ('open','closed')),
  closed_at timestamptz,
  closed_by uuid references auth.users(id),
  counted_cash_minor bigint,
  expected_cash_minor bigint,
  variance_minor bigint,
  close_note text
);
create unique index if not exists shifts_one_open_per_cashier on public.shifts (cashier_id) where status = 'open';
create index if not exists shifts_branch_idx on public.shifts (branch_id, opened_at desc);

create sequence if not exists public.pos_sale_seq;

create table if not exists public.pos_sales (
  id uuid primary key default gen_random_uuid(),
  number text not null unique,
  branch_id uuid not null references public.branches(id),
  shift_id uuid not null references public.shifts(id),
  cashier_id uuid not null references auth.users(id),
  customer_id uuid references auth.users(id),
  idempotency_key text not null,
  subtotal_minor bigint not null check (subtotal_minor > 0),
  discount_minor bigint not null default 0,
  total_minor bigint not null,
  cash_received_minor bigint not null,
  change_minor bigint not null,
  approval_id uuid references public.approvals(id),
  refunded_minor bigint not null default 0,
  created_at timestamptz not null default now(),
  unique (cashier_id, idempotency_key),
  check (discount_minor between 0 and subtotal_minor),
  check (total_minor = subtotal_minor - discount_minor),
  check (cash_received_minor >= total_minor and change_minor = cash_received_minor - total_minor),
  check (refunded_minor between 0 and total_minor)
);
create index if not exists pos_sales_shift_idx on public.pos_sales (shift_id);
create index if not exists pos_sales_branch_idx on public.pos_sales (branch_id, created_at desc);

create table if not exists public.pos_sale_items (
  id uuid primary key default gen_random_uuid(),
  sale_id uuid not null references public.pos_sales(id),
  product_id uuid not null references public.products(id),
  sku text,
  name_ar text,
  name_en text,
  quantity int not null check (quantity > 0),
  unit_price_minor bigint not null check (unit_price_minor >= 0),
  line_total_minor bigint not null,
  net_line_minor bigint not null,           -- after this line's share of the invoice discount
  refunded_qty int not null default 0,
  refunded_amount_minor bigint not null default 0,
  check (refunded_qty between 0 and quantity),
  check (refunded_amount_minor between 0 and net_line_minor)
);
create index if not exists pos_sale_items_sale_idx on public.pos_sale_items (sale_id);

create table if not exists public.pos_refunds (
  id uuid primary key default gen_random_uuid(),
  sale_id uuid not null references public.pos_sales(id),
  shift_id uuid not null references public.shifts(id),
  branch_id uuid not null references public.branches(id),
  amount_minor bigint not null check (amount_minor > 0),
  reason text not null,
  items jsonb not null,
  restocked boolean not null default true,
  requested_by uuid not null references auth.users(id),
  approval_id uuid references public.approvals(id),
  created_at timestamptz not null default now()
);
create index if not exists pos_refunds_shift_idx on public.pos_refunds (shift_id);

-- ============================================================ stock movements: new reasons + no edits
do $$ declare c text;
begin
  for c in select conname from pg_constraint
            where conrelid = 'public.inventory_movements'::regclass and contype = 'c'
              and pg_get_constraintdef(oid) ilike '%reason%' loop
    execute format('alter table public.inventory_movements drop constraint %I', c);
  end loop;
end $$;
alter table public.inventory_movements add constraint inventory_movements_reason_check
  check (reason in ('order','order_cancel','manual_adjust','restock','correction','pos_sale','pos_refund'));
alter table public.inventory_movements add column if not exists pos_sale_id uuid references public.pos_sales(id);

-- ============================================================ immutability
create or replace function public._no_change() returns trigger language plpgsql as $$
begin raise exception 'RECORD_IS_FINAL: % on % is not allowed', tg_op, tg_table_name using errcode = '42501'; end $$;

drop trigger if exists inventory_movements_final on public.inventory_movements;
create trigger inventory_movements_final before update or delete on public.inventory_movements
  for each row execute function public._no_change();
drop trigger if exists pos_refunds_final on public.pos_refunds;
create trigger pos_refunds_final before update or delete on public.pos_refunds
  for each row execute function public._no_change();
drop trigger if exists pos_sales_no_delete on public.pos_sales;
create trigger pos_sales_no_delete before delete on public.pos_sales for each row execute function public._no_change();
drop trigger if exists pos_sale_items_no_delete on public.pos_sale_items;
create trigger pos_sale_items_no_delete before delete on public.pos_sale_items for each row execute function public._no_change();
drop trigger if exists shifts_no_delete on public.shifts;
create trigger shifts_no_delete before delete on public.shifts for each row execute function public._no_change();
drop trigger if exists approvals_no_delete on public.approvals;
create trigger approvals_no_delete before delete on public.approvals for each row execute function public._no_change();

create or replace function public._pos_sales_guard() returns trigger language plpgsql as $$
begin
  if (new.id, new.number, new.branch_id, new.shift_id, new.cashier_id, new.customer_id, new.idempotency_key,
      new.subtotal_minor, new.discount_minor, new.total_minor, new.cash_received_minor, new.change_minor,
      new.approval_id, new.created_at)
     is distinct from
     (old.id, old.number, old.branch_id, old.shift_id, old.cashier_id, old.customer_id, old.idempotency_key,
      old.subtotal_minor, old.discount_minor, old.total_minor, old.cash_received_minor, old.change_minor,
      old.approval_id, old.created_at) then
    raise exception 'RECORD_IS_FINAL: a completed invoice cannot be edited, use a refund' using errcode = '42501';
  end if;
  return new;
end $$;
drop trigger if exists pos_sales_guard on public.pos_sales;
create trigger pos_sales_guard before update on public.pos_sales for each row execute function public._pos_sales_guard();

create or replace function public._pos_items_guard() returns trigger language plpgsql as $$
begin
  if (new.id, new.sale_id, new.product_id, new.sku, new.name_ar, new.name_en, new.quantity, new.unit_price_minor,
      new.line_total_minor, new.net_line_minor)
     is distinct from
     (old.id, old.sale_id, old.product_id, old.sku, old.name_ar, old.name_en, old.quantity, old.unit_price_minor,
      old.line_total_minor, old.net_line_minor) then
    raise exception 'RECORD_IS_FINAL: invoice lines cannot be edited' using errcode = '42501';
  end if;
  return new;
end $$;
drop trigger if exists pos_sale_items_guard on public.pos_sale_items;
create trigger pos_sale_items_guard before update on public.pos_sale_items for each row execute function public._pos_items_guard();

create or replace function public._shifts_guard() returns trigger language plpgsql as $$
begin
  if old.status = 'closed' then raise exception 'RECORD_IS_FINAL: a closed shift cannot be changed' using errcode = '42501'; end if;
  if (new.id, new.branch_id, new.cashier_id, new.opened_at, new.opening_cash_minor)
     is distinct from (old.id, old.branch_id, old.cashier_id, old.opened_at, old.opening_cash_minor) then
    raise exception 'RECORD_IS_FINAL' using errcode = '42501';
  end if;
  return new;
end $$;
drop trigger if exists shifts_guard on public.shifts;
create trigger shifts_guard before update on public.shifts for each row execute function public._shifts_guard();

create or replace function public._approvals_guard() returns trigger language plpgsql as $$
begin
  if (new.id, new.kind, new.branch_id, new.requested_by, new.amount_minor, new.reason, new.payload, new.created_at)
     is distinct from (old.id, old.kind, old.branch_id, old.requested_by, old.amount_minor, old.reason, old.payload, old.created_at)
     or old.status in ('rejected','used') then
    raise exception 'RECORD_IS_FINAL' using errcode = '42501';
  end if;
  return new;
end $$;
drop trigger if exists approvals_guard on public.approvals;
create trigger approvals_guard before update on public.approvals for each row execute function public._approvals_guard();

-- ============================================================ RLS (reads only; every write goes through the functions below)
alter table public.approvals enable row level security;
alter table public.shifts enable row level security;
alter table public.pos_sales enable row level security;
alter table public.pos_sale_items enable row level security;
alter table public.pos_refunds enable row level security;
revoke all on public.approvals, public.shifts, public.pos_sales, public.pos_sale_items, public.pos_refunds from anon, authenticated;
grant select on public.approvals, public.shifts, public.pos_sales, public.pos_sale_items, public.pos_refunds to authenticated;

drop policy if exists shifts_read on public.shifts;
create policy shifts_read on public.shifts for select to authenticated
  using (cashier_id = auth.uid() or (public.has_permission('shifts.review') and public._branch_ok(branch_id)));
drop policy if exists pos_sales_read on public.pos_sales;
create policy pos_sales_read on public.pos_sales for select to authenticated
  using (cashier_id = auth.uid() or (public.has_permission('shifts.review') and public._branch_ok(branch_id)));
drop policy if exists pos_sale_items_read on public.pos_sale_items;
create policy pos_sale_items_read on public.pos_sale_items for select to authenticated
  using (exists (select 1 from public.pos_sales s where s.id = sale_id));
drop policy if exists pos_refunds_read on public.pos_refunds;
create policy pos_refunds_read on public.pos_refunds for select to authenticated
  using (requested_by = auth.uid() or (public.has_permission('shifts.review') and public._branch_ok(branch_id)));
drop policy if exists approvals_read on public.approvals;
create policy approvals_read on public.approvals for select to authenticated
  using (requested_by = auth.uid() or (public.has_permission('pos.approve') and public._branch_ok(branch_id)));

-- ============================================================ tamper-evident audit log
alter table public.audit_logs add column if not exists branch_id uuid;
alter table public.audit_logs add column if not exists prev_hash text;
alter table public.audit_logs add column if not exists row_hash text;

create or replace function public._audit_hash(p_prev text, p_id bigint, p_actor uuid, p_action text, p_type text,
                                              p_entity text, p_details jsonb, p_at timestamptz)
returns text language sql immutable set search_path = public, extensions as $$
  select encode(extensions.digest(convert_to(concat_ws('|', p_prev, p_id::text, coalesce(p_actor::text, ''), p_action, p_type,
           coalesce(p_entity, ''), p_details::text, to_char(p_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US')), 'UTF8'), 'sha256'), 'hex')
$$;
revoke all on function public._audit_hash(text, bigint, uuid, text, text, text, jsonb, timestamptz) from public, anon, authenticated;

create or replace function public.audit_logs_chain() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
declare v_prev text;
begin
  perform pg_advisory_xact_lock(610061);
  select row_hash into v_prev from public.audit_logs where row_hash is not null order by id desc limit 1;
  new.prev_hash := coalesce(v_prev, 'genesis');
  begin new.branch_id := nullif(new.details ->> 'branch_id', '')::uuid; exception when others then new.branch_id := null; end;
  new.row_hash := public._audit_hash(new.prev_hash, new.id, new.actor_id, new.action, new.entity_type, new.entity_id, new.details, new.created_at);
  return new;
end $$;
revoke all on function public.audit_logs_chain() from public, anon, authenticated;
drop trigger if exists audit_logs_chain on public.audit_logs;
create trigger audit_logs_chain before insert on public.audit_logs for each row execute function public.audit_logs_chain();
drop trigger if exists audit_logs_no_truncate on public.audit_logs;
create trigger audit_logs_no_truncate before truncate on public.audit_logs for each statement execute function public.audit_logs_immutable();

create or replace function public.audit_verify() returns jsonb
language plpgsql security definer set search_path = public as $$
declare r record; v_prev text; v_n bigint := 0; v_bad bigint; v_head text;
begin
  perform public.require_permission('audit.view');
  for r in select * from public.audit_logs where row_hash is not null order by id loop
    v_n := v_n + 1;
    if r.prev_hash is distinct from coalesce(v_prev, 'genesis')
       or r.row_hash is distinct from public._audit_hash(r.prev_hash, r.id, r.actor_id, r.action, r.entity_type, r.entity_id, r.details, r.created_at) then
      v_bad := r.id; exit;
    end if;
    v_prev := r.row_hash;
  end loop;
  select row_hash into v_head from public.audit_logs where row_hash is not null order by id desc limit 1;
  return jsonb_build_object('ok', v_bad is null, 'checked', v_n, 'first_bad_id', v_bad, 'head', v_head,
                            'unchained_old_rows', (select count(*) from public.audit_logs where row_hash is null));
end $$;
revoke all on function public.audit_verify() from public, anon;
grant execute on function public.audit_verify() to authenticated;

-- ============================================================ settings (owner only)
create or replace function public.pos_get_limits() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_auth();
  if not (public.has_permission('pos.sell') or public.has_permission('settings.manage')) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return jsonb_build_object('discount_approval_pct', public._pos_num('pos_discount_approval_pct', 10),
    'refund_approval_minor', public._pos_num('pos_refund_approval_minor', 50000),
    'allow_negative_stock', exists (select 1 from public.application_settings where key = 'pos_allow_negative_stock' and value = 'true'::jsonb),
    'can_discount', public.has_permission('pos.discount'), 'is_owner', public.has_role('owner'));
end $$;

create or replace function public.pos_set_limits(p_discount_pct numeric, p_refund_minor bigint, p_allow_negative boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.require_permission('settings.manage');
  if not public.has_role('owner') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_discount_pct is null or p_discount_pct < 0 or p_discount_pct > 100 or p_refund_minor is null or p_refund_minor < 0 then raise exception 'INVALID_INPUT'; end if;
  insert into public.application_settings (key, value, updated_by, updated_at) values
    ('pos_discount_approval_pct', to_jsonb(p_discount_pct), auth.uid(), now()),
    ('pos_refund_approval_minor', to_jsonb(p_refund_minor), auth.uid(), now()),
    ('pos_allow_negative_stock', to_jsonb(coalesce(p_allow_negative, false)), auth.uid(), now())
  on conflict (key) do update set value = excluded.value, updated_by = excluded.updated_by, updated_at = now();
  perform public.audit_write('pos.limits', 'settings', 'pos', jsonb_build_object('discount_pct', p_discount_pct, 'refund_minor', p_refund_minor, 'allow_negative', p_allow_negative));
end $$;

-- ============================================================ branches for staff
create or replace function public.staff_my_branches()
returns table (id uuid, name_ar text, name_en text)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_auth();
  return query select b.id, b.name_ar, b.name_en from public.branches b
    where b.is_active and (public.has_role('owner') or exists (select 1 from public.staff_branches sb where sb.user_id = auth.uid() and sb.branch_id = b.id))
    order by b.created_at;
end $$;

create or replace function public.staff_get_branches(p_user uuid) returns uuid[]
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_permission('staff.manage');
  return coalesce((select array_agg(branch_id) from public.staff_branches where user_id = p_user), '{}');
end $$;

create or replace function public.staff_set_branches(p_user uuid, p_branches uuid[]) returns void
language plpgsql security definer set search_path = public as $$
declare b uuid;
begin
  perform public.require_permission('staff.manage');
  if not exists (select 1 from public.user_roles where user_id = p_user) or public.has_role('owner') is null then raise exception 'NOT_FOUND'; end if;
  if exists (select 1 from public.user_roles where user_id = p_user and role = 'owner') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_user = auth.uid() and not public.has_role('owner') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  foreach b in array coalesce(p_branches, '{}') loop
    if not public._branch_ok(b) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  end loop;
  delete from public.staff_branches where user_id = p_user and (public.has_role('owner') or public._branch_ok(branch_id));
  insert into public.staff_branches (user_id, branch_id, granted_by)
    select distinct x, auth.uid() from unnest(coalesce(p_branches, '{}')) x on conflict do nothing;
  perform public.audit_write('staff.branches', 'user', p_user::text, jsonb_build_object('branches', to_jsonb(p_branches)));
end $$;

-- ============================================================ shifts
create or replace function public._shift_totals(p_shift uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'opening_minor', s.opening_cash_minor,
    'sales_count', (select count(*) from public.pos_sales x where x.shift_id = s.id),
    'sales_minor', coalesce((select sum(total_minor) from public.pos_sales x where x.shift_id = s.id), 0),
    'refunds_minor', coalesce((select sum(r.amount_minor) from public.pos_refunds r where r.shift_id = s.id), 0),
    'expected_minor', s.opening_cash_minor
        + coalesce((select sum(total_minor) from public.pos_sales x where x.shift_id = s.id), 0)
        - coalesce((select sum(r.amount_minor) from public.pos_refunds r where r.shift_id = s.id), 0))
  from public.shifts s where s.id = p_shift
$$;
revoke all on function public._shift_totals(uuid) from public, anon, authenticated;

create or replace function public.pos_open_shift(p_branch uuid, p_opening_minor bigint) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  perform public.require_permission('pos.shift');
  if p_opening_minor is null or p_opening_minor < 0 or p_opening_minor > 100000000 then raise exception 'INVALID_INPUT'; end if;
  if not public._branch_ok(p_branch) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if exists (select 1 from public.shifts where cashier_id = auth.uid() and status = 'open') then raise exception 'SHIFT_ALREADY_OPEN'; end if;
  insert into public.shifts (branch_id, cashier_id, opening_cash_minor) values (p_branch, auth.uid(), p_opening_minor) returning id into v_id;
  perform public.audit_write('shift.open', 'shift', v_id::text, jsonb_build_object('branch_id', p_branch, 'opening_minor', p_opening_minor));
  return v_id;
exception when unique_violation then raise exception 'SHIFT_ALREADY_OPEN';
end $$;

-- the caller's open shift with live totals (null when none)
create or replace function public.pos_current_shift() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s public.shifts%rowtype;
begin
  perform public.require_permission('pos.shift');
  select * into s from public.shifts where cashier_id = auth.uid() and status = 'open';
  if not found then return null; end if;
  return to_jsonb(s) || public._shift_totals(s.id)
         || jsonb_build_object('branch_name_ar', (select name_ar from public.branches where id = s.branch_id));
end $$;

create or replace function public.pos_shift_summary(p_shift uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s public.shifts%rowtype;
begin
  perform public.require_auth();
  select * into s from public.shifts where id = p_shift;
  if not found then raise exception 'NOT_FOUND'; end if;
  if not (s.cashier_id = auth.uid() or (public.has_permission('shifts.review') and public._branch_ok(s.branch_id))) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return to_jsonb(s) || public._shift_totals(s.id);
end $$;

create or replace function public.pos_close_shift(p_shift uuid, p_counted_minor bigint, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.shifts%rowtype; t jsonb; v_exp bigint; v_var bigint;
begin
  perform public.require_auth();
  select * into s from public.shifts where id = p_shift for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if s.status <> 'open' then raise exception 'SHIFT_CLOSED'; end if;
  if not ((s.cashier_id = auth.uid() and public.has_permission('pos.shift'))
          or (public.has_permission('shifts.review') and public._branch_ok(s.branch_id))) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_counted_minor is null or p_counted_minor < 0 or p_counted_minor > 1000000000 then raise exception 'INVALID_INPUT'; end if;
  t := public._shift_totals(s.id);
  v_exp := (t ->> 'expected_minor')::bigint;
  v_var := p_counted_minor - v_exp;
  if v_var <> 0 and char_length(btrim(coalesce(p_note, ''))) < 3 then raise exception 'NOTE_REQUIRED'; end if;
  update public.shifts set status = 'closed', closed_at = now(), closed_by = auth.uid(), counted_cash_minor = p_counted_minor,
         expected_cash_minor = v_exp, variance_minor = v_var, close_note = nullif(left(btrim(coalesce(p_note, '')), 300), '')
   where id = s.id;
  perform public.audit_write('shift.close', 'shift', s.id::text, jsonb_build_object('branch_id', s.branch_id, 'expected_minor', v_exp,
          'counted_minor', p_counted_minor, 'variance_minor', v_var, 'closed_by_other', s.cashier_id <> auth.uid()));
  if v_var <> 0 then
    perform public._notify_staff('shifts.review', 'فرق في درج الكاشير', 'Cash drawer difference',
      case when v_var < 0 then 'عجز ' else 'زيادة ' end || (abs(v_var) / 100.0)::numeric(12,2) || ' ج.م في وردية اتقفلت',
      (case when v_var < 0 then 'Short ' else 'Over ' end) || (abs(v_var) / 100.0)::numeric(12,2) || ' EGP on a closed shift', s.id::text);
  end if;
  return jsonb_build_object('expected_minor', v_exp, 'counted_minor', p_counted_minor, 'variance_minor', v_var);
end $$;

create or replace function public.pos_shift_list(p_branch uuid default null, p_from timestamptz default null, p_to timestamptz default null, p_limit int default 100)
returns table (id uuid, branch_id uuid, branch_name_ar text, cashier_id uuid, cashier_name text, status text, opened_at timestamptz, closed_at timestamptz,
               opening_minor bigint, sales_count bigint, sales_minor bigint, refunds_minor bigint, expected_minor bigint, counted_minor bigint, variance_minor bigint, note text)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_auth();
  if not (public.has_permission('shifts.review') or public.has_permission('pos.shift')) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return query
    select s.id, s.branch_id, b.name_ar, s.cashier_id, coalesce(tm.login_display, p.full_name, '—'), s.status, s.opened_at, s.closed_at,
           s.opening_cash_minor, (t ->> 'sales_count')::bigint, (t ->> 'sales_minor')::bigint, (t ->> 'refunds_minor')::bigint,
           coalesce(s.expected_cash_minor, (t ->> 'expected_minor')::bigint), s.counted_cash_minor, s.variance_minor, s.close_note
      from public.shifts s
      join public.branches b on b.id = s.branch_id
      left join public.team_members tm on tm.user_id = s.cashier_id
      left join public.profiles p on p.id = s.cashier_id
      cross join lateral (select public._shift_totals(s.id) as t) x
     where (s.cashier_id = auth.uid() or (public.has_permission('shifts.review') and public._branch_ok(s.branch_id)))
       and (p_branch is null or s.branch_id = p_branch)
       and (p_from is null or s.opened_at >= p_from) and (p_to is null or s.opened_at < p_to)
     order by s.opened_at desc limit least(greatest(coalesce(p_limit, 100), 1), 300);
end $$;

-- ============================================================ products for the cashier
create or replace function public.pos_search_products(p_q text default null, p_limit int default 24)
returns table (id uuid, sku text, name_ar text, name_en text, price_minor bigint, stock_quantity int)
language plpgsql stable security definer set search_path = public as $$
declare v text := nullif(btrim(coalesce(p_q, '')), '');
begin
  perform public.require_permission('pos.sell');
  return query select p.id, p.sku, p.name_ar, p.name_en, p.price_minor, p.stock_quantity
    from public.products p
   where p.status = 'published'
     and (v is null or lower(p.sku) = lower(v) or p.name_ar ilike '%' || v || '%' or p.name_en ilike '%' || v || '%' or p.sku ilike '%' || v || '%')
   order by (lower(p.sku) = lower(coalesce(v, ''))) desc, p.name_ar
   limit least(greatest(coalesce(p_limit, 24), 1), 60);
end $$;

-- ============================================================ approvals
create or replace function public.pos_request_approval(p_kind text, p_amount_minor bigint, p_reason text, p_branch uuid, p_payload jsonb default '{}')
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  perform public.require_permission('pos.sell');
  if p_kind not in ('discount','refund') or p_amount_minor is null or p_amount_minor <= 0 or char_length(btrim(coalesce(p_reason, ''))) < 3 then raise exception 'INVALID_INPUT'; end if;
  if not public._branch_ok(p_branch) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if (select count(*) from public.approvals where requested_by = auth.uid() and status = 'pending') >= 10 then raise exception 'TOO_MANY_PENDING'; end if;
  insert into public.approvals (kind, branch_id, requested_by, amount_minor, reason, payload)
  values (p_kind, p_branch, auth.uid(), p_amount_minor, left(btrim(p_reason), 300), coalesce(p_payload, '{}'))
  returning id into v_id;
  perform public.audit_write('approval.request', 'approval', v_id::text, jsonb_build_object('branch_id', p_branch, 'kind', p_kind, 'amount_minor', p_amount_minor, 'reason', left(btrim(p_reason), 300)));
  perform public._notify_staff('pos.approve', 'طلب موافقة جديد', 'New approval request',
    (case p_kind when 'discount' then 'خصم ' else 'مرتجع ' end) || (p_amount_minor / 100.0)::numeric(12,2) || ' ج.م',
    (case p_kind when 'discount' then 'Discount ' else 'Refund ' end) || (p_amount_minor / 100.0)::numeric(12,2) || ' EGP', v_id::text);
  return v_id;
end $$;

create or replace function public.pos_pending_approvals()
returns table (id uuid, kind text, branch_id uuid, requester_id uuid, requester_name text, amount_minor bigint, reason text, payload jsonb, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_permission('pos.approve');
  return query select a.id, a.kind, a.branch_id, a.requested_by, coalesce(tm.login_display, p.full_name, '—'), a.amount_minor, a.reason, a.payload, a.created_at
    from public.approvals a
    left join public.team_members tm on tm.user_id = a.requested_by
    left join public.profiles p on p.id = a.requested_by
   where a.status = 'pending' and a.requested_by <> auth.uid() and public._branch_ok(a.branch_id)
   order by a.created_at;
end $$;

create or replace function public.pos_decide_approval(p_id uuid, p_approve boolean, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare a public.approvals%rowtype;
begin
  perform public.require_permission('pos.approve');
  select * into a from public.approvals where id = p_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if a.status <> 'pending' then raise exception 'ALREADY_DECIDED'; end if;
  if a.requested_by = auth.uid() then raise exception 'SELF_APPROVAL' using errcode = '42501'; end if;
  if not public._branch_ok(a.branch_id) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if not p_approve and char_length(btrim(coalesce(p_note, ''))) < 2 then p_note := coalesce(nullif(btrim(p_note), ''), 'مرفوض'); end if;
  update public.approvals set status = case when p_approve then 'approved' else 'rejected' end, decided_by = auth.uid(), decided_at = now(),
         decision_note = nullif(left(btrim(coalesce(p_note, '')), 300), '') where id = a.id;
  perform public.audit_write('approval.decide', 'approval', a.id::text, jsonb_build_object('branch_id', a.branch_id, 'kind', a.kind,
          'amount_minor', a.amount_minor, 'approved', p_approve, 'requested_by', a.requested_by));
  perform public.notify_user(a.requested_by, case when p_approve then 'تمت الموافقة' else 'تم الرفض' end,
    case when p_approve then 'Approved' else 'Rejected' end,
    (case a.kind when 'discount' then 'طلب الخصم ' else 'طلب المرتجع ' end) || (case when p_approve then 'اتوافق عليه، كمّل العملية' else 'اترفض' end),
    (case a.kind when 'discount' then 'Your discount request ' else 'Your refund request ' end) || (case when p_approve then 'was approved' else 'was rejected' end),
    'system', null, a.id::text, '/hato-console');
end $$;

-- ============================================================ sales
create or replace function public._pos_sale_json(p_sale uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select to_jsonb(s) || jsonb_build_object(
    'branch_name_ar', (select name_ar from public.branches where id = s.branch_id),
    'cashier_name', (select coalesce(tm.login_display, p.full_name) from public.profiles p left join public.team_members tm on tm.user_id = p.id where p.id = s.cashier_id),
    'items', coalesce((select jsonb_agg(to_jsonb(i) order by i.name_ar) from public.pos_sale_items i where i.sale_id = s.id), '[]'::jsonb))
  from public.pos_sales s where s.id = p_sale
$$;
revoke all on function public._pos_sale_json(uuid) from public, anon, authenticated;

create or replace function public.pos_sale_get(p_sale uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s public.pos_sales%rowtype;
begin
  perform public.require_auth();
  select * into s from public.pos_sales where id = p_sale;
  if not found then raise exception 'NOT_FOUND'; end if;
  if not (s.cashier_id = auth.uid() or (public.has_permission('shifts.review') and public._branch_ok(s.branch_id))) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return public._pos_sale_json(s.id);
end $$;

-- p_items: [{"product_id": "...", "quantity": 2}, ...]. Prices and stock come from the database, never from the app.
create or replace function public.pos_create_sale(p_idempotency_key text, p_shift uuid, p_items jsonb, p_discount_minor bigint default 0,
                                                  p_cash_received_minor bigint default 0, p_customer uuid default null, p_approval uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := public.require_auth(); sh public.shifts%rowtype; v_sale public.pos_sales%rowtype; ap public.approvals%rowtype;
  v_lines jsonb; v_sub bigint; v_disc bigint := coalesce(p_discount_minor, 0); v_total bigint; v_pct numeric; v_need boolean := false;
  v_neg boolean; v_id uuid; v_num text; v_n int; v_rem bigint; v_share bigint; v_net bigint; l jsonb; v_i int := 0; v_cnt int;
begin
  perform public.require_permission('pos.sell');
  if p_idempotency_key is null or char_length(p_idempotency_key) not between 8 and 80 then raise exception 'INVALID_INPUT'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v_uid::text || p_idempotency_key, 0));
  select * into v_sale from public.pos_sales where cashier_id = v_uid and idempotency_key = p_idempotency_key;
  if found then return public._pos_sale_json(v_sale.id); end if;      -- a repeated tap / re-sent request: same invoice, no second sale

  select * into sh from public.shifts where id = p_shift;
  if not found or sh.cashier_id <> v_uid or sh.status <> 'open' then raise exception 'NO_OPEN_SHIFT'; end if;
  if not public._branch_ok(sh.branch_id) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;

  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 60 then raise exception 'INVALID_INPUT'; end if;
  if exists (select 1 from jsonb_array_elements(p_items) e
              where jsonb_typeof(e) <> 'object' or jsonb_typeof(e -> 'quantity') <> 'number'
                 or (e ->> 'quantity')::numeric <> trunc((e ->> 'quantity')::numeric) or (e ->> 'quantity')::numeric not between 1 and 999
                 or coalesce(e ->> 'product_id', '') !~ '^[0-9a-fA-F-]{36}$') then raise exception 'INVALID_INPUT'; end if;

  perform 1 from public.products where id in (select (e ->> 'product_id')::uuid from jsonb_array_elements(p_items) e) order by id for update;

  select jsonb_agg(jsonb_build_object('pid', x.pid, 'q', x.q, 'sku', p.sku, 'name_ar', p.name_ar, 'name_en', p.name_en,
                   'price', p.price_minor, 'stock', p.stock_quantity, 'status', p.status) order by x.pid),
         coalesce(sum(p.price_minor * x.q), 0), count(*)
    into v_lines, v_sub, v_cnt
    from (select (e ->> 'product_id')::uuid as pid, sum((e ->> 'quantity')::int)::int as q from jsonb_array_elements(p_items) e group by 1) x
    join public.products p on p.id = x.pid;
  if v_cnt <> (select count(distinct (e ->> 'product_id')::uuid) from jsonb_array_elements(p_items) e) then raise exception 'NOT_FOUND'; end if;
  if v_sub <= 0 then raise exception 'INVALID_INPUT'; end if;

  v_neg := exists (select 1 from public.application_settings where key = 'pos_allow_negative_stock' and value = 'true'::jsonb);
  for l in select * from jsonb_array_elements(v_lines) loop
    if l ->> 'status' <> 'published' then raise exception 'NOT_FOUND'; end if;
    if not v_neg and (l ->> 'stock')::int < (l ->> 'q')::int then raise exception 'OUT_OF_STOCK' using detail = l ->> 'sku'; end if;
  end loop;

  if v_disc < 0 or v_disc > v_sub then raise exception 'INVALID_INPUT'; end if;
  if v_disc > 0 and not public.has_role('owner') then
    v_pct := v_disc * 100.0 / v_sub;
    v_need := not (public.has_permission('pos.discount') and v_pct <= public._pos_num('pos_discount_approval_pct', 10));
    if v_need then
      if p_approval is null then raise exception 'APPROVAL_REQUIRED'; end if;
      select * into ap from public.approvals where id = p_approval for update;
      if not found or ap.kind <> 'discount' or ap.status <> 'approved' or ap.requested_by <> v_uid
         or ap.branch_id <> sh.branch_id or ap.amount_minor < v_disc then raise exception 'APPROVAL_REQUIRED'; end if;
    end if;
  end if;

  v_total := v_sub - v_disc;
  if p_cash_received_minor is null or p_cash_received_minor < v_total or p_cash_received_minor > 10000000000 then raise exception 'CASH_SHORT'; end if;

  v_num := 'POS-' || to_char(now() at time zone 'Africa/Cairo', 'YYMMDD') || '-' || lpad(nextval('public.pos_sale_seq')::text, 5, '0');
  insert into public.pos_sales (number, branch_id, shift_id, cashier_id, customer_id, idempotency_key, subtotal_minor, discount_minor, total_minor,
                                cash_received_minor, change_minor, approval_id)
  values (v_num, sh.branch_id, sh.id, v_uid, p_customer, p_idempotency_key, v_sub, v_disc, v_total, p_cash_received_minor,
          p_cash_received_minor - v_total, case when v_need then ap.id end)
  returning id into v_id;

  v_n := jsonb_array_length(v_lines); v_rem := v_disc;
  perform set_config('myhato.stock_ctx', 'pos', true);
  for l in select * from jsonb_array_elements(v_lines) loop
    v_i := v_i + 1;
    v_share := case when v_i = v_n then v_rem else round(v_disc * ((l ->> 'price')::bigint * (l ->> 'q')::int)::numeric / v_sub) end;
    v_rem := v_rem - v_share;
    v_net := (l ->> 'price')::bigint * (l ->> 'q')::int - v_share;
    insert into public.pos_sale_items (sale_id, product_id, sku, name_ar, name_en, quantity, unit_price_minor, line_total_minor, net_line_minor)
    values (v_id, (l ->> 'pid')::uuid, l ->> 'sku', l ->> 'name_ar', l ->> 'name_en', (l ->> 'q')::int, (l ->> 'price')::bigint,
            (l ->> 'price')::bigint * (l ->> 'q')::int, v_net);
    update public.products set stock_quantity = stock_quantity - (l ->> 'q')::int where id = (l ->> 'pid')::uuid;
    insert into public.inventory_movements (product_id, delta, reason, note, created_by, pos_sale_id)
    values ((l ->> 'pid')::uuid, -(l ->> 'q')::int, 'pos_sale', v_num, v_uid, v_id);
  end loop;
  perform set_config('myhato.stock_ctx', '', true);

  if v_need then update public.approvals set status = 'used', used_at = now() where id = ap.id; end if;
  perform public.audit_write('pos.sale', 'pos_sale', v_id::text, jsonb_build_object('branch_id', sh.branch_id, 'number', v_num, 'shift_id', sh.id,
          'total_minor', v_total, 'discount_minor', v_disc, 'approval_id', case when v_need then ap.id end, 'lines', v_n));
  return public._pos_sale_json(v_id);
end $$;

-- p_items: [{"item_id": "...", "quantity": 1}]. Money goes out of the caller's OPEN shift drawer.
create or replace function public.pos_refund(p_sale uuid, p_items jsonb, p_reason text, p_restock boolean default true, p_approval uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := public.require_auth(); s public.pos_sales%rowtype; sh public.shifts%rowtype; ap public.approvals%rowtype;
  e jsonb; it public.pos_sale_items%rowtype; v_q int; v_amt bigint; v_total bigint := 0; v_lines jsonb := '[]'::jsonb; v_id uuid; v_need boolean := false;
begin
  perform public.require_permission('pos.refund');
  if char_length(btrim(coalesce(p_reason, ''))) < 3 then raise exception 'REASON_REQUIRED'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 60 then raise exception 'INVALID_INPUT'; end if;
  select * into sh from public.shifts where cashier_id = v_uid and status = 'open';
  if not found then raise exception 'NO_OPEN_SHIFT'; end if;
  select * into s from public.pos_sales where id = p_sale for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if s.branch_id <> sh.branch_id or not public._branch_ok(s.branch_id) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;

  for e in select * from jsonb_array_elements(p_items) loop
    if jsonb_typeof(e -> 'quantity') <> 'number' or (e ->> 'quantity')::numeric <> trunc((e ->> 'quantity')::numeric)
       or (e ->> 'quantity')::numeric < 1 or coalesce(e ->> 'item_id', '') !~ '^[0-9a-fA-F-]{36}$' then raise exception 'INVALID_INPUT'; end if;
    select * into it from public.pos_sale_items where id = (e ->> 'item_id')::uuid and sale_id = s.id for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    v_q := (e ->> 'quantity')::int;
    if v_q > it.quantity - it.refunded_qty then raise exception 'REFUND_EXCEEDS_SOLD'; end if;
    v_amt := case when v_q = it.quantity - it.refunded_qty then it.net_line_minor - it.refunded_amount_minor
                  else round(it.net_line_minor::numeric * v_q / it.quantity) end;
    v_total := v_total + v_amt;
    v_lines := v_lines || jsonb_build_array(jsonb_build_object('item_id', it.id, 'product_id', it.product_id, 'quantity', v_q, 'amount_minor', v_amt));
    update public.pos_sale_items set refunded_qty = refunded_qty + v_q, refunded_amount_minor = refunded_amount_minor + v_amt where id = it.id;
  end loop;
  if v_total <= 0 or s.refunded_minor + v_total > s.total_minor then raise exception 'REFUND_EXCEEDS_SOLD'; end if;

  if v_total > public._pos_num('pos_refund_approval_minor', 50000) and not public.has_role('owner') then
    v_need := true;
    if p_approval is null then raise exception 'APPROVAL_REQUIRED'; end if;
    select * into ap from public.approvals where id = p_approval for update;
    if not found or ap.kind <> 'refund' or ap.status <> 'approved' or ap.requested_by <> v_uid or ap.branch_id <> s.branch_id
       or ap.amount_minor < v_total then raise exception 'APPROVAL_REQUIRED'; end if;
  end if;

  insert into public.pos_refunds (sale_id, shift_id, branch_id, amount_minor, reason, items, restocked, requested_by, approval_id)
  values (s.id, sh.id, s.branch_id, v_total, left(btrim(p_reason), 300), v_lines, coalesce(p_restock, true), v_uid, case when v_need then ap.id end)
  returning id into v_id;
  update public.pos_sales set refunded_minor = refunded_minor + v_total where id = s.id;

  if coalesce(p_restock, true) then
    perform set_config('myhato.stock_ctx', 'pos', true);
    for e in select * from jsonb_array_elements(v_lines) loop
      update public.products set stock_quantity = stock_quantity + (e ->> 'quantity')::int where id = (e ->> 'product_id')::uuid;
      insert into public.inventory_movements (product_id, delta, reason, note, created_by, pos_sale_id)
      values ((e ->> 'product_id')::uuid, (e ->> 'quantity')::int, 'pos_refund', s.number, v_uid, s.id);
    end loop;
    perform set_config('myhato.stock_ctx', '', true);
  end if;
  if v_need then update public.approvals set status = 'used', used_at = now() where id = ap.id; end if;
  perform public.audit_write('pos.refund', 'pos_sale', s.id::text, jsonb_build_object('branch_id', s.branch_id, 'number', s.number, 'refund_id', v_id,
          'amount_minor', v_total, 'reason', left(btrim(p_reason), 300), 'approval_id', case when v_need then ap.id end, 'restocked', coalesce(p_restock, true)));
  return jsonb_build_object('refund_id', v_id, 'amount_minor', v_total, 'sale', public._pos_sale_json(s.id));
end $$;

-- ============================================================ owner dashboard: branches side by side
create or replace function public.pos_branch_report(p_from timestamptz default null, p_to timestamptz default null)
returns table (branch_id uuid, branch_name_ar text, sales_count bigint, sales_minor bigint, refunds_minor bigint, net_minor bigint,
               shifts_closed bigint, variance_minor bigint, cashiers bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_auth();
  if not (public.has_permission('sales.view') or public.has_permission('shifts.review')) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return query
    select b.id, b.name_ar,
           coalesce((select count(*) from public.pos_sales s where s.branch_id = b.id and (p_from is null or s.created_at >= p_from) and (p_to is null or s.created_at < p_to)), 0),
           coalesce((select sum(s.total_minor) from public.pos_sales s where s.branch_id = b.id and (p_from is null or s.created_at >= p_from) and (p_to is null or s.created_at < p_to)), 0)::bigint,
           coalesce((select sum(r.amount_minor) from public.pos_refunds r where r.branch_id = b.id and (p_from is null or r.created_at >= p_from) and (p_to is null or r.created_at < p_to)), 0)::bigint,
           (coalesce((select sum(s.total_minor) from public.pos_sales s where s.branch_id = b.id and (p_from is null or s.created_at >= p_from) and (p_to is null or s.created_at < p_to)), 0)
            - coalesce((select sum(r.amount_minor) from public.pos_refunds r where r.branch_id = b.id and (p_from is null or r.created_at >= p_from) and (p_to is null or r.created_at < p_to)), 0))::bigint,
           coalesce((select count(*) from public.shifts h where h.branch_id = b.id and h.status = 'closed' and (p_from is null or h.opened_at >= p_from) and (p_to is null or h.opened_at < p_to)), 0),
           coalesce((select sum(h.variance_minor) from public.shifts h where h.branch_id = b.id and h.status = 'closed' and (p_from is null or h.opened_at >= p_from) and (p_to is null or h.opened_at < p_to)), 0)::bigint,
           coalesce((select count(distinct cashier_id) from public.pos_sales s where s.branch_id = b.id and (p_from is null or s.created_at >= p_from) and (p_to is null or s.created_at < p_to)), 0)
      from public.branches b where b.is_active and public._branch_ok(b.id) order by b.created_at;
end $$;

-- ============================================================ backup / restore check
create or replace function public.owner_data_snapshot() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_permission('settings.manage');
  if not public.has_role('owner') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return jsonb_build_object('taken_at', now(),
    'counts', jsonb_build_object('products', (select count(*) from public.products), 'customers', (select count(*) from public.customers),
      'orders', (select count(*) from public.orders), 'pos_sales', (select count(*) from public.pos_sales), 'shifts', (select count(*) from public.shifts),
      'repairs', (select count(*) from public.repair_requests), 'audit_logs', (select count(*) from public.audit_logs),
      'inventory_movements', (select count(*) from public.inventory_movements)),
    'stock_units', (select coalesce(sum(stock_quantity), 0) from public.products),
    'audit_head', (select row_hash from public.audit_logs where row_hash is not null order by id desc limit 1));
end $$;

-- ============================================================ grants
do $$ declare f text;
begin
  foreach f in array array[
    'pos_get_limits()','pos_set_limits(numeric,bigint,boolean)','staff_my_branches()','staff_get_branches(uuid)','staff_set_branches(uuid,uuid[])',
    'pos_open_shift(uuid,bigint)','pos_current_shift()','pos_shift_summary(uuid)','pos_close_shift(uuid,bigint,text)',
    'pos_shift_list(uuid,timestamptz,timestamptz,int)','pos_search_products(text,int)','pos_request_approval(text,bigint,text,uuid,jsonb)',
    'pos_pending_approvals()','pos_decide_approval(uuid,boolean,text)','pos_sale_get(uuid)',
    'pos_create_sale(text,uuid,jsonb,bigint,bigint,uuid,uuid)','pos_refund(uuid,jsonb,text,boolean,uuid)','pos_branch_report(timestamptz,timestamptz)',
    'owner_data_snapshot()'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
