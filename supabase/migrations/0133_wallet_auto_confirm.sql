-- 0133: a wallet order is confirmed by the system when the REAL wallet SMS arrives (owner switch, off by default).
-- Safety: the SMS sender must be a name (e.g. "VF-Cash"), not a phone number (a customer could text the office phone);
-- the amount equals the order total; the sender number equals the number the customer declared; exactly one such order;
-- the transaction number was never used before. Anything else stays 'new' for staff to review.
alter table public.wallet_inbox_settings add column if not exists auto_confirm boolean not null default false;

create or replace function public._wallet_auto_confirm(p_transfer bigint) returns boolean
language plpgsql security definer set search_path = public as $$
declare t public.wallet_transfers%rowtype; v_c jsonb; v_o public.orders%rowtype;
begin
  select * into t from public.wallet_transfers where id = p_transfer for update;
  if not found or t.status <> 'new' or t.amount_minor is null or t.sender_phone is null or t.reference is null then return false; end if;
  if exists (select 1 from public.wallet_transfers x where x.reference = t.reference and x.id <> t.id and x.status = 'matched') then return false; end if;
  select jsonb_agg(c) into v_c from jsonb_array_elements(public._wallet_candidates(t.amount_minor, t.sender_phone, t.wallet)) c where (c ->> 'exact')::boolean;
  if v_c is null or jsonb_array_length(v_c) <> 1 then return false; end if;
  select * into v_o from public.orders where id = (v_c -> 0 ->> 'order_id')::uuid for update;
  if not found or v_o.payment_status::text <> 'unpaid' or v_o.total_minor <> t.amount_minor then return false; end if;
  update public.order_wallet_transfers set confirmed_at = now(), confirmed_by = null where order_id = v_o.id and confirmed_at is null;
  update public.orders set payment_status = 'paid' where id = v_o.id;
  update public.wallet_transfers set status = 'matched', order_id = v_o.id, matched_at = now() where id = t.id;
  perform public.notify_user(v_o.customer_id,
    'وصل التحويل لطلبك ' || v_o.reference, 'Transfer received for order ' || v_o.reference,
    'استلمنا المبلغ، شكرًا لك', 'We received your payment, thank you',
    'order', v_o.id, v_o.reference, '/orders/' || v_o.id);
  perform public.audit_write('wallet.auto_match', 'order', v_o.id::text, jsonb_build_object('transfer', t.id, 'amount_minor', t.amount_minor, 'ref', t.reference));
  return true;
end $$;
revoke all on function public._wallet_auto_confirm(bigint) from public, anon, authenticated;

create or replace function public._wallet_inbox_ingest(p_hash text, p_from text, p_text text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.wallet_inbox_settings%rowtype; j jsonb; k text; v_id bigint; v_new boolean; v_amt bigint; v_wal text; v_cand jsonb; v_wal_ar text; v_wal_en text; v_ord text; v_auto boolean := false;
begin
  select * into s from public.wallet_inbox_settings where id = 1;
  if not s.enabled or s.token_hash is null or p_hash is null or s.token_hash <> p_hash then return jsonb_build_object('ok', false, 'reason', 'unauthorized'); end if;
  if length(coalesce(p_text, '')) = 0 or length(p_text) > 1000 then return jsonb_build_object('ok', false, 'reason', 'invalid'); end if;
  if (select count(*) from public.wallet_transfers where received_at > now() - interval '1 minute') >= 120 then return jsonb_build_object('ok', false, 'reason', 'busy'); end if;
  j := public._wallet_parse(p_from, p_text);
  k := md5(coalesce(p_from, '') || '|' || p_text || '|' || to_char(date_trunc('minute', now()), 'YYYYMMDDHH24MI'));
  v_new := (j ->> 'incoming')::boolean;
  insert into public.wallet_transfers (wallet, amount_minor, sender_phone, reference, raw_text, dedupe, status)
  values (j ->> 'wallet', (j ->> 'amount_minor')::bigint, j ->> 'sender', j ->> 'ref', left(p_text, 500), k, case when v_new then 'new' else 'ignored' end)
  on conflict (dedupe) do nothing returning id into v_id;
  if v_id is not null and v_new then
    v_amt := (j ->> 'amount_minor')::bigint; v_wal := j ->> 'wallet';
    if s.auto_confirm and j ->> 'wallet' <> 'unknown' and coalesce(p_from, '') ~ '[A-Za-z]' and coalesce(p_from, '') !~ '^\+?[0-9 ]+$' then
      v_auto := public._wallet_auto_confirm(v_id);
    end if;
    v_wal_ar := case v_wal when 'vodafone' then 'فودافون كاش' when 'etisalat' then 'اتصالات كاش' when 'instapay' then 'إنستا باي' else 'المحفظة' end;
    v_wal_en := case v_wal when 'vodafone' then 'Vodafone Cash' when 'etisalat' then 'Etisalat Cash' when 'instapay' then 'InstaPay' else 'the wallet' end;
    v_cand := public._wallet_candidates(v_amt, j ->> 'sender', v_wal);
    v_ord := (select c ->> 'reference' from jsonb_array_elements(v_cand) c where (c ->> 'exact')::boolean limit 1);
    perform public._notify_staff('wallet.view',
      case when v_auto then '✅ اتأكد الدفع تلقائي ' else '💰 وصل تحويل ' end || coalesce(round(v_amt / 100.0, 2)::text || ' ج.م', '') || ' على ' || v_wal_ar,
      case when v_auto then '✅ Payment auto-confirmed ' else '💰 Transfer received ' end || coalesce(round(v_amt / 100.0, 2)::text || ' EGP', '') || ' on ' || v_wal_en,
      coalesce('من ' || (j ->> 'sender'), 'مرسل غير معروف') || coalesce(' - رقم العملية ' || (j ->> 'ref'), '') || coalesce(' - يطابق الأوردر ' || v_ord, ''),
      coalesce('From ' || (j ->> 'sender'), 'Unknown sender') || coalesce(' - ref ' || (j ->> 'ref'), '') || coalesce(' - matches order ' || v_ord, ''),
      v_ord);
  end if;
  return jsonb_build_object('ok', true, 'auto', v_auto);
end $$;
revoke all on function public._wallet_inbox_ingest(text, text, text) from public, anon, authenticated;
grant execute on function public._wallet_inbox_ingest(text, text, text) to service_role;

create or replace function public.wallet_inbox_state() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_permission('wallet.manage');
  return (select jsonb_build_object('enabled', enabled, 'has_token', token_hash is not null, 'auto_confirm', auto_confirm, 'last_received', (select max(received_at) from public.wallet_transfers))
            from public.wallet_inbox_settings where id = 1);
end $$;

create or replace function public.wallet_inbox_set_auto(p_on boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.require_permission('wallet.manage');
  update public.wallet_inbox_settings set auto_confirm = p_on, updated_at = now(), updated_by = auth.uid() where id = 1;
  perform public.audit_write('wallet.auto_confirm', 'system', 'inbox', jsonb_build_object('on', p_on));
end $$;
revoke all on function public.wallet_inbox_set_auto(boolean) from public, anon;
grant execute on function public.wallet_inbox_set_auto(boolean) to authenticated;
