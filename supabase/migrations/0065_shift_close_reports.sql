-- 0065: closing a cash shift becomes a controlled, final operation.
--   * The closer must type his own password again (checked by the database, rate-limited).
--   * Who closed it, when, in which branch and on which device is recorded on the shift and in the tamper-evident log.
--   * Closing creates a FINAL closing report (numbered SR-…) that can never be edited or deleted.
--   * A later fix is a separate, audited correction entry (shifts.correct); the shift and its report never change.
--   * Accountant, manager and owner see the reports and corrections (shifts.reports); the owner decides who has these rights.

alter table public.shifts add column if not exists closed_device text;

-- ============================================================ permissions
insert into public.permission_catalog (permission, grp, name_ar, name_en, desc_ar, desc_en, sensitive, inert, sort) values
  ('shifts.reports','pos','يشوف تقارير إقفال الورديات','View shift closing reports','التقرير النهائي لكل وردية: مين قفلها ومتى وعلى أنهي جهاز والمتوقع والفعلي والفرق','The final report of every shift: who closed it, when, on which device, expected, counted and the difference',true,false,67),
  ('shifts.correct','pos','يسجّل تصحيح على وردية مقفولة','Add a correction to a closed shift','التصحيح عملية منفصلة بسجل تدقيق، والوردية الأصلية مبتتغيّرش (مش بيصحّح ورديته هو)','A correction is a separate audited entry; the original shift never changes (never his own shift)',true,false,68)
on conflict (permission) do nothing;

insert into public.role_permissions (role, permission) values
  ('owner','shifts.reports'),('manager','shifts.reports'),('accountant','shifts.reports'),
  ('owner','shifts.correct'),('manager','shifts.correct')
on conflict do nothing;

-- ============================================================ final records
create sequence if not exists public.shift_report_seq;

create table if not exists public.shift_reports (
  id uuid primary key default gen_random_uuid(),
  report_no text not null unique,
  shift_id uuid not null unique references public.shifts(id),
  branch_id uuid not null references public.branches(id),
  branch_name_ar text,
  cashier_id uuid not null references auth.users(id),
  cashier_name text,
  closed_by uuid not null references auth.users(id),
  closed_by_name text,
  closed_device text,
  opened_at timestamptz not null,
  closed_at timestamptz not null,
  opening_minor bigint not null,
  sales_count int not null,
  sales_minor bigint not null,
  discounts_minor bigint not null,
  refunds_minor bigint not null,
  expected_minor bigint not null,
  counted_minor bigint not null,
  variance_minor bigint not null,
  note text,
  invoices jsonb not null default '[]'::jsonb,
  refunds jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists shift_reports_branch_idx on public.shift_reports (branch_id, closed_at desc);

create table if not exists public.shift_corrections (
  id uuid primary key default gen_random_uuid(),
  shift_id uuid not null references public.shifts(id),
  branch_id uuid not null references public.branches(id),
  amount_minor bigint not null check (amount_minor <> 0),      -- signed: + adds cash to the shift result, - removes
  reason text not null check (char_length(reason) >= 5),
  created_by uuid not null references auth.users(id),
  created_by_name text,
  created_at timestamptz not null default now()
);
create index if not exists shift_corrections_shift_idx on public.shift_corrections (shift_id);

create or replace function public._no_truncate() returns trigger language plpgsql as $$
begin raise exception 'RECORD_IS_FINAL: truncate on % is not allowed', tg_table_name using errcode = '42501'; end $$;

do $$ declare t text;
begin
  foreach t in array array['shift_reports','shift_corrections'] loop
    execute format('drop trigger if exists %I on public.%I', t || '_final', t);
    execute format('create trigger %I before update or delete on public.%I for each row execute function public._no_change()', t || '_final', t);
    execute format('drop trigger if exists %I on public.%I', t || '_no_truncate', t);
    execute format('create trigger %I before truncate on public.%I for each statement execute function public._no_truncate()', t || '_no_truncate', t);
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);   -- read and written only through the functions below
  end loop;
