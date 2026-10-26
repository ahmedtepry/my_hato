-- 0059: a full customers list for the console: every account with its email and details (phone, user name, sign-up and last sign-in dates,
-- how it signs in, how many orders and how much was bought), searchable, plus a one-tap list of all emails.
-- Same permission as the accounts page (support.manage). Team members are not listed.
create or replace function public.staff_customers(p_search text default null, p_limit int default 200, p_offset int default 0)
returns table (user_id uuid, customer_code text, full_name text, username text, phone text, email text, review_status text,
               created_at timestamptz, last_sign_in_at timestamptz, email_confirmed boolean, provider text,
               orders_count int, delivered_total_minor bigint, last_order_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare v_q text := nullif(trim(coalesce(p_search, '')), '');
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
            or coalesce(c.username, '') ilike '%' || v_q || '%'
            or coalesce(c.customer_code, '') ilike '%' || v_q || '%')
     order by c.created_at desc
     limit least(greatest(coalesce(p_limit, 200), 1), 500) offset greatest(coalesce(p_offset, 0), 0);
end $$;
revoke all on function public.staff_customers(text, int, int) from public, anon;
grant execute on function public.staff_customers(text, int, int) to authenticated;

create or replace function public.staff_customer_emails()
returns text[] language plpgsql stable security definer set search_path = public as $$
declare v text[];
begin
  perform public.require_permission('support.manage');
  select coalesce(array_agg(distinct lower(e) order by lower(e)), '{}') into v
    from (select coalesce(c.email, u.email) as e
            from public.customers c left join auth.users u on u.id = c.user_id
           where not exists (select 1 from public.user_roles ur where ur.user_id = c.user_id)) t
   where e is not null and e <> '' and e not like '%.myhato.app';
  perform public.audit_write('customers.emails_copy', 'customers', '-', jsonb_build_object('count', coalesce(array_length(v, 1), 0)));
  return v;
end $$;
revoke all on function public.staff_customer_emails() from public, anon;
grant execute on function public.staff_customer_emails() to authenticated;
