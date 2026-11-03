-- 0129: a third till payment method: e-wallet (like visa, it is not in the drawer). Run after 0128.
alter table public.pos_sales drop constraint if exists pos_sales_payment_method_chk;
alter table public.pos_sales add constraint pos_sales_payment_method_chk check (payment_method in ('cash', 'card', 'wallet'));

create or replace function public.pos_set_sale_payment(p_sale uuid, p_method text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.pos_sales%rowtype;
begin
  perform public.require_auth();
  if p_method not in ('cash', 'card', 'wallet') then raise exception 'INVALID_INPUT'; end if;
  select * into s from public.pos_sales where id = p_sale for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if s.cashier_id <> auth.uid() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if not exists (select 1 from public.shifts where id = s.shift_id and status = 'open') then raise exception 'SHIFT_CLOSED'; end if;
  if p_method <> 'cash' and (s.change_minor <> 0 or s.tip_minor <> 0 or exists (select 1 from public.pos_refunds r where r.sale_id = s.id)) then raise exception 'INVALID_INPUT'; end if;
  update public.pos_sales set payment_method = p_method where id = s.id;
  perform public.audit_write('pos.payment', 'sale', s.number, jsonb_build_object('method', p_method, 'branch_id', s.branch_id, 'shift_id', s.shift_id));
  return public._pos_sale_json(s.id);
end $$;

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
    'tips_minor', coalesce((select sum(x.tip_minor) from public.pos_sales x where x.shift_id = s.id and not coalesce(x.tip_in_drawer, false)), 0),
    'tips_kept_minor', coalesce((select sum(x.tip_minor) from public.pos_sales x where x.shift_id = s.id and coalesce(x.tip_in_drawer, false)), 0),
    'expected_minor', s.opening_cash_minor
        + coalesce((select sum(total_minor) from public.pos_sales x where x.shift_id = s.id and x.payment_method = 'cash'), 0)
        + coalesce((select sum(x.tip_minor) from public.pos_sales x where x.shift_id = s.id and coalesce(x.tip_in_drawer, false)), 0)
        - coalesce((select sum(r.amount_minor) from public.pos_refunds r join public.pos_sales x on x.id = r.sale_id
                     where r.shift_id = s.id and x.payment_method = 'cash'), 0))
  from public.shifts s where s.id = p_shift
$$;

create or replace function public.pos_branch_payment_split2(p_from timestamptz default null, p_to timestamptz default null)
returns table (branch_id uuid, cash_minor bigint, card_minor bigint, card_count bigint, wallet_minor bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_auth();
  if not (public.has_permission('sales.view') or public.has_permission('shifts.review')) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return query
    select b.id,
           coalesce(sum(s.total_minor) filter (where s.payment_method = 'cash'), 0)::bigint,
           coalesce(sum(s.total_minor) filter (where s.payment_method = 'card'), 0)::bigint,
           count(s.id) filter (where s.payment_method = 'card'),
           coalesce(sum(s.total_minor) filter (where s.payment_method = 'wallet'), 0)::bigint
      from public.branches b
      left join public.pos_sales s on s.branch_id = b.id and (p_from is null or s.created_at >= p_from) and (p_to is null or s.created_at < p_to)
     where b.is_active and public._branch_ok(b.id)
     group by b.id, b.created_at order by b.created_at;
end $$;
revoke all on function public.pos_branch_payment_split2(timestamptz, timestamptz) from public, anon;
grant execute on function public.pos_branch_payment_split2(timestamptz, timestamptz) to authenticated;
