-- 0036 When a customer accepts or rejects a repair price, the team gets an alert straight away
-- (phone notification + in the console), not only an email to the service mailbox.
create or replace function public._alert_quote_decision() returns trigger language plpgsql security definer set search_path = public as $$
declare v_r public.repair_requests%rowtype; v_ok boolean := new.decision = 'approved'; v_amt text;
begin
  if new.via <> 'customer_app' then return null; end if;
  select * into v_r from public.repair_requests where id = new.repair_id;
  v_amt := public.fmt_egp(new.quoted_amount_minor);
  perform public._notify_staff('repairs.manage',
    case when v_ok then '✅ العميل وافق على السعر — ' else '❌ العميل رفض السعر — ' end || coalesce(v_r.reference, ''),
    case when v_ok then '✅ Customer accepted the price — ' else '❌ Customer rejected the price — ' end || coalesce(v_r.reference, ''),
    coalesce(v_r.contact_name, '') || ' — ' || coalesce(v_r.device_brand, '') || ' ' || coalesce(v_r.device_model, '') || ' — ' || v_amt || ' ج.م',
    coalesce(v_r.contact_name, '') || ' — EGP ' || v_amt,
    v_r.reference);
  return null;
end $$;
revoke all on function public._alert_quote_decision() from public, anon, authenticated;
create trigger repair_approvals_alert after insert on public.repair_approvals
  for each row execute function public._alert_quote_decision();
