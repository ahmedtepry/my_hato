-- 0127: VAT percent shown on invoices (prices already include it). 0 = off. Same permission as the invoice look.
insert into public.application_settings (key, value, description) values
  ('receipt_vat', '0', 'VAT percent included in prices, shown on invoices (0 = off)')
on conflict (key) do nothing;

create or replace function public.receipt_vat_get() returns numeric
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_auth();
  if not (public.is_staff() or public.has_permission('receipt.style')) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return coalesce((select (value #>> '{}')::numeric from public.application_settings where key = 'receipt_vat'), 0);
end $$;

create or replace function public.receipt_vat_set(p_pct numeric) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.require_permission('receipt.style');
  if p_pct is null or p_pct < 0 or p_pct > 100 then raise exception 'INVALID_INPUT'; end if;
  insert into public.application_settings (key, value, updated_by, updated_at) values ('receipt_vat', to_jsonb(p_pct), auth.uid(), now())
  on conflict (key) do update set value = excluded.value, updated_by = excluded.updated_by, updated_at = now();
  perform public.audit_write('receipt.vat', 'settings', 'receipt', jsonb_build_object('pct', p_pct));
end $$;
revoke all on function public.receipt_vat_get(), public.receipt_vat_set(numeric) from public, anon;
grant execute on function public.receipt_vat_get(), public.receipt_vat_set(numeric) to authenticated;
