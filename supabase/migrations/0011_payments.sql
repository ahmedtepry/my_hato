-- =====================================================================
-- My Hatō — 0011 online payments (provider: Stripe)
-- * Card data never touches our database: only the provider's payment-method id,
--   brand, last4 and expiry are stored.
-- * Payment success is recorded ONLY from verified provider webhooks
--   (payment_apply_provider_event, service_role only) — never from the app.
-- * Secrets (API keys, webhook secret) live in Edge Function secrets, not here.
-- =====================================================================

-- provider customer per user (service role only)
create table public.payment_customers (
  user_id uuid primary key references auth.users(id) on delete cascade,
  provider text not null default 'stripe',
  provider_customer_id text not null unique,
  created_at timestamptz not null default now()
);

-- saved cards (customer explicitly ticked "save card")
create table public.payment_methods (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  provider text not null default 'stripe',
  provider_payment_method_id text not null unique,
  brand text,
  last4 text check (last4 is null or last4 ~ '^[0-9]{4}$'),
  expiry_month int check (expiry_month is null or expiry_month between 1 and 12),
  expiry_year int check (expiry_year is null or expiry_year between 2000 and 2100),
  wallet text check (wallet is null or wallet in ('apple_pay','google_pay')),
  is_default boolean not null default false,
  created_at timestamptz not null default now()
);
create index payment_methods_user_idx on public.payment_methods(user_id);
create unique index payment_methods_one_default on public.payment_methods(user_id) where is_default;

-- one row per payment attempt (a PaymentIntent)
create table public.payments (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id),
  order_id uuid not null references public.orders(id),
  provider text not null default 'stripe',
  provider_transaction_id text unique,                 -- PaymentIntent id (pi_...)
  idempotency_key text not null unique,
  amount_minor bigint not null check (amount_minor > 0),
  currency char(3) not null,
  payment_method_type text,                            -- card | apple_pay | google_pay (from provider)
  card_brand text,
  card_last4 text,
  status text not null default 'pending'
    check (status in ('pending','processing','succeeded','failed','cancelled','refunded','partially_refunded')),
  refunded_minor bigint not null default 0 check (refunded_minor >= 0),
  save_card_requested boolean not null default false,
  failure_code text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index payments_order_idx on public.payments(order_id, created_at desc);
create index payments_user_idx on public.payments(user_id, created_at desc);
create index payments_status_idx on public.payments(status, created_at desc);
create trigger payments_updated before update on public.payments
  for each row execute function public.set_updated_at();

-- verified webhook events (unique event id => idempotent processing)
create table public.payment_events (
  id bigint generated always as identity primary key,
  provider text not null default 'stripe',
  provider_event_id text not null unique,
  event_type text not null,
  payment_id uuid references public.payments(id),
  result text,
  received_at timestamptz not null default now()
);

-- merchant / settlement settings (single row). NO secrets here.
create table public.payment_settings (
  id smallint primary key default 1 check (id = 1),
  provider_name text not null default 'stripe',
  merchant_account_id text,          -- e.g. acct_... (filled from provider verification)
  merchant_iban text,
  account_holder_name text,
  bank_name text,
  settlement_currency char(3) not null default 'AED',
  settlement_schedule text not null default 'daily' check (settlement_schedule in ('daily','weekly','monthly','manual')),
  is_configured boolean not null default false,       -- set ONLY by the server after a successful provider check
  online_payments_enabled boolean not null default false,
  refunds_enabled boolean not null default false,
  provider_status jsonb not null default '{}'::jsonb, -- charges_enabled, payouts_enabled, ... as reported by provider
  verified_at timestamptz,
  updated_by uuid references auth.users(id),
  updated_at timestamptz not null default now()
);
insert into public.payment_settings(id) values (1);
create trigger payment_settings_updated before update on public.payment_settings
  for each row execute function public.set_updated_at();

