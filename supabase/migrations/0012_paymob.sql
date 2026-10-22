-- =====================================================================
-- My Hatō — 0012 switch payment provider to Paymob (Egypt)
-- Paymob flow: Intention API -> Unified Checkout -> HMAC-signed callbacks.
--   * TRANSACTION callback: success / pending / failure / void / refund
--   * TOKEN callback: saved card token (only stored if the customer opted in)
-- Settlement is to the merchant's Egyptian bank account configured in the Paymob dashboard (EGP).
-- =====================================================================

alter table public.payments alter column provider set default 'paymob';
alter table public.payments add column if not exists provider_intent_id text unique;      -- Paymob intention id
alter table public.payments add column if not exists provider_order_id text unique;       -- Paymob intention_order_id (callbacks reference it)
alter table public.payments add column if not exists checkout_client_secret text;         -- only for reopening the SAME checkout (owner-only via RLS)
alter table public.payments add column if not exists intent_expires_at timestamptz;
alter table public.payment_methods alter column provider set default 'paymob';
alter table public.payment_customers alter column provider set default 'paymob';
alter table public.payment_methods add column if not exists card_subtype text;            -- Visa / MasterCard / Meeza ...

alter table public.payment_settings alter column provider_name set default 'paymob';
alter table public.payment_settings alter column settlement_currency set default 'EGP';
update public.payment_settings set provider_name = 'paymob', settlement_currency = 'EGP' where id = 1 and not is_configured;

alter table public.admin_payment_method alter column provider set default 'paymob';
alter table public.admin_payment_method add column if not exists pending_provider_order_id text;

-- client secret must never be visible to staff dashboards or other users
revoke select on public.payments from authenticated;
grant select (id, user_id, order_id, provider, provider_transaction_id, provider_intent_id, provider_order_id, idempotency_key,
              amount_minor, currency, payment_method_type, card_brand, card_last4, status, refunded_minor, save_card_requested,
              failure_code, created_at, updated_at) on public.payments to authenticated;

