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
update auth.users set encrypted_password = extensions.crypt('pw-test-1', extensions.gen_salt('bf')) where id::text like '00000000-0000-0000-0000-0000000000a%';
insert into public.user_roles (user_id, role) values
 ('00000000-0000-0000-0000-0000000000a1', 'owner'), ('00000000-0000-0000-0000-0000000000a2', 'manager'),
 ('00000000-0000-0000-0000-0000000000a3', 'sales'), ('00000000-0000-0000-0000-0000000000a4', 'technician'),
 ('00000000-0000-0000-0000-0000000000a5', 'sales'), ('00000000-0000-0000-0000-0000000000a6', 'manager')
on conflict do nothing;
insert into public.branches (id, name_ar, name_en, address_ar, address_en, phone, hours_ar, hours_en, pickup_instructions_ar, pickup_instructions_en) values
 ('b0000000-0000-0000-0000-00000000000a','فرع أ','Branch A','ع','a','1','h','h','p','p'), ('b0000000-0000-0000-0000-00000000000b','فرع ب','Branch B','ع','a','1','h','h','p','p') on conflict do nothing;
insert into public.user_permission_overrides(user_id, permission, effect) values ('00000000-0000-0000-0000-0000000000a2','branches.all','deny'),('00000000-0000-0000-0000-0000000000a6','branches.all','deny') on conflict do nothing;
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
select public._expect('wrong password does not close the shift', format($q$select 1/(case when public.pos_close_shift(%L, 1000, 'nope', 'x y z', null) ->> 'error' = 'WRONG_PASSWORD' and (select status from public.shifts where id = %L) = 'open' then 1 else 0 end)$q$, :'shift_a', :'shift_a'), null);
select public._expect('missing password does not close the shift', format($q$select 1/(case when public.pos_close_shift(%L, 1000, null, 'x y z', null) ->> 'error' = 'WRONG_PASSWORD' then 1 else 0 end)$q$, :'shift_a'), null);
select public._expect('closing with a difference needs a note', format($q$select public.pos_close_shift(%L, 1000, 'pw-test-1', null)$q$, :'shift_a'), 'NOTE_REQUIRED');
select public.pos_close_shift(:'shift_a', :'exp_a'::bigint - 500, 'pw-test-1', 'ناقص ٥ جنيه', 'windows · TILL-1') -> 'report' ->> 'variance_minor' as var_a \gset
select public._expect('variance recorded (-500)', format($q$select 1/(case when %s = -500 then 1 else 0 end)$q$, :'var_a'), null);
select public._expect('closed shift cannot sell', format($q$select public.pos_create_sale('idem-0011-aaaa', %L, '[{"product_id":"d0000000-0000-0000-0000-000000000001","quantity":1}]', 0, 10000)$q$, :'shift_a'), 'NO_OPEN_SHIFT');
reset role;
select public._expect('closed shift cannot be edited', format($q$update public.shifts set counted_cash_minor = 1 where id = %L$q$, :'shift_a'), 'RECORD_IS_FINAL');

-- ---------- final closing report + corrections
select public._expect('closing report records who, where and on which device', format($q$select 1/(case when exists (select 1 from public.shift_reports where shift_id = %L and closed_by_name is not null and closed_device = 'windows · TILL-1' and branch_name_ar is not null and report_no like 'SR-%%' and variance_minor = -500) then 1 else 0 end)$q$, :'shift_a'), null);
select public._expect('shift row also records the device', format($q$select 1/(case when (select closed_device from public.shifts where id = %L) = 'windows · TILL-1' then 1 else 0 end)$q$, :'shift_a'), null);
select public._expect('report cannot be edited', format($q$update public.shift_reports set counted_minor = 1 where shift_id = %L$q$, :'shift_a'), 'RECORD_IS_FINAL');
select public._expect('report cannot be deleted', format($q$delete from public.shift_reports where shift_id = %L$q$, :'shift_a'), 'RECORD_IS_FINAL');
select public._expect('reports cannot be truncated', $q$truncate public.shift_reports$q$, 'RECORD_IS_FINAL');
select set_config('request.jwt.claim.sub', :'CASH', false); set role authenticated;
select public._expect('cashier reads his own final report', format($q$select public.pos_shift_report_get(%L)$q$, :'shift_a'), null);
select public._expect('cashier cannot list all reports', $q$select * from public.pos_shift_report_list()$q$, 'FORBIDDEN');
select public._expect('cashier cannot add a correction', format($q$select public.pos_add_shift_correction(%L, 500, 'تصحيح عد الدرج')$q$, :'shift_a'), 'FORBIDDEN');
select public._expect('report tables are not readable directly', $q$select * from public.shift_reports$q$, 'permission denied');
reset role; select set_config('request.jwt.claim.sub', :'CASHB', false); set role authenticated;
select public._expect('other branch cashier cannot read the report', format($q$select public.pos_shift_report_get(%L)$q$, :'shift_a'), 'FORBIDDEN');
reset role; select set_config('request.jwt.claim.sub', :'TECH', false); set role authenticated;
select public._expect('technician cannot list reports', $q$select * from public.pos_shift_report_list()$q$, 'FORBIDDEN');
reset role; select set_config('request.jwt.claim.sub', :'MGRB', false); set role authenticated;
select public._expect('manager of another branch sees no report of branch A', format($q$select 1/(case when (select count(*) from public.pos_shift_report_list()) = 0 then 1 else 0 end)$q$, null), null);
select public._expect('manager of another branch cannot correct it', format($q$select public.pos_add_shift_correction(%L, 500, 'تصحيح عد الدرج')$q$, :'shift_a'), 'FORBIDDEN');
reset role; select set_config('request.jwt.claim.sub', :'MGR', false); set role authenticated;
select public._expect('manager sees the report list', $q$select 1/(case when (select count(*) from public.pos_shift_report_list()) >= 1 then 1 else 0 end)$q$, null);
select public._expect('correction needs a real reason', format($q$select public.pos_add_shift_correction(%L, 500, 'x')$q$, :'shift_a'), 'INVALID_INPUT');
select public._expect('manager adds a correction', format($q$select public.pos_add_shift_correction(%L, 500, 'عدّ الدرج غلط والفرق اتصحح')$q$, :'shift_a'), null);
select public._expect('original shift unchanged, corrected result shown', format($q$select 1/(case when (public.pos_shift_report_get(%L) ->> 'variance_minor')::bigint = -500 and (public.pos_shift_report_get(%L) ->> 'variance_after_corrections_minor')::bigint = 0 then 1 else 0 end)$q$, :'shift_a', :'shift_a'), null);
reset role;
select public._expect('correction cannot be edited', $q$update public.shift_corrections set amount_minor = 1$q$, 'RECORD_IS_FINAL');
select public._expect('correction cannot be deleted', $q$delete from public.shift_corrections$q$, 'RECORD_IS_FINAL');
select public._expect('closing and correcting are in the log', $q$select 1/(case when exists (select 1 from public.audit_logs where action = 'shift.close' and details ->> 'device' = 'windows · TILL-1') and exists (select 1 from public.audit_logs where action = 'shift.correct') then 1 else 0 end)$q$, null);
select set_config('request.jwt.claim.sub', :'CASH', false);

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
update auth.users set encrypted_password = extensions.crypt('pw-test-1', extensions.gen_salt('bf')) where id::text like '00000000-0000-0000-0000-0000000000a_';
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
select public._expect('cashier role opens and closes a shift', format($q$select public.pos_close_shift(%L, 0, 'pw-test-1', null)$q$, :'ncash_shift'), null);
select public.pos_open_shift(:'A', 0) as ncash_shift2 \gset
select public._expect('a wrong password is counted', format($q$select 1/(case when public.pos_close_shift(%L, 0, 'bad-1', null) ->> 'error' = 'WRONG_PASSWORD' then 1 else 0 end)$q$, :'ncash_shift2'), null);
select public.pos_close_shift(:'ncash_shift2', 0, 'bad-2', null);
select public.pos_close_shift(:'ncash_shift2', 0, 'bad-3', null);
select public.pos_close_shift(:'ncash_shift2', 0, 'bad-4', null);
select public.pos_close_shift(:'ncash_shift2', 0, 'bad-5', null);
select public.pos_close_shift(:'ncash_shift2', 0, 'bad-6', null);
select public.pos_close_shift(:'ncash_shift2', 0, 'bad-7', null);
select public.pos_close_shift(:'ncash_shift2', 0, 'bad-8', null);
select public._expect('too many wrong passwords are blocked', format($q$select public.pos_close_shift(%L, 0, 'pw-test-1', null)$q$, :'ncash_shift2'), 'RATE_LIMITED');

