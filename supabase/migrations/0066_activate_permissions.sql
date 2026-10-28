-- 0066: the nine "coming soon" permissions become real. Each one now gates the exact action it names.
-- Nothing is locked out: every role/person that could do the action before (through the broader permission)
-- is given the new permission automatically, so the owner can then switch it off per role or per person.

-- 1) catalog: not inert any more
update public.permission_catalog set inert = false
 where permission in ('customers.review','cancel_requests.decide','coupons.manage','notifications.broadcast','reviews.moderate',
                      'audit.export','payments.manage','roles.assign','branches.manage');

-- 2) backfill from the broader permission (roles, then per-person grants/denies)
create temp table _pmap (parent text, child text);
insert into _pmap values
 ('support.manage','customers.review'), ('orders.manage','cancel_requests.decide'), ('orders.manage','coupons.manage'),
 ('orders.manage','notifications.broadcast'), ('products.manage','reviews.moderate'), ('audit.view','audit.export'),
 ('orders.manage','payments.manage'), ('staff.manage','roles.assign'), ('settings.manage','branches.manage');

insert into public.role_permissions (role, permission)
select rp.role, m.child from public.role_permissions rp join _pmap m on m.parent = rp.permission
on conflict do nothing;

insert into public.user_permission_overrides (user_id, permission, effect, note, granted_by)
select o.user_id, m.child, o.effect, o.note, o.granted_by from public.user_permission_overrides o join _pmap m on m.parent = o.permission
on conflict do nothing;

-- 3) patch the live function bodies (safe even if a function was redefined in a later migration)
create or replace function public._swap_perm(p_fn regprocedure, p_old text, p_new text) returns void language plpgsql as $$
declare d text;
begin
  d := pg_get_functiondef(p_fn);
  if position('''' || p_old || '''' in d) = 0 then raise exception 'perm % not found in %', p_old, p_fn; end if;
  execute replace(d, '''' || p_old || '''', '''' || p_new || '''');
end $$;

select public._swap_perm('public.staff_decide_cancel(uuid,boolean,text)'::regprocedure, 'orders.manage', 'cancel_requests.decide');
select public._swap_perm('public.staff_save_coupon(text,text,int,bigint,bigint,int,int,timestamptz,boolean)'::regprocedure, 'orders.manage', 'coupons.manage');
select public._swap_perm('public.staff_broadcast_offer(text,text,text,text)'::regprocedure, 'orders.manage', 'notifications.broadcast');
select public._swap_perm('public.staff_moderate_review(uuid,text)'::regprocedure, 'products.manage', 'reviews.moderate');
select public._swap_perm('public.staff_accounts(text)'::regprocedure, 'support.manage', 'customers.review');
select public._swap_perm('public.staff_mark_account_approved(uuid)'::regprocedure, 'support.manage', 'customers.review');
select public._swap_perm('public.staff_reject_account(uuid,text)'::regprocedure, 'support.manage', 'customers.review');
select public._swap_perm('public.staff_pending_accounts_count()'::regprocedure, 'support.manage', 'customers.review');
select public._swap_perm('public.staff_refund_check(uuid,bigint)'::regprocedure, 'orders.manage', 'payments.manage');
select public._swap_perm('public.staff_assign_role(uuid,public.app_role)'::regprocedure, 'staff.manage', 'roles.assign');
drop function public._swap_perm(regprocedure, text, text);
drop table _pmap;

-- 4) reading stays open to the old permission too (so lists still load); writing needs the new one
drop policy if exists coupons_staff_read on public.coupons;
create policy coupons_staff_read on public.coupons for select to authenticated
  using (public.has_permission('orders.manage') or public.has_permission('coupons.manage'));

drop policy if exists branches_write on public.branches;
create policy branches_write on public.branches for all to authenticated
  using (public.has_permission('branches.manage')) with check (public.has_permission('branches.manage'));
drop policy if exists zones_write on public.delivery_zones;
create policy zones_write on public.delivery_zones for all to authenticated
  using (public.has_permission('branches.manage')) with check (public.has_permission('branches.manage'));

-- 5) download the activity log (CSV text, newest first, at most 20,000 rows, the download itself is logged)
create or replace function public.audit_export(p_days int default 30) returns text
language plpgsql security definer set search_path = public as $$
declare v_days int := least(greatest(coalesce(p_days, 30), 1), 3650); v_out text;
begin
  perform public.require_permission('audit.export');
  select 'id,time,actor,action,entity_type,entity_id,details' || E'\n' ||
         coalesce(string_agg(format('%s,%s,%s,%s,%s,%s,%s', id, to_char(created_at at time zone 'UTC', 'YYYY-MM-DD HH24:MI:SS'),
           coalesce(actor_id::text, ''), '"' || replace(action, '"', '""') || '"', '"' || replace(coalesce(entity_type, ''), '"', '""') || '"',
           '"' || replace(coalesce(entity_id, ''), '"', '""') || '"', '"' || replace(coalesce(details::text, ''), '"', '""') || '"'), E'\n' order by id desc), '')
    into v_out
    from (select * from public.audit_logs where created_at > now() - make_interval(days => v_days) order by id desc limit 20000) a;
  perform public.audit_write('audit.export', 'audit', null, jsonb_build_object('days', v_days));
  return v_out;
end $$;
revoke all on function public.audit_export(int) from public, anon;
grant execute on function public.audit_export(int) to authenticated;
