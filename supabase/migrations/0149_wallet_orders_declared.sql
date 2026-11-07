-- Owner assistant: which wallet number did the customer say he would pay from, per wallet-paid order.
create or replace function public.wallet_orders_declared(p_ref text default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_permission('wallet.view');
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'order', o.reference, 'customer', o.customer_name, 'customer_phone', o.customer_phone,
      'total_minor', o.total_minor, 'payment_status', o.payment_status, 'order_status', o.status,
      'wallet', w.wallet, 'transfer_from_phone', w.from_phone, 'same_as_customer_phone', w.same_number,
      'has_proof_image', w.proof_path is not null, 'confirmed', w.confirmed_at is not null,
      'created_at', o.created_at,
      'received_transfers_from_that_number', (select coalesce(jsonb_agg(jsonb_build_object('amount_minor', t.amount_minor, 'at', t.received_at, 'status', t.status)), '[]'::jsonb)
         from public.wallet_transfers t where t.sender_phone is not null and right(regexp_replace(t.sender_phone,'\D','','g'), 10) = right(regexp_replace(w.from_phone,'\D','','g'), 10))
    ) order by o.created_at desc)
    from public.order_wallet_transfers w join public.orders o on o.id = w.order_id
    where p_ref is null or o.reference ilike '%' || p_ref || '%'
    limit 10), '[]'::jsonb);
end $$;
revoke execute on function public.wallet_orders_declared(text) from public, anon;
grant execute on function public.wallet_orders_declared(text) to authenticated;
