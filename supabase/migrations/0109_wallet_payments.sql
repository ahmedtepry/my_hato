-- 0109: pay by wallet transfer. The owner sets the receiving numbers; the customer picks a wallet and says which number the money
-- comes from (the same phone number, or another one); the team confirms once the money arrives.
insert into public.permission_catalog (permission, grp, name_ar, name_en, desc_ar, desc_en, sensitive, inert, sort) values
 ('payments.wallets', 'extras', 'يضبط أرقام محافظ الدفع', 'Set the wallet payment numbers',
  'يحدد أرقام فودافون كاش واتصالات كاش وإنستا باي اللي العميل يحوّل عليها', 'Sets the Vodafone Cash, Etisalat Cash and InstaPay numbers customers transfer to', true, false, 41),
 ('orders.confirm_wallet', 'orders', 'يأكد استلام تحويل المحفظة', 'Confirm a wallet transfer arrived',
  'بعد ما يتأكد إن الفلوس وصلت يعلّم الطلب مدفوع', 'After checking the money arrived, marks the order as paid', true, false, 61)
on conflict (permission) do update set name_ar = excluded.name_ar, name_en = excluded.name_en, desc_ar = excluded.desc_ar, desc_en = excluded.desc_en;
insert into public.role_permissions (role, permission) values ('owner', 'payments.wallets'), ('owner', 'orders.confirm_wallet'), ('manager', 'orders.confirm_wallet') on conflict do nothing;

update public.application_settings set value = value || '["wallet"]'::jsonb
 where key = 'enabled_payment_methods' and jsonb_typeof(value) = 'array' and not (value ? 'wallet');

-- the receiving numbers (owner only writes; the app reads them through wallet_options())
create table if not exists public.wallet_numbers (
  wallet text primary key check (wallet in ('vodafone', 'etisalat', 'instapay')),
  number text not null default '' check (length(number) <= 40),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users (id) on delete set null
);
alter table public.wallet_numbers enable row level security;
revoke all on public.wallet_numbers from anon, authenticated;
insert into public.wallet_numbers (wallet) values ('vodafone'), ('etisalat'), ('instapay') on conflict do nothing;

create table if not exists public.order_wallet_transfers (
  order_id uuid primary key references public.orders (id) on delete cascade,
  wallet text not null check (wallet in ('vodafone', 'etisalat', 'instapay')),
  from_phone text not null,
  same_number boolean not null,
  created_at timestamptz not null default now(),
  confirmed_at timestamptz,
  confirmed_by uuid references auth.users (id) on delete set null
);
alter table public.order_wallet_transfers enable row level security;
revoke all on public.order_wallet_transfers from anon, authenticated;

-- wallets that have a number set (what the customer can choose from)
create or replace function public.wallet_options() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('wallet', wallet, 'number', number) order by wallet), '[]'::jsonb)
  from public.wallet_numbers where number <> ''
$$;
revoke all on function public.wallet_options() from public;
grant execute on function public.wallet_options() to authenticated;

-- owner: all three rows with their numbers
create or replace function public.wallet_numbers_get() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_permission('payments.wallets');
  return (select coalesce(jsonb_object_agg(wallet, number), '{}'::jsonb) from public.wallet_numbers);
end $$;
revoke all on function public.wallet_numbers_get() from public, anon;
grant execute on function public.wallet_numbers_get() to authenticated;