reset role; select set_config('request.jwt.claim.sub', :'ACCT', false); set role authenticated;
select public._expect('accountant sees the branch report', $q$select * from public.pos_branch_report()$q$, null);
select public._expect('accountant sees shifts', $q$select * from public.pos_shift_list()$q$, null);
select public._expect('accountant sees the closing reports', $q$select 1/(case when (select count(*) from public.pos_shift_report_list()) >= 1 then 1 else 0 end)$q$, null);
select public._expect('accountant cannot add a correction unless the owner allows it', format($q$select public.pos_add_shift_correction(%L, 500, 'محاولة تصحيح')$q$, :'shift_a'), 'FORBIDDEN');
select public._expect('accountant cannot sell', $q$select public.pos_search_products('x')$q$, 'FORBIDDEN');
select public._expect('accountant cannot open a shift', format($q$select public.pos_open_shift(%L, 0)$q$, :'A'), 'FORBIDDEN');
select public._expect('accountant has no price/stock rights', $q$select 1/(case when public.has_permission('products.manage') or public.has_permission('inventory.manage') then 0 else 1 end)$q$, null);
select public._expect('accountant has no remember-login right', $q$select 1/(case when public.has_permission('pos.remember_login') then 0 else 1 end)$q$, null);
reset role; select set_config('request.jwt.claim.sub', :'NCASH', false); set role authenticated;
select public._expect('cashier may remember his username', $q$select 1/(case when public.has_permission('pos.remember_login') then 1 else 0 end)$q$, null);
reset role; select set_config('request.jwt.claim.sub', :'ACCT', false); set role authenticated;
select public._expect('accountant cannot change the log', $q$update public.audit_logs set action = 'x'$q$, 'permission denied');
reset role;

-- ---------- 0066: the nine formerly "coming soon" permissions are real
reset role;
select public._expect('no permission is inert any more', $q$select 1/(case when exists (select 1 from public.permission_catalog where inert) then 0 else 1 end)$q$, null);
select public._expect('owner has every new permission', $q$select 1/(case when (select count(*) from public.role_permissions where role = 'owner' and permission in ('customers.review','cancel_requests.decide','coupons.manage','notifications.broadcast','reviews.moderate','audit.export','payments.manage','roles.assign','branches.manage')) = 9 then 1 else 0 end)$q$, null);
select public._expect('manager inherited coupons.manage from orders.manage', $q$select 1/(case when exists (select 1 from public.role_permissions where role='manager' and permission='coupons.manage') then 1 else 0 end)$q$, null);
select public._expect('manager did not get roles.assign (he had no staff.manage)', $q$select 1/(case when exists (select 1 from public.role_permissions where role='manager' and permission='roles.assign') then 0 else 1 end)$q$, null);
select set_config('request.jwt.claim.sub', :'MGR', false); set role authenticated;
select public._expect('manager can save a coupon', $q$select public.staff_save_coupon('T66', 'اختبار', 10, null, 0, null, 1, null, true)$q$, null);
reset role; insert into public.user_permission_overrides(user_id, permission, effect) values (:'MGR', 'coupons.manage', 'deny');
select set_config('request.jwt.claim.sub', :'MGR', false); set role authenticated;
select public._expect('owner can switch coupons off for one person', $q$select public.staff_save_coupon('T67', 'اختبار', 10, null, 0, null, 1, null, true)$q$, 'FORBIDDEN');
select public._expect('he still handles orders (only coupons were switched off)', $q$select 1/(case when public.has_permission('orders.manage') then 1 else 0 end)$q$, null);
reset role; delete from public.user_permission_overrides where user_id = :'MGR' and permission = 'coupons.manage';
select set_config('request.jwt.claim.sub', :'TECH', false); set role authenticated;
select public._expect('technician cannot download the log', $q$select public.audit_export(7)$q$, 'FORBIDDEN');
select public._expect('technician cannot broadcast', $q$select public.staff_broadcast_offer('x','y',null,null)$q$, 'FORBIDDEN');
select public._expect('cancellation decisions are gated by their own permission', $q$select 1/(case when pg_get_functiondef('public.staff_decide_cancel(uuid,boolean,text)'::regprocedure) like '%require_permission(''cancel_requests.decide'')%' then 1 else 0 end)$q$, null);
select public._expect('technician cannot change roles', format($q$select public.staff_assign_role(%L, 'sales')$q$, :'CASH'), 'FORBIDDEN');
reset role; select set_config('request.jwt.claim.sub', :'OWNER', false); set role authenticated;
select public._expect('owner downloads the log as CSV', $q$select 1/(case when public.audit_export(30) like 'id,time,actor,action%' then 1 else 0 end)$q$, null);
select public._expect('the download is itself logged', $q$select 1/(case when exists (select 1 from public.audit_logs where action = 'audit.export') then 1 else 0 end)$q$, null);
reset role;

-- ---------- 0067: head office, accountant sees every branch
reset role;
select public._expect('head office exists and is a branch', $q$select 1/(case when (select count(*) from public.branches where is_hq) = 1 then 1 else 0 end)$q$, null);
select set_config('request.jwt.claim.sub', '', false); set role anon;
select public._expect('customers never see head office', $q$select 1/(case when exists (select 1 from public.branches where is_hq) then 0 else 1 end)$q$, null);
reset role; select set_config('request.jwt.claim.sub', :'ACCT', false); set role authenticated;
select public._expect('accountant has no branch assigned yet still lists every branch', $q$select 1/(case when (select count(*) from public.staff_view_branches()) >= 3 then 1 else 0 end)$q$, null);
select public._expect('accountant reads shifts of every branch', $q$select 1/(case when (select count(distinct branch_id) from public.pos_shift_list()) >= 1 then 1 else 0 end)$q$, null);
select public._expect('accountant branch report lists all branches', $q$select 1/(case when (select count(*) from public.pos_branch_report()) >= 3 then 1 else 0 end)$q$, null);
select public._expect('accountant gets the sales list', $q$select 1/(case when (select count(*) from public.books_sales()) >= 1 then 1 else 0 end)$q$, null);
select public._expect('seeing a branch does not let him work in it', format($q$select public.pos_open_shift(%L, 0)$q$, :'B'), 'FORBIDDEN');
reset role; select set_config('request.jwt.claim.sub', :'MGR', false); set role authenticated;
reset role; delete from public.user_permission_overrides where user_id = :'MGR' and permission = 'branches.all';
select set_config('request.jwt.claim.sub', :'MGR', false); set role authenticated;
select public._expect('a manager sees every branch by default', $q$select 1/(case when (select count(*) from public.pos_branch_report()) >= 3 then 1 else 0 end)$q$, null);
reset role; insert into public.user_permission_overrides(user_id, permission, effect) values (:'MGR', 'branches.all', 'deny');
select set_config('request.jwt.claim.sub', :'MGR', false); set role authenticated;
select public._expect('owner can switch "every branch" off for one manager and it works at once', $q$select 1/(case when (select count(*) from public.pos_branch_report()) >= 3 then 0 else 1 end)$q$, null);
reset role; delete from public.user_permission_overrides where user_id = :'MGR' and permission = 'branches.all';

