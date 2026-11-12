-- 0181: "اليومية والتحصيل" - the daily register per branch (like an Odoo POS session, one line per branch per day).
-- A day = every shift of a branch OPENED on that Cairo calendar day. Each line sums cash / card / wallet (sales minus refunds),
-- expenses, drawer difference, and "to collect" = the cash counted at closing minus the opening float of each closed shift.
-- The accountant records collections on any later day (several allowed, can be voided with a reason), the owner can lock
-- a day (nothing changes after), and the owner can switch the whole page off for the team (daybook setting).
-- Permissions (owner decides who has them in Team > Permissions):
--   daybook.view    - see the days of his branches (branches.all: every branch)
--   daybook.collect - record / void a collection
--   daybook.lock    - lock / unlock a day

create table if not exists public.daybook_collections (
  id uuid primary key default gen_random_uuid(),
  branch_id uuid not null references public.branches(id),
  day date not null,
  amount_minor bigint not null check (amount_minor > 0),
  method text not null default 'cash' check (method in ('cash', 'bank', 'wallet', 'other')),
  note text,
  collected_by uuid not null,
  collected_by_name text,
  created_at timestamptz not null default now(),
  voided_at timestamptz,
  voided_by uuid,
  void_reason text
);
create index if not exists daybook_collections_bd on public.daybook_collections(branch_id, day);
alter table public.daybook_collections enable row level security;
revoke all on public.daybook_collections from anon, authenticated;

create table if not exists public.daybook_locks (
  branch_id uuid not null references public.branches(id),
  day date not null,
  locked_by uuid not null,
  locked_by_name text,
  locked_at timestamptz not null default now(),
  primary key (branch_id, day)
);
alter table public.daybook_locks enable row level security;
revoke all on public.daybook_locks from anon, authenticated;

insert into public.permission_catalog (permission, grp, name_ar, name_en, desc_ar, desc_en, sensitive, inert, sort) values
  ('daybook.view', 'pos', 'يشوف اليومية والتحصيل', 'See the daily register',
   'سطر لكل يوم في فرعه: كاش وفيزا ومحفظة ومرتجع ومصروفات وفرق الدرج واللي اتحصّل وخطوات اليوم', 'One line per day of his branch: cash, card, wallet, refunds, expenses, drawer difference, what was collected and the day''s steps', true, false, 92),
  ('daybook.collect', 'pos', 'يسجّل تحصيل اليومية (محاسب)', 'Record daily collections (accountant)',
   'يسجّل إنه استلم فلوس يوم معيّن من الفرع، حتى لو في يوم تاني، ويلغي تحصيل غلط بسبب', 'Records that he received a day''s money from a branch, even on a later day, and voids a wrong one with a reason', true, false, 93),
  ('daybook.lock', 'pos', 'يقفل اليومية', 'Lock a day',
   'بعد القفل محدش يقدر يسجّل أو يلغي تحصيل في اليوم ده', 'After locking, nobody can record or void a collection for that day', true, false, 94)
on conflict (permission) do nothing;

insert into public.role_permissions (role, permission) values
  ('owner', 'daybook.view'), ('owner', 'daybook.collect'), ('owner', 'daybook.lock'),
  ('manager', 'daybook.view'), ('manager', 'daybook.collect'),
  ('accountant', 'daybook.view'), ('accountant', 'daybook.collect'),
  ('cashier', 'daybook.view')
on conflict do nothing;

insert into public.application_settings (key, value, updated_at) values ('daybook', '{"enabled": true}', now()) on conflict (key) do nothing;

-- ---------------------------------------------------------------- helpers
create or replace function public._cairo_day(p_ts timestamptz) returns date
language sql immutable as $$ select (p_ts at time zone 'Africa/Cairo')::date $$;

create or replace function public._daybook_ok(p_branch uuid) returns boolean
language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not public.has_permission('daybook.view') then return false; end if;
  if not public.has_role('owner') and coalesce((select (value ->> 'enabled')::boolean from public.application_settings where key = 'daybook'), true) = false then
    raise exception 'DAYBOOK_OFF';
  end if;
  return p_branch is null or public._branch_view_ok(p_branch);