-- ---------------------------------------------------------------- prepare (reuse an unexpired checkout => no double payment)
create or replace function public.payment_prepare(p_user_id uuid, p_order_id uuid, p_save_card boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_o public.orders%rowtype; v_s public.payment_settings%rowtype; v_p public.payments%rowtype;
begin
  select * into v_s from public.payment_settings where id = 1;
  if not (v_s.is_configured and v_s.online_payments_enabled) then raise exception 'ONLINE_PAYMENTS_DISABLED'; end if;
  select * into v_o from public.orders where id = p_order_id and customer_id = p_user_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_o.payment_method <> 'online' then raise exception 'NOT_ONLINE_ORDER'; end if;
  if v_o.status = 'cancelled' then raise exception 'ORDER_CANCELLED'; end if;
  if v_o.payment_status::text in ('paid','refunded','partially_refunded') then raise exception 'ALREADY_PAID'; end if;

  select * into v_p from public.payments
   where order_id = p_order_id and status in ('pending','processing') and amount_minor = v_o.total_minor
   order by created_at desc limit 1;
  if found and v_p.status = 'processing' then raise exception 'PAYMENT_IN_PROGRESS'; end if;
  if found and v_p.checkout_client_secret is not null and v_p.intent_expires_at > now() + interval '2 minutes'
     and v_p.save_card_requested = p_save_card then
    return jsonb_build_object('payment_id', v_p.id, 'reuse_client_secret', v_p.checkout_client_secret,
                              'amount_minor', v_p.amount_minor, 'currency', v_p.currency, 'reference', v_o.reference, 'reused', true);
  end if;
  -- an older open attempt is abandoned before opening a new checkout
  update public.payments set status = 'cancelled' where order_id = p_order_id and status = 'pending';

  insert into public.payments(user_id, order_id, provider, idempotency_key, amount_minor, currency, save_card_requested)
  values (p_user_id, p_order_id, 'paymob', 'pay_' || replace(gen_random_uuid()::text, '-', ''), v_o.total_minor, v_o.currency, p_save_card)
  returning * into v_p;
  update public.orders set payment_status = 'pending' where id = p_order_id;
  return jsonb_build_object('payment_id', v_p.id, 'idempotency_key', v_p.idempotency_key, 'amount_minor', v_p.amount_minor,
                            'currency', v_p.currency, 'reference', v_o.reference, 'reused', false,
                            'customer', (select jsonb_build_object('full_name', coalesce(full_name, ''), 'email', email, 'phone', phone)
                                           from public.profiles where id = p_user_id),
                            'card_tokens', (select coalesce(jsonb_agg(provider_payment_method_id), '[]'::jsonb)
                                              from (select provider_payment_method_id from public.payment_methods
                                                     where user_id = p_user_id order by is_default desc, created_at desc limit 3) t));
end $$;

create or replace function public.payment_attach_intent(p_payment_id uuid, p_intent_id text, p_provider_order_id text,
                                                        p_client_secret text, p_expires_at timestamptz)
returns void language sql security definer set search_path = public as $$
  update public.payments set provider_intent_id = p_intent_id, provider_order_id = p_provider_order_id,
         checkout_client_secret = p_client_secret, intent_expires_at = p_expires_at
   where id = p_payment_id and provider_intent_id is null;
$$;

-- ---------------------------------------------------------------- verified Paymob TRANSACTION callback
-- p_event_id is derived from the transaction id + state, so a retried identical callback is applied once.
create or replace function public.paymob_apply_transaction(
  p_event_id text, p_provider_order_id text, p_transaction_id text,
  p_success boolean, p_pending boolean, p_is_voided boolean, p_is_refund boolean, p_amount_cents bigint,
  p_currency text, p_source_type text, p_source_subtype text, p_pan text, p_error text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_p public.payments%rowtype; v_o public.orders%rowtype; v_new text; v_refunded bigint; v_order_ps public.payment_status;
begin
  insert into public.payment_events(provider, provider_event_id, event_type) values ('paymob', p_event_id, 'TRANSACTION')
  on conflict (provider_event_id) do nothing;
  if not found then return jsonb_build_object('result', 'duplicate'); end if;

  select * into v_p from public.payments where provider_order_id = p_provider_order_id for update;
  if not found then
    update public.payment_events set result = 'unknown_payment' where provider_event_id = p_event_id;
    return jsonb_build_object('result', 'unknown_payment');
  end if;
  update public.payment_events set payment_id = v_p.id where provider_event_id = p_event_id;
  select * into v_o from public.orders where id = v_p.order_id for update;

  v_refunded := v_p.refunded_minor;
  if p_is_refund then
    if not p_success then
      update public.payment_events set result = 'refund_failed' where provider_event_id = p_event_id;
      return jsonb_build_object('result', 'refund_failed');
    end if;
    v_refunded := least(v_p.amount_minor, v_p.refunded_minor + coalesce(p_amount_cents, 0));
    v_new := case when v_refunded >= v_p.amount_minor then 'refunded' else 'partially_refunded' end;
  elsif p_is_voided then
    v_new := case when v_p.status = 'succeeded' then 'refunded' else 'cancelled' end;
    if v_new = 'refunded' then v_refunded := v_p.amount_minor; end if;
  elsif p_pending then
    v_new := 'processing';
  elsif p_success then
    if coalesce(p_amount_cents, 0) <> v_p.amount_minor or upper(coalesce(p_currency, '')) <> upper(v_p.currency) then
      update public.payment_events set result = 'amount_mismatch' where provider_event_id = p_event_id;
      perform public.audit_write('payment.amount_mismatch', 'payment', v_p.id::text,
        jsonb_build_object('expected', v_p.amount_minor, 'received', p_amount_cents, 'currency', p_currency));
      return jsonb_build_object('result', 'amount_mismatch');
    end if;
    v_new := 'succeeded';
  else
    v_new := 'failed';
  end if;

  if v_p.status in ('succeeded','refunded','partially_refunded') and v_new in ('processing','failed','cancelled') then
    update public.payment_events set result = 'ignored_stale' where provider_event_id = p_event_id;
    return jsonb_build_object('result', 'ignored_stale');
  end if;

  update public.payments set status = v_new, refunded_minor = v_refunded,
         provider_transaction_id = case when p_is_refund or p_is_voided then provider_transaction_id else coalesce(provider_transaction_id, p_transaction_id) end,
         payment_method_type = coalesce(case when p_source_type is not null then lower(p_source_type) end, payment_method_type),
         card_brand = coalesce(p_source_subtype, card_brand),
         card_last4 = coalesce(case when p_pan ~ '[0-9]{4}$' then right(p_pan, 4) end, card_last4),
         failure_code = case when v_new = 'failed' then left(p_error, 100) else failure_code end,
         checkout_client_secret = case when v_new in ('succeeded','failed','cancelled','refunded','partially_refunded') then null else checkout_client_secret end
   where id = v_p.id;

  -- a second successful payment for an order that is already paid => flag for refund, do not double count
  if v_new = 'succeeded' and v_o.payment_status = 'paid' then
    perform public.audit_write('payment.duplicate_success', 'payment', v_p.id::text, jsonb_build_object('order', v_o.reference));
    update public.payment_events set result = 'duplicate_success_needs_refund' where provider_event_id = p_event_id;
    return jsonb_build_object('result', 'duplicate_success_needs_refund', 'payment_id', v_p.id);
  end if;

  v_order_ps := case v_new when 'succeeded' then 'paid' when 'refunded' then 'refunded'
                           when 'partially_refunded' then 'partially_refunded' when 'failed' then 'failed'
                           when 'cancelled' then 'unpaid' else 'pending' end;
  update public.orders set payment_status = v_order_ps where id = v_o.id;
  update public.payment_events set result = 'applied:' || v_new where provider_event_id = p_event_id;

  if v_new = 'succeeded' then
    perform public.notify_user(v_o.customer_id, 'تم الدفع بنجاح', 'Payment successful',
      'تم تأكيد دفع ' || public.fmt_egp(v_p.amount_minor) || ' ج.م للطلب ' || v_o.reference || '.',
      'Payment of EGP ' || public.fmt_egp(v_p.amount_minor) || ' confirmed for order ' || v_o.reference || '.',
      'order', v_o.id, v_o.reference, '/orders/' || v_o.id);
  elsif v_new = 'failed' then
    perform public.notify_user(v_o.customer_id, 'لم يتم الدفع', 'Payment failed',
      'فشلت عملية الدفع للطلب ' || v_o.reference || '. تقدر تحاول تاني من تفاصيل الطلب.',
      'Payment for order ' || v_o.reference || ' failed. You can retry from the order details.',
      'order', v_o.id, v_o.reference, '/orders/' || v_o.id);
  elsif v_new in ('refunded','partially_refunded') then
    perform public.notify_user(v_o.customer_id, 'تم استرداد مبلغ', 'Refund issued',
      'تم استرداد ' || public.fmt_egp(v_refunded) || ' ج.م للطلب ' || v_o.reference || '. قد يستغرق ظهوره في حسابك عدة أيام.',
      'A refund of EGP ' || public.fmt_egp(v_refunded) || ' was issued for order ' || v_o.reference || '. It may take several days to appear.',
      'order', v_o.id, v_o.reference, '/orders/' || v_o.id);
  end if;
  perform public.audit_write('payment.' || v_new, 'payment', v_p.id::text,
    jsonb_build_object('order', v_o.reference, 'amount_minor', v_p.amount_minor, 'refunded_minor', v_refunded, 'txn', p_transaction_id));
  return jsonb_build_object('result', 'applied', 'status', v_new, 'payment_id', v_p.id);
end $$;

-- ---------------------------------------------------------------- verified Paymob TOKEN callback
-- Saves a customer card only if that payment's customer opted in; or the admin card if it belongs to the admin setup checkout.
create or replace function public.paymob_apply_card_token(p_provider_order_id text, p_token text, p_masked_pan text,
                                                          p_card_subtype text, p_exp_month int, p_exp_year int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_p public.payments%rowtype; v_last4 text := case when p_masked_pan ~ '[0-9]{4}$' then right(p_masked_pan, 4) end;
begin
  if exists (select 1 from public.admin_payment_method where id = 1 and pending_provider_order_id = p_provider_order_id) then
    update public.admin_payment_method set provider_payment_method_id = p_token, brand = p_card_subtype, last4 = v_last4,
           expiry_month = p_exp_month, expiry_year = p_exp_year, status = 'active', pending_provider_order_id = null, updated_at = now()
     where id = 1;
    perform public.audit_write('admin_card.active', 'settings', 'admin_payment_method', jsonb_build_object('last4', v_last4));
    return jsonb_build_object('result', 'admin_card');
  end if;
  select * into v_p from public.payments where provider_order_id = p_provider_order_id;
  if not found then return jsonb_build_object('result', 'unknown_payment'); end if;
  if not v_p.save_card_requested then return jsonb_build_object('result', 'not_requested'); end if;
  insert into public.payment_methods(user_id, provider, provider_payment_method_id, brand, card_subtype, last4, expiry_month, expiry_year, is_default)
  values (v_p.user_id, 'paymob', p_token, lower(p_card_subtype), p_card_subtype, v_last4,
          case when p_exp_month between 1 and 12 then p_exp_month end, case when p_exp_year between 2000 and 2100 then p_exp_year end,
          not exists (select 1 from public.payment_methods where user_id = v_p.user_id))
  on conflict (provider_payment_method_id) do nothing;
  return jsonb_build_object('result', 'saved');
end $$;

create or replace function public.payment_set_admin_pending(p_provider_order_id text, p_actor uuid)
returns void language sql security definer set search_path = public as $$
  update public.admin_payment_method set pending_provider_order_id = p_provider_order_id,
         status = case when status = 'active' then 'active' else 'pending' end, updated_by = p_actor, updated_at = now()
   where id = 1;
$$;

-- refund pre-check now needs the Paymob transaction id
create or replace function public.staff_refund_check(p_payment_id uuid, p_amount_minor bigint)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_p public.payments%rowtype;
begin
  perform public.require_permission('orders.manage');
  if not (select refunds_enabled from public.payment_settings where id = 1) then raise exception 'REFUNDS_DISABLED'; end if;
  select * into v_p from public.payments where id = p_payment_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_p.status not in ('succeeded','partially_refunded') or v_p.provider_transaction_id is null then raise exception 'NOT_REFUNDABLE'; end if;
  if p_amount_minor is null or p_amount_minor <= 0 or p_amount_minor > v_p.amount_minor - v_p.refunded_minor then
    raise exception 'INVALID_AMOUNT';
  end if;
  return jsonb_build_object('provider_transaction_id', v_p.provider_transaction_id, 'amount_minor', p_amount_minor,
                            'currency', v_p.currency, 'refunded_minor', v_p.refunded_minor);
end $$;

revoke execute on function public.payment_attach_intent(uuid, text, text, text, timestamptz) from public, anon, authenticated;
revoke execute on function public.paymob_apply_transaction(text, text, text, boolean, boolean, boolean, boolean, bigint, text, text, text, text, text) from public, anon, authenticated;
revoke execute on function public.paymob_apply_card_token(text, text, text, text, int, int) from public, anon, authenticated;
revoke execute on function public.payment_set_admin_pending(text, uuid) from public, anon, authenticated;
grant execute on function public.payment_attach_intent(uuid, text, text, text, timestamptz),
  public.paymob_apply_transaction(text, text, text, boolean, boolean, boolean, boolean, bigint, text, text, text, text, text),
  public.paymob_apply_card_token(text, text, text, text, int, int), public.payment_set_admin_pending(text, uuid) to service_role;