create or replace function public.wallet_numbers_set(p_numbers jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare w text; v text;
begin
  perform public.require_permission('payments.wallets');
  if jsonb_typeof(p_numbers) is distinct from 'object' then raise exception 'INVALID_INPUT'; end if;
  foreach w in array array['vodafone', 'etisalat', 'instapay'] loop
    v := trim(coalesce(p_numbers ->> w, ''));
    if v !~ '^[0-9+@._a-zA-Z-]{0,40}$' then raise exception 'INVALID_INPUT'; end if;
    update public.wallet_numbers set number = v, updated_at = now(), updated_by = auth.uid() where wallet = w;
  end loop;
  perform public.audit_write('payments.wallets', 'wallet_numbers', 'all', '{}'::jsonb);
end $$;
revoke all on function public.wallet_numbers_set(jsonb) from public, anon;
grant execute on function public.wallet_numbers_set(jsonb) to authenticated;

-- customer: after placing a wallet order, says which wallet and which number the money comes from (null = the same number as the order's phone)
create or replace function public.order_wallet_submit(p_order_id uuid, p_wallet text, p_from_phone text)
returns void language plpgsql security definer set search_path = public as $$
declare v_o public.orders%rowtype; v_from text; v_same boolean;
begin
  perform public.require_auth();
  select * into v_o from public.orders where id = p_order_id and customer_id = auth.uid();
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_o.payment_method::text <> 'wallet' or v_o.payment_status::text = 'paid' then raise exception 'INVALID_INPUT'; end if;
  if not exists (select 1 from public.wallet_numbers where wallet = p_wallet and number <> '') then raise exception 'INVALID_INPUT'; end if;
  v_same := nullif(trim(coalesce(p_from_phone, '')), '') is null;
  v_from := case when v_same then v_o.customer_phone else trim(p_from_phone) end;
  if v_from is null or v_from !~ '^[0-9+ ]{8,20}$' then raise exception 'INVALID_PHONE'; end if;
  insert into public.order_wallet_transfers (order_id, wallet, from_phone, same_number)
  values (v_o.id, p_wallet, v_from, v_same)
  on conflict (order_id) do update set wallet = excluded.wallet, from_phone = excluded.from_phone, same_number = excluded.same_number
    where public.order_wallet_transfers.confirmed_at is null;
end $$;
revoke all on function public.order_wallet_submit(uuid, text, text) from public, anon;
grant execute on function public.order_wallet_submit(uuid, text, text) to authenticated;

-- customer: how to pay this order
create or replace function public.my_order_wallet(p_order_id uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('wallet', t.wallet, 'number', n.number, 'from_phone', t.from_phone, 'same_number', t.same_number, 'confirmed', t.confirmed_at is not null)
  from public.order_wallet_transfers t
  join public.orders o on o.id = t.order_id and o.customer_id = auth.uid()
  left join public.wallet_numbers n on n.wallet = t.wallet
  where t.order_id = p_order_id
$$;
revoke all on function public.my_order_wallet(uuid) from public, anon;
grant execute on function public.my_order_wallet(uuid) to authenticated;

-- team: the transfer details of an order
create or replace function public.staff_order_wallet(p_order_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_permission('orders.view');
  return (select jsonb_build_object('wallet', t.wallet, 'from_phone', t.from_phone, 'same_number', t.same_number, 'confirmed', t.confirmed_at is not null)
          from public.order_wallet_transfers t where t.order_id = p_order_id);
end $$;
revoke all on function public.staff_order_wallet(uuid) from public, anon;
grant execute on function public.staff_order_wallet(uuid) to authenticated;

-- team: the money arrived
create or replace function public.staff_confirm_wallet_payment(p_order_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_o public.orders%rowtype;
begin
  perform public.require_permission('orders.confirm_wallet');
  select * into v_o from public.orders where id = p_order_id for update;
  if not found or v_o.payment_method::text <> 'wallet' then raise exception 'NOT_FOUND'; end if;
  if not exists (select 1 from public.order_wallet_transfers where order_id = v_o.id) then raise exception 'INVALID_INPUT'; end if;
  update public.order_wallet_transfers set confirmed_at = now(), confirmed_by = auth.uid() where order_id = v_o.id and confirmed_at is null;
  update public.orders set payment_status = 'paid' where id = v_o.id;
  perform public.notify_user(v_o.customer_id,
    'وصل التحويل لطلبك ' || v_o.reference, 'Transfer received for order ' || v_o.reference,
    'استلمنا المبلغ، شكرًا لك', 'We received your payment, thank you',
    'order', v_o.id, v_o.reference, '/orders/' || v_o.id);
  perform public.audit_write('order.wallet_confirmed', 'order', v_o.id::text, '{}'::jsonb);
end $$;
revoke all on function public.staff_confirm_wallet_payment(uuid) from public, anon;
grant execute on function public.staff_confirm_wallet_payment(uuid) to authenticated;
