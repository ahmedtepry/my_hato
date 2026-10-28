-- 0071: live operations room for the owner (permission ops.live, owner only unless the owner grants it):
-- today's sales per branch, open shifts and who opened them, who is online, the latest sales and actions,
-- plus drill-down lists (sales of a branch / shift, actions of a person).

insert into public.permission_catalog (permission, grp, name_ar, name_en, desc_ar, desc_en, sensitive, inert, sort) values
 ('ops.live', 'system', 'غرفة العمليات المباشرة', 'Live operations room',
  'يشوف مبيعات كل فرع لحظيًا، والورديات المفتوحة ومين فاتحها، ومين أونلاين، وكل ما بيحصل ويدخل في تفاصيله',
  'Sees every branch''s sales live, the open shifts and who opened them, who is online, and everything that happens, with drill-down', true, false, 72)
on conflict (permission) do update set name_ar = excluded.name_ar, name_en = excluded.name_en, desc_ar = excluded.desc_ar, desc_en = excluded.desc_en, sensitive = true, inert = false;
insert into public.role_permissions (role, permission) values ('owner', 'ops.live') on conflict do nothing;

create or replace function public._ops_name(p_user uuid) returns text
language sql stable security definer set search_path = public as $$
  select coalesce(nullif(tm.login_display, ''), nullif(p.full_name, ''), nullif(c.full_name, ''), '—')
    from (select 1) x
    left join public.team_members tm on tm.user_id = p_user
    left join public.profiles p on p.id = p_user
    left join public.customers c on c.user_id = p_user
$$;
revoke all on function public._ops_name(uuid) from public, anon, authenticated;

create or replace function public.ops_live() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_from timestamptz := date_trunc('day', now() at time zone 'Africa/Cairo') at time zone 'Africa/Cairo'; v_out jsonb;
begin
  perform public.require_permission('ops.live');
  select jsonb_build_object(
    'now', now(),
    'branches', coalesce((select jsonb_agg(jsonb_build_object(
        'id', b.id, 'name_ar', b.name_ar, 'name_en', b.name_en, 'is_hq', b.is_hq,
        'sales_count', (select count(*) from public.pos_sales s where s.branch_id = b.id and s.created_at >= v_from),
        'net_minor', coalesce((select sum(s.total_minor - s.refunded_minor) from public.pos_sales s where s.branch_id = b.id and s.created_at >= v_from), 0),
        'refunds_minor', coalesce((select sum(s.refunded_minor) from public.pos_sales s where s.branch_id = b.id and s.created_at >= v_from), 0),
        'last_sale_at', (select max(s.created_at) from public.pos_sales s where s.branch_id = b.id),
        'open_shifts', (select count(*) from public.shifts sh where sh.branch_id = b.id and sh.status = 'open')
      ) order by b.is_hq, b.created_at) from public.branches b where b.is_active), '[]'::jsonb),
    'open_shifts', coalesce((select jsonb_agg(jsonb_build_object(
        'shift_id', sh.id, 'branch_id', sh.branch_id, 'branch_name_ar', b.name_ar, 'cashier_id', sh.cashier_id,
        'cashier_name', public._ops_name(sh.cashier_id), 'opened_at', sh.opened_at, 'opening_minor', sh.opening_cash_minor,
        'sales_count', (select count(*) from public.pos_sales s where s.shift_id = sh.id),
        'sales_minor', coalesce((select sum(s.total_minor) from public.pos_sales s where s.shift_id = sh.id), 0),
        'last_sale_at', (select max(s.created_at) from public.pos_sales s where s.shift_id = sh.id)
      ) order by sh.opened_at) from public.shifts sh join public.branches b on b.id = sh.branch_id where sh.status = 'open'), '[]'::jsonb),
    'team', coalesce((select jsonb_agg(t order by t.rank, t.name) from (
        select ur.user_id, public._ops_name(ur.user_id) as name, (array_agg(ur.role::text))[1] as role,
               case when tm.suspended_at is not null then 'suspended'
                    when ur.user_id = auth.uid() then 'online'
                    when tm.online and tm.last_seen_at > now() - interval '2 minutes' then 'online'
                    when tm.last_seen_at > now() - interval '15 minutes' then 'away' else 'offline' end as presence,
               case when tm.suspended_at is not null then 3 when ur.user_id = auth.uid() then 0
                    when tm.online and tm.last_seen_at > now() - interval '2 minutes' then 0
                    when tm.last_seen_at > now() - interval '15 minutes' then 1 else 2 end as rank,
               tm.last_seen_at, tm.area, tm.platform
          from public.user_roles ur left join public.team_members tm on tm.user_id = ur.user_id
         group by ur.user_id, tm.suspended_at, tm.online, tm.last_seen_at, tm.area, tm.platform) t), '[]'::jsonb),
    'recent_sales', coalesce((select jsonb_agg(r order by r.created_at desc) from (
        select s.id, s.number, s.created_at, s.branch_id, b.name_ar as branch_name_ar, public._ops_name(s.cashier_id) as cashier_name,
               s.total_minor, s.refunded_minor, s.discount_minor
          from public.pos_sales s join public.branches b on b.id = s.branch_id order by s.created_at desc limit 25) r), '[]'::jsonb),
    'recent_actions', coalesce((select jsonb_agg(a order by a.created_at desc) from (
        select l.id, l.action, l.entity_type, l.entity_id, l.created_at, l.actor_id, public._ops_name(l.actor_id) as actor_name, l.details
          from public.audit_logs l order by l.created_at desc limit 30) a), '[]'::jsonb)
  ) into v_out;
  return v_out;
