-- 0063: permissions and wording for the two new roles (needs 0062 to have been run first, as its own step).
--   cashier    -> opens the cashier screen only: sells, opens/closes his own shift, gives discounts within the limit, refunds within the limit.
--   accountant -> sees sales, shifts (cash differences), branch comparison and orders. Cannot sell, change prices or stock.
-- Nothing existing is changed or deleted; the owner can still change every permission from the permissions screen.

create or replace function public._role_label_ar(p_role public.app_role)
returns text language sql immutable as $$
  select case p_role when 'owner' then 'مالك' when 'manager' then 'مدير' when 'accountant' then 'محاسب' when 'cashier' then 'كاشير'
                     when 'sales' then 'مبيعات' when 'technician' then 'فني صيانة' else 'خدمة عملاء' end
$$;

insert into public.role_permissions (role, permission) values
  ('cashier','pos.sell'), ('cashier','pos.shift'), ('cashier','pos.discount'), ('cashier','pos.refund'),
  ('accountant','sales.view'), ('accountant','shifts.review'), ('accountant','orders.view')
on conflict do nothing;

create or replace function public.staff_team()
returns table (user_id uuid, full_name text, username text, phone text, email text, role text,
               granted_at timestamptz, last_sign_in_at timestamptz, is_me boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_permission('staff.manage');
  return query
    select ur.user_id, coalesce(nullif(p.full_name, ''), c.full_name), c.username, coalesce(c.phone, p.contact_phone),
           coalesce(c.email, p.email),
           (array_agg(ur.role::text order by array_position(array['owner','manager','accountant','cashier','sales','technician','support'], ur.role::text)))[1],
           min(ur.created_at), max(u.last_sign_in_at), ur.user_id = auth.uid()
      from public.user_roles ur
      left join public.profiles p on p.id = ur.user_id
      left join public.customers c on c.user_id = ur.user_id
      left join auth.users u on u.id = ur.user_id
     group by ur.user_id, p.full_name, c.full_name, c.username, c.phone, p.contact_phone, c.email, p.email
     order by min(array_position(array['owner','manager','accountant','cashier','sales','technician','support'], ur.role::text)), 2;
end $$;

create or replace function public.staff_team_live()
returns table (user_id uuid, full_name text, username text, phone text, email text, role text,
               granted_at timestamptz, last_sign_in_at timestamptz, is_me boolean,
               presence text, last_seen_at timestamptz, platform text, app_version text, area text,
               suspended boolean, actions_today int, last_action text, last_action_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_permission('staff.manage');
  return query
    with m as (
      select ur.user_id,
             (array_agg(ur.role::text order by array_position(array['owner','manager','accountant','cashier','sales','technician','support'], ur.role::text)))[1] as role,
             min(ur.created_at) as granted_at
        from public.user_roles ur group by ur.user_id
    )
    select m.user_id, coalesce(nullif(p.full_name, ''), c.full_name), coalesce(tm.login_display, c.username),
           coalesce(c.phone, p.contact_phone), case when tm.login_name is not null then null else coalesce(c.email, p.email) end,
           m.role, m.granted_at, u.last_sign_in_at, m.user_id = auth.uid(),
           case when tm.suspended_at is not null then 'suspended'
                when m.user_id = auth.uid() then 'online'
                when tm.online and tm.last_seen_at > now() - interval '2 minutes' then 'online'
                when tm.last_seen_at > now() - interval '15 minutes' then 'away'
                else 'offline' end,
           tm.last_seen_at, tm.platform, tm.app_version, tm.area, tm.suspended_at is not null,
           (select count(*)::int from public.audit_logs a where a.actor_id = m.user_id
                and a.created_at >= date_trunc('day', now() at time zone 'Africa/Cairo') at time zone 'Africa/Cairo'),
           la.action, la.created_at
      from m
      left join public.profiles p on p.id = m.user_id
      left join public.customers c on c.user_id = m.user_id
      left join public.team_members tm on tm.user_id = m.user_id
      left join auth.users u on u.id = m.user_id
      left join lateral (select a.action, a.created_at from public.audit_logs a where a.actor_id = m.user_id
                          order by a.created_at desc limit 1) la on true
     order by m.user_id <> auth.uid(),
              case when tm.suspended_at is not null then 3
                   when tm.online and tm.last_seen_at > now() - interval '2 minutes' then 0
                   when tm.last_seen_at > now() - interval '15 minutes' then 1 else 2 end,
              array_position(array['owner','manager','accountant','cashier','sales','technician','support'], m.role), 2;
end $$;
