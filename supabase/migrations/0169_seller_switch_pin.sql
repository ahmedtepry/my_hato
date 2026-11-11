-- 0169: switch the active seller on the same cashier screen with a 4-digit PIN.
-- The account that opened the shift keeps the shift / drawer; every sale records who actually sold (seller_id)
-- and targets, commission, bonus, KPIs and invoices follow the seller.

create table if not exists public.staff_pins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  pin_hash text not null,
  fails int not null default 0,
  locked_until timestamptz,
  updated_at timestamptz not null default now()
);
alter table public.staff_pins enable row level security;
revoke all on public.staff_pins from anon, authenticated;

create table if not exists public.shift_sellers (
  shift_id uuid primary key references public.shifts(id) on delete cascade,
  user_id uuid not null references auth.users(id),
  since timestamptz not null default now()
);
alter table public.shift_sellers enable row level security;
revoke all on public.shift_sellers from anon, authenticated;

alter table public.pos_sales add column if not exists seller_id uuid references auth.users(id);

-- may this user sell on this shift? (the shift holder, or an unsuspended cashier of the same branch)
create or replace function public._seller_ok(p_shift uuid, p_user uuid) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.shifts sh where sh.id = p_shift and (
           sh.cashier_id = p_user
           or exists (select 1 from public.staff_branches sb where sb.user_id = p_user and sb.branch_id = sh.branch_id)))
     and public._user_has_permission(p_user, 'pos.sell')
     and not exists (select 1 from public.team_members tm where tm.user_id = p_user and tm.suspended_at is not null)
$$;

-- the user whose numbers a screen should show: yourself, or the seller currently switched in on your open shift
create or replace function public._acting_user(p_user uuid) returns uuid
language plpgsql stable security definer set search_path to 'public' as $$
begin
  if p_user is null or p_user = auth.uid() then return auth.uid(); end if;
  if exists (select 1 from public.shift_sellers ss join public.shifts sh on sh.id = ss.shift_id
              where sh.cashier_id = auth.uid() and sh.status = 'open' and ss.user_id = p_user) then
    return p_user;
  end if;
  raise exception 'FORBIDDEN' using errcode = '42501';
end $$;

create or replace function public.pos_seller_candidates(p_shift uuid) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare v_uid uuid := public.require_auth(); sh public.shifts%rowtype; v_active uuid;
begin
  select * into sh from public.shifts where id = p_shift;
  if not found or sh.cashier_id <> v_uid or sh.status <> 'open' then raise exception 'NO_OPEN_SHIFT'; end if;
  select user_id into v_active from public.shift_sellers where shift_id = p_shift;
  v_active := coalesce(v_active, sh.cashier_id);
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', u.id, 'name', u.name, 'code', u.code,
             'has_pin', exists (select 1 from public.staff_pins sp where sp.user_id = u.id), 'active', u.id = v_active) order by u.name)
      from (select c.id, coalesce(tm.login_display, p.full_name, '—') as name, tm.login_name as code
              from (select sb.user_id as id from public.staff_branches sb where sb.branch_id = sh.branch_id
                    union select sh.cashier_id) c
              left join public.team_members tm on tm.user_id = c.id
              left join public.profiles p on p.id = c.id
             where public._seller_ok(p_shift, c.id)) u), '[]'::jsonb);
end $$;

create or replace function public.pos_current_seller(p_shift uuid) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare v_uid uuid := public.require_auth(); sh public.shifts%rowtype; v_s uuid;
begin
  select * into sh from public.shifts where id = p_shift;
  if not found or sh.cashier_id <> v_uid then raise exception 'NO_OPEN_SHIFT'; end if;
  select user_id into v_s from public.shift_sellers where shift_id = p_shift;
  if v_s is null or not public._seller_ok(p_shift, v_s) then v_s := sh.cashier_id; end if;
  return (select jsonb_build_object('id', v_s, 'name', coalesce(tm.login_display, p.full_name, '—'))
            from public.profiles p left join public.team_members tm on tm.user_id = p.id where p.id = v_s);
end $$;