end $$;

-- ============================================================ password check (never raises on a wrong password, so the failed attempt is kept)
create or replace function public._confirm_my_password(p_password text) returns boolean
language plpgsql security definer set search_path = public, extensions as $$
declare v_hash text; v_key text := 'c:' || coalesce(auth.uid()::text, ''); v_since timestamptz;
begin
  if auth.uid() is null or p_password is null or p_password = '' or length(p_password) > 200 then return false; end if;
  select greatest(now() - interval '15 minutes', coalesce(max(created_at) filter (where ok), '-infinity')) into v_since
    from public.auth_login_attempts where key = v_key;
  if (select count(*) from public.auth_login_attempts where key = v_key and not ok and created_at > v_since) >= 8 then
    raise exception 'RATE_LIMITED';
  end if;
  select encrypted_password into v_hash from auth.users where id = auth.uid();
  if v_hash is not null and v_hash <> '' and v_hash = extensions.crypt(p_password, v_hash) then
    insert into public.auth_login_attempts(key, ok) values (v_key, true);
    return true;
  end if;
  insert into public.auth_login_attempts(key, ok) values (v_key, false);
  return false;
end $$;
revoke all on function public._confirm_my_password(text) from public, anon, authenticated;

-- ============================================================ close a shift
drop function if exists public.pos_close_shift(uuid, bigint, text);
create or replace function public.pos_close_shift(p_shift uuid, p_counted_minor bigint, p_password text, p_note text default null, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  s public.shifts%rowtype; t jsonb; v_exp bigint; v_var bigint; v_dev text := nullif(left(btrim(coalesce(p_device, '')), 120), '');
  v_note text := nullif(left(btrim(coalesce(p_note, '')), 300), ''); v_no text; v_rep public.shift_reports%rowtype;
  v_by text; v_cashier text; v_branch text; v_disc bigint; v_cnt int;
begin
  perform public.require_auth();
  select * into s from public.shifts where id = p_shift for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if s.status <> 'open' then raise exception 'SHIFT_CLOSED'; end if;
  if not ((s.cashier_id = auth.uid() and public.has_permission('pos.shift'))
          or (public.has_permission('shifts.review') and public._branch_ok(s.branch_id))) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_counted_minor is null or p_counted_minor < 0 or p_counted_minor > 1000000000 then raise exception 'INVALID_INPUT'; end if;
  if not public._confirm_my_password(p_password) then
    return jsonb_build_object('ok', false, 'error', 'WRONG_PASSWORD');
  end if;
  t := public._shift_totals(s.id);
  v_exp := (t ->> 'expected_minor')::bigint;
  v_var := p_counted_minor - v_exp;
  if v_var <> 0 and char_length(coalesce(v_note, '')) < 3 then raise exception 'NOTE_REQUIRED'; end if;

  select coalesce(tm.login_display, p.full_name, '—') into v_by from public.profiles p left join public.team_members tm on tm.user_id = p.id where p.id = auth.uid();
  select coalesce(tm.login_display, p.full_name, '—') into v_cashier from public.profiles p left join public.team_members tm on tm.user_id = p.id where p.id = s.cashier_id;
  select name_ar into v_branch from public.branches where id = s.branch_id;
  select coalesce(sum(discount_minor), 0), count(*) into v_disc, v_cnt from public.pos_sales where shift_id = s.id;

  update public.shifts set status = 'closed', closed_at = now(), closed_by = auth.uid(), counted_cash_minor = p_counted_minor,
         expected_cash_minor = v_exp, variance_minor = v_var, close_note = v_note, closed_device = v_dev
   where id = s.id;

  v_no := 'SR-' || lpad(nextval('public.shift_report_seq')::text, 6, '0');
  insert into public.shift_reports (report_no, shift_id, branch_id, branch_name_ar, cashier_id, cashier_name, closed_by, closed_by_name, closed_device,
                                    opened_at, closed_at, opening_minor, sales_count, sales_minor, discounts_minor, refunds_minor,
                                    expected_minor, counted_minor, variance_minor, note, invoices, refunds)
  values (v_no, s.id, s.branch_id, v_branch, s.cashier_id, v_cashier, auth.uid(), v_by, v_dev,
          s.opened_at, now(), s.opening_cash_minor, v_cnt, (t ->> 'sales_minor')::bigint, v_disc, (t ->> 'refunds_minor')::bigint,
          v_exp, p_counted_minor, v_var, v_note,
          coalesce((select jsonb_agg(jsonb_build_object('number', x.number, 'total_minor', x.total_minor, 'discount_minor', x.discount_minor,
                                                       'refunded_minor', x.refunded_minor) order by x.created_at)
                      from public.pos_sales x where x.shift_id = s.id), '[]'::jsonb),
          coalesce((select jsonb_agg(jsonb_build_object('sale_number', (select number from public.pos_sales where id = r.sale_id),
                                                       'amount_minor', r.amount_minor, 'reason', r.reason, 'at', r.created_at) order by r.created_at)
                      from public.pos_refunds r where r.shift_id = s.id), '[]'::jsonb))
  returning * into v_rep;

  perform public.audit_write('shift.close', 'shift', s.id::text, jsonb_build_object('report_no', v_no, 'branch_id', s.branch_id, 'branch', v_branch,
          'expected_minor', v_exp, 'counted_minor', p_counted_minor, 'variance_minor', v_var, 'closed_by_name', v_by, 'device', v_dev,
          'closed_by_other', s.cashier_id <> auth.uid()));
  perform public._notify_staff('shifts.reports', 'اتقفلت وردية ' || v_no, 'Shift closed ' || v_no,
    v_branch || ' · ' || v_cashier || case when v_var = 0 then ' · الدرج مظبوط' when v_var < 0 then ' · عجز ' || (abs(v_var) / 100.0)::numeric(12,2) || ' ج.م'
                                          else ' · زيادة ' || (abs(v_var) / 100.0)::numeric(12,2) || ' ج.م' end,
    v_branch || ' · ' || v_cashier || case when v_var = 0 then ' · drawer matches' when v_var < 0 then ' · short ' || (abs(v_var) / 100.0)::numeric(12,2) || ' EGP'
                                          else ' · over ' || (abs(v_var) / 100.0)::numeric(12,2) || ' EGP' end, s.id::text);
  return jsonb_build_object('ok', true, 'report', to_jsonb(v_rep));
end $$;

-- ============================================================ read the reports
create or replace function public.pos_shift_report_list(p_branch uuid default null, p_from timestamptz default null, p_to timestamptz default null, p_limit int default 100)
returns table (report_no text, shift_id uuid, branch_id uuid, branch_name_ar text, cashier_name text, closed_by_name text, closed_device text,
               opened_at timestamptz, closed_at timestamptz, sales_minor bigint, refunds_minor bigint, expected_minor bigint, counted_minor bigint,
               variance_minor bigint, corrections_minor bigint, note text)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_auth();
  if not public.has_permission('shifts.reports') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return query
    select r.report_no, r.shift_id, r.branch_id, r.branch_name_ar, r.cashier_name, r.closed_by_name, r.closed_device, r.opened_at, r.closed_at,
           r.sales_minor, r.refunds_minor, r.expected_minor, r.counted_minor, r.variance_minor,
           coalesce((select sum(c.amount_minor) from public.shift_corrections c where c.shift_id = r.shift_id), 0)::bigint, r.note
      from public.shift_reports r
     where public._branch_ok(r.branch_id) and (p_branch is null or r.branch_id = p_branch)
       and (p_from is null or r.closed_at >= p_from) and (p_to is null or r.closed_at < p_to)
     order by r.closed_at desc limit least(greatest(coalesce(p_limit, 100), 1), 300);
end $$;

create or replace function public.pos_shift_report_get(p_shift uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r public.shift_reports%rowtype; v_corr jsonb; v_sum bigint;
begin
  perform public.require_auth();
  select * into r from public.shift_reports where shift_id = p_shift;
  if not found then raise exception 'NOT_FOUND'; end if;
  if not (r.cashier_id = auth.uid() or (public.has_permission('shifts.reports') and public._branch_ok(r.branch_id))) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('amount_minor', c.amount_minor, 'reason', c.reason, 'by', c.created_by_name, 'at', c.created_at) order by c.created_at), '[]'::jsonb),
         coalesce(sum(c.amount_minor), 0)
    into v_corr, v_sum from public.shift_corrections c where c.shift_id = p_shift;
  return to_jsonb(r) || jsonb_build_object('corrections', v_corr, 'corrections_minor', v_sum, 'variance_after_corrections_minor', r.variance_minor + v_sum);