-- ---------- 0068: team colour theme (owner sets it for everybody, nobody else can)
reset role; select set_config('request.jwt.claim.sub', :'MGR', false); set role authenticated;
select public._expect('a manager cannot set the colours for everybody', $q$select public.owner_set_team_theme('terracotta')$q$, 'FORBIDDEN');
select public._expect('staff can read the current theme', $q$select public.team_theme_get()$q$, null);
reset role; select set_config('request.jwt.claim.sub', :'OWNER', false); set role authenticated;
select public._expect('the owner sets the theme for everybody', $q$select 1/(case when public.owner_set_team_theme('terracotta') ->> 'theme' = 'terracotta' then 1 else 0 end)$q$, null);
select public._expect('a bad theme name is refused', $q$select public.owner_set_team_theme('Bad Name!')$q$, 'INVALID_INPUT');
reset role; select set_config('request.jwt.claim.sub', '', false); set role authenticated;
select public._expect('a non-staff person cannot read it', $q$select public.team_theme_get()$q$, 'FORBIDDEN');
reset role;

-- ---------- 0069: periods, targets, commissions
reset role; select set_config('request.jwt.claim.sub', :'ACCT', false); set role authenticated;
select public._expect('accountant sees the branch targets chart', $q$select 1/(case when jsonb_array_length(public.targets_overview() -> 'branches') >= 2 then 1 else 0 end)$q$, null);
select public._expect('every ordinary branch starts at 50,000 EGP', $q$select 1/(case when (select bool_and((b ->> 'target_minor')::bigint = 5000000) from jsonb_array_elements(public.targets_overview() -> 'branches') b) then 1 else 0 end)$q$, null);
select public._expect('accountant cannot change a target', format($q$select public.targets_set_branch(%L, 100)$q$, :'A'), 'FORBIDDEN');
select public._expect('accountant cannot set commissions', $q$select public.commission_list()$q$, 'FORBIDDEN');
reset role; select set_config('request.jwt.claim.sub', :'TECH', false); set role authenticated;
select public._expect('technician cannot see targets', $q$select public.targets_overview()$q$, 'FORBIDDEN');
select public._expect('technician has no target page of his own', $q$select public.my_target_status()$q$, 'FORBIDDEN');
reset role; select set_config('request.jwt.claim.sub', :'OWNER', false); set role authenticated;
select public._expect('owner changes a branch target', format($q$select public.targets_set_branch(%L, 7000000)$q$, :'A'), null);
select public._expect('the new branch target shows', format($q$select 1/(case when (select (b ->> 'target_minor')::bigint from jsonb_array_elements(public.targets_overview() -> 'branches') b where b ->> 'branch_id' = %L) = 7000000 then 1 else 0 end)$q$, :'A'), null);
select public._expect('owner gives a seller a monthly target', format($q$select public.targets_set_user(%L, 2000000)$q$, :'NCASH'), null);
select public._expect('owner sets a product commission', $q$select public.commission_set('d0000000-0000-0000-0000-000000000001', 100)$q$, null);
select public._expect('a commission above the price is refused', $q$select public.commission_set('d0000000-0000-0000-0000-000000000001', 999999999)$q$, 'INVALID_INPUT');
reset role;
insert into public.pos_sales (number, branch_id, shift_id, cashier_id, idempotency_key, subtotal_minor, discount_minor, total_minor, cash_received_minor, change_minor)
  values ('T-COMM-1', :'A', :'shift_a', :'NCASH', 'comm-test-1', 2000, 0, 2000, 2000, 0) returning id as comm_sale \gset
insert into public.pos_sale_items (sale_id, product_id, sku, name_ar, name_en, quantity, unit_price_minor, line_total_minor, net_line_minor)
  values (:'comm_sale', 'd0000000-0000-0000-0000-000000000001', 'x', 'x', 'x', 2, 1000, 2000, 2000);
select public._expect('the commission is frozen on the sale line', format($q$select 1/(case when (select commission_unit_minor from public.pos_sale_items where sale_id = %L) = 100 then 1 else 0 end)$q$, :'comm_sale'), null);
select set_config('request.jwt.claim.sub', :'OWNER', false); set role authenticated;
select public._expect('owner changes the commission later', $q$select public.commission_set('d0000000-0000-0000-0000-000000000001', 150)$q$, null);
reset role;
select public._expect('an old sale keeps the old commission', format($q$select 1/(case when (select commission_unit_minor from public.pos_sale_items where sale_id = %L) = 100 then 1 else 0 end)$q$, :'comm_sale'), null);
select set_config('request.jwt.claim.sub', :'NCASH', false); set role authenticated;
select public._expect('the seller sees his own commission today (2 x 1 EGP)', $q$select 1/(case when (public.my_target_status() ->> 'commission_today_minor')::bigint >= 200 then 1 else 0 end)$q$, null);
select public._expect('the seller sees his target progress', $q$select 1/(case when (public.my_target_status() ->> 'target_minor')::bigint = 2000000 and public.my_target_status() ->> 'pct' is not null then 1 else 0 end)$q$, null);
select public._expect('the seller cannot see the branch chart', $q$select public.targets_overview()$q$, 'FORBIDDEN');
select public._expect('a cashier still lists his own shifts without a period', $q$select count(*) from public.pos_shift_list()$q$, null);
reset role; insert into public.user_permission_overrides(user_id, permission, effect) values (:'ACCT', 'books.period', 'deny');
select set_config('request.jwt.claim.sub', :'ACCT', false); set role authenticated;
select public._expect('without the period right, a year back is refused', $q$select * from public.pos_shift_list(null, now() - interval '200 days', null, 50)$q$, 'FORBIDDEN');
select public._expect('without the period right, the last week is fine', $q$select * from public.pos_shift_list(null, now() - interval '7 days', null, 50)$q$, null);
reset role; delete from public.user_permission_overrides where user_id = :'ACCT' and permission = 'books.period';
select set_config('request.jwt.claim.sub', :'ACCT', false); set role authenticated;
select public._expect('with the period right, any range works', $q$select * from public.pos_shift_list(null, now() - interval '400 days', null, 50)$q$, null);
reset role;

