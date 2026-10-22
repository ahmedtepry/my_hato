\set ON_ERROR_STOP 1
-- Runs after integration_test.sql (reuses users/branch/products and the t.* helpers)

\echo 'P01 online payment cannot be used before the provider is configured'
do $$ begin
  perform t.act('00000000-0000-0000-0000-0000000000c0');
  begin perform public.staff_set_online_payments(true); raise exception 'P01 enabled without config';
  exception when raise_exception then if sqlerrm <> 'PAYMENTS_NOT_CONFIGURED' then raise; end if; end;
  perform t.act('00000000-0000-0000-0000-00000000000a');
  perform public.cart_set_item((select id from public.products where sku='ANK-20W'), null, 1);
  begin
    perform public.place_order('online-key-001', 'pickup', 'online', (select id from public.branches limit 1), null, null);
    raise exception 'P01 online order accepted while disabled';
  exception when raise_exception then if sqlerrm <> 'PAYMENT_METHOD_DISABLED' then raise; end if; end;
  perform t.reset();
end $$;

\echo 'P02 customers/staff without settings.manage cannot read merchant settings or set is_configured'
do $$ begin
  perform t.act('00000000-0000-0000-0000-00000000000a');
  if exists (select 1 from public.payment_settings) then raise exception 'P02 customer reads settings'; end if;
  perform t.act('00000000-0000-0000-0000-0000000000c2');  -- sales
  if exists (select 1 from public.payment_settings) then raise exception 'P02 sales reads settings'; end if;
  perform t.act('00000000-0000-0000-0000-0000000000c0');  -- owner
  update public.payment_settings set merchant_iban = 'AE070331234567890123456', account_holder_name = 'My Hato' where id = 1;
  begin update public.payment_settings set is_configured = true where id = 1; raise exception 'P02 owner set is_configured directly';
  exception when insufficient_privilege then null; end;
  perform t.reset();
end $$;

\echo 'P03 provider verified -> enable online -> order + payment prepared with server amount'
do $$ declare r jsonb; p jsonb; p2 jsonb; begin
  perform public.payment_record_provider_check(true, 'paymob_profile_1', '{"api_key_valid":true}');
  perform t.act('00000000-0000-0000-0000-0000000000c0');
  perform public.staff_set_online_payments(true);
  perform t.reset();
  if not (public.setting('enabled_payment_methods') ? 'online') then raise exception 'P03 online not in enabled methods'; end if;
  perform t.act('00000000-0000-0000-0000-00000000000a');
  r := public.place_order('online-key-002', 'pickup', 'online', (select id from public.branches limit 1), null, null);
  insert into t.ids values ('online_order', (r->>'order_id')::uuid);
  begin perform public.payment_prepare(auth.uid(), (r->>'order_id')::uuid, true); raise exception 'P03 client prepare';
  exception when insufficient_privilege then null; end;
  begin update public.orders set payment_status = 'paid' where id = (r->>'order_id')::uuid; raise exception 'P03 client paid';
  exception when insufficient_privilege then null; end;
  perform t.reset();
  p := public.payment_prepare('00000000-0000-0000-0000-00000000000a', (r->>'order_id')::uuid, true);
  if (p->>'amount_minor')::bigint <> (r->>'total_minor')::bigint then raise exception 'P03 amount'; end if;
  perform public.payment_attach_intent((p->>'payment_id')::uuid, 'pi_intent_1', '900001', 'egy_csk_secret', now() + interval '1 hour');
  -- second prepare within validity reuses the same checkout (no second charge possible)
  p2 := public.payment_prepare('00000000-0000-0000-0000-00000000000a', (r->>'order_id')::uuid, true);
  if p2->>'payment_id' <> p->>'payment_id' or p2->>'reuse_client_secret' <> 'egy_csk_secret' then raise exception 'P03 not reused: %', p2; end if;
  begin perform public.payment_prepare('00000000-0000-0000-0000-00000000000b', (r->>'order_id')::uuid, false); raise exception 'P03 B prepare';
  exception when raise_exception then if sqlerrm <> 'NOT_FOUND' then raise; end if; end;
  -- customer can read own payment but NOT the checkout client secret column; staff neither
  perform t.act('00000000-0000-0000-0000-00000000000a');
  if not exists (select 1 from public.payments where id = (p->>'payment_id')::uuid) then raise exception 'P03 own payment hidden'; end if;
  begin perform checkout_client_secret from public.payments limit 1; raise exception 'P03 secret readable';
  exception when insufficient_privilege then null; end;
  perform t.reset();