create or replace function public.pos_switch_seller(p_shift uuid, p_user uuid, p_pin text) returns jsonb
language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare v_uid uuid := public.require_auth(); sh public.shifts%rowtype; sp public.staff_pins%rowtype; v_old uuid; v_name text; v_fails int;
begin
  perform public.require_permission('pos.sell');
  select * into sh from public.shifts where id = p_shift;
  if not found or sh.cashier_id <> v_uid or sh.status <> 'open' then raise exception 'NO_OPEN_SHIFT'; end if;
  if not public._seller_ok(p_shift, p_user) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into sp from public.staff_pins where user_id = p_user for update;
  if not found then raise exception 'NO_PIN'; end if;
  if sp.locked_until is not null and sp.locked_until > now() then
    return jsonb_build_object('ok', false, 'error', 'PIN_LOCKED', 'seconds', ceil(extract(epoch from sp.locked_until - now()))::int);
  end if;
  if p_pin is null or p_pin !~ '^[0-9]{4}$' or sp.pin_hash <> crypt(p_pin, sp.pin_hash) then
    v_fails := sp.fails + 1;
    update public.staff_pins set fails = case when v_fails >= 5 then 0 else v_fails end,
           locked_until = case when v_fails >= 5 then now() + interval '5 minutes' end where user_id = p_user;
    perform public.audit_write('pos.seller_pin_failed', 'shift', p_shift::text, jsonb_build_object('target', p_user, 'fails', v_fails));
    return jsonb_build_object('ok', false, 'error', case when v_fails >= 5 then 'PIN_LOCKED' else 'BAD_PIN' end, 'left', greatest(5 - v_fails, 0), 'seconds', case when v_fails >= 5 then 300 end);
  end if;
  update public.staff_pins set fails = 0, locked_until = null where user_id = p_user;
  select user_id into v_old from public.shift_sellers where shift_id = p_shift;
  insert into public.shift_sellers (shift_id, user_id) values (p_shift, p_user)
    on conflict (shift_id) do update set user_id = excluded.user_id, since = now();
  perform public.audit_write('pos.seller_switch', 'shift', p_shift::text,
    jsonb_build_object('from', coalesce(v_old, sh.cashier_id), 'to', p_user, 'branch_id', sh.branch_id));
  select coalesce(tm.login_display, p.full_name, '—') into v_name from public.profiles p left join public.team_members tm on tm.user_id = p.id where p.id = p_user;
  return jsonb_build_object('ok', true, 'id', p_user, 'name', v_name);
end $$;

create or replace function public.staff_pin_set(p_user uuid, p_pin text) returns void
language plpgsql security definer set search_path to 'public', 'extensions' as $$
begin
  perform public.require_auth();
  if not public.has_role('owner') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_pin is null or p_pin !~ '^[0-9]{4}$' then raise exception 'INVALID_INPUT'; end if;
  if not exists (select 1 from auth.users where id = p_user) then raise exception 'NOT_FOUND'; end if;
  insert into public.staff_pins (user_id, pin_hash) values (p_user, crypt(p_pin, gen_salt('bf')))
    on conflict (user_id) do update set pin_hash = excluded.pin_hash, fails = 0, locked_until = null, updated_at = now();
  perform public.audit_write('staff.pin_set', 'user', p_user::text, '{}'::jsonb);
end $$;

create or replace function public.staff_pins_list() returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
begin
  perform public.require_auth();
  if not public.has_role('owner') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(user_id) from public.staff_pins), '[]'::jsonb);
end $$;

-- ---- patch live functions (position-asserted) ----
create or replace function pg_temp.pf(p_fn regprocedure, p_old text, p_new text) returns void language plpgsql as $$
declare d text;
begin
  d := pg_get_functiondef(p_fn);
  if position(p_old in d) = 0 then raise exception 'patch miss [%] in %', p_old, p_fn; end if;
  execute replace(d, p_old, p_new);
end $$;

-- sales: who actually sold
select pg_temp.pf('public.pos_create_sale(text,uuid,jsonb,bigint,bigint,uuid,uuid)'::regprocedure, 'v_n int; v_rem bigint;', 'v_n int; v_seller uuid; v_rem bigint;');
select pg_temp.pf('public.pos_create_sale(text,uuid,jsonb,bigint,bigint,uuid,uuid)'::regprocedure, 'v_num := public._pos_new_number();',
  'v_num := public._pos_new_number(); select user_id into v_seller from public.shift_sellers where shift_id = sh.id and public._seller_ok(sh.id, user_id);');
select pg_temp.pf('public.pos_create_sale(text,uuid,jsonb,bigint,bigint,uuid,uuid)'::regprocedure, 'cash_received_minor, change_minor, approval_id)', 'cash_received_minor, change_minor, approval_id, seller_id)');
select pg_temp.pf('public.pos_create_sale(text,uuid,jsonb,bigint,bigint,uuid,uuid)'::regprocedure, 'p_cash_received_minor - v_total, case when v_need then ap.id end)',
  'p_cash_received_minor - v_total, case when v_need then ap.id end, case when v_seller is distinct from v_uid then v_seller end)');

