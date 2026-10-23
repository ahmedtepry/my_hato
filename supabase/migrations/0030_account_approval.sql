-- 0030 Account approval: new customer accounts wait for a team member (support.manage) to accept or
-- reject them from the console. Accepting confirms the account in Supabase Auth (done by the
-- admin-customer Edge Function with the service role) and then calls staff_mark_account_approved().
-- Rejected accounts stay unable to sign in; a rejected account can still be accepted later.
-- The team gets an alert for every new sign-up.

alter table public.customers
  add column if not exists review_status text not null default 'pending'
    check (review_status in ('pending', 'approved', 'rejected')),
  add column if not exists reviewed_by uuid references auth.users(id),
  add column if not exists reviewed_at timestamptz,
  add column if not exists reject_reason text;

-- accounts that can already sign in are approved
update public.customers c set review_status = 'approved'
 where exists (select 1 from auth.users u where u.id = c.user_id
                and (u.email_confirmed_at is not null or u.phone_confirmed_at is not null));

-- an account confirmed any other way (e.g. from the Supabase dashboard) counts as approved
create or replace function public._customer_auto_approve() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.email_verified and not coalesce(old.email_verified, false) and new.review_status = 'pending' then
    new.review_status := 'approved';
    new.reviewed_at := coalesce(new.reviewed_at, now());
  end if;
  return new;
end $$;
create trigger customers_auto_approve before update of email_verified on public.customers
  for each row execute function public._customer_auto_approve();

-- a new account that Auth already confirmed (phone / email) needs no review
create or replace function public._customer_initial_review() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.email_verified or exists (select 1 from auth.users u where u.id = new.user_id
                                    and (u.email_confirmed_at is not null or u.phone_confirmed_at is not null)) then
    new.review_status := 'approved';
  end if;
  return new;
end $$;
create trigger customers_initial_review before insert on public.customers
  for each row execute function public._customer_initial_review();

-- list accounts by review status (team members excluded)
create or replace function public.staff_accounts(p_status text default 'pending')
returns table (user_id uuid, customer_code text, full_name text, username text, phone text, email text,
               review_status text, reject_reason text, reviewed_at timestamptz, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_permission('support.manage');
  if p_status not in ('pending', 'approved', 'rejected') then raise exception 'INVALID_INPUT'; end if;
  return query
    select c.user_id, c.customer_code, coalesce(nullif(c.full_name, ''), p.full_name), c.username,
           coalesce(c.phone, p.contact_phone), c.email, c.review_status, c.reject_reason, c.reviewed_at, c.created_at
      from public.customers c
      left join public.profiles p on p.id = c.user_id
     where c.review_status = p_status
       and not exists (select 1 from public.user_roles ur where ur.user_id = c.user_id)
     order by case when p_status = 'pending' then c.created_at end asc,
              coalesce(c.reviewed_at, c.created_at) desc
     limit 200;
end $$;

create or replace function public.staff_pending_accounts_count()
returns int language sql stable security definer set search_path = public as $$
  select case when public.has_permission('support.manage') then
    (select count(*)::int from public.customers c
      where c.review_status = 'pending'
        and not exists (select 1 from public.user_roles ur where ur.user_id = c.user_id))
  else 0 end
$$;

-- called by the admin-customer Edge Function (as the staff member) after the Auth account is confirmed
create or replace function public.staff_mark_account_approved(p_user_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v_code text;
begin
  perform public.require_permission('support.manage');
  update public.customers
     set review_status = 'approved', reviewed_by = auth.uid(), reviewed_at = now(), reject_reason = null
   where user_id = p_user_id
  returning customer_code into v_code;
  if v_code is null then raise exception 'NOT_FOUND'; end if;
  perform public.notify_user(p_user_id, '🎉 أهلاً بيك في My Hatō', '🎉 Welcome to My Hatō',
    'حسابك اتفعّل وتقدر تطلب وتتابع طلباتك من التطبيق.', 'Your account is active. You can now order and track your orders in the app.',
    'system', null, v_code, '/');
  perform public.audit_write('customer.approve', 'customer', v_code, jsonb_build_object('user_id', p_user_id));
  return v_code;
end $$;

create or replace function public.staff_reject_account(p_user_id uuid, p_reason text default null)
returns text language plpgsql security definer set search_path = public as $$
declare v_code text;
begin
  perform public.require_permission('support.manage');
  if exists (select 1 from public.user_roles where user_id = p_user_id) then raise exception 'FORBIDDEN'; end if;
  update public.customers
     set review_status = 'rejected', reviewed_by = auth.uid(), reviewed_at = now(),
         reject_reason = nullif(left(trim(coalesce(p_reason, '')), 300), '')
   where user_id = p_user_id and review_status = 'pending'
  returning customer_code into v_code;
  if v_code is null then raise exception 'ALREADY_DECIDED'; end if;
  perform public.audit_write('customer.reject', 'customer', v_code, jsonb_build_object('user_id', p_user_id, 'reason', p_reason));
  return v_code;
end $$;

-- alert the team for every new sign-up waiting for approval
create or replace function public._alert_new_account() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.review_status = 'pending' then
    perform public._notify_staff('support.manage',
      '👤 حساب جديد محتاج تفعيل', '👤 New account to approve',
      coalesce(nullif(new.full_name, ''), new.username, new.email, '') || coalesce(' — ' || new.phone, ''),
      coalesce(nullif(new.full_name, ''), new.username, new.email, '') || coalesce(' — ' || new.phone, ''),
      new.customer_code);
  end if;
  return null;
end $$;
create trigger customers_alert_staff after insert on public.customers
  for each row execute function public._alert_new_account();

revoke all on function public._customer_initial_review() from public, anon, authenticated;
revoke all on function public._customer_auto_approve() from public, anon, authenticated;
revoke all on function public._alert_new_account() from public, anon, authenticated;
revoke all on function public.staff_accounts(text) from public, anon;
grant execute on function public.staff_accounts(text) to authenticated;
revoke all on function public.staff_pending_accounts_count() from public, anon;
grant execute on function public.staff_pending_accounts_count() to authenticated;
revoke all on function public.staff_mark_account_approved(uuid) from public, anon;
grant execute on function public.staff_mark_account_approved(uuid) to authenticated;
revoke all on function public.staff_reject_account(uuid, text) from public, anon;
grant execute on function public.staff_reject_account(uuid, text) to authenticated;
