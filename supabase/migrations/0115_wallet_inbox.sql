-- 0115: wallet inbox. The phone that owns the wallets stays in the office; an SMS-forwarder app on it posts each incoming-money SMS to the Edge Function
-- `wallet-sms` (secret token, owner switches it on). Staff only SEE the transfers and link them to the matching order; they can never move money.
-- Refunds of wallet orders are recorded by the accountant only (permission wallet.refund). Nothing here is on by default.
insert into public.permission_catalog (permission, grp, name_ar, name_en, desc_ar, desc_en, sensitive, inert, sort) values
 ('wallet.view', 'orders', 'يشوف تحويلات المحافظ الواصلة', 'See incoming wallet transfers',
  'يشوف أي فلوس وصلت المحفظة لحظة بلحظة ويربطها بالأوردر. مشاهدة فقط، من غير تحويل أو سحب', 'Sees money arriving in the wallets live and links it to the order. View only, no sending or withdrawing', true, false, 64),
 ('wallet.refund', 'system', 'يسجّل مرتجع المحفظة وسحب الفلوس (محاسب)', 'Record wallet refunds and withdrawals (accountant)',
  'المحاسب بس: يسجل مرتجع أوردر اتدفع بمحفظة وعمليات سحب الفلوس ويشوف الرصيد المتوقع', 'Accountant only: records refunds of wallet orders and money withdrawals and sees the expected balance', true, false, 44),
 ('wallet.manage', 'extras', 'يشغّل استقبال المحافظ ومفتاحه', 'Switch the wallet inbox on and manage its key',
  'المالك بس: تشغيل وإيقاف استقبال الرسايل وتجديد المفتاح السري', 'Owner only: turn the SMS inbox on/off and renew the secret key', true, false, 45)
on conflict (permission) do update set name_ar = excluded.name_ar, name_en = excluded.name_en, desc_ar = excluded.desc_ar, desc_en = excluded.desc_en;
insert into public.role_permissions (role, permission) values
 ('owner', 'wallet.view'), ('owner', 'wallet.refund'), ('owner', 'wallet.manage'),
 ('accountant', 'wallet.view'), ('accountant', 'wallet.refund'), ('accountant', 'orders.confirm_wallet'),
 ('manager', 'wallet.view'), ('sales', 'wallet.view'), ('sales', 'orders.confirm_wallet')
on conflict do nothing;

create table if not exists public.wallet_inbox_settings (
  id integer primary key check (id = 1),
  enabled boolean not null default false,
  token_hash text,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users (id) on delete set null
);
alter table public.wallet_inbox_settings enable row level security;
revoke all on public.wallet_inbox_settings from anon, authenticated;
insert into public.wallet_inbox_settings (id) values (1) on conflict do nothing;

create table if not exists public.wallet_transfers (
  id bigserial primary key,
  wallet text not null check (wallet in ('vodafone', 'etisalat', 'instapay', 'unknown')),
  amount_minor bigint check (amount_minor is null or amount_minor > 0),
  sender_phone text,
  reference text,
  raw_text text,
  received_at timestamptz not null default now(),
  dedupe text not null unique,
  status text not null default 'new' check (status in ('new', 'matched', 'ignored')),
  order_id uuid references public.orders (id) on delete set null,
  matched_by uuid references auth.users (id) on delete set null,
  matched_at timestamptz
);
create index if not exists wallet_transfers_recent on public.wallet_transfers (received_at desc);
alter table public.wallet_transfers enable row level security;
revoke all on public.wallet_transfers from anon, authenticated;

create table if not exists public.wallet_refunds (
  id bigserial primary key,
  order_id uuid not null references public.orders (id) on delete restrict,
  wallet text not null,
  amount_minor bigint not null check (amount_minor > 0),
  reference text,
  note text,
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now()
);
alter table public.wallet_refunds enable row level security;
revoke all on public.wallet_refunds from anon, authenticated;

create table if not exists public.wallet_withdrawals (
  id bigserial primary key,
  wallet text not null check (wallet in ('vodafone', 'etisalat', 'instapay')),
  amount_minor bigint not null check (amount_minor > 0),
  note text,
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now()
);
alter table public.wallet_withdrawals enable row level security;
revoke all on public.wallet_withdrawals from anon, authenticated;