-- ---------- 0071: live operations room
reset role; select set_config('request.jwt.claim.sub', :'OWNER', false); set role authenticated;
select public._expect('owner opens the live room', $q$select 1/(case when jsonb_array_length(public.ops_live() -> 'branches') >= 2 then 1 else 0 end)$q$, null);
select public._expect('live room lists the sales', $q$select 1/(case when jsonb_typeof(public.ops_sales(null, null, false, 50)) = 'array' then 1 else 0 end)$q$, null);
select public._expect('owner reads the actions feed', $q$select public.ops_actions(null, 20)$q$, null);
reset role; select set_config('request.jwt.claim.sub', :'MGR', false); set role authenticated;
select public._expect('manager has no live room by default', $q$select public.ops_live()$q$, 'FORBIDDEN');
select public._expect('manager cannot read sales through it', $q$select public.ops_sales()$q$, 'FORBIDDEN');
reset role; select set_config('request.jwt.claim.sub', :'ACCT', false); set role authenticated;
select public._expect('accountant has no live room', $q$select public.ops_actions()$q$, 'FORBIDDEN');
reset role;

-- ---------- 0072: branch assignment and renaming
reset role; select set_config('request.jwt.claim.sub', :'OWNER', false); set role authenticated;
select public._expect('owner puts the accountant in head office', format($q$select public.staff_set_branches(%L, array[(select id from public.branches where is_hq)])$q$, :'ACCT'), null);
select public._expect('owner puts the cashier in two branches', format($q$select public.staff_set_branches(%L, array[%L::uuid, %L::uuid])$q$, :'CASH', :'A', :'B'), null);
select public._expect('there are four ordinary branches', $q$select 1/(case when (select count(*) from public.branches where not is_hq) >= 4 then 1 else 0 end)$q$, null);
select public._expect('owner renames a branch', format($q$select public.staff_rename_branch(%L, 'فرع تجريبي', null)$q$, :'A'), null);
reset role; select set_config('request.jwt.claim.sub', :'MGR', false); set role authenticated;
select public._expect('manager cannot rename without the right', format($q$select public.staff_rename_branch(%L, 'x', null)$q$, :'A'), 'FORBIDDEN');
reset role;

-- ---------- 0073: tips
select public._expect('tip column exists with a guard', $q$select 1/(case when exists (select 1 from information_schema.columns where table_name='pos_sales' and column_name='tip_minor') then 1 else 0 end)$q$, null);
select public._expect('shift totals carry the tips', $q$select 1/(case when pg_get_functiondef('public._shift_totals(uuid)'::regprocedure) like '%tips_minor%' then 1 else 0 end)$q$, null);
select public._expect('a stranger cannot mark a tip', $q$select public.pos_mark_tip('00000000-0000-0000-0000-000000000000')$q$, 'NOT_FOUND');

-- ---------- 0074: employee target from the account screen
reset role; select set_config('request.jwt.claim.sub', :'OWNER', false); set role authenticated;
select public._expect('owner sets an employee target', format($q$select public.targets_set_user(%L, 3000000)$q$, :'CASH'), null);
select public._expect('owner reads it back', format($q$select 1/(case when public.targets_get_user(%L) = 3000000 then 1 else 0 end)$q$, :'CASH'), null);
select public._expect('the employee got a notification', format($q$select 1/(case when exists (select 1 from public.notifications where user_id = %L and title_ar like '%%تارجت%%') then 1 else 0 end)$q$, :'CASH'), null);
reset role; select set_config('request.jwt.claim.sub', :'TECH', false); set role authenticated;
select public._expect('technician cannot read targets', format($q$select public.targets_get_user(%L)$q$, :'CASH'), 'FORBIDDEN');
reset role;

-- ---------- 0075: branches of each member
reset role; select set_config('request.jwt.claim.sub', :'OWNER', false); set role authenticated;
select public._expect('owner lists the branches of every member', $q$select * from public.staff_members_branches()$q$, null);
reset role; select set_config('request.jwt.claim.sub', :'TECH', false); set role authenticated;
select public._expect('technician cannot list them', $q$select * from public.staff_members_branches()$q$, 'FORBIDDEN');
reset role;

-- ---------- 0076: app updates
reset role; insert into public.app_releases (platform, build, path, sha256) values ('windows', 5, 'windows/MyHatoTeam-Setup-5.exe', repeat('a', 64)), ('windows', 7, 'windows/MyHatoTeam-Setup-7.exe', repeat('b', 64));
select set_config('request.jwt.claim.sub', :'OWNER', false); set role authenticated;
select public._expect('a team member gets the newest build', $q$select 1/(case when (select build from public.latest_app_update('windows')) = 7 then 1 else 0 end)$q$, null);
select public._expect('the table itself is closed', $q$select * from public.app_releases$q$, 'permission denied');
reset role; delete from public.app_releases;

-- ---------- 0077: direct chat
reset role; select set_config('request.jwt.claim.sub', :'TECH', false); set role authenticated;
select public._expect('technician sends a message to the office', $q$select public.chat_staff_send('محتاج خصم ١٠ جنيه')$q$, null);
select public._expect('technician cannot answer members', $q$select public.chat_directory()$q$, 'FORBIDDEN');
select public._expect('technician cannot read logs', $q$select public.chat_logs()$q$, 'FORBIDDEN');
select public._expect('technician sees his message', $q$select 1/(case when jsonb_array_length(public.chat_staff_fetch()->'messages') = 1 then 1 else 0 end)$q$, null);
reset role; select set_config('request.jwt.claim.sub', :'OWNER', false); set role authenticated;
select public._expect('owner sees one unread', $q$select 1/(case when (public.chat_unread()->>'count')::int = 1 then 1 else 0 end)$q$, null);
select public._expect('owner answers', format($q$select public.chat_manager_send(%L::uuid, 'تمام')$q$, :'TECH'), null);
reset role; select set_config('request.jwt.claim.sub', :'TECH', false); set role authenticated;
select public._expect('technician clears his view', $q$select public.chat_staff_clear()$q$, null);
select public._expect('technician sees nothing after clearing', $q$select 1/(case when jsonb_array_length(public.chat_staff_fetch()->'messages') = 0 then 1 else 0 end)$q$, null);
reset role; select set_config('request.jwt.claim.sub', :'OWNER', false); set role authenticated;
select public._expect('owner still has the record', $q$select 1/(case when (select count(*) from jsonb_array_elements(public.chat_logs())) = 1 then 1 else 0 end)$q$, null);
reset role; update public.chat_threads set closed_at = now();
select set_config('request.jwt.claim.sub', :'OWNER', false); set role authenticated;
select public._expect('owner deletes all closed logs', $q$select 1/(case when public.chat_logs_delete(null, true) = 1 then 1 else 0 end)$q$, null);
reset role;