end $$;

\echo 'P04 Paymob callbacks: amount mismatch rejected; success once; duplicate + stale ignored; card token saved only on opt-in'
do $$ declare j jsonb; v_o uuid := (select v from t.ids where k='online_order'); v_amt bigint; begin
  select total_minor into v_amt from public.orders where id = v_o;
  j := public.paymob_apply_transaction('txn_1:a', '900001', '111', true, false, false, false, v_amt - 1, 'EGP', 'card', 'Visa', 'xxxx4242', null);
  if j->>'result' <> 'amount_mismatch' then raise exception 'P04 mismatch: %', j; end if;
  if (select payment_status from public.orders where id = v_o) = 'paid' then raise exception 'P04 paid on mismatch'; end if;
  j := public.paymob_apply_transaction('txn_1:ok', '900001', '111', true, false, false, false, v_amt, 'EGP', 'card', 'Visa', 'xxxx4242', null);
  if j->>'status' <> 'succeeded' then raise exception 'P04 success: %', j; end if;
  if (select payment_status from public.orders where id = v_o) <> 'paid' then raise exception 'P04 order not paid'; end if;
  if (select provider_transaction_id || card_last4 from public.payments where provider_order_id = '900001') <> '1114242' then raise exception 'P04 txn/last4'; end if;
  j := public.paymob_apply_transaction('txn_1:ok', '900001', '111', true, false, false, false, v_amt, 'EGP', 'card', 'Visa', 'xxxx4242', null);
  if j->>'result' <> 'duplicate' then raise exception 'P04 duplicate'; end if;
  j := public.paymob_apply_transaction('txn_2:fail', '900001', '112', false, false, false, false, v_amt, 'EGP', 'card', null, null, 'declined');
  if j->>'result' <> 'ignored_stale' then raise exception 'P04 stale'; end if;
  if (select count(*) from public.notifications where entity_id = v_o and title_ar = 'تم الدفع بنجاح') <> 1 then raise exception 'P04 notif count'; end if;
  j := public.paymob_apply_card_token('900001', 'tok_card_1', 'xxxx-xxxx-xxxx-4242', 'Visa', 12, 2030);
  if j->>'result' <> 'saved' then raise exception 'P04 token: %', j; end if;
end $$;

\echo 'P05 paid online order cannot be self-cancelled; B cannot see A payment'
do $$ declare v_o uuid := (select v from t.ids where k='online_order'); begin
  perform t.act('00000000-0000-0000-0000-00000000000a');
  begin perform public.customer_cancel_order(v_o); raise exception 'P05 cancelled paid';
  exception when raise_exception then if sqlerrm <> 'CANNOT_CANCEL_PAID' then raise; end if; end;
  perform t.act('00000000-0000-0000-0000-00000000000b');
  if exists (select 1 from public.payments where order_id = v_o) then raise exception 'P05 leak'; end if;
  perform t.reset();
end $$;