-- ---------------------------------------------------------------- reading an SMS (best effort; the raw text is always kept for a person to read)
create or replace function public._wallet_parse(p_from text, p_text text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare t text; wallet text := 'unknown'; amt text; m text[]; sender text; ref text; incoming boolean; otp boolean; r record;
begin
  t := translate(coalesce(p_text, ''), '٠١٢٣٤٥٦٧٨٩٫٬', '0123456789.,');
  if (coalesce(p_from, '') || ' ' || t) ~* 'vodafone|فودافون' then wallet := 'vodafone';
  elsif (coalesce(p_from, '') || ' ' || t) ~* 'etisalat|اتصالات|e&' then wallet := 'etisalat';
  elsif (coalesce(p_from, '') || ' ' || t) ~* 'instapay|انستا|إنستا' then wallet := 'instapay'; end if;
  otp := t ~* 'otp|رمز التحقق|كود التحقق|verification|one.time|password|الرقم السري';
  m := regexp_match(t, '(?:استلمت|استلام|استقبلت|received|مبلغ|amount|اضافة|إضافة|added|credited)[^0-9]{0,30}([0-9][0-9,]*(?:\.[0-9]+)?)', 'i');
  amt := m[1];
  if amt is null then
    m := regexp_match(t, '(?:EGP|LE|جنيه|ج\.م|جم)\s*([0-9][0-9,]*(?:\.[0-9]+)?)|([0-9][0-9,]*(?:\.[0-9]+)?)\s*(?:EGP|LE|جنيه|ج\.م|جم)', 'i');
    amt := coalesce(m[1], m[2]);
  end if;
  incoming := not otp and (t ~* 'received|استلم|استقبل|وصلك|وصل لك|اضافة|إضافة|added|credited|حول لك|حولك|transferred to you|you have received' or (amt is not null and wallet <> 'unknown'));
  for r in select (x)[1] as n from regexp_matches(regexp_replace(t, '[ -]', '', 'g'), '(?:\+?2)?(01[0125][0-9]{8})', 'g') x loop
    if not exists (select 1 from public.wallet_numbers w where w.number <> '' and right(regexp_replace(w.number, '\D', '', 'g'), 10) = right(r.n, 10)) then sender := r.n; exit; end if;
  end loop;
  m := regexp_match(t, '(?:رقم العملية|رقم المعاملة|transaction(?: id| number| no)?|trx|ref(?:erence)?|id)[^0-9]{0,15}([0-9]{6,})', 'i');
  ref := m[1];
  return jsonb_build_object('wallet', wallet, 'amount_minor', case when amt is null then null else round(replace(amt, ',', '')::numeric * 100)::bigint end,
                            'sender', sender, 'ref', ref, 'incoming', incoming);
exception when others then
  return jsonb_build_object('wallet', 'unknown', 'amount_minor', null, 'sender', null, 'ref', null, 'incoming', false);
end $$;
revoke all on function public._wallet_parse(text, text) from public, anon, authenticated;

-- the Edge Function calls this with the service role (the token is checked here, only its hash is stored)
create or replace function public._wallet_inbox_ingest(p_hash text, p_from text, p_text text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.wallet_inbox_settings%rowtype; j jsonb; k text;
begin
  select * into s from public.wallet_inbox_settings where id = 1;
  if not s.enabled or s.token_hash is null or p_hash is null or s.token_hash <> p_hash then return jsonb_build_object('ok', false, 'reason', 'unauthorized'); end if;
  if length(coalesce(p_text, '')) = 0 or length(p_text) > 1000 then return jsonb_build_object('ok', false, 'reason', 'invalid'); end if;
  if (select count(*) from public.wallet_transfers where received_at > now() - interval '1 minute') >= 120 then return jsonb_build_object('ok', false, 'reason', 'busy'); end if;
  j := public._wallet_parse(p_from, p_text);
  k := md5(coalesce(p_from, '') || '|' || p_text || '|' || to_char(date_trunc('minute', now()), 'YYYYMMDDHH24MI'));
  insert into public.wallet_transfers (wallet, amount_minor, sender_phone, reference, raw_text, dedupe, status)
  values (j ->> 'wallet', (j ->> 'amount_minor')::bigint, j ->> 'sender', j ->> 'ref', left(p_text, 500), k, case when (j ->> 'incoming')::boolean then 'new' else 'ignored' end)
  on conflict (dedupe) do nothing;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public._wallet_inbox_ingest(text, text, text) from public, anon, authenticated;
grant execute on function public._wallet_inbox_ingest(text, text, text) to service_role;

-- pending wallet orders that could be this transfer (same amount; sender number matches = exact)
create or replace function public._wallet_candidates(p_amount bigint, p_sender text, p_wallet text) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('order_id', c.id, 'reference', c.reference, 'total_minor', c.total_minor, 'exact',
           p_sender is not null and right(regexp_replace(c.from_phone, '\D', '', 'g'), 10) = right(regexp_replace(p_sender, '\D', '', 'g'), 10)) order by c.created_at), '[]'::jsonb)
  from (select o.id, o.reference, o.total_minor, o.created_at, t.from_phone from public.orders o
          join public.order_wallet_transfers t on t.order_id = o.id and t.confirmed_at is null
         where p_amount is not null and o.payment_method::text = 'wallet' and o.payment_status::text = 'unpaid' and o.status::text <> 'cancelled'
           and o.total_minor = p_amount and (p_wallet = 'unknown' or t.wallet = p_wallet)
         order by o.created_at desc limit 5) c