-- ---------- 0078: commission dates + KPI
reset role; select set_config('request.jwt.claim.sub', :'OWNER', false); set role authenticated;
select public._expect('commission with an end before its start is refused', $q$select public.commission_set((select id from public.products limit 1), 100, current_date, current_date - 1)$q$, 'INVALID_INPUT');
select public._expect('owner sets a dated commission', $q$select public.commission_set((select id from public.products order by id limit 1), 100, current_date, current_date)$q$, null);
select public._expect('the dates are read back', $q$select 1/(case when (public.commission_get_full((select id from public.products order by id limit 1))->>'starts_on')::date = current_date then 1 else 0 end)$q$, null);
select public._expect('owner reads employee KPIs', $q$select public.kpi_employees(now() - interval '30 days', now() + interval '1 day')$q$, null);
select public._expect('a bad range is refused', $q$select public.kpi_employees(now(), now() - interval '1 day')$q$, 'INVALID_INPUT');
select public._expect('owner reads a commission log', format($q$select public.kpi_commission_log(%L::uuid, now() - interval '30 days', now() + interval '1 day')$q$, :'TECH'), null);
reset role; select set_config('request.jwt.claim.sub', :'TECH', false); set role authenticated;
select public._expect('technician cannot read KPIs', $q$select public.kpi_employees(now() - interval '30 days', now())$q$, 'FORBIDDEN');
reset role; delete from public.product_commissions;

-- ---------- 0079: office users message each other
reset role; select set_config('request.jwt.claim.sub', :'OWNER', false); set role authenticated;
select public._expect('owner writes to a manager', format($q$select public.chat_manager_send(%L::uuid, 'ازيك')$q$, :'MGR'), null);
reset role; select set_config('request.jwt.claim.sub', :'MGR', false); set role authenticated;
select public._expect('manager sees one unread from the owner', $q$select 1/(case when (public.chat_unread()->>'count')::int = 1 and (public.chat_unread()->>'staff_id') = current_setting('request.jwt.claim.sub')::text is false then 1 else 0 end)$q$, null);
select public._expect('manager answers the owner', format($q$select public.chat_manager_send(%L::uuid, 'تمام يا باشا')$q$, :'OWNER'), null);
select public._expect('manager sees both messages, one of them his', format($q$select 1/(case when jsonb_array_length(public.chat_manager_fetch(%L::uuid)->'messages') = 2 and (select count(*) from jsonb_array_elements(public.chat_manager_fetch(%L::uuid)->'messages') e where (e->>'mine')::boolean) = 1 then 1 else 0 end)$q$, :'OWNER', :'OWNER'), null);
reset role; select set_config('request.jwt.claim.sub', :'OWNER', false); set role authenticated;
select public._expect('owner gets the manager''s answer', $q$select 1/(case when (public.chat_unread()->>'count')::int >= 1 then 1 else 0 end)$q$, null);
reset role; delete from public.chat_threads;

-- ---------- 0081: today's commission products
reset role; select set_config('request.jwt.claim.sub', :'OWNER', false); set role authenticated;
select public._expect('owner sets a commission running today', $q$select public.commission_set((select id from public.products where sku='T-CASE'), 2500, current_date - 1, current_date + 1)$q$, null);
select public._expect('owner sees it in today''s list', $q$select 1/(case when exists (select 1 from jsonb_array_elements(public.commission_today_products()) e where e->>'sku' = 'T-CASE' and (e->>'amount_minor')::int = 2500) then 1 else 0 end)$q$, null);
select public._expect('an ended commission is not listed', $q$select public.commission_set((select id from public.products where sku='T-CASE'), 2500, current_date - 5, current_date - 2)$q$, null);
select public._expect('list is empty for it now', $q$select 1/(case when not exists (select 1 from jsonb_array_elements(public.commission_today_products()) e where e->>'sku' = 'T-CASE') then 1 else 0 end)$q$, null);
reset role; select set_config('request.jwt.claim.sub', :'TECH', false); set role authenticated;
select public._expect('technician has no permission to the list', $q$select public.commission_today_products()$q$, 'FORBIDDEN');
reset role; delete from public.product_commissions;

-- ---------- 0082: a small discount needs no approval
reset role; select set_config('request.jwt.claim.sub', :'OWNER', false); set role authenticated;
select public._expect('limits expose the free amount', $q$select 1/(case when (public.pos_get_limits()->>'discount_free_minor')::int = 1000 then 1 else 0 end)$q$, null);
select public._expect('owner changes the free amount', $q$select public.pos_set_limits(10, 50000, false, 2000)$q$, null);
select public._expect('new free amount is read back', $q$select 1/(case when (public.pos_get_limits()->>'discount_free_minor')::int = 2000 then 1 else 0 end)$q$, null);
reset role;
select public._expect('sale function honours the free amount', $q$select 1/(case when pg_get_functiondef('public.pos_create_sale(text,uuid,jsonb,bigint,bigint,uuid,uuid)'::regprocedure) like '%pos_discount_free_minor%' then 1 else 0 end)$q$, null);
-- ---------- 0083: invoice look
reset role; select set_config('request.jwt.claim.sub', :'OWNER', false); set role authenticated;
select public._expect('default look is clean', $q$select 1/(case when public.receipt_style_get() = 'clean' then 1 else 0 end)$q$, null);
select public._expect('owner picks banner', $q$select public.receipt_style_set('banner')$q$, null);
select public._expect('a bad look is refused', $q$select public.receipt_style_set('fancy')$q$, 'INVALID_INPUT');
reset role; select set_config('request.jwt.claim.sub', :'TECH', false); set role authenticated;
select public._expect('staff reads the shop look', $q$select 1/(case when public.receipt_style_get() = 'banner' then 1 else 0 end)$q$, null);
select public._expect('technician cannot change it', $q$select public.receipt_style_set('cards')$q$, 'FORBIDDEN');
reset role;
-- ---------- 0084: profit
reset role; select set_config('request.jwt.claim.sub', :'OWNER', false); set role authenticated;
select public._expect('owner sets a cost', $q$select public.cost_set((select id from public.products where sku='T-CASE'), 6000)$q$, null);
select public._expect('cost is read back', $q$select 1/(case when public.cost_get((select id from public.products where sku='T-CASE')) = 6000 then 1 else 0 end)$q$, null);
select public._expect('bulk cost by sku', $q$select public.cost_set_bulk('[{"sku":"T-CASE","cost_minor":7000},{"sku":"NOPE","cost_minor":1}]'::jsonb)$q$, null);
select public._expect('bulk reports the unknown sku', $q$select 1/(case when public.cost_set_bulk('[{"sku":"NOPE","cost_minor":1}]'::jsonb)->'not_found' = '["NOPE"]'::jsonb then 1 else 0 end)$q$, null);
select public._expect('profit report runs for the owner', $q$select 1/(case when (public.profit_report(now() - interval '30 days', now() + interval '1 day')->'totals') is not null then 1 else 0 end)$q$, null);
select public._expect('profit report runs twice in one session', $q$select public.profit_report(now() - interval '30 days', now() + interval '1 day')$q$, null);
reset role; select set_config('request.jwt.claim.sub', :'TECH', false); set role authenticated;
select public._expect('technician cannot read profit', $q$select public.profit_report(now() - interval '30 days', now())$q$, 'FORBIDDEN');
select public._expect('technician cannot set a cost', $q$select public.cost_set((select id from public.products where sku='T-CASE'), 1)$q$, 'FORBIDDEN');
reset role;
select public._expect('customers cannot read costs directly', $q$select 1/(case when has_table_privilege('authenticated', 'public.product_costs', 'select') then 0 else 1 end)$q$, null);
-- ---------- 0085: live profit
reset role; select set_config('request.jwt.claim.sub', :'OWNER', false); set role authenticated;
select public._expect('owner sees profit in the live room', $q$select 1/(case when public.ops_live()->'profit' is not null and (public.ops_live()->'profit'->>'sales_counted') is not null then 1 else 0 end)$q$, null);
reset role;
-- ---------- 0088: contests
create table if not exists public._ct (id uuid); grant all on public._ct to authenticated; delete from public._ct;
reset role; select set_config('request.jwt.claim.sub', :'OWNER', false); set role authenticated;
select public._expect('owner creates a contest', $q$select public.contest_save(null, '{"title":"تحدي الذكاء","intro":"ورّينا شطارتك","audience":"all","duration_minutes":30,"answer_seconds":60,"winners_count":1,"prize":"كوبون 50 ج","questions":[{"body":"عاصمة مصر؟","kind":"text","correct":"القاهره|القاهرة"},{"body":"2+2؟","kind":"choice","options":["3","4","5"],"correct":"4"}]}'::jsonb)$q$, null);
insert into public._ct select (public.contest_admin_list()->0->>'id')::uuid;
select public._expect('more than 3 questions are refused', $q$select public.contest_save(null, '{"title":"زيادة","questions":[{"body":"أ؟؟"},{"body":"ب؟؟"},{"body":"ج؟؟"},{"body":"د؟؟"}]}'::jsonb)$q$, 'INVALID_INPUT');
select public._expect('a choice answer must be one of the options', $q$select public.contest_save(null, '{"title":"غلط","questions":[{"body":"س؟؟؟","kind":"choice","options":["a","b"],"correct":"z"}]}'::jsonb)$q$, 'INVALID_INPUT');
reset role; select set_config('request.jwt.claim.sub', :'CASH', false); set role authenticated;
select public._expect('a draft contest is invisible to participants', $q$select 1/(case when jsonb_array_length(public.contest_active()) = 0 then 1 else 0 end)$q$, null);
select public._expect('seller cannot manage contests', $q$select public.contest_admin_list()$q$, 'FORBIDDEN');
reset role; select set_config('request.jwt.claim.sub', :'OWNER', false); set role authenticated;
select public._expect('owner publishes and notifies', $q$select 1/(case when public.contest_publish((select id from public._ct)) >= 1 then 1 else 0 end)$q$, null);
reset role;
select public._expect('the notification reached the team', $q$select 1/(case when exists (select 1 from public.notifications where title_ar like '%تحدي الذكاء%' and user_id = '00000000-0000-0000-0000-0000000000a3') then 1 else 0 end)$q$, null);
select set_config('request.jwt.claim.sub', :'OWNER', false); set role authenticated;
reset role; select set_config('request.jwt.claim.sub', :'CASH', false); set role authenticated;
select public._expect('team member sees the running contest', $q$select 1/(case when jsonb_array_length(public.contest_active()) = 1 then 1 else 0 end)$q$, null);
select public._expect('open returns questions without the right answers', $q$select 1/(case when jsonb_array_length(public.contest_open((select id from public._ct))->'questions') = 2
  and not (public.contest_open((select id from public._ct))::text like '%القاهره%') then 1 else 0 end)$q$, null);