-- attribution follows the seller
select pg_temp.pf('public._daily_bonus(uuid,timestamptz,timestamptz)'::regprocedure, 'where cashier_id = p_user', 'where coalesce(seller_id, cashier_id) = p_user');
select pg_temp.pf('public.kpi_commission_log(uuid,timestamptz,timestamptz,integer)'::regprocedure, 'p.cashier_id = p_user', 'coalesce(p.seller_id, p.cashier_id) = p_user');
select pg_temp.pf('public.kpi_employees(timestamptz,timestamptz,uuid)'::regprocedure, 'select cashier_id as uid from public.pos_sales', 'select coalesce(seller_id, cashier_id) as uid from public.pos_sales');
select pg_temp.pf('public.kpi_employees(timestamptz,timestamptz,uuid)'::regprocedure, 'p.cashier_id = u.uid', 'coalesce(p.seller_id, p.cashier_id) = u.uid');
select pg_temp.pf('public.targets_overview(date)'::regprocedure, 'select cashier_id as uid from public.pos_sales', 'select coalesce(seller_id, cashier_id) as uid from public.pos_sales');
select pg_temp.pf('public.targets_overview(date)'::regprocedure, 'p.cashier_id = u.uid', 'coalesce(p.seller_id, p.cashier_id) = u.uid');
select pg_temp.pf('public._pos_sale_json(uuid)'::regprocedure, 'where p.id = s.cashier_id', 'where p.id = coalesce(s.seller_id, s.cashier_id)');
select pg_temp.pf('public.pos_invoice_detail(uuid)'::regprocedure, 'where user_id = s.cashier_id', 'where user_id = coalesce(s.seller_id, s.cashier_id)');
select pg_temp.pf('public.pos_invoices_list(text,timestamptz,timestamptz,text,integer)'::regprocedure, 'p.id = s.cashier_id', 'p.id = coalesce(s.seller_id, s.cashier_id)');
select pg_temp.pf('public.pos_invoices_list(text,timestamptz,timestamptz,text,integer)'::regprocedure, 'tm.user_id = s.cashier_id', 'tm.user_id = coalesce(s.seller_id, s.cashier_id)');
select pg_temp.pf('public.ops_sales(uuid,uuid,boolean,integer)'::regprocedure, '_ops_name(s.cashier_id)', '_ops_name(coalesce(s.seller_id, s.cashier_id))');

-- "my target / my challenge" can show the seller switched in on this screen
do $$
declare d text;
begin
  d := pg_get_functiondef('public.my_target_status()'::regprocedure);
  d := replace(d, 'cashier_id = auth.uid()', 'coalesce(seller_id, cashier_id) = auth.uid()');
  d := replace(d, 'p.coalesce(seller_id, cashier_id)', 'coalesce(p.seller_id, p.cashier_id)');
  d := replace(d, 'auth.uid()', 'v_u');
  d := replace(d, 'FUNCTION public.my_target_status()', 'FUNCTION public.my_target_status(p_user uuid DEFAULT NULL::uuid)');
  d := replace(d, 'declare v_from timestamptz;', 'declare v_u uuid := public._acting_user(p_user); v_from timestamptz;');
  if position('v_u uuid' in d) = 0 or position('p_user uuid' in d) = 0 then raise exception 'patch my_target_status'; end if;
  drop function public.my_target_status();
  execute d;
  d := pg_get_functiondef('public.my_challenge_today()'::regprocedure);
  d := replace(d, 'p.cashier_id = auth.uid()', 'coalesce(p.seller_id, p.cashier_id) = v_u');
  d := replace(d, 'FUNCTION public.my_challenge_today()', 'FUNCTION public.my_challenge_today(p_user uuid DEFAULT NULL::uuid)');
  d := replace(d, E'declare\n  v_from timestamptz;', E'declare\n  v_u uuid := public._acting_user(p_user);\n  v_from timestamptz;');
  d := replace(d, 'public.my_target_status()', 'public.my_target_status(p_user)');
  if position('v_u uuid' in d) = 0 or position('p_user uuid' in d) = 0 then raise exception 'patch my_challenge_today'; end if;
  drop function public.my_challenge_today();
  execute d;
end $$;

revoke all on function public.my_target_status(uuid), public.my_challenge_today(uuid), public._acting_user(uuid), public._seller_ok(uuid, uuid),
  public.pos_seller_candidates(uuid), public.pos_current_seller(uuid), public.pos_switch_seller(uuid, uuid, text),
  public.staff_pin_set(uuid, text), public.staff_pins_list() from public, anon;
grant execute on function public.my_target_status(uuid), public.my_challenge_today(uuid),
  public.pos_seller_candidates(uuid), public.pos_current_seller(uuid), public.pos_switch_seller(uuid, uuid, text),
  public.staff_pin_set(uuid, text), public.staff_pins_list() to authenticated;