end $$;

-- ============================================================ corrections (separate, audited; the shift itself never changes)
create or replace function public.pos_add_shift_correction(p_shift uuid, p_amount_minor bigint, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare s public.shifts%rowtype; v_by text; v_reason text := btrim(coalesce(p_reason, ''));
begin
  perform public.require_permission('shifts.correct');
  select * into s from public.shifts where id = p_shift;
  if not found then raise exception 'NOT_FOUND'; end if;
  if s.status <> 'closed' then raise exception 'SHIFT_NOT_CLOSED'; end if;
  if not public._branch_ok(s.branch_id) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if s.cashier_id = auth.uid() and not public.has_role('owner') then raise exception 'SELF_APPROVAL'; end if;
  if p_amount_minor is null or p_amount_minor = 0 or abs(p_amount_minor) > 100000000 or char_length(v_reason) < 5 then raise exception 'INVALID_INPUT'; end if;
  select coalesce(tm.login_display, p.full_name, '—') into v_by from public.profiles p left join public.team_members tm on tm.user_id = p.id where p.id = auth.uid();
  insert into public.shift_corrections (shift_id, branch_id, amount_minor, reason, created_by, created_by_name)
  values (s.id, s.branch_id, p_amount_minor, left(v_reason, 300), auth.uid(), v_by);
  perform public.audit_write('shift.correct', 'shift', s.id::text, jsonb_build_object('branch_id', s.branch_id, 'amount_minor', p_amount_minor, 'reason', left(v_reason, 300), 'by', v_by));
  perform public._notify_staff('shifts.reports', 'تصحيح على وردية مقفولة', 'Correction on a closed shift',
    v_by || ' سجّل تصحيح ' || (p_amount_minor / 100.0)::numeric(12,2) || ' ج.م: ' || left(v_reason, 80),
    v_by || ' added a correction of ' || (p_amount_minor / 100.0)::numeric(12,2) || ' EGP: ' || left(v_reason, 80), s.id::text);
end $$;

do $$ begin
  revoke all on function public.pos_close_shift(uuid, bigint, text, text, text) from public, anon;
  grant execute on function public.pos_close_shift(uuid, bigint, text, text, text) to authenticated;
  revoke all on function public.pos_shift_report_list(uuid, timestamptz, timestamptz, int) from public, anon;
  grant execute on function public.pos_shift_report_list(uuid, timestamptz, timestamptz, int) to authenticated;
  revoke all on function public.pos_shift_report_get(uuid) from public, anon;
  grant execute on function public.pos_shift_report_get(uuid) to authenticated;
  revoke all on function public.pos_add_shift_correction(uuid, bigint, text) from public, anon;
  grant execute on function public.pos_add_shift_correction(uuid, bigint, text) to authenticated;
end $$;
