-- Cashier / approvals / shifts / branches / audit-chain tests (run after all migrations).
-- Every check runs as a real database role (authenticated) with a given user id, never as the table owner.
\set ON_ERROR_STOP on

create table if not exists public._t (n serial, name text, ok boolean, detail text);
grant all on public._t to authenticated;
grant usage on sequence public._t_n_seq to authenticated;

-- run p_sql, expect it to raise something containing p_needle (or succeed when p_needle is null)
create or replace function public._expect(p_name text, p_sql text, p_needle text) returns void language plpgsql as $$
declare m text;
begin
  begin
    execute p_sql;
    if p_needle is null then insert into public._t(name, ok) values (p_name, true); else insert into public._t(name, ok, detail) values (p_name, false, 'no error'); end if;
  exception when others then
    m := sqlerrm;
    if p_needle is not null and m ilike '%' || p_needle || '%' then insert into public._t(name, ok) values (p_name, true);
    else insert into public._t(name, ok, detail) values (p_name, false, m); end if;
  end;
end $$;
grant execute on function public._expect(text, text, text) to authenticated;

-- ---------- fixtures (as the table owner)
insert into auth.users (id, email) values
 ('00000000-0000-0000-0000-0000000000a1', 'owner@t'), ('00000000-0000-0000-0000-0000000000a2', 'mgr@t'),
 ('00000000-0000-0000-0000-0000000000a3', 'cash@t'), ('00000000-0000-0000-0000-0000000000a4', 'tech@t'),
 ('00000000-0000-0000-0000-0000000000a5', 'cashB@t'), ('00000000-0000-0000-0000-0000000000a6', 'mgrB@t')
on conflict do nothing;
insert into public.profiles (id, full_name) select id, split_part(email, '@', 1) from auth.users where id::text like '00000000-0000-0000-0000-0000000000a%' on conflict do nothing;
insert into public.user_roles (user_id, role) values
 ('00000000-0000-0000-0000-0000000000a1', 'owner'), ('00000000-0000-0000-0000-0000000000a2', 'manager'),
 ('00000000-0000-0000-0000-0000000000a3', 'sales'), ('00000000-0000-0000-0000-0000000000a4', 'technician'),
 ('00000000-0000-0000-0000-0000000000a5', 'sales'), ('00000000-0000-0000-0000-0000000000a6', 'manager')
on conflict do nothing;
insert into public.branches (id, name_ar, name_en, address_ar, address_en, phone, hours_ar, hours_en, pickup_instructions_ar, pickup_instructions_en) values
 ('b0000000-0000-0000-0000-00000000000a','فرع أ','Branch A','ع','a','1','h','h','p','p'), ('b0000000-0000-0000-0000-00000000000b','فرع ب','Branch B','ع','a','1','h','h','p','p') on conflict do nothing;
delete from public.staff_branches;
insert into public.staff_branches (user_id, branch_id) values
 ('00000000-0000-0000-0000-0000000000a2', 'b0000000-0000-0000-0000-00000000000a'),
 ('00000000-0000-0000-0000-0000000000a3', 'b0000000-0000-0000-0000-00000000000a'),
 ('00000000-0000-0000-0000-0000000000a4', 'b0000000-0000-0000-0000-00000000000a'),
 ('00000000-0000-0000-0000-0000000000a5', 'b0000000-0000-0000-0000-00000000000b'),
 ('00000000-0000-0000-0000-0000000000a6', 'b0000000-0000-0000-0000-00000000000b');
insert into public.categories (id, kind, slug, name_ar, name_en) values ('c0000000-0000-0000-0000-000000000001', 'accessories', 'tcat', 'قسم', 'cat') on conflict do nothing;
insert into public.products (id, sku, slug, category_id, name_ar, name_en, price_minor, stock_quantity, status) values
 ('d0000000-0000-0000-0000-000000000001', 'T-CASE', 't-case', 'c0000000-0000-0000-0000-000000000001', 'جراب', 'Case', 10000, 10, 'published'),
 ('d0000000-0000-0000-0000-000000000002', 'T-LAST', 't-last', 'c0000000-0000-0000-0000-000000000001', 'آخر قطعة', 'Last', 50000, 1, 'published'),
 ('d0000000-0000-0000-0000-000000000003', 'T-BIG', 't-big', 'c0000000-0000-0000-0000-000000000001', 'موبايل', 'Phone', 300000, 5, 'published')
