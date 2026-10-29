-- 0102: the cashier assistant ("المساعد الذكي") and the shift/operations guard. Two switches, both OFF until the owner (or whoever he allows) turns them on:
--   cashier  assistant.cashier  a helper at the till: price, where a product is, alternatives (read only)
--   guard    assistant.guard    the operations guard: reviews every shift (cash difference, unusual discounts, repeated refunds, voided invoices),
--                               tells the managers when a shift closes with something to look at, and watches the stock (low, unbalanced, to re-order, stagnant)
-- The robot NEVER acts on its own: nothing here changes a price, a stock quantity, an invoice or a refund. It only reads, shows and notifies.

update public.permission_catalog set inert = false, desc_ar = 'يشغّل «المساعد الذكي» عند الكاشير: يدوّر على سعر المنتج ومكانه وبدايله، ويشرح خطوات الفاتورة والمرتجع',
  desc_en = 'Turns on the smart assistant at the till: finds a product price, where it is and its alternatives, and explains invoices and refunds' where permission = 'assistant.cashier';
insert into public.permission_catalog (permission, grp, name_ar, name_en, desc_ar, desc_en, sensitive, inert, sort) values
 ('assistant.guard', 'assistant', 'يفعّل حارس الوردية والعمليات', 'Turn on the shift and operations guard',
  'يراجع كل وردية (فرق النقدية، الخصومات غير المعتادة، المرتجعات المتكررة، الفواتير الملغية) وينبّه لما المخزون يقرب يخلص أو يختلف بين الفروع',
  'Reviews every shift (cash difference, unusual discounts, repeated refunds, voided invoices) and warns about low or unbalanced stock', true, false, 4)
on conflict (permission) do update set grp = excluded.grp, name_ar = excluded.name_ar, name_en = excluded.name_en, desc_ar = excluded.desc_ar, desc_en = excluded.desc_en,
  sensitive = excluded.sensitive, inert = excluded.inert, sort = excluded.sort;
insert into public.role_permissions (role, permission) values ('owner', 'assistant.cashier'), ('owner', 'assistant.guard') on conflict do nothing;

-- what each person may USE (separate from who may switch a mode on): the owner hands these out one by one, per role or per person
insert into public.permission_catalog (permission, grp, name_ar, name_en, desc_ar, desc_en, sensitive, inert, sort) values
 ('assistant.use_find', 'assistant', 'يستخدم زرار «المساعد الذكي» عند البيع', 'Use the smart assistant button at the till',
  'يدوّر على سعر المنتج ومكانه وبدايله ويشوف شرح الفاتورة والمرتجع', 'Looks up a product price, where it is and alternatives, and reads the invoice and refund guides', false, false, 10),
 ('assistant.use_robot_close', 'assistant', 'يقفل الوردية بالروبوت', 'Close the shift with the robot',
  'إقفال الوردية بمراجعة الروبوت (30 ثانية) وتنبيهه لأي خلل', 'Closes the shift with the robot review (30 seconds) and its warnings', false, false, 11),
 ('assistant.use_robot_open', 'assistant', 'يفتح الوردية بالروبوت', 'Open the shift with the robot',
  'فتح الوردية بتجهيز الروبوت للدرج وآية أو قول عن الأمانة', 'Opens the shift with the robot preparing the drawer and a verse or saying about trust', false, false, 12),
 ('assistant.use_fingerprint', 'assistant', 'يستخدم البصمة في الفتح والإقفال', 'Use the fingerprint to open and close',
  'يفتح ويقفل الوردية بالبصمة بدل كتابة الباسورد', 'Opens and closes the shift with the fingerprint instead of typing the password', false, false, 13),
 ('assistant.use_reel', 'assistant', 'يشوف ريل الصباح', 'See the morning reel',
  'ريل قصير مرة في اليوم: ترحيب وآية ووردية النهارده وتنبيهات', 'A short reel once a day: greeting, verse, today''s shift and tips', false, false, 14),
 ('assistant.use_challenge', 'assistant', 'يشوف تحدّي اليوم', 'See the daily challenge',
  'شريط تحدّي اليوم في شاشة البيع مع احتفال لما يكتمل', 'The daily challenge bar at the till, with a celebration when it is complete', false, false, 15),
 ('assistant.use_overview', 'assistant', 'يشوف مراجعة العمليات', 'See the operations review',
  'تقرير حارس الوردية: الموظفين، فروق النقدية، نقص الشاشات والبطاريات، اقتراح الشراء، الراكد', 'The guard report: staff, cash differences, low screens and batteries, purchase suggestions, stagnant stock', true, false, 16)
