-- 0116: an incoming transfer notifies everyone who may see wallet transfers, with the amount, wallet, sender and reference; plus a tidier balance query.
create or replace function public._wallet_inbox_ingest(p_hash text, p_from text, p_text text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.wallet_inbox_settings%rowtype; j jsonb; k text; v_id bigint; v_new boolean; v_amt bigint; v_wal text; v_cand jsonb; v_wal_ar text; v_wal_en text; v_ord text;
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
    v_wal_ar := case v_wal when 'vodafone' then 'فودافون كاش' when 'etisalat' then 'اتصالات كاش' when 'instapay' then 'إنستا باي' else 'المحفظة' end;
    v_wal_en := case v_wal when 'vodafone' then 'Vodafone Cash' when 'etisalat' then 'Etisalat Cash' when 'instapay' then 'InstaPay' else 'the wallet' end;
    v_cand := public._wallet_candidates(v_amt, j ->> 'sender', v_wal);
    v_ord := (select c ->> 'reference' from jsonb_array_elements(v_cand) c where (c ->> 'exact')::boolean limit 1);
    perform public._notify_staff('wallet.view',
      '💰 وصل تحويل ' || coalesce(round(v_amt / 100.0, 2)::text || ' ج.م', '') || ' على ' || v_wal_ar,
      '💰 Transfer received ' || coalesce(round(v_amt / 100.0, 2)::text || ' EGP', '') || ' on ' || v_wal_en,
      coalesce('من ' || (j ->> 'sender'), 'مرسل غير معروف') || coalesce(' - رقم العملية ' || (j ->> 'ref'), '') || coalesce(' - يطابق الأوردر ' || v_ord, ''),
      coalesce('From ' || (j ->> 'sender'), 'Unknown sender') || coalesce(' - ref ' || (j ->> 'ref'), '') || coalesce(' - matches order ' || v_ord, ''),
      v_ord);
  end if;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public._wallet_inbox_ingest(text, text, text) from public, anon, authenticated;
grant execute on function public._wallet_inbox_ingest(text, text, text) to service_role;

create or replace function public.wallet_balance() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_permission('wallet.refund');
  return (select coalesce(jsonb_agg(jsonb_build_object('wallet', w.wallet,
      'received_minor', coalesce((select sum(amount_minor) from public.wallet_transfers t where t.wallet = w.wallet and t.status in ('new', 'matched')), 0),
      'unlinked_minor', coalesce((select sum(amount_minor) from public.wallet_transfers t where t.wallet = w.wallet and t.status = 'new'), 0),
      'refunds_minor', coalesce((select sum(amount_minor) from public.wallet_refunds r where r.wallet = w.wallet), 0),
      'withdrawn_minor', coalesce((select sum(amount_minor) from public.wallet_withdrawals d where d.wallet = w.wallet), 0)) order by w.wallet), '[]'::jsonb)
    from public.wallet_numbers w);
end $$;
revoke all on function public.wallet_balance() from public, anon;
grant execute on function public.wallet_balance() to authenticated;