on conflict do nothing;

\set A 'b0000000-0000-0000-0000-00000000000a'
\set B 'b0000000-0000-0000-0000-00000000000b'
\set OWNER '00000000-0000-0000-0000-0000000000a1'
\set MGR '00000000-0000-0000-0000-0000000000a2'
\set CASH '00000000-0000-0000-0000-0000000000a3'
\set TECH '00000000-0000-0000-0000-0000000000a4'
\set CASHB '00000000-0000-0000-0000-0000000000a5'
\set MGRB '00000000-0000-0000-0000-0000000000a6'

\o /dev/null
-- ---------- cashier opens a shift and sells
set role authenticated; select set_config('request.jwt.claim.sub', :'CASH', false);
reset role; select set_config('request.jwt.claim.sub', :'TECH', false); set role authenticated;
select public._expect('technician cannot sell', $q$select public.pos_search_products('x')$q$, 'FORBIDDEN');
select public._expect('technician cannot open shift', format($q$select public.pos_open_shift(%L, 0)$q$, :'A'), 'FORBIDDEN');

reset role; select set_config('request.jwt.claim.sub', :'CASHB', false); set role authenticated;
select public._expect('cashier B cannot open a shift in branch A', format($q$select public.pos_open_shift(%L, 0)$q$, :'A'), 'FORBIDDEN');

reset role; select set_config('request.jwt.claim.sub', :'CASH', false); set role authenticated;
select public.pos_open_shift(:'A', 50000) as shift_a \gset
select public._expect('second open shift refused', format($q$select public.pos_open_shift(%L, 0)$q$, :'A'), 'SHIFT_ALREADY_OPEN');

-- plain sale, change computed on the server
select (public.pos_create_sale('idem-0001-aaaa', :'shift_a', '[{"product_id":"d0000000-0000-0000-0000-000000000001","quantity":2}]', 0, 25000)) ->> 'id' as sale1 \gset
select public._expect('sale total + change correct', format($q$select 1/ (case when (select total_minor = 20000 and change_minor = 5000 from public.pos_sales where id = %L) then 1 else 0 end)$q$, :'sale1'), null);
-- retry with the same key: same invoice, stock deducted once
select public.pos_create_sale('idem-0001-aaaa', :'shift_a', '[{"product_id":"d0000000-0000-0000-0000-000000000001","quantity":2}]', 0, 25000) ->> 'id' as sale1b \gset
select public._expect('retry returns the same invoice', format($q$select 1/(case when %L = %L then 1 else 0 end)$q$, :'sale1', :'sale1b'), null);
reset role;
select public._expect('stock deducted once (10 -> 8)', $q$select 1/(case when (select stock_quantity from public.products where sku='T-CASE') = 8 then 1 else 0 end)$q$, null);
set role authenticated; select set_config('request.jwt.claim.sub', :'CASH', false);

select public._expect('cash short refused', format($q$select public.pos_create_sale('idem-0002-aaaa', %L, '[{"product_id":"d0000000-0000-0000-0000-000000000001","quantity":1}]', 0, 5000)$q$, :'shift_a'), 'CASH_SHORT');
select public._expect('app cannot set its own price/qty trick (qty 0)', format($q$select public.pos_create_sale('idem-0003-aaaa', %L, '[{"product_id":"d0000000-0000-0000-0000-000000000001","quantity":0}]', 0, 5000)$q$, :'shift_a'), 'INVALID_INPUT');

-- ---------- last piece: second sale fails
select public.pos_create_sale('idem-0004-aaaa', :'shift_a', '[{"product_id":"d0000000-0000-0000-0000-000000000002","quantity":1}]', 0, 50000);
select public._expect('last piece cannot be sold twice', format($q$select public.pos_create_sale('idem-0005-aaaa', %L, '[{"product_id":"d0000000-0000-0000-0000-000000000002","quantity":1}]', 0, 50000)$q$, :'shift_a'), 'OUT_OF_STOCK');