select public._expect('answers are graded (Arabic spelling forgiven)', $q$select 1/(case when (public.contest_submit((select id from public._ct),
  (select jsonb_object_agg(q->>'id', case (q->>'position')::int when 1 then ' القاهرة ' else '4' end) from jsonb_array_elements(public.contest_open((select id from public._ct))->'questions') q))->>'correct_count')::int = 2 then 1 else 0 end)$q$, null);
select public._expect('a second submission is refused', $q$select public.contest_submit((select id from public._ct), '{}'::jsonb)$q$, 'ALREADY_SUBMITTED');
reset role; select set_config('request.jwt.claim.sub', :'TECH', false); set role authenticated;
select public._expect('a wrong answer scores less', $q$select public.contest_open((select id from public._ct))$q$, null);
select public._expect('wrong answers score zero', $q$select 1/(case when (public.contest_submit((select id from public._ct), '{}'::jsonb)->>'correct_count')::int = 0 then 1 else 0 end)$q$, null);
reset role; select set_config('request.jwt.claim.sub', :'OWNER', false); set role authenticated;
select public._expect('the owner sees both entries, best first', $q$select 1/(case when jsonb_array_length(public.contest_results((select id from public._ct))) = 2
  and (public.contest_results((select id from public._ct))->0->>'correct_count')::int = 2 then 1 else 0 end)$q$, null);
select public._expect('questions are locked once someone entered', $q$select public.contest_save((select id from public._ct), '{"title":"تعديل","questions":[{"body":"سؤال جديد؟؟"}]}'::jsonb)$q$, 'HAS_ENTRIES');
select public._expect('owner announces the winner', $q$select 1/(case when public.contest_announce((select id from public._ct)) = 1 then 1 else 0 end)$q$, null);
select public._expect('the winner is the best entry', $q$select 1/(case when (public.contest_results((select id from public._ct))->0->>'is_winner')::boolean then 1 else 0 end)$q$, null);
reset role; select set_config('request.jwt.claim.sub', :'CASH', false); set role authenticated;
select public._expect('after closing it is no longer offered', $q$select 1/(case when jsonb_array_length(public.contest_active()) = 0 then 1 else 0 end)$q$, null);
reset role; select set_config('request.jwt.claim.sub', :'OWNER', false); set role authenticated;
select public._expect('the owner sees the winner with purchases info', $q$select 1/(case when jsonb_array_length(public.contest_winners((select id from public._ct))) = 1 and (public.contest_winners((select id from public._ct))->0) ? 'shop_total_minor' then 1 else 0 end)$q$, null);
select public._expect('winner gets a pickup message', $q$select public.contest_message_winner((public.contest_winners((select id from public._ct))->0->>'entry_id')::uuid, 'pickup', 'بعد الظهر')$q$, null);
select public._expect('a custom message needs text', $q$select public.contest_message_winner((public.contest_winners((select id from public._ct))->0->>'entry_id')::uuid, 'custom', null)$q$, 'INVALID_INPUT');
select public._expect('a non-winner cannot be messaged', $q$select public.contest_message_winner(gen_random_uuid(), 'pickup')$q$, 'NOT_FOUND');
select public._expect('switching off needs the confirmation', $q$select public.feature_set('points', false)$q$, 'CONFIRM_REQUIRED');
reset role; select set_config('request.jwt.claim.sub', :'CASH', false); set role authenticated;
select public._expect('a cashier cannot switch features', $q$select public.feature_set('points', false, true)$q$, 'FORBIDDEN');
reset role; select set_config('request.jwt.claim.sub', :'OWNER', false); set role authenticated;
select public._expect('owner switches points off', $q$select public.feature_set('points', false, true)$q$, null);
select public._expect('the team still sees points', $q$select 1/(case when (public.feature_flags()->>'points')::boolean then 1 else 0 end)$q$, null);
reset role; select set_config('request.jwt.claim.sub', :'A', false); set role authenticated;
select public._expect('customers no longer see points', $q$select 1/(case when not (public.feature_flags()->>'points')::boolean then 1 else 0 end)$q$, null);
select public._expect('customers cannot open the points screen', $q$select public.loyalty_dashboard()$q$, 'FEATURE_OFF');
select public._expect('customers cannot claim missions', $q$select public.loyalty_claim('checkin_daily')$q$, 'FEATURE_OFF');
select public._expect('customers cannot open the vault', $q$select public.loyalty_open_vault()$q$, 'FEATURE_OFF');
reset role; select set_config('request.jwt.claim.sub', :'OWNER', false); set role authenticated;
select public._expect('owner switches points back on', $q$select public.feature_set('points', true)$q$, null);
reset role; select set_config('request.jwt.claim.sub', :'A', false); set role authenticated;
select public._expect('customers see points again', $q$select 1/(case when (public.feature_flags()->>'points')::boolean then 1 else 0 end)$q$, null);