-- admin's own card — fully separate from customer cards and from settlement settings.
-- Never used to collect customer money and never treated as the receiving account.
create table public.admin_payment_method (
  id smallint primary key default 1 check (id = 1),
  provider text not null default 'stripe',
  provider_customer_id text,
  provider_payment_method_id text,
  brand text,
  last4 text check (last4 is null or last4 ~ '^[0-9]{4}$'),
  expiry_month int,
  expiry_year int,
  status text not null default 'not_set' check (status in ('not_set','pending','active','removed')),
  updated_by uuid references auth.users(id),
  updated_at timestamptz not null default now()
);
insert into public.admin_payment_method(id) values (1);

-- ---------------------------------------------------------------- RLS
alter table public.payment_customers enable row level security;
alter table public.payment_methods enable row level security;
alter table public.payments enable row level security;
alter table public.payment_events enable row level security;
alter table public.payment_settings enable row level security;
alter table public.admin_payment_method enable row level security;

revoke all on public.payment_customers from anon, authenticated;                  -- service role only

create policy payment_methods_own_read on public.payment_methods for select to authenticated using (user_id = auth.uid());
revoke insert, update, delete on public.payment_methods from anon, authenticated; -- add/remove via Edge Functions

create policy payments_read on public.payments for select to authenticated
  using (user_id = auth.uid() or public.has_permission('orders.view'));
revoke insert, update, delete on public.payments from anon, authenticated;

create policy payment_events_read on public.payment_events for select to authenticated using (public.has_permission('audit.view'));
revoke insert, update, delete on public.payment_events from anon, authenticated;

create policy payment_settings_read on public.payment_settings for select to authenticated using (public.has_permission('settings.manage'));
create policy payment_settings_update on public.payment_settings for update to authenticated
  using (public.has_permission('settings.manage')) with check (public.has_permission('settings.manage'));
revoke insert, update, delete on public.payment_settings from anon, authenticated;
grant update (merchant_iban, account_holder_name, bank_name, settlement_currency, settlement_schedule, refunds_enabled, updated_by)
  on public.payment_settings to authenticated;

create policy admin_pm_read on public.admin_payment_method for select to authenticated using (public.has_permission('settings.manage'));
revoke insert, update, delete on public.admin_payment_method from anon, authenticated;

alter publication supabase_realtime add table public.payments;

