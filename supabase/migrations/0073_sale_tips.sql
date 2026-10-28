-- 0073: tips. When a customer pays more than the total and leaves the change ("بقشيش"), the cashier records it on the sale
-- instead of handing it back. The drawer still only counts the products' value (the cashier takes the tip out), and every tip is
-- written down with the sale number, so nothing is kept silently.

alter table public.pos_sales add column if not exists tip_minor bigint not null default 0;
alter table public.pos_sales drop constraint if exists pos_sales_tip_chk;
alter table public.pos_sales add constraint pos_sales_tip_chk check (tip_minor >= 0 and tip_minor <= change_minor);

-- only the cashier of the sale, only while the shift is open and only once
create or replace function public.pos_mark_tip(p_sale uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.pos_sales%rowtype;
begin
  perform public.require_auth();
  select * into s from public.pos_sales where id = p_sale for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if s.cashier_id <> auth.uid() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if not exists (select 1 from public.shifts where id = s.shift_id and status = 'open') then raise exception 'SHIFT_CLOSED'; end if;
  if s.change_minor <= 0 then raise exception 'INVALID_INPUT'; end if;
  if s.tip_minor = 0 then
    update public.pos_sales set tip_minor = change_minor where id = s.id;
    perform public.audit_write('pos.tip', 'sale', s.number, jsonb_build_object('tip_minor', s.change_minor, 'branch_id', s.branch_id, 'shift_id', s.shift_id));
  end if;
  return public._pos_sale_json(s.id);
end $$;
revoke all on function public.pos_mark_tip(uuid) from public, anon;
grant execute on function public.pos_mark_tip(uuid) to authenticated;

-- shift totals also say how much was left as tips (the expected drawer is unchanged)
create or replace function public._shift_totals(p_shift uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'opening_minor', s.opening_cash_minor,
    'sales_count', (select count(*) from public.pos_sales x where x.shift_id = s.id),
    'sales_minor', coalesce((select sum(total_minor) from public.pos_sales x where x.shift_id = s.id), 0),
    'refunds_minor', coalesce((select sum(r.amount_minor) from public.pos_refunds r where r.shift_id = s.id), 0),
    'tips_minor', coalesce((select sum(x.tip_minor) from public.pos_sales x where x.shift_id = s.id), 0),
    'expected_minor', s.opening_cash_minor
        + coalesce((select sum(total_minor) from public.pos_sales x where x.shift_id = s.id), 0)
        - coalesce((select sum(r.amount_minor) from public.pos_refunds r where r.shift_id = s.id), 0))
  from public.shifts s where s.id = p_shift
$$;
revoke all on function public._shift_totals(uuid) from public, anon, authenticated;