end $$;
revoke all on function public._daybook_ok(uuid) from public, anon, authenticated;

-- the numbers of one branch-day
create or replace function public._daybook_row(p_branch uuid, p_day date) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare s record; t jsonb;
  n int := 0; n_open int := 0; v_count int := 0; v_float bigint := 0; v_cash bigint := 0; v_card bigint := 0; v_wallet bigint := 0;
  v_rcash bigint := 0; v_rcard bigint := 0; v_rwallet bigint := 0; v_exp bigint := 0; v_counted bigint := 0; v_expected bigint := 0;
  v_var bigint := 0; v_corr bigint := 0; v_to_collect bigint := 0; v_collected bigint := 0; v_names text[] := '{}'; v_first timestamptz; v_last timestamptz;
  v_locked boolean := false; v_lock_by text; v_lock_at timestamptz;
begin
  for s in select sh.*, coalesce(tm.login_display, p.full_name, '—') cashier_name
             from public.shifts sh left join public.profiles p on p.id = sh.cashier_id left join public.team_members tm on tm.user_id = sh.cashier_id
            where sh.branch_id = p_branch and public._cairo_day(sh.opened_at) = p_day loop
    n := n + 1;
    t := public._shift_totals(s.id);
    v_count := v_count + (t ->> 'sales_count')::int;
    v_float := v_float + s.opening_cash_minor;
    v_cash := v_cash + (t ->> 'cash_sales_minor')::bigint;
    v_card := v_card + (t ->> 'card_sales_minor')::bigint;
    v_wallet := v_wallet + (t ->> 'wallet_sales_minor')::bigint;
    v_rcash := v_rcash + (t ->> 'cash_refunds_minor')::bigint;
    v_rcard := v_rcard + (t ->> 'card_refunds_minor')::bigint;
    v_rwallet := v_rwallet + (t ->> 'wallet_refunds_minor')::bigint;
    v_exp := v_exp + (t ->> 'expenses_minor')::bigint;
    v_corr := v_corr + coalesce((select sum(c.amount_minor) from public.shift_corrections c where c.shift_id = s.id), 0);
    if not (s.cashier_name = any(v_names)) then v_names := v_names || s.cashier_name; end if;
    v_first := least(coalesce(v_first, s.opened_at), s.opened_at);
    if s.status = 'open' then
      n_open := n_open + 1;
      v_expected := v_expected + (t ->> 'expected_minor')::bigint;
    else
      v_last := greatest(coalesce(v_last, s.closed_at), s.closed_at);
      v_counted := v_counted + coalesce(s.counted_cash_minor, 0);
      v_expected := v_expected + coalesce(s.expected_cash_minor, (t ->> 'expected_minor')::bigint);
      v_var := v_var + coalesce(s.variance_minor, 0);
      v_to_collect := v_to_collect + greatest(coalesce(s.counted_cash_minor, 0) - s.opening_cash_minor, 0);
    end if;
  end loop;
  v_collected := coalesce((select sum(amount_minor) from public.daybook_collections where branch_id = p_branch and day = p_day and voided_at is null), 0);
  select locked_by_name, locked_at into v_lock_by, v_lock_at from public.daybook_locks where branch_id = p_branch and day = p_day;
  v_locked := found;
  return jsonb_build_object(
    'branch_id', p_branch,
    'branch_name', (select name_ar from public.branches where id = p_branch),
    'day', p_day,
    'shifts', n, 'open_shifts', n_open, 'cashiers', to_jsonb(v_names),
    'first_open', v_first, 'last_close', v_last,
    'sales_count', v_count, 'float_minor', v_float,
    'cash_minor', v_cash - v_rcash, 'card_minor', v_card - v_rcard, 'wallet_minor', v_wallet - v_rwallet,
    'cash_sales_minor', v_cash, 'card_sales_minor', v_card, 'wallet_sales_minor', v_wallet,
    'refunds_minor', v_rcash + v_rcard + v_rwallet, 'expenses_minor', v_exp,
    'total_minor', (v_cash + v_card + v_wallet) - (v_rcash + v_rcard + v_rwallet),
    'expected_minor', v_expected, 'counted_minor', v_counted, 'variance_minor', v_var, 'corrections_minor', v_corr,
    'to_collect_minor', v_to_collect, 'collected_minor', v_collected, 'remaining_minor', greatest(v_to_collect - v_collected, 0),
    'locked', v_locked, 'locked_by', v_lock_by, 'locked_at', v_lock_at,
    'status', case when v_locked then 'locked'
                   when n_open > 0 then 'open'
                   when v_to_collect > 0 and v_collected >= v_to_collect then 'collected'
                   when v_to_collect = 0 then 'nothing'
                   when v_collected > 0 then 'partial'
                   else 'due' end);
