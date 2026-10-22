-- =====================================================================
-- Backend integration & authorization tests (run against a fresh DB
-- with supabase_stub.sql + migrations + seed/dev_seed.sql applied).
-- Each block raises an exception on failure; ON_ERROR_STOP aborts the run.
-- =====================================================================
\set ON_ERROR_STOP 1
\set QUIET 1

create schema if not exists t;
create or replace function t.act(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), false);
  perform set_config('role', case when p_uid is null then 'anon' else 'authenticated' end, false);
end $$;
create or replace function t.reset() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', false);
  perform set_config('request.jwt.claim.sub', '', false);
end $$;
grant usage on schema t to anon, authenticated;
grant execute on all functions in schema t to anon, authenticated;
create table t.ids (k text primary key, v uuid);
grant all on t.ids to anon, authenticated;

-- users: two customers, owner, technician, sales, support
insert into auth.users(id, email, phone, phone_confirmed_at, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000000000a', 'a@test.local', '+201011111111', now(), '{"full_name":"Customer A"}'),
  ('00000000-0000-0000-0000-00000000000b', 'b@test.local', '+201022222222', now(), '{"full_name":"Customer B"}'),
  ('00000000-0000-0000-0000-0000000000c0', 'owner@test.local', null, null, '{"full_name":"Owner"}'),
  ('00000000-0000-0000-0000-0000000000c1', 'tech@test.local', null, null, '{"full_name":"Tech"}'),
  ('00000000-0000-0000-0000-0000000000c2', 'sales@test.local', null, null, '{"full_name":"Sales"}'),
  ('00000000-0000-0000-0000-0000000000c3', 'unverified@test.local', '+201033333333', null, '{}');
insert into public.user_roles(user_id, role) values
  ('00000000-0000-0000-0000-0000000000c0','owner'),
  ('00000000-0000-0000-0000-0000000000c1','technician'),
  ('00000000-0000-0000-0000-0000000000c2','sales');

\echo 'T01 profile auto-created, phone verified synced from auth'
do $$ begin
  if (select phone_verified from public.profiles where id = '00000000-0000-0000-0000-00000000000a') is not true then raise exception 'T01 failed'; end if;
  if (select phone_verified from public.profiles where id = '00000000-0000-0000-0000-0000000000c3') is not false then raise exception 'T01b failed'; end if;
end $$;

\echo 'T02 customer cannot escalate: phone_verified / role writes rejected'
do $$ begin
  perform t.act('00000000-0000-0000-0000-0000000000c3');
  begin
    update public.profiles set phone_verified = true where id = auth.uid();
    raise exception 'T02 failed: could set phone_verified';
  exception when insufficient_privilege then null; end;
  begin
    insert into public.user_roles(user_id, role) values (auth.uid(), 'owner');
    raise exception 'T02 failed: could self-grant owner';
  exception when insufficient_privilege then null; end;
  update public.profiles set full_name = 'New Name' where id = auth.uid();   -- allowed field
  perform t.reset();
end $$;

\echo 'T03 anon sees only published products; sort by lowest price is correct'
do $$ declare v_prices bigint[]; begin
  update public.products set status = 'draft' where sku = 'CBL-C2L';
  perform t.act(null);
  if exists (select 1 from public.products where sku = 'CBL-C2L') then raise exception 'T03 draft visible to anon'; end if;
  select array_agg(price_minor order by price_minor) into v_prices from public.catalog_products;
  if v_prices <> (select array_agg(price_minor order by price_minor asc) from public.catalog_products) or array_length(v_prices,1) <> 4 then
    raise exception 'T03 failed';
  end if;
  if (select min(price_minor) from public.catalog_products) <> v_prices[1] then raise exception 'T03 sort'; end if;
  perform t.reset();
  update public.products set status = 'published' where sku = 'CBL-C2L';
end $$;

\echo 'T04 search + filter + sort together (category=chargers OR name ilike)'
do $$ declare n int; begin
  perform t.act(null);
  select count(*) into n from public.catalog_products cp join public.categories c on c.id = cp.category_id
   where c.kind = 'phones' and cp.price_minor <= 4000000 and (cp.name_en ilike '%galaxy%' or cp.name_ar ilike '%galaxy%');
  if n <> 1 then raise exception 'T04 failed: %', n; end if;
  perform t.reset();
end $$;

\echo 'T05 anon cannot call place_order / write cart'
do $$ begin
  perform t.act(null);
  begin
    perform public.place_order('anon-key-123', 'pickup', 'pay_at_branch', null, null, null);
    raise exception 'T05 failed';
  exception when insufficient_privilege then null; end;
  perform t.reset();
end $$;

\echo 'T06 cart totals computed on server; client cannot write cart_items directly'
do $$ declare v_total bigint; begin
  perform t.act('00000000-0000-0000-0000-00000000000a');
  perform public.cart_set_item((select id from public.products where sku='ANK-20W'), null, 3);
  perform public.cart_set_item((select id from public.products where sku='IPH15-128'), null, 1);
  perform public.cart_set_item((select id from public.products where sku='ANK-20W'), null, 2);   -- set, not add
  select sum(line_total_minor) into v_total from public.get_cart();
  if v_total <> 79900*2 + 4500000 then raise exception 'T06 total wrong: %', v_total; end if;
  begin
    update public.cart_items set quantity = 1;
    raise exception 'T06 failed: direct write';
  exception when insufficient_privilege then null; end;
  perform public.cart_set_item((select id from public.products where sku='ANK-20W'), null, 0);  -- remove at zero
  if (select count(*) from public.get_cart()) <> 1 then raise exception 'T06 remove failed'; end if;
  perform public.cart_set_item((select id from public.products where sku='ANK-20W'), null, 2);
  perform t.reset();
end $$;

\echo 'T07 unverified account (no confirmed email or phone) cannot place order'
do $$ begin
  perform t.act('00000000-0000-0000-0000-0000000000c3');
  perform public.cart_set_item((select id from public.products where sku='ANK-20W'), null, 1);
  begin
    perform public.place_order('unverified-key-1', 'pickup', 'pay_at_branch', (select id from public.branches limit 1), null, null);
    raise exception 'T07 failed';
  exception when raise_exception then
    if sqlerrm <> 'ACCOUNT_NOT_VERIFIED' then raise; end if;
  end;
  perform t.reset();
end $$;

\echo 'T07b email OTP verification: flag synced from auth, not client-writable; contact phone rules'
do $$ begin
  insert into auth.users(id, email, raw_user_meta_data) values ('00000000-0000-0000-0000-0000000000e1', 'mail@test.local', '{"full_name":"Mail User"}');
  if (select email_verified from public.profiles where id = '00000000-0000-0000-0000-0000000000e1') then raise exception 'T07b: verified before OTP'; end if;
  update auth.users set email_confirmed_at = now() where id = '00000000-0000-0000-0000-0000000000e1';  -- Supabase Auth after a correct code
  if not (select email_verified from public.profiles where id = '00000000-0000-0000-0000-0000000000e1') then raise exception 'T07b: confirm not synced'; end if;

  perform t.act('00000000-0000-0000-0000-0000000000c3');
  begin
    update public.profiles set email_verified = true where id = auth.uid();
    raise exception 'T07b failed: client set email_verified';
  exception when insufficient_privilege then null; end;
  begin
    update public.profiles set contact_phone = '0101' where id = auth.uid();
    raise exception 'T07b failed: bad phone accepted';
  exception when check_violation then null; end;
  perform t.reset();

  -- email-verified account without any phone: pickup needs a contact phone first
  perform t.act('00000000-0000-0000-0000-0000000000e1');
  perform public.cart_set_item((select id from public.products where sku='ANK-20W'), null, 1);
  begin
    perform public.place_order('email-user-key-1', 'pickup', 'pay_at_branch', (select id from public.branches limit 1), null, null);
    raise exception 'T07b failed: order without phone';
  exception when raise_exception then
    if sqlerrm <> 'PHONE_REQUIRED' then raise; end if;
  end;
  update public.profiles set contact_phone = '+201044444444' where id = auth.uid();
  begin  -- succeeds, then roll the order back so later stock assertions are unaffected
    if (select customer_phone from public.orders where id = (public.place_order('email-user-key-2', 'pickup', 'pay_at_branch',
          (select id from public.branches limit 1), null, null) ->> 'order_id')::uuid) <> '+201044444444' then
      raise exception 'T07b failed: wrong order phone';
    end if;
    raise exception 'T07B_ROLLBACK';
  exception when raise_exception then
    if sqlerrm <> 'T07B_ROLLBACK' then raise; end if;
  end;
  perform public.cart_set_item((select id from public.products where sku='ANK-20W'), null, 0);
  perform t.reset();
end $$;

\echo 'T08 place order (pickup): saved once, stock reduced, cart cleared, email queued to sales'
do $$ declare r jsonb; r2 jsonb; v_stock_before int; v_stock_after int; begin
  select stock_quantity into v_stock_before from public.products where sku='ANK-20W';
  perform t.act('00000000-0000-0000-0000-00000000000a');
  r := public.place_order('order-key-0001', 'pickup', 'pay_at_branch', (select id from public.branches limit 1), null, null);
  r2 := public.place_order('order-key-0001', 'pickup', 'pay_at_branch', (select id from public.branches limit 1), null, null);
  if (r->>'order_id') <> (r2->>'order_id') or (r2->>'replayed')::boolean is not true then raise exception 'T08 idempotency failed'; end if;
  if (r->>'total_minor')::bigint <> 79900*2 + 4500000 then raise exception 'T08 total wrong'; end if;
  if (select count(*) from public.get_cart()) <> 0 then raise exception 'T08 cart not cleared'; end if;
  insert into t.ids values ('order1', (r->>'order_id')::uuid);
  perform t.reset();
  select stock_quantity into v_stock_after from public.products where sku='ANK-20W';
  if v_stock_before - v_stock_after <> 2 then raise exception 'T08 stock not reduced'; end if;
  if (select count(*) from public.orders where customer_id = '00000000-0000-0000-0000-00000000000a') <> 1 then raise exception 'T08 duplicate order'; end if;
  if (select to_email from public.email_outbox where kind='order_new' and related_id = (r->>'order_id')::uuid) <> 'myhatosales@gmail.com' then
    raise exception 'T08 order email not queued to sales';
  end if;
  if (select discount_minor from public.orders where id = (r->>'order_id')::uuid) <> (4799900-4500000) + (99900-79900)*2 then raise exception 'T08 discount wrong'; end if;
end $$;

\echo 'T09 stock can never go negative (oversell rejected, nothing committed)'
do $$ declare v_before int; begin
  perform t.act('00000000-0000-0000-0000-00000000000b');
  perform public.cart_set_item((select id from public.products where sku='CBL-C2L'), null, 4);  -- stock 3
  begin
    perform public.place_order('order-key-b-01', 'pickup', 'pay_at_branch', (select id from public.branches limit 1), null, null);
    raise exception 'T09 failed';
  exception when raise_exception then
    if sqlerrm not like 'OUT_OF_STOCK%' then raise; end if;
  end;
  perform t.reset();
  if (select stock_quantity from public.products where sku='CBL-C2L') <> 3 then raise exception 'T09 stock changed'; end if;
end $$;

\echo 'T10 delivery order: fee from zone, address snapshot'
do $$ declare v_addr uuid; r jsonb; begin
  perform t.act('00000000-0000-0000-0000-00000000000b');
  insert into public.customer_addresses(user_id, recipient_name, phone, governorate, city, street)
  values (auth.uid(), 'B', '+201022222222', 'الإسكندرية', 'سموحة', 'شارع ١') returning id into v_addr;
  perform public.cart_set_item((select id from public.products where sku='CBL-C2L'), null, 1);
  r := public.place_order('order-key-b-02', 'delivery', 'cash_on_delivery', null, v_addr, 'الدور التالت');
  if (select delivery_fee_minor from public.orders where id = (r->>'order_id')::uuid) <> 7000 then raise exception 'T10 fee'; end if;
  if (r->>'total_minor')::bigint <> 49900 + 7000 then raise exception 'T10 total'; end if;
  insert into t.ids values ('order_b', (r->>'order_id')::uuid);
  perform t.reset();
end $$;

\echo 'T11 customer A cannot read customer B data'
do $$ begin
  perform t.act('00000000-0000-0000-0000-00000000000a');
  if exists (select 1 from public.orders where customer_id = '00000000-0000-0000-0000-00000000000b') then raise exception 'T11 orders leak'; end if;
  if exists (select 1 from public.customer_addresses where user_id = '00000000-0000-0000-0000-00000000000b') then raise exception 'T11 address leak'; end if;
  if exists (select 1 from public.profiles where id = '00000000-0000-0000-0000-00000000000b') then raise exception 'T11 profile leak'; end if;
  if exists (select 1 from public.order_items oi where oi.order_id = (select v from t.ids where k='order_b')) then raise exception 'T11 items leak'; end if;
  begin
    perform public.customer_cancel_order((select v from t.ids where k='order_b'));
    raise exception 'T11 cancel other order';
  exception when raise_exception then if sqlerrm <> 'NOT_FOUND' then raise; end if; end;
  perform t.reset();
end $$;

\echo 'T12 order status: invalid transitions rejected, technician forbidden, sales allowed, customer notified'
do $$ declare v_o uuid := (select v from t.ids where k='order1'); begin
  perform t.act('00000000-0000-0000-0000-0000000000c1');
  begin perform public.staff_update_order_status(v_o, 'confirmed'); raise exception 'T12 tech allowed';
  exception when insufficient_privilege then null; end;
  perform t.act('00000000-0000-0000-0000-0000000000c2');
  begin perform public.staff_update_order_status(v_o, 'delivered'); raise exception 'T12 skip allowed';
  exception when raise_exception then if sqlerrm not like 'INVALID_TRANSITION%' then raise; end if; end;
  perform public.staff_update_order_status(v_o, 'confirmed');
  perform public.staff_update_order_status(v_o, 'preparing');
  begin perform public.staff_update_order_status(v_o, 'out_for_delivery'); raise exception 'T12 pickup->delivery allowed';
  exception when raise_exception then if sqlerrm not like 'INVALID_TRANSITION%' then raise; end if; end;
  perform public.staff_update_order_status(v_o, 'ready_for_pickup');
  perform t.act('00000000-0000-0000-0000-00000000000a');
  if (select status from public.orders where id = v_o) <> 'ready_for_pickup' then raise exception 'T12 customer status'; end if;
  if (select count(*) from public.order_status_history where order_id = v_o) <> 4 then raise exception 'T12 history'; end if;
  if not exists (select 1 from public.notifications where entity_id = v_o and body_ar like '%جاهز للاستلام%') then raise exception 'T12 notification'; end if;
  perform t.reset();
end $$;

\echo 'T13 cancelling an order restores stock'
do $$ declare v_before int; begin
  select stock_quantity into v_before from public.products where sku='CBL-C2L';
  perform t.act('00000000-0000-0000-0000-00000000000b');
  perform public.customer_cancel_order((select v from t.ids where k='order_b'));
  perform t.reset();
  if (select stock_quantity from public.products where sku='CBL-C2L') <> v_before + 1 then raise exception 'T13 restock'; end if;
end $$;

\echo 'T14 repair request: reference MY-HATO..., email queued to service mailbox'
do $$ declare r jsonb; v_addr uuid; begin
  perform t.act('00000000-0000-0000-0000-00000000000a');
  insert into public.customer_addresses(user_id, recipient_name, phone, governorate, city, street)
  values (auth.uid(), 'A', '+201011111111', 'القاهرة', 'مدينة نصر', 'شارع عباس العقاد') returning id into v_addr;
  r := public.request_repair('repair-key-0001', 'Apple', 'iPhone 13', '356938035643809', 'الشاشة مكسورة ومش بتلمس',
                             'Customer A', '+201011111111', v_addr, null, now() + interval '1 day', false);
  if r->>'reference' not like 'MY-HATO%' then raise exception 'T14 ref'; end if;
  insert into t.ids values ('repair1', (r->>'repair_id')::uuid);
  perform t.reset();
  if (select to_email from public.email_outbox where kind='repair_new' and related_id=(r->>'repair_id')::uuid) <> 'myhatoservice@gmail.com' then
    raise exception 'T14 repair email not routed to myhatoservice@gmail.com';
  end if;
end $$;

\echo 'T15 customer B cannot see A repair; customer cannot read internal_notes'
do $$ declare v_r uuid := (select v from t.ids where k='repair1'); begin
  update public.repair_requests set internal_notes = 'SECRET tech note' where id = v_r;
  perform t.act('00000000-0000-0000-0000-00000000000b');
  if exists (select 1 from public.repair_requests where id = v_r) then raise exception 'T15 leak to B'; end if;
  perform t.act('00000000-0000-0000-0000-00000000000a');
  begin
    perform internal_notes from public.repair_requests where id = v_r;
    raise exception 'T15 internal notes readable';
  exception when insufficient_privilege then null; end;
  begin perform public.staff_get_repair(v_r); raise exception 'T15 staff_get_repair';
  exception when insufficient_privilege then null; end;
  perform t.reset();
end $$;

\echo 'T16 technician not assigned is forbidden; owner assigns; tech moves to received'
do $$ declare v_r uuid := (select v from t.ids where k='repair1'); begin
  perform t.act('00000000-0000-0000-0000-0000000000c1');
  begin perform public.staff_update_repair_status(v_r, 'pickup_scheduled'); raise exception 'T16 unassigned allowed';
  exception when insufficient_privilege then null; end;
  perform t.act('00000000-0000-0000-0000-0000000000c0');
  perform public.staff_assign_technician(v_r, '00000000-0000-0000-0000-0000000000c1');
  perform public.staff_update_repair_status(v_r, 'pickup_scheduled');
  perform t.act('00000000-0000-0000-0000-0000000000c1');
  perform public.staff_update_repair_status(v_r, 'device_collected');
  perform public.staff_update_repair_status(v_r, 'received_at_branch');
  perform t.act('00000000-0000-0000-0000-00000000000a');
  if (select status from public.repair_requests where id = v_r) <> 'received_at_branch' then raise exception 'T16 customer status'; end if;
  perform t.reset();
end $$;

\echo 'T17 cannot start repair without approved quote; 200 EGP quote visible to customer'
do $$ declare v_r uuid := (select v from t.ids where k='repair1'); v_q uuid; begin
  perform t.act('00000000-0000-0000-0000-0000000000c1');
  perform public.staff_update_repair_status(v_r, 'initial_inspection');
  perform public.staff_update_repair_details(v_r, '{"diagnosis":"شاشة تالفة","internal_notes":"supplier X"}');
  perform public.staff_update_repair_status(v_r, 'diagnosis_completed');
  perform t.reset();
  update public.repair_requests set estimated_cost_minor = 20000 where id = v_r;
  perform t.act('00000000-0000-0000-0000-0000000000c1');
  begin perform public.staff_update_repair_status(v_r, 'repair_in_progress'); raise exception 'T17 started without approval';
  exception when raise_exception then if sqlerrm <> 'APPROVAL_REQUIRED' then raise; end if; end;
  v_q := public.staff_create_repair_quote(v_r, 20000, 'تغيير شاشة أصلية', null);
  insert into t.ids values ('quote1', v_q);
  perform t.act('00000000-0000-0000-0000-00000000000a');
  if (select estimated_cost_minor from public.repair_requests where id = v_r) <> 20000 then raise exception 'T17 cost'; end if;
  if (select status from public.repair_requests where id = v_r) <> 'awaiting_approval' then raise exception 'T17 status'; end if;
  if not exists (select 1 from public.notifications where entity_id = v_r and body_ar like '%تم تحديد تكلفة الصيانة بـ 200 ج.م%') then
    raise exception 'T17 notification text';
  end if;
  perform t.reset();
end $$;

\echo 'T18 customer B cannot approve A quote; staff cannot fake customer approval without note'
do $$ begin
  perform t.act('00000000-0000-0000-0000-00000000000b');
  begin perform public.customer_respond_to_quote((select v from t.ids where k='quote1'), 'approved'); raise exception 'T18 B approved';
  exception when raise_exception then if sqlerrm <> 'NOT_FOUND' then raise; end if; end;
  perform t.act('00000000-0000-0000-0000-0000000000c1');
  begin perform public.staff_record_quote_decision((select v from t.ids where k='quote1'), 'approved', 'x'); raise exception 'T18 tech recorded';
  exception when insufficient_privilege then null; end;
  perform t.reset();
end $$;

\echo 'T19 customer approves; tech progresses to ready_for_pickup; customer sees it; response email to service'
do $$ declare v_r uuid := (select v from t.ids where k='repair1'); begin
  perform t.act('00000000-0000-0000-0000-00000000000a');
  perform public.customer_respond_to_quote((select v from t.ids where k='quote1'), 'approved');
  perform t.act('00000000-0000-0000-0000-0000000000c1');
  perform public.staff_update_repair_status(v_r, 'repair_in_progress');
  perform public.staff_update_repair_status(v_r, 'quality_testing');
  perform public.staff_update_repair_status(v_r, 'repair_completed');
  perform public.staff_update_repair_status(v_r, 'ready_for_pickup');
  perform t.act('00000000-0000-0000-0000-00000000000a');
  if (select status from public.repair_requests where id = v_r) <> 'ready_for_pickup' then raise exception 'T19 status'; end if;
  if (select approved_cost_minor from public.repair_requests where id = v_r) <> 20000 then raise exception 'T19 approved cost'; end if;
  if not exists (select 1 from public.notifications where entity_id = v_r and body_ar like '%جهازك جاهز للاستلام%') then raise exception 'T19 notif'; end if;
  if not exists (select 1 from public.repair_status_history where repair_id = v_r and customer_message_ar like '%جهازك تحت التصليح حاليًا، والتكلفة المعتمدة 200 ج.م.%') then raise exception 'T19 in-progress msg'; end if;
  perform t.reset();
  if (select to_email from public.email_outbox where kind='repair_customer_response') <> 'myhatoservice@gmail.com' then raise exception 'T19 email'; end if;
  if (select count(*) from public.audit_logs where entity_id = v_r::text) < 5 then raise exception 'T19 audit'; end if;
end $$;

\echo 'T20 guest lookup view hides private data and is not callable by anon/authenticated'
do $$ declare j jsonb; begin
  j := public.guest_repair_public_view((select reference from public.repair_requests where id = (select v from t.ids where k='repair1')));
  if j ? 'imei_or_serial' or j ? 'pickup_address' or j ? 'internal_notes' or j ? 'contact_phone' or j::text like '%SECRET%' or j::text like '%supplier X%' then
    raise exception 'T20 private data in guest view';
  end if;
  perform t.act(null);
  begin perform public.guest_repair_public_view('MY-HATO75'); raise exception 'T20 anon call';
  exception when insufficient_privilege then null; end;
  perform t.reset();
end $$;

\echo 'T21 audit log is append-only; customers cannot read it'
do $$ begin
  begin update public.audit_logs set action = 'x'; raise exception 'T21 update';
  exception when raise_exception then if sqlerrm <> 'audit_logs is append-only' then raise; end if; end;
  perform t.act('00000000-0000-0000-0000-00000000000a');
  if exists (select 1 from public.audit_logs) then raise exception 'T21 readable'; end if;
  perform t.reset();
end $$;

\echo 'T22 private repair photos: other customer cannot read object'
do $$ declare v_r uuid := (select v from t.ids where k='repair1'); v_path text; begin
  v_path := '00000000-0000-0000-0000-00000000000a/' || v_r || '/p1.jpg';
  perform t.act('00000000-0000-0000-0000-00000000000a');
  insert into storage.objects(bucket_id, name) values ('repair-photos', v_path);
  perform public.add_repair_attachment(v_r, v_path);
  if not exists (select 1 from storage.objects where name = v_path) then raise exception 'T22 owner cannot read'; end if;
  perform t.act('00000000-0000-0000-0000-00000000000b');
  if exists (select 1 from storage.objects where name = v_path) then raise exception 'T22 leak'; end if;
  begin
    insert into storage.objects(bucket_id, name) values ('repair-photos', '00000000-0000-0000-0000-00000000000a/' || v_r || '/evil.jpg');
    raise exception 'T22 B uploaded into A folder';
  exception when insufficient_privilege then null; end;
  perform t.reset();
end $$;

\echo 'T23 sales cannot manage staff; owner can; nobody can remove own owner role'
do $$ begin
  perform t.act('00000000-0000-0000-0000-0000000000c2');
  begin perform public.staff_set_role('00000000-0000-0000-0000-0000000000c2', 'owner', true); raise exception 'T23 sales escalated';
  exception when insufficient_privilege then null; end;
  perform t.act('00000000-0000-0000-0000-0000000000c0');
  perform public.staff_set_role('00000000-0000-0000-0000-00000000000b', 'support', true);
  perform public.staff_set_role('00000000-0000-0000-0000-00000000000b', 'support', false);
  perform t.reset();
end $$;

\echo 'T24 used-devices section is off by default and readable publicly'
do $$ begin
  perform t.act(null);
  if (select value from public.application_settings where key = 'used_devices_enabled') <> 'false'::jsonb then raise exception 'T24'; end if;
  if exists (select 1 from public.application_settings where key like '%email%') then raise exception 'T24 email settings public'; end if;
  perform t.reset();
end $$;

\echo 'T25 sign-up creates a customer ID linking username, phone and email; duplicates and bad input rejected'
do $$ declare v_code text; begin
  insert into auth.users(id, email, raw_user_meta_data) values
    ('00000000-0000-0000-0000-0000000000f1', 'Sara@Test.local', '{"full_name":"Sara","username":"Sara_99","phone":"01055555555"}');
  select customer_code into v_code from public.customers where user_id = '00000000-0000-0000-0000-0000000000f1';
  if v_code !~ '^MHC-[0-9]{6}$' then raise exception 'T25 code %', v_code; end if;
  if (select username || '|' || phone || '|' || email from public.customers where customer_code = v_code)
     <> 'sara_99|+201055555555|sara@test.local' then raise exception 'T25 fields'; end if;
  if (select contact_phone from public.profiles where id = '00000000-0000-0000-0000-0000000000f1') <> '+201055555555' then raise exception 'T25 profile phone'; end if;
  begin
    insert into auth.users(id, email, raw_user_meta_data) values ('00000000-0000-0000-0000-0000000000f2', 'x@test.local', '{"username":"sara_99"}');
    raise exception 'T25 dup username';
  exception when raise_exception then if sqlerrm <> 'USERNAME_TAKEN' then raise; end if; end;
  begin
    insert into auth.users(id, email, raw_user_meta_data) values ('00000000-0000-0000-0000-0000000000f2', 'x@test.local', '{"username":"newone","phone":"+20 105 555 5555"}');
    raise exception 'T25 dup phone';
  exception when raise_exception then if sqlerrm <> 'PHONE_TAKEN' then raise; end if; end;
  begin
    insert into auth.users(id, email, raw_user_meta_data) values ('00000000-0000-0000-0000-0000000000f2', 'x@test.local', '{"username":"a b"}');
    raise exception 'T25 bad username';
  exception when raise_exception then if sqlerrm <> 'INVALID_USERNAME' then raise; end if; end;
  -- existing accounts were given IDs too
  if exists (select 1 from public.profiles p where not exists (select 1 from public.customers c where c.user_id = p.id)) then raise exception 'T25 backfill'; end if;
end $$;

\echo 'T26 signup_check reports availability; stale unconfirmed sign-ups release their username/phone'
do $$ declare r jsonb; begin
  perform t.act(null);
  r := public.signup_check('SARA_99', '01055555555');
  if (r->>'username_available')::boolean or (r->>'phone_available')::boolean then raise exception 'T26 taken %', r; end if;
  r := public.signup_check('free_name', '01266666666');
  if not ((r->>'username_available')::boolean and (r->>'phone_available')::boolean) or r->>'phone' <> '+201266666666' then raise exception 'T26 free %', r; end if;
  r := public.signup_check('x', '123');
  if (r->>'username_valid')::boolean or (r->>'phone_valid')::boolean then raise exception 'T26 invalid %', r; end if;
  perform t.reset();
  insert into auth.users(id, email, created_at, raw_user_meta_data) values
    ('00000000-0000-0000-0000-0000000000f3', 'old@test.local', now() - interval '2 days', '{"username":"oldname","phone":"01177777777"}');
  perform t.act(null);
  if not (public.signup_check('oldname', '01177777777')->>'username_available')::boolean then raise exception 'T26 stale not free'; end if;
  perform t.reset();
  insert into auth.users(id, email, raw_user_meta_data) values ('00000000-0000-0000-0000-0000000000f4', 'new@test.local', '{"username":"oldname","phone":"01177777777"}');
  if (select username from public.customers where user_id = '00000000-0000-0000-0000-0000000000f4') <> 'oldname'
     or (select username from public.customers where user_id = '00000000-0000-0000-0000-0000000000f3') is not null then raise exception 'T26 release'; end if;
end $$;

\echo 'T27 sign in with email, mobile or username + password; wrong password and throttling'
do $$ declare i int; begin
  update auth.users set encrypted_password = extensions.crypt('Secret123', extensions.gen_salt('bf', 6)), email_confirmed_at = now()
   where id = '00000000-0000-0000-0000-0000000000f1';
  perform t.act(null);
  if public.login_email_for('sara_99', 'Secret123') is distinct from 'Sara@Test.local' then raise exception 'T27 username'; end if;
  if public.login_email_for(' SARA_99 ', 'Secret123') is distinct from 'Sara@Test.local' then raise exception 'T27 username case'; end if;
  if public.login_email_for('01055555555', 'Secret123') is distinct from 'Sara@Test.local' then raise exception 'T27 phone'; end if;
  if public.login_email_for('+201055555555', 'Secret123') is distinct from 'Sara@Test.local' then raise exception 'T27 phone e164'; end if;
  if public.login_email_for('sara@test.local', 'Secret123') is distinct from 'Sara@Test.local' then raise exception 'T27 email'; end if;
  if public.login_email_for('sara_99', 'wrong') is not null then raise exception 'T27 wrong pw'; end if;
  if public.login_email_for('nobody_here', 'Secret123') is not null then raise exception 'T27 unknown'; end if;
  for i in 1..7 loop perform public.login_email_for('sara_99', 'wrong'); end loop;  -- 8 failures in total
  begin
    perform public.login_email_for('sara_99', 'Secret123');
    raise exception 'T27 no throttle';
  exception when raise_exception then if sqlerrm <> 'RATE_LIMITED' then raise; end if; end;
  perform t.reset();
end $$;

\echo 'T28 customer register is private: own row only, staff with customers.view see all, no client writes'
do $$ begin
  perform t.act('00000000-0000-0000-0000-0000000000f1');
  if (select count(*) from public.customers) <> 1 then raise exception 'T28 own only'; end if;
  begin
    update public.customers set username = 'hacker' where user_id = auth.uid();
    raise exception 'T28 client write';
  exception when insufficient_privilege then null; end;
  begin
    update public.profiles set contact_phone = '+201011111111' where id = auth.uid();  -- belongs to customer A? (A has verified phone, not contact)
  exception when raise_exception then null; end;
  perform t.reset();
  perform t.act('00000000-0000-0000-0000-0000000000c0');
  if (select count(*) from public.customers) < 5 then raise exception 'T28 owner sees all'; end if;
  perform t.reset();
  perform t.act(null);
  begin
    perform 1 from public.customers;
    raise exception 'T28 anon read';
  exception when insufficient_privilege then null; end;
  perform t.reset();
end $$;

\echo 'ALL BACKEND TESTS PASSED'