on conflict (permission) do update set grp = excluded.grp, name_ar = excluded.name_ar, name_en = excluded.name_en, desc_ar = excluded.desc_ar, desc_en = excluded.desc_en,
  sensitive = excluded.sensitive, inert = excluded.inert, sort = excluded.sort;
insert into public.role_permissions (role, permission)
select 'owner', permission from public.permission_catalog where permission like 'assistant.use\_%' on conflict do nothing;

do $$ declare c record; begin
  for c in select conname from pg_constraint where conrelid = 'public.assistant_modes'::regclass and contype = 'c' loop
    execute format('alter table public.assistant_modes drop constraint %I', c.conname);
  end loop;
end $$;
alter table public.assistant_modes add constraint assistant_modes_key_check check (key in ('accountant', 'support', 'cashier', 'guard'));
insert into public.assistant_modes (key, enabled) values ('cashier', false), ('guard', false) on conflict (key) do nothing;

-- state for the console (only the modes he may switch) and flags for everyone (which buttons to show)
create or replace function public.assistant_state() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_sup boolean;
begin
  perform public.require_auth();
  v_sup := public.has_permission('assistant.support');
  return jsonb_build_object(
    'accountant', case when public.has_permission('assistant.accountant') then jsonb_build_object('enabled', public._assistant_on('accountant')) end,
    'cashier', case when public.has_permission('assistant.cashier') then jsonb_build_object('enabled', public._assistant_on('cashier')) end,
    'guard', case when public.has_permission('assistant.guard') then jsonb_build_object('enabled', public._assistant_on('guard')) end,
    'support', case when v_sup then jsonb_build_object('enabled', public._assistant_on('support'),
        'log', coalesce((select jsonb_agg(jsonb_build_object('kind', kind, 'text', text_ar, 'at', created_at) order by created_at desc)
                           from (select * from public.assistant_events where kind not like 'guard%' order by created_at desc limit 30) e), '[]'::jsonb)) end);
end $$;

-- each person switches the automatic mode ON or OFF for himself (only if he holds at least one "use" permission and a mode is on):
-- ON opens every robot feature the owner gave him; OFF closes them all again.
create table if not exists public.assistant_user_prefs (
  user_id uuid primary key references auth.users (id) on delete cascade,
  enabled boolean not null default false,
  updated_at timestamptz not null default now()
);
alter table public.assistant_user_prefs enable row level security;
revoke all on public.assistant_user_prefs from anon, authenticated;

create or replace function public._assistant_can_any() returns boolean language sql stable security definer set search_path = public as $$
  select (public._assistant_on('cashier') or public._assistant_on('guard')) and (
    coalesce(public.has_permission('assistant.use_find'), false) or coalesce(public.has_permission('assistant.use_robot_close'), false)
    or coalesce(public.has_permission('assistant.use_robot_open'), false) or coalesce(public.has_permission('assistant.use_fingerprint'), false)
    or coalesce(public.has_permission('assistant.use_reel'), false) or coalesce(public.has_permission('assistant.use_challenge'), false))
$$;
revoke all on function public._assistant_can_any() from public, anon;

