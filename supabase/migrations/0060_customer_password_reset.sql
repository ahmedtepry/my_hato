-- 0060: (1) the customers search also finds a phone typed in any format (01012345678, +201012345678, 1012345678);
--       (2) new permission customers.reset_password: the owner (and anyone the owner gives it to) can set a new password for a CUSTOMER account.
--           Team and owner accounts can never be changed this way. The customer is signed out everywhere and gets a notification.
insert into public.role_permissions (role, permission) values ('owner', 'customers.reset_password') on conflict do nothing;
insert into public.permission_catalog (permission, grp, name_ar, name_en, desc_ar, desc_en, sensitive, inert, sort)
values ('customers.reset_password', 'system', 'يغيّر الرقم السري للعميل', 'Reset a customer password',
        'يحط رقم سري جديد لحساب عميل، والعميل بيتسجّل خروج من كل أجهزته',
        'Sets a new password on a customer account; the customer is signed out of every device', true, false, 49)
on conflict (permission) do nothing;

create or replace function public.staff_customers(p_search text default null, p_limit int default 200, p_offset int default 0)
returns table (user_id uuid, customer_code text, full_name text, username text, phone text, email text, review_status text,
               created_at timestamptz, last_sign_in_at timestamptz, email_confirmed boolean, provider text,
               orders_count int, delivered_total_minor bigint, last_order_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare
  v_q text := nullif(trim(coalesce(p_search, '')), '');
  -- digits only, without a leading 0 / 20 / 0020, so every way of writing the same number matches
  v_d text := regexp_replace(regexp_replace(coalesce(p_search, ''), '\D', '', 'g'), '^(0020|20|0)', '');
begin
  perform public.require_permission('support.manage');
  return query
    select c.user_id, c.customer_code, coalesce(nullif(c.full_name, ''), p.full_name), c.username,
           coalesce(c.phone, p.contact_phone), coalesce(c.email, u.email), c.review_status, c.created_at,
           u.last_sign_in_at, (u.email_confirmed_at is not null), (u.raw_app_meta_data ->> 'provider'),
           coalesce(o.n, 0)::int, coalesce(o.total, 0)::bigint, o.last_at
      from public.customers c
      left join public.profiles p on p.id = c.user_id
      left join auth.users u on u.id = c.user_id
      left join lateral (
        select count(*) as n, sum(x.total_minor) filter (where x.status = 'delivered') as total, max(x.created_at) as last_at
          from public.orders x where x.customer_id = c.user_id) o on true
     where not exists (select 1 from public.user_roles ur where ur.user_id = c.user_id)
       and (v_q is null
            or coalesce(nullif(c.full_name, ''), p.full_name, '') ilike '%' || v_q || '%'
            or coalesce(c.email, u.email, '') ilike '%' || v_q || '%'
            or coalesce(c.phone, p.contact_phone, '') ilike '%' || v_q || '%'
            or (length(v_d) >= 3 and regexp_replace(coalesce(c.phone, p.contact_phone, ''), '\D', '', 'g') like '%' || v_d || '%')
            or coalesce(c.username, '') ilike '%' || v_q || '%'
            or coalesce(c.customer_code, '') ilike '%' || v_q || '%')
     order by c.created_at desc
     limit least(greatest(coalesce(p_limit, 200), 1), 500) offset greatest(coalesce(p_offset, 0), 0);
end $$;

create or replace function public.staff_set_customer_password(p_user uuid, p_password text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.require_permission('customers.reset_password');
  if p_user is null or p_password is null or length(p_password) < 8 or length(p_password) > 72
     or p_password !~ '[[:alpha:]]' or p_password !~ '[0-9]' then
    raise exception 'INVALID_INPUT';
  end if;
  -- customer accounts only: never a team member or the owner
  if not exists (select 1 from public.customers c where c.user_id = p_user)
     or exists (select 1 from public.user_roles ur where ur.user_id = p_user) then
    raise exception 'FORBIDDEN';
  end if;
  update auth.users set encrypted_password = extensions.crypt(p_password, extensions.gen_salt('bf')), updated_at = now()
   where id = p_user;
  if not found then raise exception 'NOT_FOUND'; end if;
  delete from auth.sessions where user_id = p_user;   -- signed out everywhere
  perform public.notify_user(p_user, 'تم تغيير كلمة السر', 'Your password was changed',
    'فريق المتجر غيّر كلمة سر حسابك. استخدم الكلمة الجديدة اللي اتبعتتلك في الدخول.',
    'The store team changed your account password. Use the new password you were given to sign in.', 'account', null, null, '/');
  perform public.audit_write('customer.password_reset', 'customer', p_user::text, '{}'::jsonb);   -- the password itself is never logged
end $$;
revoke all on function public.staff_set_customer_password(uuid, text) from public, anon;
grant execute on function public.staff_set_customer_password(uuid, text) to authenticated;