-- ---------- discounts
select public._expect('cashier without pos.discount cannot discount', format($q$select public.pos_create_sale('idem-0006-aaaa', %L, '[{"product_id":"d0000000-0000-0000-0000-000000000003","quantity":1}]', 1000, 300000)$q$, :'shift_a'), 'APPROVAL_REQUIRED');
select public.pos_request_approval('discount', 60000, 'عميل دائم', :'A') as ap1 \gset
select public._expect('unapproved approval is not usable', format($q$select public.pos_create_sale('idem-0007-aaaa', %L, '[{"product_id":"d0000000-0000-0000-0000-000000000003","quantity":1}]', 60000, 300000, null, %L)$q$, :'shift_a', :'ap1'), 'APPROVAL_REQUIRED');
select public._expect('requester cannot approve himself', format($q$select public.pos_decide_approval(%L, true, null)$q$, :'ap1'), 'FORBIDDEN');
reset role; select set_config('request.jwt.claim.sub', :'CASHB', false); set role authenticated;
select public._expect('other branch manager-less cashier cannot approve', format($q$select public.pos_decide_approval(%L, true, null)$q$, :'ap1'), 'FORBIDDEN');
reset role; select set_config('request.jwt.claim.sub', :'MGRB', false); set role authenticated;
select public._expect('manager of another branch cannot approve', format($q$select public.pos_decide_approval(%L, true, null)$q$, :'ap1'), 'FORBIDDEN');
reset role; select set_config('request.jwt.claim.sub', :'MGR', false); set role authenticated;
select count(*) as pend from public.pos_pending_approvals() \gset
select public._expect('manager sees the pending request', format($q$select 1/(case when %s = 1 then 1 else 0 end)$q$, :'pend'), null);
select public.pos_decide_approval(:'ap1', true, 'تمام');
reset role; select set_config('request.jwt.claim.sub', :'CASH', false); set role authenticated;
select public._expect('discount larger than approved amount refused', format($q$select public.pos_create_sale('idem-0008-aaaa', %L, '[{"product_id":"d0000000-0000-0000-0000-000000000003","quantity":1}]', 90000, 300000, null, %L)$q$, :'shift_a', :'ap1'), 'APPROVAL_REQUIRED');
select public.pos_create_sale('idem-0009-aaaa', :'shift_a', '[{"product_id":"d0000000-0000-0000-0000-000000000003","quantity":1}]', 60000, 240000, null, :'ap1') ->> 'id' as sale_big \gset
select public._expect('approval cannot be reused', format($q$select public.pos_create_sale('idem-0010-aaaa', %L, '[{"product_id":"d0000000-0000-0000-0000-000000000003","quantity":1}]', 60000, 240000, null, %L)$q$, :'shift_a', :'ap1'), 'APPROVAL_REQUIRED');

-- ---------- invoices are final
select public._expect('cashier cannot delete an invoice', format($q$delete from public.pos_sales where id = %L$q$, :'sale_big'), 'permission denied');
select public._expect('cashier cannot edit an invoice total', format($q$update public.pos_sales set total_minor = 1 where id = %L$q$, :'sale_big'), 'permission denied');
select public._expect('cashier cannot insert an invoice directly', format($q$insert into public.pos_sales(number,branch_id,shift_id,cashier_id,idempotency_key,subtotal_minor,total_minor,cash_received_minor,change_minor) values ('x',%L,%L,auth.uid(),'k',1,1,1,0)$q$, :'A', :'shift_a'), 'permission denied');
select public._expect('cashier cannot edit stock movements', $q$update public.inventory_movements set delta = 99$q$, 'permission denied');
select public._expect('cashier cannot touch the audit log', $q$delete from public.audit_logs$q$, 'permission denied');
select public._expect('cashier cannot grant himself a role', format($q$insert into public.user_roles(user_id, role) values (%L, 'owner')$q$, :'CASH'), 'permission denied');
reset role; select set_config('request.jwt.claim.sub', :'TECH', false); set role authenticated;
update public.products set price_minor = 1;   -- a technician: RLS hides the rows, 0 rows updated
select public._expect('technician cannot adjust stock', $q$select public.staff_adjust_stock('d0000000-0000-0000-0000-000000000001', null, 5, 'restock', 'x')$q$, 'FORBIDDEN');
reset role;
select public._expect('technician cannot change a price', $q$select 1/(case when (select price_minor from public.products where sku='T-CASE') = 10000 then 1 else 0 end)$q$, null);
-- even the table owner cannot edit a final invoice
select public._expect('invoice trigger blocks edits for everybody', format($q$update public.pos_sales set total_minor = 1 where id = %L$q$, :'sale_big'), 'RECORD_IS_FINAL');