\echo 'P06 saved cards: owner-only visibility, client cannot insert, token without opt-in is NOT saved, removal'
do $$ declare v_id uuid; v_pm text; r jsonb; p jsonb; begin
  perform t.act('00000000-0000-0000-0000-00000000000a');
  select id into v_id from public.payment_methods where provider_payment_method_id = 'tok_card_1';
  if v_id is null then raise exception 'P06 not visible to owner'; end if;
  begin insert into public.payment_methods(user_id, provider_payment_method_id) values (auth.uid(), 'tok_fake'); raise exception 'P06 client insert';
  exception when insufficient_privilege then null; end;
  -- second order without opt-in
  perform public.cart_set_item((select id from public.products where sku='ANK-20W'), null, 1);
  r := public.place_order('online-key-003', 'pickup', 'online', (select id from public.branches limit 1), null, null);
  perform t.act('00000000-0000-0000-0000-00000000000b');
  if exists (select 1 from public.payment_methods) then raise exception 'P06 leak'; end if;
  perform t.reset();
  p := public.payment_prepare('00000000-0000-0000-0000-00000000000a', (r->>'order_id')::uuid, false);
  if jsonb_array_length(p->'card_tokens') <> 1 then raise exception 'P06 saved token not offered at checkout'; end if;
  perform public.payment_attach_intent((p->>'payment_id')::uuid, 'pi_intent_2', '900002', 'egy_csk_2', now() + interval '1 hour');
  if public.paymob_apply_card_token('900002', 'tok_card_2', 'xxxx-1111', 'MasterCard', 1, 2031)->>'result' <> 'not_requested' then raise exception 'P06 saved without opt-in'; end if;
  begin perform public.payment_remove_method('00000000-0000-0000-0000-00000000000b', v_id); raise exception 'P06 B removed A card';
  exception when raise_exception then if sqlerrm <> 'NOT_FOUND' then raise; end if; end;
  v_pm := public.payment_remove_method('00000000-0000-0000-0000-00000000000a', v_id);
  if v_pm <> 'tok_card_1' or exists (select 1 from public.payment_methods where id = v_id) then raise exception 'P06 remove'; end if;
end $$;

\echo 'P07 refunds: disabled by default, permission + cap, partial then full via refund callbacks'
do $$ declare v_pay uuid; v_amt bigint; j jsonb; begin
  select id, amount_minor into v_pay, v_amt from public.payments where provider_order_id = '900001';
  perform t.act('00000000-0000-0000-0000-0000000000c2');
  begin perform public.staff_refund_check(v_pay, 100); raise exception 'P07 refunds enabled by default';
  exception when raise_exception then if sqlerrm <> 'REFUNDS_DISABLED' then raise; end if; end;
  perform t.act('00000000-0000-0000-0000-0000000000c0');
  update public.payment_settings set refunds_enabled = true where id = 1;
  perform t.act('00000000-0000-0000-0000-0000000000c1');
  begin perform public.staff_refund_check(v_pay, 100); raise exception 'P07 tech refund';
  exception when insufficient_privilege then null; end;
  perform t.act('00000000-0000-0000-0000-0000000000c2');
  begin perform public.staff_refund_check(v_pay, v_amt + 1); raise exception 'P07 over-refund';
  exception when raise_exception then if sqlerrm <> 'INVALID_AMOUNT' then raise; end if; end;
  if (public.staff_refund_check(v_pay, 1000)->>'provider_transaction_id') <> '111' then raise exception 'P07 txn id'; end if;
  perform t.reset();
  j := public.paymob_apply_transaction('txn_r1:ok', '900001', '201', true, false, false, true, 1000, 'EGP', null, null, null, null);
  if j->>'status' <> 'partially_refunded' then raise exception 'P07 partial: %', j; end if;
  j := public.paymob_apply_transaction('txn_r2:ok', '900001', '202', true, false, false, true, v_amt - 1000, 'EGP', null, null, null, null);
  if j->>'status' <> 'refunded' or (select payment_status from public.orders where id = (select v from t.ids where k='online_order')) <> 'refunded' then
    raise exception 'P07 full: %', j;
  end if;
end $$;

\echo 'P08 admin card: token from admin setup checkout goes ONLY to admin card; readable only with settings.manage'
do $$ begin
  perform public.payment_set_admin_pending('900777', '00000000-0000-0000-0000-0000000000c0');
  if public.paymob_apply_card_token('900777', 'tok_admin', 'xxxx5555', 'MasterCard', 1, 2031)->>'result' <> 'admin_card' then raise exception 'P08 admin'; end if;
  perform t.act('00000000-0000-0000-0000-0000000000c2');
  if exists (select 1 from public.admin_payment_method) then raise exception 'P08 sales reads admin card'; end if;
  perform t.act('00000000-0000-0000-0000-0000000000c0');
  if (select last4 || status from public.admin_payment_method) <> '5555active' then raise exception 'P08 owner'; end if;
  perform t.reset();
  if exists (select 1 from public.payment_methods where provider_payment_method_id = 'tok_admin') then raise exception 'P08 mixed with customer cards'; end if;
end $$;

\echo 'ALL PAYMENT TESTS PASSED'