$$;
revoke all on function public._wallet_candidates(bigint, text, text) from public, anon, authenticated;

create or replace function public.wallet_inbox_list(p_limit int default 60) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_permission('wallet.view');
  return jsonb_build_object('enabled', (select enabled from public.wallet_inbox_settings where id = 1),
    'transfers', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'wallet', x.wallet, 'amount_minor', x.amount_minor, 'sender', x.sender_phone, 'reference', x.reference,
              'at', x.received_at, 'status', x.status, 'order', (select o.reference from public.orders o where o.id = x.order_id),
              'raw', case when x.amount_minor is null then x.raw_text end,
              'suggest', case when x.status = 'new' then public._wallet_candidates(x.amount_minor, x.sender_phone, x.wallet) else '[]'::jsonb end) order by x.received_at desc)
            from (select * from public.wallet_transfers where status <> 'ignored' order by received_at desc limit greatest(1, least(coalesce(p_limit, 60), 200))) x), '[]'::jsonb));
end $$;
revoke all on function public.wallet_inbox_list(int) from public, anon;
grant execute on function public.wallet_inbox_list(int) to authenticated;

-- the person confirms: this transfer pays this order (the amount must equal the order total)
create or replace function public.wallet_transfer_match(p_transfer bigint, p_order uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t public.wallet_transfers%rowtype; o public.orders%rowtype;
begin
  perform public.require_permission('wallet.view');
  perform public.require_permission('orders.confirm_wallet');
  select * into t from public.wallet_transfers where id = p_transfer for update;
  if not found or t.status <> 'new' then raise exception 'NOT_FOUND'; end if;
  select * into o from public.orders where id = p_order for update;
  if not found or o.payment_method::text <> 'wallet' or o.payment_status::text <> 'unpaid' then raise exception 'INVALID_INPUT'; end if;
  if t.amount_minor is distinct from o.total_minor then raise exception 'AMOUNT_MISMATCH'; end if;
  perform public.staff_confirm_wallet_payment(o.id);
  update public.wallet_transfers set status = 'matched', order_id = o.id, matched_by = auth.uid(), matched_at = now() where id = t.id;
  perform public.audit_write('wallet.match', 'order', o.id::text, jsonb_build_object('transfer', t.id, 'amount_minor', t.amount_minor));
end $$;
revoke all on function public.wallet_transfer_match(bigint, uuid) from public, anon;
grant execute on function public.wallet_transfer_match(bigint, uuid) to authenticated;

-- accountant / owner: a transfer that is not an order payment (hide it, it stays counted as money received)
create or replace function public.wallet_transfer_ignore(p_transfer bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.require_permission('wallet.refund');
  update public.wallet_transfers set status = 'ignored', matched_by = auth.uid(), matched_at = now() where id = p_transfer and status = 'new';
  perform public.audit_write('wallet.ignore', 'system', p_transfer::text, '{}'::jsonb);
end $$;
revoke all on function public.wallet_transfer_ignore(bigint) from public, anon;
grant execute on function public.wallet_transfer_ignore(bigint) to authenticated;

-- ---------------------------------------------------------------- refunds: accountant only
create or replace function public.wallet_refund(p_order uuid, p_amount_minor bigint, p_reference text, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare o public.orders%rowtype; w text; v_done bigint;
begin
  perform public.require_permission('wallet.refund');
  select * into o from public.orders where id = p_order for update;
  if not found or o.payment_method::text <> 'wallet' or o.payment_status::text not in ('paid', 'partially_refunded') then raise exception 'INVALID_INPUT'; end if;
  select wallet into w from public.order_wallet_transfers where order_id = o.id;
  select coalesce(sum(amount_minor), 0) into v_done from public.wallet_refunds where order_id = o.id;
  if p_amount_minor is null or p_amount_minor <= 0 or p_amount_minor + v_done > o.total_minor then raise exception 'INVALID_INPUT'; end if;
  if p_reference is not null and length(p_reference) > 60 then raise exception 'INVALID_INPUT'; end if;
  insert into public.wallet_refunds (order_id, wallet, amount_minor, reference, note, created_by)
  values (o.id, coalesce(w, 'unknown'), p_amount_minor, nullif(trim(p_reference), ''), left(p_note, 300), auth.uid());
  update public.orders set payment_status = case when p_amount_minor + v_done >= o.total_minor then 'refunded' else 'partially_refunded' end::public.payment_status where id = o.id;
  perform public.notify_user(o.customer_id, 'تم رد مبلغ لطلبك ' || o.reference, 'A refund was sent for order ' || o.reference,
    'رجّعنا لك ' || round(p_amount_minor / 100.0, 2) || ' ج.م على محفظتك', 'We sent you ' || round(p_amount_minor / 100.0, 2) || ' EGP back to your wallet',
    'order', o.id, o.reference, '/orders/' || o.id);
  perform public.audit_write('wallet.refund', 'order', o.id::text, jsonb_build_object('amount_minor', p_amount_minor, 'reference', nullif(trim(p_reference), '')));
end $$;
revoke all on function public.wallet_refund(uuid, bigint, text, text) from public, anon;
grant execute on function public.wallet_refund(uuid, bigint, text, text) to authenticated;

create or replace function public.wallet_withdrawal_log(p_wallet text, p_amount_minor bigint, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.require_permission('wallet.refund');
  if p_wallet not in ('vodafone', 'etisalat', 'instapay') or p_amount_minor is null or p_amount_minor <= 0 then raise exception 'INVALID_INPUT'; end if;
  insert into public.wallet_withdrawals (wallet, amount_minor, note, created_by) values (p_wallet, p_amount_minor, left(p_note, 300), auth.uid());
  perform public.audit_write('wallet.withdrawal', 'system', p_wallet, jsonb_build_object('amount_minor', p_amount_minor));
end $$;
revoke all on function public.wallet_withdrawal_log(text, bigint, text) from public, anon;
grant execute on function public.wallet_withdrawal_log(text, bigint, text) to authenticated;

-- expected balance per wallet: money received (matched or not) - refunds - withdrawals. The accountant compares it with the real wallet balance.
create or replace function public.wallet_balance() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_permission('wallet.refund');
  return (select coalesce(jsonb_agg(jsonb_build_object('wallet', w.wallet,
      'received_minor', coalesce((select sum(amount_minor) from public.wallet_transfers t where t.wallet = w.wallet and t.status <> 'ignored' or (t.wallet = w.wallet and t.status = 'ignored' and false)), 0),
      'unlinked_minor', coalesce((select sum(amount_minor) from public.wallet_transfers t where t.wallet = w.wallet and t.status = 'new'), 0),
      'refunds_minor', coalesce((select sum(amount_minor) from public.wallet_refunds r where r.wallet = w.wallet), 0),
      'withdrawn_minor', coalesce((select sum(amount_minor) from public.wallet_withdrawals d where d.wallet = w.wallet), 0)) order by w.wallet), '[]'::jsonb)
    from public.wallet_numbers w);
end $$;
revoke all on function public.wallet_balance() from public, anon;
grant execute on function public.wallet_balance() to authenticated;

-- ---------------------------------------------------------------- owner: switch on/off and the secret key
create or replace function public.wallet_inbox_state() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_permission('wallet.manage');
  return (select jsonb_build_object('enabled', enabled, 'has_token', token_hash is not null, 'last_received', (select max(received_at) from public.wallet_transfers))
            from public.wallet_inbox_settings where id = 1);
end $$;
revoke all on function public.wallet_inbox_state() from public, anon;
grant execute on function public.wallet_inbox_state() to authenticated;

create or replace function public.wallet_inbox_set(p_enabled boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.require_permission('wallet.manage');
  if p_enabled and (select token_hash from public.wallet_inbox_settings where id = 1) is null then raise exception 'INVALID_INPUT'; end if;
  update public.wallet_inbox_settings set enabled = p_enabled, updated_at = now(), updated_by = auth.uid() where id = 1;
  perform public.audit_write('wallet.inbox', 'system', 'inbox', jsonb_build_object('enabled', p_enabled));
end $$;
revoke all on function public.wallet_inbox_set(boolean) from public, anon;
grant execute on function public.wallet_inbox_set(boolean) to authenticated;

-- a new random key; it is shown ONCE here and only its hash is stored. The old key stops working at once.
create or replace function public.wallet_inbox_token_rotate() returns text
language plpgsql security definer set search_path = public as $$
declare tok text := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
begin
  perform public.require_permission('wallet.manage');
  update public.wallet_inbox_settings set token_hash = encode(sha256(convert_to(tok, 'UTF8')), 'hex'), updated_at = now(), updated_by = auth.uid() where id = 1;
  perform public.audit_write('wallet.inbox_key', 'system', 'inbox', '{}'::jsonb);
  return tok;
end $$;
revoke all on function public.wallet_inbox_token_rotate() from public, anon;
grant execute on function public.wallet_inbox_token_rotate() to authenticated;