-- ---------------------------------------------------------------- order rules for online payments
-- delivery marks cash/branch orders as paid; online orders are paid only by a verified provider event
create or replace function public._apply_order_status(p_order public.orders, p_to public.order_status, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare v_msg record;
begin
  if not exists (select 1 from public.order_transitions t
                  where t.from_status = p_order.status and t.to_status = p_to
                    and (t.fulfillment is null or t.fulfillment = p_order.fulfillment)) then
    raise exception 'INVALID_TRANSITION:%->%', p_order.status, p_to;
  end if;
  update public.orders set status = p_to,
         payment_status = case when p_to = 'delivered' and p_order.payment_method <> 'online' then 'paid' else payment_status end
   where id = p_order.id;
  insert into public.order_status_history(order_id, from_status, to_status, note, changed_by)
  values (p_order.id, p_order.status, p_to, left(p_note, 500), auth.uid());
  if p_to = 'cancelled' then
    perform public._restock_order(p_order.id);
  end if;
  select * into v_msg from public.order_status_message(p_to);
  perform public.notify_user(p_order.customer_id,
    'تحديث الطلب ' || p_order.reference, 'Order ' || p_order.reference || ' update',
    v_msg.ar, v_msg.en, 'order', p_order.id, p_order.reference, '/orders/' || p_order.id);
end $$;

-- a paid online order cannot be self-cancelled (needs a refund by staff)
create or replace function public.customer_cancel_order(p_order_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_order public.orders%rowtype;
begin
  select * into v_order from public.orders where id = p_order_id and customer_id = public.require_auth() for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_order.status <> 'pending_confirmation' then raise exception 'CANNOT_CANCEL'; end if;
  if v_order.payment_status::text in ('paid','partially_refunded') then raise exception 'CANNOT_CANCEL_PAID'; end if;
  perform public._apply_order_status(v_order, 'cancelled', 'cancelled by customer');
  -- abandon any open payment attempt
  update public.payments set status = 'cancelled' where order_id = p_order_id and status in ('pending','processing');
end $$;

-- ---------------------------------------------------------------- service-role functions (Edge Functions)

-- Register a new payment attempt for an order after server-side checks. Amount comes from the order row.
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
  -- reuse an open attempt (same intent => no double charge)
  select * into v_p from public.payments
   where order_id = p_order_id and status in ('pending','processing') and amount_minor = v_o.total_minor
   order by created_at desc limit 1;
  if found then
    update public.payments set save_card_requested = p_save_card where id = v_p.id;
    return jsonb_build_object('payment_id', v_p.id, 'idempotency_key', v_p.idempotency_key, 'provider_transaction_id', v_p.provider_transaction_id,
                              'amount_minor', v_p.amount_minor, 'currency', v_p.currency, 'reference', v_o.reference, 'reused', true);
  end if;
  insert into public.payments(user_id, order_id, idempotency_key, amount_minor, currency, save_card_requested)
  values (p_user_id, p_order_id, 'pay_' || replace(gen_random_uuid()::text, '-', ''), v_o.total_minor, v_o.currency, p_save_card)
  returning * into v_p;
  update public.orders set payment_status = 'pending' where id = p_order_id;
  return jsonb_build_object('payment_id', v_p.id, 'idempotency_key', v_p.idempotency_key, 'provider_transaction_id', null,
                            'amount_minor', v_p.amount_minor, 'currency', v_p.currency, 'reference', v_o.reference, 'reused', false);
end $$;

create or replace function public.payment_attach_intent(p_payment_id uuid, p_provider_tx text)
returns void language sql security definer set search_path = public as $$
  update public.payments set provider_transaction_id = p_provider_tx
   where id = p_payment_id and (provider_transaction_id is null or provider_transaction_id = p_provider_tx);
$$;

-- Apply a VERIFIED provider event. Idempotent on p_event_id. Never downgrades a succeeded payment to failed.
create or replace function public.payment_apply_provider_event(
  p_event_id text, p_event_type text, p_provider_tx text, p_status text,
  p_amount_received bigint, p_amount_refunded bigint, p_currency text,
  p_method_type text, p_card_brand text, p_card_last4 text, p_failure_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_p public.payments%rowtype; v_o public.orders%rowtype; v_new text; v_order_ps public.payment_status;
begin
  insert into public.payment_events(provider_event_id, event_type) values (p_event_id, p_event_type)
  on conflict (provider_event_id) do nothing;
  if not found then return jsonb_build_object('result', 'duplicate'); end if;

  select * into v_p from public.payments where provider_transaction_id = p_provider_tx for update;
  if not found then
    update public.payment_events set result = 'unknown_payment' where provider_event_id = p_event_id;
    return jsonb_build_object('result', 'unknown_payment');
  end if;
  update public.payment_events set payment_id = v_p.id where provider_event_id = p_event_id;
  select * into v_o from public.orders where id = v_p.order_id for update;

  v_new := p_status;
  if v_new = 'succeeded' and (coalesce(p_amount_received, 0) <> v_p.amount_minor or upper(coalesce(p_currency, '')) <> upper(v_p.currency)) then
    update public.payment_events set result = 'amount_mismatch' where provider_event_id = p_event_id;
    perform public.audit_write('payment.amount_mismatch', 'payment', v_p.id::text,
      jsonb_build_object('expected', v_p.amount_minor, 'received', p_amount_received, 'currency', p_currency));
    return jsonb_build_object('result', 'amount_mismatch');
  end if;
  if p_amount_refunded is not null and p_amount_refunded > 0 then
    v_new := case when p_amount_refunded >= v_p.amount_minor then 'refunded' else 'partially_refunded' end;
  end if;
  -- ordering guard: once succeeded/refunded, late failure/cancel/processing events are ignored
  if v_p.status in ('succeeded','refunded','partially_refunded') and v_new in ('pending','processing','failed','cancelled') then
    update public.payment_events set result = 'ignored_stale' where provider_event_id = p_event_id;
    return jsonb_build_object('result', 'ignored_stale');
  end if;

  update public.payments set status = v_new,
         refunded_minor = greatest(refunded_minor, coalesce(p_amount_refunded, 0)),
         payment_method_type = coalesce(p_method_type, payment_method_type),
         card_brand = coalesce(p_card_brand, card_brand), card_last4 = coalesce(p_card_last4, card_last4),
         failure_code = case when v_new = 'failed' then left(p_failure_code, 100) else failure_code end
   where id = v_p.id;

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
      'تم استرداد ' || public.fmt_egp(p_amount_refunded) || ' ج.م للطلب ' || v_o.reference || '. قد يستغرق ظهوره في حسابك عدة أيام.',
      'A refund of EGP ' || public.fmt_egp(p_amount_refunded) || ' was issued for order ' || v_o.reference || '. It may take several days to appear.',
      'order', v_o.id, v_o.reference, '/orders/' || v_o.id);
  end if;
  perform public.audit_write('payment.' || v_new, 'payment', v_p.id::text,
    jsonb_build_object('event', p_event_type, 'order', v_o.reference, 'amount_minor', v_p.amount_minor, 'refunded_minor', p_amount_refunded));
  return jsonb_build_object('result', 'applied', 'status', v_new, 'payment_id', v_p.id, 'save_card', v_p.save_card_requested, 'user_id', v_p.user_id);
end $$;

-- Save a card only after the customer opted in and the provider confirmed it.
create or replace function public.payment_save_method(p_user_id uuid, p_provider_pm text, p_brand text, p_last4 text,
                                                      p_exp_month int, p_exp_year int, p_wallet text)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into public.payment_methods(user_id, provider_payment_method_id, brand, last4, expiry_month, expiry_year, wallet, is_default)
  values (p_user_id, p_provider_pm, p_brand, p_last4, p_exp_month, p_exp_year, p_wallet,
          not exists (select 1 from public.payment_methods where user_id = p_user_id))
  on conflict (provider_payment_method_id) do update
     set brand = excluded.brand, last4 = excluded.last4, expiry_month = excluded.expiry_month, expiry_year = excluded.expiry_year
   where public.payment_methods.user_id = p_user_id;
end $$;

create or replace function public.payment_set_default_method(p_user_id uuid, p_method_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.payment_methods where id = p_method_id and user_id = p_user_id) then raise exception 'NOT_FOUND'; end if;
  update public.payment_methods set is_default = false where user_id = p_user_id and is_default;
  update public.payment_methods set is_default = true where id = p_method_id;
end $$;

create or replace function public.payment_remove_method(p_user_id uuid, p_method_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v_pm text;
begin
  select provider_payment_method_id into v_pm from public.payment_methods where id = p_method_id and user_id = p_user_id;
  if v_pm is null then raise exception 'NOT_FOUND'; end if;
  delete from public.payment_methods where id = p_method_id;
  return v_pm;
end $$;

create or replace function public.payment_record_provider_check(p_ok boolean, p_account_id text, p_status jsonb)
returns void language sql security definer set search_path = public as $$
  update public.payment_settings set is_configured = p_ok, merchant_account_id = coalesce(p_account_id, merchant_account_id),
         provider_status = coalesce(p_status, '{}'::jsonb), verified_at = now(),
         online_payments_enabled = case when p_ok then online_payments_enabled else false end
   where id = 1;
$$;

create or replace function public.payment_set_admin_card(p_customer text, p_pm text, p_brand text, p_last4 text, p_exp_month int, p_exp_year int, p_status text, p_actor uuid)
returns void language sql security definer set search_path = public as $$
  update public.admin_payment_method set provider_customer_id = coalesce(p_customer, provider_customer_id),
         provider_payment_method_id = p_pm, brand = p_brand, last4 = p_last4, expiry_month = p_exp_month, expiry_year = p_exp_year,
         status = p_status, updated_by = p_actor, updated_at = now()
   where id = 1;
$$;

-- Staff: turn online payments on/off (only after the provider check succeeded)
create or replace function public.staff_set_online_payments(p_enabled boolean)
returns void language plpgsql security definer set search_path = public as $$
declare v_methods jsonb;
begin
  perform public.require_permission('settings.manage');
  if p_enabled and not (select is_configured from public.payment_settings where id = 1) then
    raise exception 'PAYMENTS_NOT_CONFIGURED';
  end if;
  update public.payment_settings set online_payments_enabled = p_enabled, updated_by = auth.uid() where id = 1;
  select coalesce(jsonb_agg(m), '[]'::jsonb) into v_methods
    from jsonb_array_elements_text(coalesce(public.setting('enabled_payment_methods'), '[]'::jsonb)) m where m <> 'online';
  if p_enabled then v_methods := v_methods || '["online"]'::jsonb; end if;
  update public.application_settings set value = v_methods, updated_by = auth.uid(), updated_at = now() where key = 'enabled_payment_methods';
  perform public.audit_write(case when p_enabled then 'payments.enabled' else 'payments.disabled' end, 'settings', 'payment_settings', '{}');
end $$;

-- Staff refund pre-check (the actual refund is executed by the Edge Function at the provider;
-- the payment row changes only when the provider's charge.refunded webhook arrives)
create or replace function public.staff_refund_check(p_payment_id uuid, p_amount_minor bigint)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_p public.payments%rowtype;
begin
  perform public.require_permission('orders.manage');
  if not (select refunds_enabled from public.payment_settings where id = 1) then raise exception 'REFUNDS_DISABLED'; end if;
  select * into v_p from public.payments where id = p_payment_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_p.status not in ('succeeded','partially_refunded') then raise exception 'NOT_REFUNDABLE'; end if;
  if p_amount_minor is null or p_amount_minor <= 0 or p_amount_minor > v_p.amount_minor - v_p.refunded_minor then
    raise exception 'INVALID_AMOUNT';
  end if;
  return jsonb_build_object('provider_transaction_id', v_p.provider_transaction_id, 'amount_minor', p_amount_minor, 'currency', v_p.currency);
end $$;

revoke execute on function public.payment_prepare(uuid, uuid, boolean) from public, anon, authenticated;
revoke execute on function public.payment_attach_intent(uuid, text) from public, anon, authenticated;
revoke execute on function public.payment_apply_provider_event(text, text, text, text, bigint, bigint, text, text, text, text, text) from public, anon, authenticated;
revoke execute on function public.payment_save_method(uuid, text, text, text, int, int, text) from public, anon, authenticated;
revoke execute on function public.payment_set_default_method(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.payment_remove_method(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.payment_record_provider_check(boolean, text, jsonb) from public, anon, authenticated;
revoke execute on function public.payment_set_admin_card(text, text, text, text, int, int, text, uuid) from public, anon, authenticated;
revoke execute on function public.staff_set_online_payments(boolean) from public, anon;
revoke execute on function public.staff_refund_check(uuid, bigint) from public, anon;
grant execute on function public.payment_prepare(uuid, uuid, boolean), public.payment_attach_intent(uuid, text),
  public.payment_apply_provider_event(text, text, text, text, bigint, bigint, text, text, text, text, text),
  public.payment_save_method(uuid, text, text, text, int, int, text), public.payment_set_default_method(uuid, uuid),
  public.payment_remove_method(uuid, uuid), public.payment_record_provider_check(boolean, text, jsonb),
  public.payment_set_admin_card(text, text, text, text, int, int, text, uuid) to service_role;
