-- Closing a shift reconciles the drawer in three parts: cash (counted in the drawer, required), card (the card machine's total) and
-- e-wallets (the wallet apps' total). Card and wallet counts are optional; when typed, any difference is recorded and needs a reason.
-- The final report keeps all three (sales, refunds paid that way, expected, counted, difference). Expected card / wallet come from the invoices.
alter table public.shift_reports add column if not exists methods jsonb;

do $$
declare d text;
begin
  d := pg_get_functiondef('public.pos_close_shift(uuid,bigint,text,text,text)'::regprocedure);
  d := replace(d, 'p_note text DEFAULT NULL::text, p_device text DEFAULT NULL::text)', 'p_note text DEFAULT NULL::text, p_device text DEFAULT NULL::text, p_counted_card bigint DEFAULT NULL::bigint, p_counted_wallet bigint DEFAULT NULL::bigint)');
  if position('p_counted_card' in d) = 0 then raise exception 'header'; end if;
  -- declarations
  if position('v_by text; v_cashier text;' in d) = 0 then raise exception 'declare'; end if;
  d := replace(d, 'v_by text; v_cashier text;', 'v_cx bigint; v_wx bigint; v_cvar bigint; v_wvar bigint; v_meth jsonb; v_by text; v_cashier text;');
  -- validation + variances
  if position('v_var := p_counted_minor - v_exp;' in d) = 0 then raise exception 'var'; end if;
  d := replace(d, 'v_var := p_counted_minor - v_exp;', $b$v_var := p_counted_minor - v_exp;
  if (p_counted_card is not null and (p_counted_card < 0 or p_counted_card > 1000000000)) or (p_counted_wallet is not null and (p_counted_wallet < 0 or p_counted_wallet > 1000000000)) then raise exception 'INVALID_INPUT'; end if;
  v_cx := (t ->> 'card_sales_minor')::bigint - coalesce((select sum(r.amount_minor) from public.pos_refunds r where r.shift_id = s.id and r.refund_method = 'card'), 0);
  v_wx := (t ->> 'wallet_sales_minor')::bigint - coalesce((select sum(r.amount_minor) from public.pos_refunds r where r.shift_id = s.id and r.refund_method = 'wallet'), 0);
  v_cvar := case when p_counted_card is null then null else p_counted_card - v_cx end;
  v_wvar := case when p_counted_wallet is null then null else p_counted_wallet - v_wx end;
  v_meth := jsonb_build_object(
    'cash', jsonb_build_object('sales_minor', (t ->> 'cash_sales_minor')::bigint, 'refunds_minor', (t ->> 'cash_refunds_minor')::bigint, 'expected_minor', v_exp, 'counted_minor', p_counted_minor, 'variance_minor', v_var),
    'card', jsonb_build_object('sales_minor', (t ->> 'card_sales_minor')::bigint, 'refunds_minor', coalesce((select sum(r.amount_minor) from public.pos_refunds r where r.shift_id = s.id and r.refund_method = 'card'), 0), 'expected_minor', v_cx, 'counted_minor', p_counted_card, 'variance_minor', v_cvar),
    'wallet', jsonb_build_object('sales_minor', (t ->> 'wallet_sales_minor')::bigint, 'refunds_minor', coalesce((select sum(r.amount_minor) from public.pos_refunds r where r.shift_id = s.id and r.refund_method = 'wallet'), 0), 'expected_minor', v_wx, 'counted_minor', p_counted_wallet, 'variance_minor', v_wvar));$b$);
  if position($a$if v_var <> 0 and char_length(coalesce(v_note, '')) < 3$a$ in d) = 0 then raise exception 'note'; end if;
  d := replace(d, $a$if v_var <> 0 and char_length(coalesce(v_note, '')) < 3$a$, $a$if (v_var <> 0 or coalesce(v_cvar, 0) <> 0 or coalesce(v_wvar, 0) <> 0) and char_length(coalesce(v_note, '')) < 3$a$);
  -- report row
  if position('expected_minor, counted_minor, variance_minor, note, invoices, refunds)' in d) = 0 then raise exception 'cols'; end if;
  d := replace(d, 'expected_minor, counted_minor, variance_minor, note, invoices, refunds)', 'expected_minor, counted_minor, variance_minor, note, invoices, refunds, methods)');
  if position($a$from public.pos_refunds r where r.shift_id = s.id), '[]'::jsonb))$a$ in d) = 0 then raise exception 'vals'; end if;
  d := replace(d, $a$from public.pos_refunds r where r.shift_id = s.id), '[]'::jsonb))$a$, $a$from public.pos_refunds r where r.shift_id = s.id), '[]'::jsonb), v_meth)$a$);
  d := replace(d, $a$'refunded_minor', x.refunded_minor)$a$, $a$'refunded_minor', x.refunded_minor, 'method', x.payment_method)$a$);
  d := replace(d, $a$'amount_minor', r.amount_minor, 'reason', r.reason, 'at', r.created_at)$a$, $a$'amount_minor', r.amount_minor, 'reason', r.reason, 'method', r.refund_method, 'at', r.created_at)$a$);
  drop function public.pos_close_shift(uuid, bigint, text, text, text);
  execute d;
  revoke all on function public.pos_close_shift(uuid, bigint, text, text, text, bigint, bigint) from public, anon;
  grant execute on function public.pos_close_shift(uuid, bigint, text, text, text, bigint, bigint) to authenticated;
end $$;

-- refunds paid back by card / wallet, for the closing screen
do $$
declare d text; old text := $q$'expenses_minor', coalesce(($q$;
begin
  d := pg_get_functiondef('public._shift_totals(uuid)'::regprocedure);
  if position('card_refunds_minor' in d) > 0 then return; end if;
  if position(old in d) = 0 then raise exception 'pattern'; end if;
  execute replace(d, old, $q$'card_refunds_minor', coalesce((select sum(r.amount_minor) from public.pos_refunds r where r.shift_id = s.id and r.refund_method = 'card'), 0),
    'wallet_refunds_minor', coalesce((select sum(r.amount_minor) from public.pos_refunds r where r.shift_id = s.id and r.refund_method = 'wallet'), 0),
    'expenses_minor', coalesce(($q$);
end $$;
