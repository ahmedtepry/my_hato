-- 0070: accounts the owner creates by hand for the team now appear in the accounts list and the customers search,
-- with an is_staff flag, so the owner (or anyone with customers.review) can verify them like any other account.

-- every team member gets a customer register row (so there is something to list and verify)
insert into public.customers (user_id, email, full_name, email_verified, review_status)
select u.id, lower(nullif(u.email, '')), p.full_name, u.email_confirmed_at is not null, 'pending'
  from public.user_roles ur
  join auth.users u on u.id = ur.user_id
  left join public.profiles p on p.id = u.id
 where not exists (select 1 from public.customers c where c.user_id = u.id)
 group by u.id, u.email, p.full_name, u.email_confirmed_at
on conflict do nothing;

drop function if exists public.staff_accounts(text);
create or replace function public.staff_accounts(p_status text default 'pending')
returns table (user_id uuid, customer_code text, full_name text, username text, phone text, email text,
               review_status text, reject_reason text, reviewed_at timestamptz, created_at timestamptz, is_staff boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_permission('customers.review');
  if p_status not in ('pending', 'approved', 'rejected') then raise exception 'INVALID_INPUT'; end if;
  return query
    select c.user_id, c.customer_code, coalesce(nullif(c.full_name, ''), p.full_name, tm.login_display), c.username,
           coalesce(c.phone, p.contact_phone), c.email, c.review_status, c.reject_reason, c.reviewed_at, c.created_at,
           exists (select 1 from public.user_roles ur where ur.user_id = c.user_id)
      from public.customers c
      left join public.profiles p on p.id = c.user_id
      left join public.team_members tm on tm.user_id = c.user_id
     where c.review_status = p_status
     order by case when p_status = 'pending' then c.created_at end asc,
              coalesce(c.reviewed_at, c.created_at) desc
     limit 200;
end $$;
revoke all on function public.staff_accounts(text) from public, anon;
grant execute on function public.staff_accounts(text) to authenticated;

create or replace function public.staff_pending_accounts_count()
returns int language sql stable security definer set search_path = public as $$
  select case when public.has_permission('customers.review') then
    (select count(*)::int from public.customers c where c.review_status = 'pending')
  else 0 end
$$;

drop function if exists public.staff_customers(text, int, int);
create or replace function public.staff_customers(p_search text default null, p_limit int default 200, p_offset int default 0)
returns table (user_id uuid, customer_code text, full_name text, username text, phone text, email text, review_status text,
               created_at timestamptz, last_sign_in_at timestamptz, email_confirmed boolean, provider text,
               orders_count int, delivered_total_minor bigint, last_order_at timestamptz, is_staff boolean)
language plpgsql stable security definer set search_path = public as $$
declare
  v_q text := nullif(trim(coalesce(p_search, '')), '');
  v_d text := regexp_replace(regexp_replace(coalesce(p_search, ''), '\D', '', 'g'), '^(0020|20|0)', '');
begin
  perform public.require_permission('support.manage');
  return query
    select c.user_id, c.customer_code, coalesce(nullif(c.full_name, ''), p.full_name, tm.login_display), c.username,
           coalesce(c.phone, p.contact_phone), coalesce(c.email, u.email), c.review_status, c.created_at,
           u.last_sign_in_at, (u.email_confirmed_at is not null), (u.raw_app_meta_data ->> 'provider'),
           coalesce(o.n, 0)::int, coalesce(o.total, 0)::bigint, o.last_at,
           exists (select 1 from public.user_roles ur where ur.user_id = c.user_id)
      from public.customers c
      left join public.profiles p on p.id = c.user_id
      left join auth.users u on u.id = c.user_id
      left join public.team_members tm on tm.user_id = c.user_id
      left join lateral (
        select count(*) as n, sum(x.total_minor) filter (where x.status = 'delivered') as total, max(x.created_at) as last_at
          from public.orders x where x.customer_id = c.user_id) o on true
     where (v_q is null
            or coalesce(nullif(c.full_name, ''), p.full_name, tm.login_display, '') ilike '%' || v_q || '%'
            or coalesce(tm.login_display, '') ilike '%' || v_q || '%'
            or coalesce(c.email, u.email, '') ilike '%' || v_q || '%'
            or coalesce(c.phone, p.contact_phone, '') ilike '%' || v_q || '%'
            or (length(v_d) >= 3 and regexp_replace(coalesce(c.phone, p.contact_phone, ''), '\D', '', 'g') like '%' || v_d || '%')
            or coalesce(c.username, '') ilike '%' || v_q || '%'
            or coalesce(c.customer_code, '') ilike '%' || v_q || '%')
     order by c.created_at desc
     limit least(greatest(coalesce(p_limit, 200), 1), 500) offset greatest(coalesce(p_offset, 0), 0);
end $$;
revoke all on function public.staff_customers(text, int, int) from public, anon;
grant execute on function public.staff_customers(text, int, int) to authenticated;
