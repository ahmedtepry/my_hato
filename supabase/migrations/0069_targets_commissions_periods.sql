-- 0069: accountant picks any period (right), branch and employee monthly targets, per-product sales commission.

-- ------------------------------------------------------------------ permissions
insert into public.permission_catalog (permission, grp, name_ar, name_en, desc_ar, desc_en, sensitive, inert, sort) values
 ('books.period',   'pos', 'يختار فترة التقرير (يوم/شهر/سنة)', 'Pick the report period (day / month / year)',
  'يطلّع حسابات وورديات أي يوم أو شهر أو سنة أو فترة يحددها. من غيرها بيشوف آخر ٣٠ يوم بس', 'Reports and shifts for any day, month, year or custom range. Without it, the last 30 days only', false, false, 91),
 ('targets.view',   'pos', 'يشوف تارجت الفروع', 'See branch targets', 'رسم بياني بيوضّح أنهي فرع حقق التارجت وأنهي لأ', 'A chart showing which branch hit its target', false, false, 92),
 ('targets.manage', 'pos', 'يحدد التارجت (فروع وموظفين)', 'Set targets (branches and employees)', 'يغيّر تارجت أي فرع ويدّي أي موظف تارجت شهري', 'Change a branch target and give an employee a monthly target', false, false, 93),
 ('targets.mine',   'pos', 'يشوف تارجته وعمولته', 'See his own target and commission', 'يشوف وصل لكام في المية من تارجته وعمولته لحظة بلحظة', 'Sees his progress and commission live', false, false, 94),
 ('commission.set', 'pos', 'يحدد عمولة المنتجات', 'Set product commissions', 'يحط على كل منتج مبلغ عمولة بيتحسب للبياع عند البيع', 'Sets a commission amount per product, earned by the seller on each sale', true, false, 95)
on conflict (permission) do update set name_ar = excluded.name_ar, name_en = excluded.name_en, desc_ar = excluded.desc_ar, desc_en = excluded.desc_en, sensitive = excluded.sensitive, inert = false;
insert into public.role_permissions (role, permission) values
 ('owner','books.period'),('manager','books.period'),('accountant','books.period'),
 ('owner','targets.view'),('manager','targets.view'),('accountant','targets.view'),
 ('owner','targets.manage'),('owner','commission.set'),
 ('sales','targets.mine'),('cashier','targets.mine')
on conflict do nothing;

-- ------------------------------------------------------------------ tables (reached only through the functions below)
create table if not exists public.branch_targets (
  branch_id uuid primary key references public.branches(id) on delete cascade,
  monthly_minor bigint not null check (monthly_minor >= 0),
  updated_by uuid references auth.users(id), updated_at timestamptz not null default now());
create table if not exists public.user_targets (
  user_id uuid primary key references auth.users(id) on delete cascade,
  monthly_minor bigint not null check (monthly_minor > 0),
  updated_by uuid references auth.users(id), updated_at timestamptz not null default now());
create table if not exists public.product_commissions (
  product_id uuid primary key references public.products(id) on delete cascade,
  amount_minor bigint not null check (amount_minor > 0),
  updated_by uuid references auth.users(id), updated_at timestamptz not null default now());
alter table public.branch_targets enable row level security;
alter table public.user_targets enable row level security;
alter table public.product_commissions enable row level security;
revoke all on public.branch_targets, public.user_targets, public.product_commissions from anon, authenticated;

-- every ordinary branch starts at 50,000 EGP a month (5,000,000 piasters); the owner can change it
insert into public.branch_targets (branch_id, monthly_minor)
select id, 5000000 from public.branches where not is_hq on conflict do nothing;