end $$;

-- the sales of a branch and/or a shift (newest first), with their lines
create or replace function public.ops_sales(p_branch uuid default null, p_shift uuid default null, p_today boolean default true, p_limit int default 100)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_from timestamptz := case when p_today then date_trunc('day', now() at time zone 'Africa/Cairo') at time zone 'Africa/Cairo' end;
begin
  perform public.require_permission('ops.live');
  return coalesce((select jsonb_agg(r order by r.created_at desc) from (
    select s.id, s.number, s.created_at, s.branch_id, b.name_ar as branch_name_ar, public._ops_name(s.cashier_id) as cashier_name,
           s.subtotal_minor, s.discount_minor, s.total_minor, s.refunded_minor,
           coalesce((select jsonb_agg(jsonb_build_object('name_ar', i.name_ar, 'quantity', i.quantity, 'line_total_minor', i.line_total_minor, 'refunded_qty', i.refunded_qty))
                       from public.pos_sale_items i where i.sale_id = s.id), '[]'::jsonb) as items
      from public.pos_sales s join public.branches b on b.id = s.branch_id
     where (p_branch is null or s.branch_id = p_branch) and (p_shift is null or s.shift_id = p_shift)
       and (v_from is null or s.created_at >= v_from)
     order by s.created_at desc limit least(greatest(coalesce(p_limit, 100), 1), 500)) r), '[]'::jsonb);
end $$;

-- what a person did lately
create or replace function public.ops_actions(p_actor uuid default null, p_limit int default 100)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_permission('ops.live');
  return coalesce((select jsonb_agg(a order by a.created_at desc) from (
    select l.id, l.action, l.entity_type, l.entity_id, l.created_at, l.actor_id, public._ops_name(l.actor_id) as actor_name, l.details
      from public.audit_logs l where p_actor is null or l.actor_id = p_actor
     order by l.created_at desc limit least(greatest(coalesce(p_limit, 100), 1), 500)) a), '[]'::jsonb);
end $$;

revoke all on function public.ops_live(), public.ops_sales(uuid, uuid, boolean, int), public.ops_actions(uuid, int) from public, anon;
grant execute on function public.ops_live(), public.ops_sales(uuid, uuid, boolean, int), public.ops_actions(uuid, int) to authenticated;