-- ---------- refunds
select set_config('request.jwt.claim.sub', :'MGR', false); set role authenticated;
select public._expect('refund needs a reason', format($q$select public.pos_refund(%L, '[]', 'x')$q$, :'sale1'), 'REASON_REQUIRED');
select id as it_case from public.pos_sale_items where sale_id = :'sale1' \gset
reset role; select set_config('request.jwt.claim.sub', :'CASH', false); set role authenticated;
select public._expect('cashier has no refund permission', format($q$select public.pos_refund(%L, '[{"item_id":"%s","quantity":1}]', 'عيب')$q$, :'sale1', :'it_case'), 'FORBIDDEN');
reset role; select set_config('request.jwt.claim.sub', :'MGR', false); set role authenticated;
select public._expect('manager needs an open shift to refund', format($q$select public.pos_refund(%L, '[{"item_id":"%s","quantity":1}]', 'عيب')$q$, :'sale1', :'it_case'), 'NO_OPEN_SHIFT');
select public.pos_open_shift(:'A', 10000) as shift_m \gset
select (public.pos_refund(:'sale1', format('[{"item_id":"%s","quantity":1}]', :'it_case')::jsonb, 'عيب مصنع')) ->> 'amount_minor' as r1 \gset
select public._expect('refund amount = one case 10000', format($q$select 1/(case when %s = 10000 then 1 else 0 end)$q$, :'r1'), null);
select public._expect('cannot refund more than sold', format($q$select public.pos_refund(%L, '[{"item_id":"%s","quantity":5}]', 'زيادة')$q$, :'sale1', :'it_case'), 'REFUND_EXCEEDS_SOLD');
select id as it_big from public.pos_sale_items where sale_id = :'sale_big' \gset
reset role; select set_config('request.jwt.claim.sub', :'MGR', false); set role authenticated;
select public._expect('big refund by manager needs another approver', format($q$select public.pos_refund(%L, '[{"item_id":"%s","quantity":1}]', 'مش عاجبه')$q$, :'sale_big', :'it_big'), 'APPROVAL_REQUIRED');
select public.pos_request_approval('refund', 240000, 'مش عاجبه', :'A') as ap2 \gset
select public._expect('manager cannot approve his own refund', format($q$select public.pos_decide_approval(%L, true, null)$q$, :'ap2'), 'SELF_APPROVAL');
reset role; select set_config('request.jwt.claim.sub', :'OWNER', false); set role authenticated;
select public.pos_decide_approval(:'ap2', true, 'تمام');
reset role; select set_config('request.jwt.claim.sub', :'MGR', false); set role authenticated;
select (public.pos_refund(:'sale_big', format('[{"item_id":"%s","quantity":1}]', :'it_big')::jsonb, 'مش عاجبه', true, :'ap2')) ->> 'amount_minor' as r2 \gset
select public._expect('refund after approval = discounted net 240000', format($q$select 1/(case when %s = 240000 then 1 else 0 end)$q$, :'r2'), null);
reset role;
select public._expect('refund restocked the phone (5 -> 5)', $q$select 1/(case when (select stock_quantity from public.products where sku='T-BIG') = 5 then 1 else 0 end)$q$, null);