-- ---- lucky wheel ----
reset role;
\set CUST1 '00000000-0000-0000-0000-0000000000c1'
\set CUST2 '00000000-0000-0000-0000-0000000000c2'
insert into auth.users (id, email) values (:'CUST1', 'c1@t'), (:'CUST2', 'c2@t') on conflict do nothing;
insert into public.profiles (id, full_name) values (:'CUST1', 'c1'), (:'CUST2', 'c2') on conflict do nothing;
select set_config('request.jwt.claim.sub', :'CUST1', false); set role authenticated;
select public._expect('the wheel is hidden while switched off', $q$select public.wheel_state()$q$, 'FEATURE_OFF');
reset role; select set_config('request.jwt.claim.sub', :'OWNER', false); set role authenticated;
select public._expect('owner turns the wheel on', $q$select public.feature_set('wheel', true)$q$, null);
select public._expect('owner saves 3 points slices', $q$select public.wheel_admin_save('{"ease":50,"spins_per_day":1,"require_order":false,"segments":[
  {"label_ar":"٥٠ نقطة","kind":"points","points":50,"weight":10},{"label_ar":"٥٠ نقطة","kind":"points","points":50,"weight":10},{"label_ar":"٥٠ نقطة","kind":"points","points":50,"weight":10}]}'::jsonb)$q$, null);
select public._expect('a wheel needs at least 3 slices', $q$select public.wheel_admin_save('{"segments":[{"label_ar":"أ","kind":"lose","weight":1}]}'::jsonb)$q$, 'INVALID_INPUT');
select public._expect('the team spin is only a preview', $q$select 1/(case when (public.wheel_spin()->>'preview')::boolean then 1 else 0 end)$q$, null);
reset role; update public.profiles set email_verified = false, phone_verified = false where id in ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000c2');
select set_config('request.jwt.claim.sub', :'CUST1', false); set role authenticated;
select public._expect('an unverified account cannot spin', $q$select public.wheel_spin()$q$, 'NOT_VERIFIED');
reset role; update public.profiles set email_verified = true where id in ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000c2');
update public.customers set review_status = 'approved' where user_id in ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000c2');
select set_config('request.jwt.claim.sub', :'CUST1', false); set role authenticated;
select public._expect('a verified customer spins and wins points', $q$select 1/(case when (public.wheel_spin()->>'points')::int > 0 then 1 else 0 end)$q$, null);
select public._expect('only one spin a day', $q$select public.wheel_spin()$q$, 'NO_SPINS_LEFT');
select public._expect('the customer sees no weights', $q$select 1/(case when not (public.wheel_state()::text like '%weight%') and jsonb_array_length(public.wheel_state()->'segments') = 3 then 1 else 0 end)$q$, null);
reset role;
select public._expect('the points were really paid', $q$select 1/(case when exists (select 1 from public.loyalty_ledger where user_id = '00000000-0000-0000-0000-0000000000c1' and kind = 'wheel' and points > 0) then 1 else 0 end)$q$, null);
select set_config('request.jwt.claim.sub', :'OWNER', false); set role authenticated;
select public._expect('owner saves a one-gift wheel', $q$select public.wheel_admin_save('{"ease":50,"spins_per_day":1,"segments":[
  {"label_ar":"سماعة","kind":"gift","weight":10,"daily_limit":1},{"label_ar":"حظ","kind":"lose","weight":0},{"label_ar":"حظ","kind":"lose","weight":0}]}'::jsonb)$q$, null);
reset role; select set_config('request.jwt.claim.sub', :'CUST2', false); set role authenticated;
select public._expect('first customer gets the gift', $q$select 1/(case when public.wheel_spin()->>'kind' = 'gift' then 1 else 0 end)$q$, null);
reset role; select set_config('request.jwt.claim.sub', :'OWNER', false); set role authenticated;
select public._expect('the gift is waiting to be handed over', $q$select 1/(case when jsonb_array_length(public.wheel_gifts_list('pending')) = 1 then 1 else 0 end)$q$, null);
select public._expect('owner marks the gift delivered', $q$select public.wheel_gift_set_status((public.wheel_gifts_list('pending')->0->>'id')::uuid, 'delivered')$q$, null);
select public._expect('owner switches the wheel off', $q$select public.feature_set('wheel', false, true)$q$, null);
reset role; select set_config('request.jwt.claim.sub', :'CUST1', false); set role authenticated;
select public._expect('customers cannot spin while it is off', $q$select public.wheel_spin()$q$, 'FEATURE_OFF');
reset role; select set_config('request.jwt.claim.sub', :'CASH', false); set role authenticated;
select public._expect('a cashier cannot edit the wheel', $q$select public.wheel_admin_get()$q$, 'FORBIDDEN');

