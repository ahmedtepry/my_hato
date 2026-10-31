-- 0114: the OWNER is not an employee. An order the owner confirms gets no employee, no commission and no target; the owner has no online shift.
create or replace function public._online_confirmer(p_order uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select case when exists (select 1 from public.user_roles r where r.user_id = h.changed_by and r.role = 'owner') then null else h.changed_by end
    from public.order_status_history h where h.order_id = p_order and h.to_status = 'confirmed' order by h.created_at, h.id limit 1
$$;
revoke all on function public._online_confirmer(uuid) from public, anon, authenticated;

-- commissions already recorded for an order the owner confirmed are ignored (nothing is deleted)
create or replace function public._online_com(p_user uuid, p_from timestamptz, p_to timestamptz) returns bigint
language sql stable security definer set search_path = public as $$
  select coalesce(sum(c.amount_minor), 0)::bigint from public.online_commissions c join public.orders o on o.id = c.order_id
   where c.user_id = p_user and c.delivered_at >= p_from and c.delivered_at < p_to and o.payment_status <> 'refunded'
     and not exists (select 1 from public.user_roles r where r.user_id = c.user_id and r.role = 'owner')
$$;
revoke all on function public._online_com(uuid, timestamptz, timestamptz) from public, anon, authenticated;

create or replace function public.online_shift_open() returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.require_permission('online.shift');
  if public.has_role('owner') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if exists (select 1 from public.online_shifts where user_id = auth.uid() and closed_at is null) then return; end if;
  insert into public.online_shifts (user_id) values (auth.uid());
  perform public.audit_write('online.shift_open', 'user', auth.uid()::text, '{}'::jsonb);
end $$;
revoke all on function public.online_shift_open() from public, anon;
grant execute on function public.online_shift_open() to authenticated;

-- the owner's overview lists employees only
create or replace function public.online_overview() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_from timestamptz; v_to timestamptz; v_day timestamptz;
begin
  perform public.require_permission('online.manage');
  select m_from, m_to, m_day into v_from, v_to, v_day from public._cairo_month(null);
  return jsonb_build_object('employees', coalesce((select jsonb_agg(x order by x ->> 'name') from (
    select jsonb_build_object('user_id', u.uid, 'name', coalesce(tm.login_display, pr.full_name, '—'),
           'daily_hours', p.daily_hours, 'orders_target', p.orders_monthly, 'value_target_minor', p.value_monthly_minor, 'commission_pct', p.commission_pct,
           'orders_done', d.n, 'value_done_minor', d.value_minor) as x
    from (select ur.user_id as uid from public.user_roles ur where ur.role in ('sales', 'manager')
          union select user_id from public.online_plan) u
    left join public.online_plan p on p.user_id = u.uid
    left join public.team_members tm on tm.user_id = u.uid
    left join public.profiles pr on pr.id = u.uid
    left join lateral public._online_done(u.uid, v_from, v_to) d on true
    where not exists (select 1 from public.user_roles o where o.user_id = u.uid and o.role = 'owner')) q), '[]'::jsonb));
end $$;
revoke all on function public.online_overview() from public, anon;
grant execute on function public.online_overview() to authenticated;