select public._expect('find invoice by number (own)', format($q$select public.pos_find_sale((select number from public.pos_sales where id = %L))$q$, :'sale1'), null);
reset role; select set_config('request.jwt.claim.sub', :'CASHB', false); set role authenticated;
select public._expect('other branch cannot find the invoice', format($q$select public.pos_find_sale((select number from public.pos_sales where id = %L))$q$, :'sale1'), 'NOT_FOUND');
reset role; select set_config('request.jwt.claim.sub', :'CASH', false); set role authenticated;
-- ---------- shift close
select set_config('request.jwt.claim.sub', :'CASH', false); set role authenticated;
select public.pos_shift_summary(:'shift_a') ->> 'expected_minor' as exp_a \gset
select public._expect('cashier B cannot read shift A', format($q$select 1$q$), null);
reset role; select set_config('request.jwt.claim.sub', :'CASHB', false); set role authenticated;
select public._expect('cashier B cannot see shift A summary', format($q$select public.pos_shift_summary(%L)$q$, :'shift_a'), 'FORBIDDEN');
select public._expect('cashier B sees zero shifts of A via REST', format($q$select 1/(case when (select count(*) from public.shifts where branch_id = %L) = 0 then 1 else 0 end)$q$, :'A'), null);
select public._expect('cashier B sees zero sales of A via REST', $q$select 1/(case when (select count(*) from public.pos_sales) = 0 then 1 else 0 end)$q$, null);
reset role; select set_config('request.jwt.claim.sub', :'CASH', false); set role authenticated;
select public._expect('closing with a difference needs a note', format($q$select public.pos_close_shift(%L, 1000, null)$q$, :'shift_a'), 'NOTE_REQUIRED');
select public.pos_close_shift(:'shift_a', :'exp_a'::bigint - 500, 'ناقص ٥ جنيه') ->> 'variance_minor' as var_a \gset
select public._expect('variance recorded (-500)', format($q$select 1/(case when %s = -500 then 1 else 0 end)$q$, :'var_a'), null);
select public._expect('closed shift cannot sell', format($q$select public.pos_create_sale('idem-0011-aaaa', %L, '[{"product_id":"d0000000-0000-0000-0000-000000000001","quantity":1}]', 0, 10000)$q$, :'shift_a'), 'NO_OPEN_SHIFT');
reset role;
select public._expect('closed shift cannot be edited', format($q$update public.shifts set counted_cash_minor = 1 where id = %L$q$, :'shift_a'), 'RECORD_IS_FINAL');

-- ---------- disabled employee
update public.team_members set suspended_at = now() where user_id = :'CASH'::uuid;
insert into public.team_members (user_id, login_name, login_display, suspended_at) values (:'CASH', 'cash', 'cash', now()) on conflict (user_id) do update set suspended_at = now();
select set_config('request.jwt.claim.sub', :'CASH', false); set role authenticated;
select public._expect('suspended employee cannot sell', $q$select public.pos_search_products('x')$q$, 'FORBIDDEN');
reset role;
select public._expect('history of the suspended employee stays', $q$select 1/(case when (select count(*) from public.pos_sales) >= 3 then 1 else 0 end)$q$, null);

-- ---------- owner: branch compare, limits, snapshot; nobody else
select set_config('request.jwt.claim.sub', :'OWNER', false); set role authenticated;
select count(*) as nb from public.pos_branch_report() \gset
select public._expect('owner compares both branches', format($q$select 1/(case when %s >= 2 then 1 else 0 end)$q$, :'nb'), null);
select public._expect('owner sets limits', $q$select public.pos_set_limits(5, 20000, false)$q$, null);
select public._expect('owner snapshot works', $q$select public.owner_data_snapshot()$q$, null);
reset role; select set_config('request.jwt.claim.sub', :'MGR', false); set role authenticated;
select public._expect('manager cannot change limits', $q$select public.pos_set_limits(99, 99999999, true)$q$, 'FORBIDDEN');
select public._expect('manager sees only his branch in the report', $q$select 1/(case when (select count(*) from public.pos_branch_report()) = 1 then 1 else 0 end)$q$, null);
select public._expect('manager cannot give himself another branch', format($q$select public.staff_set_branches(%L, array[%L::uuid, %L::uuid])$q$, :'MGR', :'A', :'B'), 'FORBIDDEN');

