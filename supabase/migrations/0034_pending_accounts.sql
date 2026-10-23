-- 0034 New accounts can sign in and browse right away; ordering, repair requests and reviews open
-- once a team member approves the account (customers.review_status = 'approved').
-- Sign-in is unlocked by the account-open Edge Function (checks the password, then confirms the
-- account in Auth). Confirming in Auth no longer approves the account by itself.

create or replace function public._customer_auto_approve() returns trigger
language plpgsql set search_path = public as $$
begin
  return new; -- approval is a team decision now (see staff_mark_account_approved)
end $$;

create or replace function public._require_approved_customer() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := coalesce(to_jsonb(new)->>'customer_id', to_jsonb(new)->>'user_id')::uuid;
begin
  if v_uid is not null
     and exists (select 1 from public.customers where user_id = v_uid and review_status <> 'approved')
     and not exists (select 1 from public.user_roles where user_id = v_uid) then
    raise exception 'ACCOUNT_PENDING';
  end if;
  return new;
end $$;
revoke all on function public._require_approved_customer() from public, anon, authenticated;

create trigger orders_require_approved before insert on public.orders
  for each row execute function public._require_approved_customer();
create trigger repair_requests_require_approved before insert on public.repair_requests
  for each row execute function public._require_approved_customer();
create trigger product_reviews_require_approved before insert on public.product_reviews
  for each row execute function public._require_approved_customer();