-- ---- branch stock and transfers ----
reset role; select set_config('request.jwt.claim.sub', :'OWNER', false); set role authenticated;
select public._expect('owner gives branch A 3 pieces', $q$select public.stock_allocate('b0000000-0000-0000-0000-00000000000a', 'd0000000-0000-0000-0000-000000000003', 3)$q$, null);
select public._expect('only the unallocated pieces can be given', $q$select public.stock_allocate('b0000000-0000-0000-0000-00000000000b', 'd0000000-0000-0000-0000-000000000003', 3)$q$, 'NOT_ENOUGH_UNALLOCATED');
select public._expect('owner gives branch B the other 2', $q$select public.stock_allocate('b0000000-0000-0000-0000-00000000000b', 'd0000000-0000-0000-0000-000000000003', 2)$q$, null);
reset role; select set_config('request.jwt.claim.sub', :'MGR', false); set role authenticated;
select public._expect('a manager cannot allocate', $q$select public.stock_allocate('b0000000-0000-0000-0000-00000000000a', 'd0000000-0000-0000-0000-000000000003', 1)$q$, 'FORBIDDEN');
select public._expect('cannot send more than the branch holds', $q$select public.stock_transfer_create('b0000000-0000-0000-0000-00000000000a', 'b0000000-0000-0000-0000-00000000000b', '[{"product_id":"d0000000-0000-0000-0000-000000000003","qty":4}]'::jsonb)$q$, 'INSUFFICIENT_STOCK:موبايل');
select public._expect('cannot send from another branch', $q$select public.stock_transfer_create('b0000000-0000-0000-0000-00000000000b', 'b0000000-0000-0000-0000-00000000000a', '[{"product_id":"d0000000-0000-0000-0000-000000000003","qty":1}]'::jsonb)$q$, 'FORBIDDEN');
select public.stock_transfer_create('b0000000-0000-0000-0000-00000000000a', 'b0000000-0000-0000-0000-00000000000b', '[{"product_id":"d0000000-0000-0000-0000-000000000003","qty":2}]'::jsonb, 'تحويل تجريبي') as tr1 \gset
select public._expect('the sender cannot receive his own transfer', format($q$select public.stock_transfer_receive(%L, '[]'::jsonb)$q$, :'tr1'), 'FORBIDDEN');
reset role;
select public._expect('the other branch was notified', $q$select 1/(case when exists (select 1 from public.notifications where user_id = '00000000-0000-0000-0000-0000000000a6' and title_ar like '%تحويل جديد%') then 1 else 0 end)$q$, null);
reset role; select set_config('request.jwt.claim.sub', :'MGRB', false); set role authenticated;
select public._expect('the receiver sees it with who sent it', $q$select 1/(case when (public.stock_transfers_list()->0->>'can_receive')::boolean and public.stock_transfers_list()->0->>'created_by_name' is not null and public.stock_transfers_list()->0->>'from_name' is not null then 1 else 0 end)$q$, null);
select public._expect('receiving less needs a reason', format($q$select public.stock_transfer_receive(%L, '[{"product_id":"d0000000-0000-0000-0000-000000000003","qty":1}]'::jsonb)$q$, :'tr1'), 'REASON_REQUIRED');
select public._expect('the other reason needs a text', format($q$select public.stock_transfer_receive(%L, '[{"product_id":"d0000000-0000-0000-0000-000000000003","qty":1}]'::jsonb, 'other', '')$q$, :'tr1'), 'REASON_REQUIRED');
select public._expect('receiving one of two is partial', format($q$select 1/(case when public.stock_transfer_receive(%L, '[{"product_id":"d0000000-0000-0000-0000-000000000003","qty":1}]'::jsonb, 'not_received') = 'partial' then 1 else 0 end)$q$, :'tr1'), null);
select public._expect('a decided transfer cannot be decided again', format($q$select public.stock_transfer_reject(%L, 'not_received')$q$, :'tr1'), 'ALREADY_DECIDED');
reset role;
select public._expect('branch A keeps 2 (1 never arrived)', $q$select 1/(case when (select quantity from public.branch_stock where branch_id = 'b0000000-0000-0000-0000-00000000000a' and product_id = 'd0000000-0000-0000-0000-000000000003') = 2 then 1 else 0 end)$q$, null);
select public._expect('branch B got the 1 that arrived', $q$select 1/(case when (select quantity from public.branch_stock where branch_id = 'b0000000-0000-0000-0000-00000000000b' and product_id = 'd0000000-0000-0000-0000-000000000003') = 3 then 1 else 0 end)$q$, null);
select public._expect('the sender was told', $q$select 1/(case when exists (select 1 from public.notifications where user_id = '00000000-0000-0000-0000-0000000000a2' and title_ar like '%اتستلم%') then 1 else 0 end)$q$, null);
reset role; select set_config('request.jwt.claim.sub', :'MGRB', false); set role authenticated;
select public.stock_transfer_create('b0000000-0000-0000-0000-00000000000b', 'b0000000-0000-0000-0000-00000000000a', '[{"product_id":"d0000000-0000-0000-0000-000000000003","qty":1}]'::jsonb) as tr2 \gset
reset role; select set_config('request.jwt.claim.sub', :'MGR', false); set role authenticated;
select public._expect('rejecting with another reason needs the reason', format($q$select public.stock_transfer_reject(%L, 'other')$q$, :'tr2'), 'REASON_REQUIRED');
select public._expect('rejecting returns the pieces', format($q$select public.stock_transfer_reject(%L, 'other', 'القطعة مكسورة')$q$, :'tr2'), null);
reset role;
select public._expect('branch B has its 3 back', $q$select 1/(case when (select quantity from public.branch_stock where branch_id = 'b0000000-0000-0000-0000-00000000000b' and product_id = 'd0000000-0000-0000-0000-000000000003') = 3 then 1 else 0 end)$q$, null);
reset role; select set_config('request.jwt.claim.sub', :'MGR', false); set role authenticated;
select public.stock_transfer_create('b0000000-0000-0000-0000-00000000000a', 'b0000000-0000-0000-0000-00000000000b', '[{"product_id":"d0000000-0000-0000-0000-000000000003","qty":1}]'::jsonb) as tr3 \gset
select public._expect('the sender cancels', format($q$select public.stock_transfer_cancel(%L)$q$, :'tr3'), null);
reset role;
select public._expect('cancel returned the piece', $q$select 1/(case when (select quantity from public.branch_stock where branch_id = 'b0000000-0000-0000-0000-00000000000a' and product_id = 'd0000000-0000-0000-0000-000000000003') = 2 then 1 else 0 end)$q$, null);
update public.products set stock_quantity = stock_quantity - 3 where id = 'd0000000-0000-0000-0000-000000000003';
select public._expect('a sale beyond the free stock takes from the biggest branch', $q$select 1/(case when (select coalesce(sum(quantity),0) from public.branch_stock where product_id = 'd0000000-0000-0000-0000-000000000003') = 2 and (select quantity from public.branch_stock where branch_id = 'b0000000-0000-0000-0000-00000000000b' and product_id = 'd0000000-0000-0000-0000-000000000003') = 0 then 1 else 0 end)$q$, null);

-- ---- warehouse view ----
reset role; select set_config('request.jwt.claim.sub', :'MGR', false); set role authenticated;
select public._expect('a branch member sees his branch only', $q$select 1/(case when jsonb_array_length(public.stock_product_where('d0000000-0000-0000-0000-000000000003')->'branches') = 1 and not (public.stock_product_where('d0000000-0000-0000-0000-000000000003')->>'can_see_others')::boolean and public.stock_product_where('d0000000-0000-0000-0000-000000000003')->'warehouse' = 'null'::jsonb then 1 else 0 end)$q$, null);
select public._expect('his list hides the store totals', $q$select 1/(case when (select bool_and(e->'total' = 'null'::jsonb) from jsonb_array_elements(public.stock_overview(null, 'موبايل')) e) then 1 else 0 end)$q$, null);
reset role; select set_config('request.jwt.claim.sub', :'OWNER', false); set role authenticated;
select public._expect('the owner sees the warehouse and every branch', $q$select 1/(case when (public.stock_product_where('d0000000-0000-0000-0000-000000000003')->>'can_see_others')::boolean and (public.stock_product_where('d0000000-0000-0000-0000-000000000003')->>'warehouse') is not null and jsonb_array_length(public.stock_product_where('d0000000-0000-0000-0000-000000000003')->'branches') >= 2 then 1 else 0 end)$q$, null);

-- ---- the wheel needs a purchase ----
reset role;
update public.wheel_settings set require_order = true;
update public.feature_switches set enabled = true where key = 'wheel';
select set_config('request.jwt.claim.sub', :'OWNER', false); set role authenticated;
select public._expect('owner keeps the buy-first rule', $q$select public.wheel_admin_save('{"ease":50,"spins_per_day":1,"require_order":true,"segments":[{"label_ar":"أ","kind":"points","points":5,"weight":10},{"label_ar":"ب","kind":"points","points":5,"weight":10},{"label_ar":"ج","kind":"points","points":5,"weight":10}]}'::jsonb)$q$, null);
reset role;
select set_config('request.jwt.claim.sub', :'CUST2', false); set role authenticated;
select public._expect('a customer with no purchase cannot spin', $q$select public.wheel_spin()$q$, 'NEEDS_ORDER');
select public._expect('the screen tells him to buy first', $q$select 1/(case when public.wheel_state()->>'block' = 'NEEDS_ORDER' then 1 else 0 end)$q$, null);
reset role;
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
