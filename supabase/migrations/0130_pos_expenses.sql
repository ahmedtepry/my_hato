-- 0130: cash expenses paid out of the drawer during a shift (cleaning, delivery fee, small purchases...). They come off the expected drawer.
create table if not exists public.pos_expenses (
  id uuid primary key default gen_random_uuid(),
  shift_id uuid not null references public.shifts(id),
  branch_id uuid not null references public.branches(id),
  amount_minor bigint not null check (amount_minor > 0 and amount_minor <= 1000000000),
  reason text not null check (char_length(btrim(reason)) between 3 and 200),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);
create index if not exists pos_expenses_shift_idx on public.pos_expenses (shift_id);
alter table public.pos_expenses enable row level security;

create or replace function public.pos_add_expense(p_shift uuid, p_amount_minor bigint, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := public.require_auth(); sh public.shifts%rowtype; v_id uuid;
begin
  perform public.require_permission('pos.sell');
  select * into sh from public.shifts where id = p_shift;
  if not found or sh.cashier_id <> v_uid or sh.status <> 'open' then raise exception 'NO_OPEN_SHIFT'; end if;
  if p_amount_minor is null or p_amount_minor <= 0 or p_amount_minor > 1000000000 then raise exception 'INVALID_INPUT'; end if;
  if char_length(btrim(coalesce(p_reason, ''))) < 3 then raise exception 'REASON_REQUIRED'; end if;
  insert into public.pos_expenses (shift_id, branch_id, amount_minor, reason, created_by)
  values (sh.id, sh.branch_id, p_amount_minor, left(btrim(p_reason), 200), v_uid) returning id into v_id;
  perform public.audit_write('pos.expense', 'shift', sh.id::text, jsonb_build_object('amount_minor', p_amount_minor, 'reason', left(btrim(p_reason), 200), 'branch_id', sh.branch_id));
  return jsonb_build_object('id', v_id, 'amount_minor', p_amount_minor);
end $$;
revoke all on function public.pos_add_expense(uuid, bigint, text) from public, anon;
grant execute on function public.pos_add_expense(uuid, bigint, text) to authenticated;

create or replace function public.pos_shift_expenses(p_shift uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s public.shifts%rowtype;
begin
  perform public.require_auth();
  select * into s from public.shifts where id = p_shift;
  if not found then raise exception 'NOT_FOUND'; end if;
  if not (s.cashier_id = auth.uid() or (public.has_permission('shifts.review') and public._branch_ok(s.branch_id))) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'amount_minor', e.amount_minor, 'reason', e.reason, 'created_at', e.created_at) order by e.created_at desc)
                     from public.pos_expenses e where e.shift_id = p_shift), '[]'::jsonb);
end $$;
revoke all on function public.pos_shift_expenses(uuid) from public, anon;
grant execute on function public.pos_shift_expenses(uuid) to authenticated;

create or replace function public._shift_totals(p_shift uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'opening_minor', s.opening_cash_minor,
    'sales_count', (select count(*) from public.pos_sales x where x.shift_id = s.id),
    'sales_minor', coalesce((select sum(total_minor) from public.pos_sales x where x.shift_id = s.id), 0),
    'cash_sales_minor', coalesce((select sum(total_minor) from public.pos_sales x where x.shift_id = s.id and x.payment_method = 'cash'), 0),
    'card_sales_minor', coalesce((select sum(total_minor) from public.pos_sales x where x.shift_id = s.id and x.payment_method = 'card'), 0),
    'wallet_sales_minor', coalesce((select sum(total_minor) from public.pos_sales x where x.shift_id = s.id and x.payment_method = 'wallet'), 0),
    'card_sales_count', (select count(*) from public.pos_sales x where x.shift_id = s.id and x.payment_method = 'card'),
    'refunds_minor', coalesce((select sum(r.amount_minor) from public.pos_refunds r where r.shift_id = s.id), 0),
    'expenses_minor', coalesce((select sum(e.amount_minor) from public.pos_expenses e where e.shift_id = s.id), 0),
    'tips_minor', coalesce((select sum(x.tip_minor) from public.pos_sales x where x.shift_id = s.id and not coalesce(x.tip_in_drawer, false)), 0),
    'tips_kept_minor', coalesce((select sum(x.tip_minor) from public.pos_sales x where x.shift_id = s.id and coalesce(x.tip_in_drawer, false)), 0),
    'expected_minor', s.opening_cash_minor
        + coalesce((select sum(total_minor) from public.pos_sales x where x.shift_id = s.id and x.payment_method = 'cash'), 0)
        + coalesce((select sum(x.tip_minor) from public.pos_sales x where x.shift_id = s.id and coalesce(x.tip_in_drawer, false)), 0)
        - coalesce((select sum(r.amount_minor) from public.pos_refunds r join public.pos_sales x on x.id = r.sale_id
                     where r.shift_id = s.id and x.payment_method = 'cash'), 0)
        - coalesce((select sum(e.amount_minor) from public.pos_expenses e where e.shift_id = s.id), 0))
  from public.shifts s where s.id = p_shift
$$;
revoke all on function public._shift_totals(uuid) from public, anon, authenticated;