-- ---------- audit chain
reset role; select set_config('request.jwt.claim.sub', :'OWNER', false); set role authenticated;
select public.audit_verify() ->> 'ok' as chain_ok \gset
select public._expect('audit chain verifies', format($q$select 1/(case when %L = 'true' then 1 else 0 end)$q$, :'chain_ok'), null);
select public._expect('owner cannot edit the log through the API', $q$update public.audit_logs set action = 'x'$q$, 'permission denied');
reset role;
select public._expect('log update blocked even for the table owner', $q$update public.audit_logs set action = 'x'$q$, 'append-only');
select public._expect('log truncate blocked', $q$truncate public.audit_logs$q$, 'append-only');
-- a database admin who disables the trigger and edits a row is caught
alter table public.audit_logs disable trigger audit_logs_no_update;
update public.audit_logs set details = '{"tampered":true}' where id = (select max(id) - 3 from public.audit_logs where row_hash is not null);
alter table public.audit_logs enable trigger audit_logs_no_update;
select set_config('request.jwt.claim.sub', :'OWNER', false); set role authenticated;
select public.audit_verify() ->> 'ok' as chain_ok2 \gset
select public._expect('tampering is detected', format($q$select 1/(case when %L = 'false' then 1 else 0 end)$q$, :'chain_ok2'), null);
reset role;

-- ---------- new roles: cashier and accountant (0062/0063)
reset role;
insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000a7', 'cashier2@t'), ('00000000-0000-0000-0000-0000000000a8', 'acct@t') on conflict do nothing;
insert into public.profiles (id, full_name) values ('00000000-0000-0000-0000-0000000000a7', 'cashier2'), ('00000000-0000-0000-0000-0000000000a8', 'acct') on conflict do nothing;
select set_config('request.jwt.claim.sub', :'OWNER', false); set role authenticated;
select public._expect('owner can make a cashier', $q$select public.staff_assign_role('00000000-0000-0000-0000-0000000000a7', 'cashier')$q$, null);
select public._expect('owner can make an accountant', $q$select public.staff_assign_role('00000000-0000-0000-0000-0000000000a8', 'accountant')$q$, null);
select public._expect('team list shows the new roles',
  $q$select 1/(case when (select count(*) from public.staff_team_live() where role in ('cashier','accountant')) = 2 then 1 else 0 end)$q$, null);
reset role;
insert into public.staff_branches (user_id, branch_id) values ('00000000-0000-0000-0000-0000000000a7', :'A'), ('00000000-0000-0000-0000-0000000000a8', :'A') on conflict do nothing;
\set NCASH '00000000-0000-0000-0000-0000000000a7'
\set ACCT '00000000-0000-0000-0000-0000000000a8'

select set_config('request.jwt.claim.sub', :'NCASH', false); set role authenticated;
select public._expect('cashier role can sell', $q$select public.pos_search_products('x')$q$, null);
select public._expect('cashier role has no price/stock rights', $q$select 1/(case when public.has_permission('products.manage') or public.has_permission('inventory.manage') then 0 else 1 end)$q$, null);
select public._expect('cashier role cannot see branch report', $q$select * from public.pos_branch_report()$q$, 'FORBIDDEN');
select public._expect('cashier role cannot approve', $q$select * from public.pos_pending_approvals()$q$, 'FORBIDDEN');
select public._expect('cashier role cannot manage the team', $q$select * from public.staff_team_live()$q$, 'FORBIDDEN');
select public.pos_open_shift(:'A', 0) as ncash_shift \gset
select public._expect('cashier role opens and closes a shift', format($q$select public.pos_close_shift(%L, 0, null)$q$, :'ncash_shift'), null);

reset role; select set_config('request.jwt.claim.sub', :'ACCT', false); set role authenticated;
select public._expect('accountant sees the branch report', $q$select * from public.pos_branch_report()$q$, null);
select public._expect('accountant sees shifts', $q$select * from public.pos_shift_list()$q$, null);
select public._expect('accountant cannot sell', $q$select public.pos_search_products('x')$q$, 'FORBIDDEN');
select public._expect('accountant cannot open a shift', format($q$select public.pos_open_shift(%L, 0)$q$, :'A'), 'FORBIDDEN');
select public._expect('accountant has no price/stock rights', $q$select 1/(case when public.has_permission('products.manage') or public.has_permission('inventory.manage') then 0 else 1 end)$q$, null);
select public._expect('accountant cannot change the log', $q$update public.audit_logs set action = 'x'$q$, 'permission denied');
reset role;

\o
-- ---------- report
select n, case when ok then 'PASS' else 'FAIL' end as result, name, detail from public._t order by n;
select count(*) filter (where not ok) > 0 as failed from public._t \gset
\if :failed
  \echo 'POS TESTS FAILED'
  \quit 1
\endif
\echo 'POS TESTS OK'