end $$;
revoke all on function public._daybook_row(uuid, date) from public, anon, authenticated;

-- ---------------------------------------------------------------- the list: one line per branch per day, newest first
create or replace function public.daybook_list(p_branch uuid default null, p_from date default null, p_to date default null) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare v_from date := coalesce(p_from, public._cairo_day(now()) - 13); v_to date := coalesce(p_to, public._cairo_day(now()));
begin
  perform public.require_auth();
  if not public._daybook_ok(p_branch) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if v_to < v_from or v_to - v_from > 92 then raise exception 'INVALID_INPUT'; end if;
  return jsonb_build_object(
    'from', v_from, 'to', v_to,
    'enabled', coalesce((select (value ->> 'enabled')::boolean from public.application_settings where key = 'daybook'), true),
    'can_collect', public.has_permission('daybook.collect'),
    'can_lock', public.has_permission('daybook.lock'),
    'rows', coalesce((
      select jsonb_agg(public._daybook_row(x.branch_id, x.day) order by x.day desc, x.name_ar)
        from (select distinct sh.branch_id, public._cairo_day(sh.opened_at) as day, b.name_ar
                from public.shifts sh join public.branches b on b.id = sh.branch_id
               where public._cairo_day(sh.opened_at) between v_from and v_to
                 and public._branch_view_ok(sh.branch_id) and (p_branch is null or sh.branch_id = p_branch)) x), '[]'::jsonb),
    -- days still waiting for collection before the range (the accountant may come days later)
    'older_due', coalesce((
      select jsonb_agg(r order by (r ->> 'day') desc) from (
        select public._daybook_row(x.branch_id, x.day) r
          from (select distinct sh.branch_id, public._cairo_day(sh.opened_at) as day
                  from public.shifts sh
                 where public._cairo_day(sh.opened_at) < v_from and public._cairo_day(sh.opened_at) >= v_from - 60
                   and sh.status <> 'open' and public._branch_view_ok(sh.branch_id) and (p_branch is null or sh.branch_id = p_branch)) x) q
       where (r ->> 'status') in ('due', 'partial')), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------- one day: the numbers and the steps (process) in time order
create or replace function public.daybook_day(p_branch uuid, p_day date) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare v jsonb := '[]'::jsonb;
begin
  perform public.require_auth();
  if p_branch is null or p_day is null or not public._daybook_ok(p_branch) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  -- shift opened / closed
  v := v || coalesce((select jsonb_agg(e) from (
    select jsonb_build_object('kind', 'open', 'at', sh.opened_at, 'who', coalesce(tm.login_display, p.full_name, '—'), 'amount_minor', sh.opening_cash_minor, 'shift_id', sh.id) e
      from public.shifts sh left join public.profiles p on p.id = sh.cashier_id left join public.team_members tm on tm.user_id = sh.cashier_id
     where sh.branch_id = p_branch and public._cairo_day(sh.opened_at) = p_day
    union all
    select jsonb_build_object('kind', 'close', 'at', sh.closed_at, 'who', coalesce(r.closed_by_name, tm.login_display, p.full_name, '—'), 'shift_id', sh.id,
             'report_no', r.report_no, 'counted_minor', sh.counted_cash_minor, 'expected_minor', sh.expected_cash_minor, 'variance_minor', sh.variance_minor,
             'methods', r.methods, 'sales_count', r.sales_count, 'sales_minor', r.sales_minor, 'note', sh.close_note)
      from public.shifts sh left join public.shift_reports r on r.shift_id = sh.id
      left join public.profiles p on p.id = sh.closed_by left join public.team_members tm on tm.user_id = sh.closed_by
     where sh.branch_id = p_branch and public._cairo_day(sh.opened_at) = p_day and sh.status <> 'open' and sh.closed_at is not null
    union all
    select jsonb_build_object('kind', 'refund', 'at', rf.created_at, 'amount_minor', rf.amount_minor, 'method', rf.refund_method, 'reason', rf.reason,
             'who', (select coalesce(tm.login_display, p.full_name, '—') from public.profiles p left join public.team_members tm on tm.user_id = p.id where p.id = rf.requested_by))
      from public.pos_refunds rf join public.shifts sh on sh.id = rf.shift_id
     where sh.branch_id = p_branch and public._cairo_day(sh.opened_at) = p_day
    union all
    select jsonb_build_object('kind', 'expense', 'at', ex.created_at, 'amount_minor', ex.amount_minor, 'reason', ex.reason,
             'who', (select coalesce(tm.login_display, p.full_name, '—') from public.profiles p left join public.team_members tm on tm.user_id = p.id where p.id = ex.created_by))
      from public.pos_expenses ex join public.shifts sh on sh.id = ex.shift_id
     where sh.branch_id = p_branch and public._cairo_day(sh.opened_at) = p_day
    union all
    select jsonb_build_object('kind', 'correction', 'at', c.created_at, 'amount_minor', c.amount_minor, 'reason', c.reason, 'who', c.created_by_name)
      from public.shift_corrections c join public.shifts sh on sh.id = c.shift_id
     where sh.branch_id = p_branch and public._cairo_day(sh.opened_at) = p_day
    union all
    select jsonb_build_object('kind', case when dc.voided_at is null then 'collect' else 'collect_void' end, 'at', dc.created_at, 'id', dc.id,
             'amount_minor', dc.amount_minor, 'method', dc.method, 'note', dc.note, 'who', dc.collected_by_name,
             'voided_at', dc.voided_at, 'void_reason', dc.void_reason)
      from public.daybook_collections dc where dc.branch_id = p_branch and dc.day = p_day
    union all
    select jsonb_build_object('kind', 'lock', 'at', l.locked_at, 'who', l.locked_by_name)
      from public.daybook_locks l where l.branch_id = p_branch and l.day = p_day
  ) q), '[]'::jsonb);
  return jsonb_build_object(
    'summary', public._daybook_row(p_branch, p_day),
    'steps', coalesce((select jsonb_agg(x order by (x ->> 'at')::timestamptz) from jsonb_array_elements(v) x), '[]'::jsonb),
    'can_collect', public.has_permission('daybook.collect'),
    'can_lock', public.has_permission('daybook.lock'));
end $$;

-- ---------------------------------------------------------------- collect / void / lock / switch
create or replace function public.daybook_collect(p_branch uuid, p_day date, p_amount_minor bigint, p_method text default 'cash', p_note text default null) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_uid uuid := public.require_auth(); r jsonb; v_id uuid; v_name text;
begin
  if not public.has_permission('daybook.collect') or not public._daybook_ok(p_branch) or p_branch is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_amount_minor is null or p_amount_minor <= 0 or coalesce(p_method, '') not in ('cash', 'bank', 'wallet', 'other') then raise exception 'INVALID_INPUT'; end if;
  perform pg_advisory_xact_lock(hashtext('daybook:' || p_branch::text || ':' || p_day::text));
  r := public._daybook_row(p_branch, p_day);
  if (r ->> 'locked')::boolean then raise exception 'DAY_LOCKED'; end if;
  if (r ->> 'open_shifts')::int > 0 then raise exception 'SHIFT_STILL_OPEN'; end if;
  if (r ->> 'shifts')::int = 0 then raise exception 'NOT_FOUND'; end if;
  if p_amount_minor > (r ->> 'remaining_minor')::bigint then raise exception 'OVER_COLLECT'; end if;
  select coalesce(tm.login_display, p.full_name, '—') into v_name from public.profiles p left join public.team_members tm on tm.user_id = p.id where p.id = v_uid;
  insert into public.daybook_collections (branch_id, day, amount_minor, method, note, collected_by, collected_by_name)
  values (p_branch, p_day, p_amount_minor, p_method, nullif(left(btrim(coalesce(p_note, '')), 300), ''), v_uid, v_name) returning id into v_id;
  perform public.audit_write('daybook.collect', 'branch', p_branch::text, jsonb_build_object('day', p_day, 'amount_minor', p_amount_minor, 'method', p_method, 'id', v_id));
  return public._daybook_row(p_branch, p_day);
end $$;

create or replace function public.daybook_collection_void(p_id uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_uid uuid := public.require_auth(); c public.daybook_collections%rowtype;
begin
  select * into c from public.daybook_collections where id = p_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if not public.has_permission('daybook.collect') or not public._daybook_ok(c.branch_id) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if c.voided_at is not null then raise exception 'ALREADY_VOIDED'; end if;
  if length(btrim(coalesce(p_reason, ''))) < 3 then raise exception 'REASON_REQUIRED'; end if;
  if exists (select 1 from public.daybook_locks where branch_id = c.branch_id and day = c.day) then raise exception 'DAY_LOCKED'; end if;
  update public.daybook_collections set voided_at = now(), voided_by = v_uid, void_reason = left(btrim(p_reason), 300) where id = p_id;
  perform public.audit_write('daybook.collect_void', 'branch', c.branch_id::text, jsonb_build_object('day', c.day, 'amount_minor', c.amount_minor, 'id', p_id, 'reason', p_reason));
  return public._daybook_row(c.branch_id, c.day);
end $$;

create or replace function public.daybook_lock(p_branch uuid, p_day date, p_lock boolean) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_uid uuid := public.require_auth(); v_name text;
begin
  if not public.has_permission('daybook.lock') or not public._daybook_ok(p_branch) or p_branch is null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if coalesce(p_lock, true) then
    if (public._daybook_row(p_branch, p_day) ->> 'open_shifts')::int > 0 then raise exception 'SHIFT_STILL_OPEN'; end if;
    select coalesce(tm.login_display, p.full_name, '—') into v_name from public.profiles p left join public.team_members tm on tm.user_id = p.id where p.id = v_uid;
    insert into public.daybook_locks (branch_id, day, locked_by, locked_by_name) values (p_branch, p_day, v_uid, v_name) on conflict do nothing;
  else
    delete from public.daybook_locks where branch_id = p_branch and day = p_day;
  end if;
  perform public.audit_write(case when coalesce(p_lock, true) then 'daybook.lock' else 'daybook.unlock' end, 'branch', p_branch::text, jsonb_build_object('day', p_day));
  return public._daybook_row(p_branch, p_day);
end $$;

-- owner: switch the page on/off for the whole team (the owner always sees it)
create or replace function public.daybook_enable(p_on boolean) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  perform public.require_auth();
  if not public.has_role('owner') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  insert into public.application_settings (key, value, updated_by, updated_at) values ('daybook', jsonb_build_object('enabled', coalesce(p_on, true)), auth.uid(), now())
    on conflict (key) do update set value = excluded.value, updated_by = excluded.updated_by, updated_at = now();
  perform public.audit_write('daybook.switch', 'setting', 'daybook', jsonb_build_object('enabled', coalesce(p_on, true)));
end $$;

do $$
declare f text;
begin
  foreach f in array array['daybook_list(uuid,date,date)', 'daybook_day(uuid,date)', 'daybook_collect(uuid,date,bigint,text,text)',
    'daybook_collection_void(uuid,text)', 'daybook_lock(uuid,date,boolean)', 'daybook_enable(boolean)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
