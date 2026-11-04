-- The customer can attach a screenshot of the wallet transfer. Private bucket: only the customer and staff who can view orders can see it.
alter table public.order_wallet_transfers add column if not exists proof_path text check (proof_path is null or length(proof_path) <= 200);

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('transfer-proofs', 'transfer-proofs', false, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;

drop policy if exists "transfer proofs customer upload" on storage.objects;
create policy "transfer proofs customer upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'transfer-proofs' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "transfer proofs customer replace" on storage.objects;
create policy "transfer proofs customer replace" on storage.objects for update to authenticated
  using (bucket_id = 'transfer-proofs' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'transfer-proofs' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "transfer proofs read" on storage.objects;
create policy "transfer proofs read" on storage.objects for select to authenticated
  using (bucket_id = 'transfer-proofs' and ((storage.foldername(name))[1] = auth.uid()::text or public.has_permission('orders.view')));

create or replace function public.order_wallet_proof_set(p_order_id uuid, p_path text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.require_auth();
  if p_path is null or p_path !~ ('^' || auth.uid()::text || '/[A-Za-z0-9._-]+$') then raise exception 'INVALID_INPUT'; end if;
  update public.order_wallet_transfers t set proof_path = p_path
   where t.order_id = p_order_id and t.confirmed_at is null
     and exists (select 1 from public.orders o where o.id = t.order_id and o.customer_id = auth.uid());
  if not found then raise exception 'NOT_FOUND'; end if;
end $$;
revoke all on function public.order_wallet_proof_set(uuid, text) from public, anon;
grant execute on function public.order_wallet_proof_set(uuid, text) to authenticated;

create or replace function public.my_order_wallet(p_order_id uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('wallet', t.wallet, 'number', n.number, 'from_phone', t.from_phone, 'same_number', t.same_number, 'confirmed', t.confirmed_at is not null, 'proof_path', t.proof_path)
  from public.order_wallet_transfers t
  join public.orders o on o.id = t.order_id and o.customer_id = auth.uid()
  left join public.wallet_numbers n on n.wallet = t.wallet
  where t.order_id = p_order_id
$$;

create or replace function public.staff_order_wallet(p_order_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_permission('orders.view');
  return (select jsonb_build_object('wallet', t.wallet, 'from_phone', t.from_phone, 'same_number', t.same_number, 'confirmed', t.confirmed_at is not null, 'proof_path', t.proof_path)
          from public.order_wallet_transfers t where t.order_id = p_order_id);
end $$;
