-- The payment method (cash / card / wallet) is for the shop's accounts only; it is not printed on the customer's receipt.
-- A wrong choice can be corrected while the shift is still open (by the cashier who made the sale or a branch reviewer), before the closing.
-- Cash received / change are re-set so nothing else changes; every change is logged (old -> new, who, why). A closed shift's report stays final.
drop function if exists public.pos_set_sale_payment(uuid, text);
create or replace function public.pos_set_sale_payment(p_sale uuid, p_method text, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.pos_sales%rowtype; v_old text;
begin
  perform public.require_auth();
  if p_method not in ('cash', 'card', 'wallet') then raise exception 'INVALID_INPUT'; end if;
  select * into s from public.pos_sales where id = p_sale for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if not (s.cashier_id = auth.uid() or (public.has_permission('shifts.review') and public._branch_ok(s.branch_id))) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if not exists (select 1 from public.shifts where id = s.shift_id and status = 'open') then raise exception 'SHIFT_CLOSED'; end if;
  if s.tip_minor <> 0 then raise exception 'PAYMENT_LOCKED_TIP'; end if;
  if exists (select 1 from public.pos_refunds r where r.sale_id = s.id) then raise exception 'PAYMENT_LOCKED_REFUND'; end if;
  v_old := s.payment_method;
  if v_old = p_method then return public._pos_sale_json(s.id); end if;
  -- the drawer math only uses the invoice total, so the money received simply equals the total after a change of method
  update public.pos_sales set payment_method = p_method, cash_received_minor = total_minor, change_minor = 0 where id = s.id;
  perform public.audit_write('pos.payment', 'sale', s.number, jsonb_build_object('from', v_old, 'to', p_method, 'reason', left(btrim(coalesce(p_reason, '')), 200),
          'branch_id', s.branch_id, 'shift_id', s.shift_id, 'total_minor', s.total_minor));
  return public._pos_sale_json(s.id);
end $$;
revoke all on function public.pos_set_sale_payment(uuid, text, text) from public, anon;
grant execute on function public.pos_set_sale_payment(uuid, text, text) to authenticated;

create or replace function public.pos_invoice_detail(p_sale uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s public.pos_sales%rowtype; v_open boolean;
begin
  perform public.require_permission('invoices.view');
  select * into s from public.pos_sales where id = p_sale;
  if not found or not public._branch_ok(s.branch_id) then raise exception 'NOT_FOUND'; end if;
  v_open := exists (select 1 from public.shifts where id = s.shift_id and status = 'open');
  return public._pos_sale_json(s.id) || jsonb_build_object(
    'seller_code', (select login_name from public.team_members where user_id = s.cashier_id),
    'can_edit_payment', v_open and s.tip_minor = 0 and not exists (select 1 from public.pos_refunds r where r.sale_id = s.id)
                        and (s.cashier_id = auth.uid() or public.has_permission('shifts.review')));
end $$;

-- closing summary: how much of the refunds really left the drawer as cash
do $$
declare d text; old text := $q$'expenses_minor', coalesce(($q$;
begin
  d := pg_get_functiondef('public._shift_totals(uuid)'::regprocedure);
  if position('cash_refunds_minor' in d) > 0 then return; end if;
  if position(old in d) = 0 then raise exception 'pattern'; end if;
  execute replace(d, old, $q$'cash_refunds_minor', coalesce((select sum(r.amount_minor) from public.pos_refunds r where r.shift_id = s.id and r.refund_method = 'cash'), 0),
    'expenses_minor', coalesce(($q$);
end $$;