-- the commission of a line is frozen when the sale is made (changing a product's commission later never rewrites history)
alter table public.pos_sale_items add column if not exists commission_unit_minor bigint not null default 0;
create or replace function public._item_commission() returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.commission_unit_minor := coalesce((select amount_minor from public.product_commissions where product_id = new.product_id), 0);
  return new;
end $$;
drop trigger if exists pos_sale_items_commission on public.pos_sale_items;
create trigger pos_sale_items_commission before insert on public.pos_sale_items for each row execute function public._item_commission();

-- ------------------------------------------------------------------ the period right
create or replace function public._books_range_ok(p_from timestamptz, p_to timestamptz) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if public.has_permission('shifts.review') and not public.has_permission('books.period') and not public.has_role('owner') then
    if p_from is null or p_from < now() - interval '32 days' or (p_to is not null and p_to - p_from > interval '32 days') then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
  end if;
end $$;
revoke all on function public._books_range_ok(timestamptz, timestamptz) from public, anon;
grant execute on function public._books_range_ok(timestamptz, timestamptz) to authenticated;

create or replace function public._patch_books_fn(p_sig text, p_more boolean) returns void language plpgsql as $$
declare v_fn regprocedure := to_regprocedure(p_sig); d text;
begin
  if v_fn is null then return; end if;
  d := pg_get_functiondef(v_fn);
  if position('_books_range_ok' in d) = 0 then
    d := replace(d, 'perform public.require_auth();', 'perform public.require_auth();' || E'\n  ' || 'perform public._books_range_ok(p_from, p_to);');
  end if;
  if p_more then d := replace(d, '1), 300)', '1), 3000)'); end if;
  execute d;
end $$;
select public._patch_books_fn('public.pos_branch_report(timestamptz,timestamptz)', false);
select public._patch_books_fn('public.pos_shift_list(uuid,timestamptz,timestamptz,integer)', true);
select public._patch_books_fn('public.pos_shift_report_list(uuid,timestamptz,timestamptz,integer)', true);
select public._patch_books_fn('public.books_sales(uuid,timestamptz,timestamptz,integer)', false);
drop function public._patch_books_fn(text, boolean);

-- ------------------------------------------------------------------ helpers
create or replace function public._cairo_month(p_month date, out m_from timestamptz, out m_to timestamptz, out m_day timestamptz) language plpgsql stable as $$
declare v_first date := date_trunc('month', coalesce(p_month, (now() at time zone 'Africa/Cairo')::date))::date;
begin
  m_from := v_first::timestamp at time zone 'Africa/Cairo';
  m_to := (v_first + interval '1 month')::timestamp at time zone 'Africa/Cairo';
  m_day := date_trunc('day', now() at time zone 'Africa/Cairo') at time zone 'Africa/Cairo';
end $$;

-- ------------------------------------------------------------------ branch chart + employees (owner / manager / accountant)
create or replace function public.targets_overview(p_month date default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_from timestamptz; v_to timestamptz; v_day timestamptz; v_money boolean := public.has_permission('commission.set') or public.has_permission('targets.manage');
        v_b jsonb; v_e jsonb;
begin
  perform public.require_permission('targets.view');
  select m_from, m_to, m_day into v_from, v_to, v_day from public._cairo_month(p_month);
  select coalesce(jsonb_agg(x order by (x ->> 'pct')::numeric desc), '[]') into v_b from (
    select jsonb_build_object('branch_id', b.id, 'name_ar', b.name_ar, 'name_en', b.name_en,
             'target_minor', coalesce(t.monthly_minor, 5000000), 'net_minor', coalesce(s.net, 0), 'sales_count', coalesce(s.n, 0),
             'pct', case when coalesce(t.monthly_minor, 5000000) > 0 then round(coalesce(s.net, 0) * 100.0 / coalesce(t.monthly_minor, 5000000), 1) else 0 end,
             'hit', coalesce(s.net, 0) >= coalesce(t.monthly_minor, 5000000)) as x
      from public.branches b
      left join public.branch_targets t on t.branch_id = b.id
      left join lateral (select sum(p.total_minor - p.refunded_minor) as net, count(*) as n from public.pos_sales p
                          where p.branch_id = b.id and p.created_at >= v_from and p.created_at < v_to) s on true
     where b.is_active and not b.is_hq and public._branch_view_ok(b.id)) q;
  select coalesce(jsonb_agg(x order by (x ->> 'net_minor')::bigint desc), '[]') into v_e from (
    select jsonb_build_object('user_id', u.uid, 'name', coalesce(tm.login_display, pr.full_name, '—'),
             'role', (select role from public.user_roles ur where ur.user_id = u.uid limit 1),
             'target_minor', ut.monthly_minor, 'net_minor', coalesce(s.net, 0),
             'pct', case when ut.monthly_minor > 0 then round(coalesce(s.net, 0) * 100.0 / ut.monthly_minor, 1) else null end,
             'commission_minor', case when v_money then coalesce(c.com, 0) else null end) as x
      from (select cashier_id as uid from public.pos_sales where created_at >= v_from and created_at < v_to and public._branch_view_ok(branch_id)
            union select user_id from public.user_targets) u
      left join public.user_targets ut on ut.user_id = u.uid
      left join public.team_members tm on tm.user_id = u.uid
      left join public.profiles pr on pr.id = u.uid
      left join lateral (select sum(p.total_minor - p.refunded_minor) as net from public.pos_sales p
                          where p.cashier_id = u.uid and p.created_at >= v_from and p.created_at < v_to and public._branch_view_ok(p.branch_id)) s on true
      left join lateral (select sum(i.commission_unit_minor * (i.quantity - i.refunded_qty)) as com from public.pos_sale_items i
                           join public.pos_sales p on p.id = i.sale_id
                          where p.cashier_id = u.uid and p.created_at >= v_from and p.created_at < v_to and public._branch_view_ok(p.branch_id)) c on true
     where exists (select 1 from public.user_roles ur where ur.user_id = u.uid)) q;
  return jsonb_build_object('month_from', v_from, 'month_to', v_to, 'default_target_minor', 5000000, 'branches', v_b, 'employees', v_e,
                            'can_manage', public.has_permission('targets.manage'));
end $$;

-- ------------------------------------------------------------------ the seller sees only himself
create or replace function public.my_target_status() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_from timestamptz; v_to timestamptz; v_day timestamptz; v_t bigint; v_net bigint; v_com bigint; v_net_d bigint; v_com_d bigint;
begin
  perform public.require_permission('targets.mine');
  select m_from, m_to, m_day into v_from, v_to, v_day from public._cairo_month(null);
  select monthly_minor into v_t from public.user_targets where user_id = auth.uid();
  select coalesce(sum(total_minor - refunded_minor), 0) into v_net from public.pos_sales where cashier_id = auth.uid() and created_at >= v_from and created_at < v_to;
  select coalesce(sum(total_minor - refunded_minor), 0) into v_net_d from public.pos_sales where cashier_id = auth.uid() and created_at >= v_day;
  select coalesce(sum(i.commission_unit_minor * (i.quantity - i.refunded_qty)), 0) into v_com from public.pos_sale_items i
    join public.pos_sales p on p.id = i.sale_id where p.cashier_id = auth.uid() and p.created_at >= v_from and p.created_at < v_to;
  select coalesce(sum(i.commission_unit_minor * (i.quantity - i.refunded_qty)), 0) into v_com_d from public.pos_sale_items i
    join public.pos_sales p on p.id = i.sale_id where p.cashier_id = auth.uid() and p.created_at >= v_day;
  return jsonb_build_object('month_from', v_from, 'target_minor', v_t, 'net_minor', v_net,
    'pct', case when coalesce(v_t, 0) > 0 then round(v_net * 100.0 / v_t, 1) else null end,
    'commission_month_minor', v_com, 'commission_today_minor', v_com_d, 'sales_today_minor', v_net_d, 'at', now());
end $$;

-- ------------------------------------------------------------------ setting targets and commissions
create or replace function public.targets_set_branch(p_branch uuid, p_monthly_minor bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.require_permission('targets.manage');
  if p_monthly_minor is null or p_monthly_minor < 0 or p_monthly_minor > 100000000000 then raise exception 'INVALID_INPUT'; end if;
  if not exists (select 1 from public.branches where id = p_branch and not is_hq) then raise exception 'NOT_FOUND'; end if;
  insert into public.branch_targets (branch_id, monthly_minor, updated_by) values (p_branch, p_monthly_minor, auth.uid())
  on conflict (branch_id) do update set monthly_minor = excluded.monthly_minor, updated_by = auth.uid(), updated_at = now();
  perform public.audit_write('target.branch', 'branch', p_branch::text, jsonb_build_object('monthly_minor', p_monthly_minor));
end $$;

create or replace function public.targets_set_user(p_user uuid, p_monthly_minor bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.require_permission('targets.manage');
  if not exists (select 1 from public.user_roles where user_id = p_user) then raise exception 'NOT_FOUND'; end if;
  if p_monthly_minor is null or p_monthly_minor = 0 then
    delete from public.user_targets where user_id = p_user;
  else
    if p_monthly_minor < 0 or p_monthly_minor > 100000000000 then raise exception 'INVALID_INPUT'; end if;
    insert into public.user_targets (user_id, monthly_minor, updated_by) values (p_user, p_monthly_minor, auth.uid())
    on conflict (user_id) do update set monthly_minor = excluded.monthly_minor, updated_by = auth.uid(), updated_at = now();
  end if;
  perform public.audit_write('target.user', 'user', p_user::text, jsonb_build_object('monthly_minor', coalesce(p_monthly_minor, 0)));
end $$;

create or replace function public.commission_list(p_search text default null, p_limit int default 100)
returns table (product_id uuid, name_ar text, sku text, price_minor bigint, commission_minor bigint)
language plpgsql stable security definer set search_path = public as $$
declare v text := nullif(btrim(coalesce(p_search, '')), '');
begin
  perform public.require_permission('commission.set');
  return query select p.id, p.name_ar, p.sku, p.price_minor, c.amount_minor
    from public.products p left join public.product_commissions c on c.product_id = p.id
   where v is null or p.name_ar ilike '%' || v || '%' or p.sku ilike '%' || v || '%'
   order by (c.amount_minor is null), p.name_ar limit least(greatest(coalesce(p_limit, 100), 1), 300);
end $$;

create or replace function public.commission_get(p_product uuid) returns bigint
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_permission('commission.set');
  return (select amount_minor from public.product_commissions where product_id = p_product);
end $$;

create or replace function public.commission_set(p_product uuid, p_amount_minor bigint) returns void
language plpgsql security definer set search_path = public as $$
declare v_price bigint;
begin
  perform public.require_permission('commission.set');
  select price_minor into v_price from public.products where id = p_product;
  if not found then raise exception 'NOT_FOUND'; end if;
  if p_amount_minor is null or p_amount_minor = 0 then
    delete from public.product_commissions where product_id = p_product;
  else
    if p_amount_minor < 0 or p_amount_minor > v_price then raise exception 'INVALID_INPUT'; end if;
    insert into public.product_commissions (product_id, amount_minor, updated_by) values (p_product, p_amount_minor, auth.uid())
    on conflict (product_id) do update set amount_minor = excluded.amount_minor, updated_by = auth.uid(), updated_at = now();
  end if;
  perform public.audit_write('commission.set', 'product', p_product::text, jsonb_build_object('amount_minor', coalesce(p_amount_minor, 0)));
end $$;

do $$ declare f text;
begin
  foreach f in array array['targets_overview(date)','my_target_status()','targets_set_branch(uuid,bigint)','targets_set_user(uuid,bigint)',
                           'commission_list(text,int)','commission_get(uuid)','commission_set(uuid,bigint)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
revoke all on function public._cairo_month(date) from public, anon, authenticated;
revoke all on function public._item_commission() from public, anon, authenticated;
