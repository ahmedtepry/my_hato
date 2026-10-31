-- 1) trigger-only functions must not be callable through the API
do $$
declare f text;
begin
  foreach f in array array['_guard_on_shift_close','_orders_add_location','_stock_movement_sync','_wheel_first_purchase'] loop
    execute format('revoke execute on function public.%I() from public, anon, authenticated', f);
  end loop;
end $$;

-- 2) pin search_path on helper functions that left it open
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = any(array['order_status_message','_role_label_ar','_team_login_norm','_loy_num','_loy_period','_loy_period_start','_loy_gift_code','_loy_tz','_no_change','_pos_sales_guard','_pos_items_guard','_shifts_guard','_approvals_guard','_no_truncate','_cairo_month','_contest_norm','_wheel_day','_console_link','_notification_link_fix'])
      and not exists (select 1 from unnest(coalesce(p.proconfig,'{}')) c where c like 'search_path=%')
  loop
    execute format('alter function %s set search_path = public, pg_temp', r.sig);
  end loop;
end $$;