create or replace function public.assistant_my_mode_set(p_enabled boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.require_auth();
  if not public._assistant_can_any() then raise exception 'FORBIDDEN'; end if;
  insert into public.assistant_user_prefs (user_id, enabled) values (auth.uid(), coalesce(p_enabled, false))
  on conflict (user_id) do update set enabled = excluded.enabled, updated_at = now();
  perform public.audit_write('assistant.my_mode', 'assistant', auth.uid()::text, jsonb_build_object('enabled', coalesce(p_enabled, false)));
end $$;
revoke all on function public.assistant_my_mode_set(boolean) from public, anon;
grant execute on function public.assistant_my_mode_set(boolean) to authenticated;

create or replace function public.assistant_flags() returns jsonb
language sql stable security definer set search_path = public as $$
  with m as (select coalesce((select enabled from public.assistant_user_prefs where user_id = auth.uid()), false) as mine)
  select jsonb_build_object(
    'available', public._assistant_can_any(),
    'mine', m.mine,
    'cashier', m.mine and public._assistant_on('cashier') and coalesce(public.has_permission('assistant.use_find'), false),
    'guard', m.mine and public._assistant_on('guard') and (coalesce(public.has_permission('assistant.use_robot_close'), false) or coalesce(public.has_permission('assistant.use_robot_open'), false)),
    'find', m.mine and public._assistant_on('cashier') and coalesce(public.has_permission('assistant.use_find'), false),
    'robot_close', m.mine and public._assistant_on('guard') and coalesce(public.has_permission('assistant.use_robot_close'), false),
    'robot_open', m.mine and public._assistant_on('guard') and coalesce(public.has_permission('assistant.use_robot_open'), false),
    'fingerprint', m.mine and coalesce(public.has_permission('assistant.use_fingerprint'), false),
    'reel', m.mine and public._assistant_on('cashier') and coalesce(public.has_permission('assistant.use_reel'), false),
    'challenge', m.mine and public._assistant_on('cashier') and coalesce(public.has_permission('assistant.use_challenge'), false))
  from m
$$;
revoke all on function public.assistant_flags() from public, anon;
grant execute on function public.assistant_flags() to authenticated;

create or replace function public.assistant_set(p_key text, p_enabled boolean, p_confirm boolean default false) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_key not in ('accountant', 'support', 'cashier', 'guard') then raise exception 'INVALID_INPUT'; end if;
  perform public.require_permission('assistant.' || p_key);
  if p_enabled and coalesce(p_confirm, false) is not true then raise exception 'CONFIRM_REQUIRED'; end if;
  update public.assistant_modes set enabled = p_enabled, updated_at = now(), updated_by = auth.uid() where key = p_key;
  perform public.audit_write('assistant.switch', 'assistant', p_key, jsonb_build_object('enabled', p_enabled));
end $$;

-- ------------------------------------------------------------ the till assistant (read only)
-- how many pieces of a product sit where he works (his branch stores; with "see stock elsewhere" also the warehouse)
create or replace function public._my_branch_qty(p_product uuid) returns int
language sql stable security definer set search_path = public as $$
  select coalesce((select sum(quantity)::int from public.branch_stock where product_id = p_product and public._branch_ok(branch_id)), 0)
       + case when public.has_permission('stock.others') then greatest(public._stock_unallocated(p_product), 0) else 0 end
$$;
revoke all on function public._my_branch_qty(uuid) from public, anon, authenticated;

create or replace function public.assistant_find_product(p_q text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_q text := nullif(btrim(coalesce(p_q, '')), ''); v_all boolean;
begin
  perform public.require_auth();
  if not public.has_permission('assistant.use_find') then raise exception 'FORBIDDEN'; end if;
  if not public._assistant_on('cashier') then raise exception 'MODE_OFF'; end if;
  if v_q is null or char_length(v_q) < 2 then return '[]'::jsonb; end if;
  v_all := public.has_permission('stock.others');
  return coalesce((select jsonb_agg(x) from (
    select p.id as product_id, p.sku, p.name_ar, p.name_en, p.price_minor, p.compare_at_price_minor as compare_minor,
           public._my_branch_qty(p.id) as here_qty,
           -- where else: names and numbers only with "see stock elsewhere", otherwise just yes / no
           case when v_all then coalesce((select jsonb_agg(jsonb_build_object('branch', b.name_ar, 'qty', bs.quantity) order by b.name_ar)
                                            from public.branch_stock bs join public.branches b on b.id = bs.branch_id where bs.product_id = p.id and bs.quantity > 0 and not b.is_hq), '[]'::jsonb) end as branches,
           case when v_all then greatest(public._stock_unallocated(p.id), 0) end as warehouse,
           (exists (select 1 from public.branch_stock bs where bs.product_id = p.id and bs.quantity > 0 and not public._branch_ok(bs.branch_id))
             or greatest(public._stock_unallocated(p.id), 0) > 0) as elsewhere,
           coalesce((select jsonb_agg(jsonb_build_object('product_id', a.id, 'sku', a.sku, 'name_ar', a.name_ar, 'price_minor', a.price_minor, 'here_qty', a.q) order by abs(a.price_minor - p.price_minor))
                       from (select a0.id, a0.sku, a0.name_ar, a0.price_minor, public._my_branch_qty(a0.id) q
                               from public.products a0 where a0.category_id = p.category_id and a0.id <> p.id and a0.status = 'published'
                                and public._my_branch_qty(a0.id) > 0 order by abs(a0.price_minor - p.price_minor) limit 4) a), '[]'::jsonb) as alternatives
      from public.products p
     where p.status = 'published' and (p.name_ar ilike '%' || v_q || '%' or p.name_en ilike '%' || v_q || '%' or p.sku ilike '%' || v_q || '%')
     order by p.name_ar limit 6) x), '[]'::jsonb);
end $$;
revoke all on function public.assistant_find_product(text) from public, anon;
grant execute on function public.assistant_find_product(text) to authenticated;

-- ------------------------------------------------------------ the shift guard
create or replace function public._guard_shift_flags(p_shift uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s public.shifts; v_avg numeric; v_lim numeric; v_n int; v_total bigint; v_disc bigint; v_sub bigint; v_exp bigint;
        v_ref_n int; v_ref_total bigint; v_void int; v_flag jsonb; v_refs jsonb; v_voids jsonb; v_alerts jsonb := '[]'::jsonb;
begin
  select * into s from public.shifts where id = p_shift;
  if not found then raise exception 'NOT_FOUND'; end if;
  select coalesce(sum(discount_minor)::numeric / nullif(sum(subtotal_minor), 0), 0) into v_avg
    from public.pos_sales where branch_id = s.branch_id and created_at >= now() - interval '30 days' and shift_id <> p_shift;
  v_lim := greatest(0.10, v_avg * 2);
  select count(*), coalesce(sum(total_minor), 0), coalesce(sum(discount_minor), 0), coalesce(sum(subtotal_minor), 0) into v_n, v_total, v_disc, v_sub from public.pos_sales where shift_id = p_shift;
  select coalesce(jsonb_agg(jsonb_build_object('number', number, 'at', created_at, 'discount_minor', discount_minor, 'subtotal_minor', subtotal_minor,
           'percent', round(discount_minor::numeric / subtotal_minor * 100), 'approved', approval_id is not null) order by created_at), '[]'::jsonb) into v_flag
    from public.pos_sales where shift_id = p_shift and subtotal_minor > 0 and discount_minor::numeric / subtotal_minor > v_lim;
  select count(*), coalesce(sum(amount_minor), 0) into v_ref_n, v_ref_total from public.pos_refunds where shift_id = p_shift;
  select coalesce(jsonb_agg(jsonb_build_object('sale', ps.number, 'amount_minor', r.amount_minor, 'reason', r.reason, 'at', r.created_at, 'approved', r.approval_id is not null) order by r.created_at), '[]'::jsonb) into v_refs
    from public.pos_refunds r join public.pos_sales ps on ps.id = r.sale_id where r.shift_id = p_shift;
  select count(*), coalesce(jsonb_agg(jsonb_build_object('number', number, 'total_minor', total_minor, 'at', created_at) order by created_at), '[]'::jsonb) into v_void, v_voids
    from public.pos_sales where shift_id = p_shift and refunded_minor >= total_minor and total_minor > 0;
  v_exp := coalesce(s.expected_cash_minor, nullif(public._shift_totals(s.id) ->> 'expected_minor', '')::bigint);

  if s.variance_minor is not null and s.variance_minor <> 0 then
    v_alerts := v_alerts || jsonb_build_object('level', 'warn', 'text_ar', 'فرق في النقدية: ' || (s.variance_minor / 100.0)::text || ' ج (المعدود ' || (case when s.variance_minor < 0 then 'أقل' else 'أكتر' end) || ' من المتوقع)');
  end if;
  if jsonb_array_length(v_flag) > 0 then
    v_alerts := v_alerts || jsonb_build_object('level', 'warn', 'text_ar', jsonb_array_length(v_flag) || ' فاتورة فيها خصم أعلى من المعتاد (الحد ' || round(v_lim * 100) || '٪)');
  end if;
  if v_ref_n >= 3 then
    v_alerts := v_alerts || jsonb_build_object('level', 'warn', 'text_ar', v_ref_n || ' مرتجعات في وردية واحدة');
  end if;
  if v_void > 0 then
    v_alerts := v_alerts || jsonb_build_object('level', 'warn', 'text_ar', v_void || ' فاتورة اترجعت بالكامل (زي الإلغاء)');
  end if;
  return jsonb_build_object(
    'shift', jsonb_build_object('id', s.id, 'status', s.status, 'opened_at', s.opened_at, 'closed_at', s.closed_at, 'cashier', public._ops_name(s.cashier_id),
                                'branch', (select name_ar from public.branches where id = s.branch_id)),
    'cash', jsonb_build_object('opening_minor', s.opening_cash_minor, 'expected_minor', v_exp, 'counted_minor', s.counted_cash_minor, 'variance_minor', s.variance_minor),
    'sales', jsonb_build_object('count', v_n, 'total_minor', v_total, 'discount_minor', v_disc, 'discount_percent', case when v_sub > 0 then round(v_disc::numeric / v_sub * 100, 1) else 0 end,
                                'usual_percent', round(v_avg * 100, 1)),
    'flagged_discounts', v_flag, 'refunds', jsonb_build_object('count', v_ref_n, 'total_minor', v_ref_total, 'items', v_refs),
    'voided', v_voids, 'alerts', v_alerts);
end $$;
revoke all on function public._guard_shift_flags(uuid) from public, anon, authenticated;

-- the review: the cashier of the shift (before closing it) or a manager who may review shifts / holds the guard switch
create or replace function public.assistant_shift_review(p_shift uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.shifts;
begin
  perform public.require_auth();
  select * into s from public.shifts where id = p_shift;
  if not found then raise exception 'NOT_FOUND'; end if;
  if not (s.cashier_id = auth.uid() or ((public.has_permission('assistant.guard') or public.has_permission('shifts.review')) and public._branch_view_ok(s.branch_id))) then raise exception 'FORBIDDEN'; end if;
  if not public._assistant_on('guard') then raise exception 'MODE_OFF'; end if;
  return public._guard_shift_flags(p_shift);
end $$;
revoke all on function public.assistant_shift_review(uuid) from public, anon;
grant execute on function public.assistant_shift_review(uuid) to authenticated;

-- when a shift closes with something to look at, the managers are told (once)
create or replace function public._guard_on_shift_close() returns trigger
language plpgsql security definer set search_path = public as $$
declare f jsonb; v_text text;
begin
  if new.status = 'closed' and old.status is distinct from 'closed' and public._assistant_on('guard') then
    f := public._guard_shift_flags(new.id);
    if jsonb_array_length(f -> 'alerts') > 0 then
      select string_agg(a ->> 'text_ar', ' · ') into v_text from jsonb_array_elements(f -> 'alerts') a;
      insert into public.assistant_events (kind, ref, text_ar) values ('guard_shift', new.id::text, 'وردية ' || (f #>> '{shift,cashier}') || ': ' || v_text) on conflict do nothing;
      perform public._notify_staff('shifts.review', '🛡️ وردية محتاجة مراجعة', '🛡️ A shift needs a look',
        'وردية ' || (f #>> '{shift,cashier}') || ' في ' || (f #>> '{shift,branch}') || ': ' || v_text, 'Shift of ' || (f #>> '{shift,cashier}') || ' closed with alerts.', 'SH-' || left(new.id::text, 6));
    end if;
  end if;
  return null;
end $$;
drop trigger if exists shifts_guard_on_close on public.shifts;
create trigger shifts_guard_on_close after update of status on public.shifts for each row execute function public._guard_on_shift_close();

-- ------------------------------------------------------------ the operations overview (managers)
-- units sold per product over the last 30 days (counter + online, net of refunds/cancellations)
create or replace view public.v_assistant_units as
  select t.product_id, sum(t.units)::numeric as units from (
    select i.product_id, (i.quantity - i.refunded_qty) as units from public.pos_sale_items i join public.pos_sales s on s.id = i.sale_id where s.created_at >= now() - interval '30 days'
    union all
    select oi.product_id, oi.quantity from public.order_items oi join public.orders o on o.id = oi.order_id
     where o.created_at >= now() - interval '30 days' and o.status <> 'cancelled' and oi.product_id is not null) t
  where t.product_id is not null group by t.product_id;
revoke all on public.v_assistant_units from public, anon, authenticated;

create or replace function public.assistant_guard_overview(p_days int default 7) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_days int := least(greatest(coalesce(p_days, 7), 1), 60);
begin
  perform public.require_permission('assistant.use_overview');
  if not public._assistant_on('guard') then raise exception 'MODE_OFF'; end if;
  return jsonb_build_object(
    'days', v_days,
    -- cashiers whose discounts or refunds stand out from the rest
    'cashiers', coalesce((select jsonb_agg(x order by (x ->> 'refund_count')::int desc) from (
      select jsonb_build_object('name', public._ops_name(c.uid), 'sales', c.n, 'total_minor', c.total, 'discount_percent', case when c.sub > 0 then round(c.disc::numeric / c.sub * 100, 1) else 0 end,
               'refund_count', coalesce(r.n, 0), 'refund_minor', coalesce(r.amount, 0),
               'flag', (coalesce(r.n, 0) >= 3 and coalesce(r.n, 0)::numeric / greatest(c.n, 1) > 0.1) or (c.sub > 0 and c.disc::numeric / c.sub > 0.15)) as x
        from (select cashier_id uid, count(*) n, sum(total_minor) total, sum(discount_minor) disc, sum(subtotal_minor) sub from public.pos_sales
               where created_at >= now() - make_interval(days => v_days) and public._branch_view_ok(branch_id) group by cashier_id) c
        left join (select requested_by uid, count(*) n, sum(amount_minor) amount from public.pos_refunds
                    where created_at >= now() - make_interval(days => v_days) and public._branch_view_ok(branch_id) group by requested_by) r on r.uid = c.uid) q), '[]'::jsonb),
    'cash_differences', coalesce((select jsonb_agg(jsonb_build_object('branch', b.name_ar, 'cashier', public._ops_name(h.cashier_id), 'closed_at', h.closed_at, 'variance_minor', h.variance_minor) order by h.closed_at desc)
        from public.shifts h join public.branches b on b.id = h.branch_id
       where h.closed_at >= now() - make_interval(days => v_days) and coalesce(h.variance_minor, 0) <> 0 and public._branch_view_ok(h.branch_id)), '[]'::jsonb),
    -- screens, batteries and accessories close to running out
    'low_key', coalesce((select jsonb_agg(jsonb_build_object('sku', p.sku, 'name', p.name_ar, 'total', p.stock_quantity, 'category', c.name_ar) order by p.stock_quantity, p.name_ar)
        from (select * from public.products where status = 'published' and stock_quantity <= 5 order by stock_quantity limit 300) p join public.categories c on c.id = p.category_id
       where c.kind = 'accessories' or c.name_ar ~* '(شاش|بطار|اكسسوار|إكسسوار|اكسسوارات|إكسسوارات|جراب|شاحن|كابل)' or c.name_en ~* '(screen|display|batter|accessor|case|charger|cable)'), '[]'::jsonb),
    -- a branch is empty of a product while another one holds plenty
    'imbalance', coalesce((select jsonb_agg(jsonb_build_object('name', p.name_ar, 'sku', p.sku, 'empty_branch', e.name_ar, 'rich_branch', r.name_ar, 'rich_qty', r.qty))
        from public.products p
        join lateral (select b.name_ar, bs.quantity qty from public.branch_stock bs join public.branches b on b.id = bs.branch_id
                       where bs.product_id = p.id and not b.is_hq and bs.quantity >= 5 order by bs.quantity desc limit 1) r on true
        join lateral (select b.name_ar from public.branches b where b.is_active and not b.is_hq and public._branch_view_ok(b.id)
                         and coalesce((select quantity from public.branch_stock where branch_id = b.id and product_id = p.id), 0) = 0 limit 1) e on true
       where p.status = 'published' limit 30), '[]'::jsonb),
    -- re-order: sold in the last 30 days, will run out within two weeks; suggested quantity covers three weeks
    'reorder', coalesce((select jsonb_agg(x order by (x ->> 'days_left')::numeric) from (
      select jsonb_build_object('sku', p.sku, 'name', p.name_ar, 'stock', p.stock_quantity, 'per_day', round(u.units / 30.0, 2), 'days_left', round(p.stock_quantity / (u.units / 30.0), 1),
               'suggest', greatest(ceil(u.units / 30.0 * 21)::int - p.stock_quantity, 0)) as x
        from public.products p join public.v_assistant_units u on u.product_id = p.id
       where p.status = 'published' and u.units >= 3 and p.stock_quantity / (u.units / 30.0) < 14 limit 40) q), '[]'::jsonb),
    -- stagnant: stock on the shelf, nothing sold for 60 days
    'stagnant', coalesce((select jsonb_agg(jsonb_build_object('sku', p.sku, 'name', p.name_ar, 'stock', p.stock_quantity) order by p.stock_quantity desc)
        from (select * from public.products p0 where p0.status = 'published' and p0.stock_quantity > 0 and p0.created_at < now() - interval '60 days'
                 and not exists (select 1 from public.pos_sale_items i join public.pos_sales s on s.id = i.sale_id where i.product_id = p0.id and s.created_at >= now() - interval '60 days')
                 and not exists (select 1 from public.order_items oi join public.orders o on o.id = oi.order_id where oi.product_id = p0.id and o.created_at >= now() - interval '60 days' and o.status <> 'cancelled')
               order by p0.stock_quantity desc limit 30) p), '[]'::jsonb));
end $$;
revoke all on function public.assistant_guard_overview(int) from public, anon;
grant execute on function public.assistant_guard_overview(int) to authenticated;
