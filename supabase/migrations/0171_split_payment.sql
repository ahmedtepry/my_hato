-- 0171: split payment — one invoice paid partly cash, partly Visa, partly wallet.
-- Every sale now records how much went to each method (paid_cash / paid_card / paid_wallet). A single-method sale fills
-- its method with the total automatically, so all totals (shift header, close-shift reconciliation, branch split) read the parts.

alter table public.pos_sales
  add column if not exists paid_cash_minor bigint not null default 0,
  add column if not exists paid_card_minor bigint not null default 0,
  add column if not exists paid_wallet_minor bigint not null default 0;

alter table public.pos_sales drop constraint if exists pos_sales_payment_method_check;
alter table public.pos_sales add constraint pos_sales_payment_method_check check (payment_method = any (array['cash','card','wallet','split']));

-- keep the parts in step with the method; a split must add up to the invoice total
create or replace function public._pos_paid_sync() returns trigger
language plpgsql set search_path to 'public' as $$
begin
  if coalesce(new.payment_method, 'cash') <> 'split' then
    new.paid_cash_minor := case when coalesce(new.payment_method, 'cash') = 'cash' then new.total_minor else 0 end;
    new.paid_card_minor := case when new.payment_method = 'card' then new.total_minor else 0 end;
    new.paid_wallet_minor := case when new.payment_method = 'wallet' then new.total_minor else 0 end;
  elsif new.paid_cash_minor < 0 or new.paid_card_minor < 0 or new.paid_wallet_minor < 0
        or new.paid_cash_minor + new.paid_card_minor + new.paid_wallet_minor <> new.total_minor then
    raise exception 'SPLIT_NOT_TOTAL';
  end if;
  return new;
end $$;
drop trigger if exists pos_sales_paid_sync on public.pos_sales;
create trigger pos_sales_paid_sync before insert or update of payment_method, paid_cash_minor, paid_card_minor, paid_wallet_minor
  on public.pos_sales for each row execute function public._pos_paid_sync();

update public.pos_sales set payment_method = coalesce(payment_method, 'cash');  -- fires the trigger: fills the parts of every old sale

-- set (or change) the split of a sale; same rules as changing the payment method (open shift, no tip, no refund yet)
create or replace function public.pos_set_sale_split(p_sale uuid, p_cash bigint, p_card bigint, p_wallet bigint, p_reason text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare s public.pos_sales%rowtype; v_c bigint := coalesce(p_cash, 0); v_k bigint := coalesce(p_card, 0); v_w bigint := coalesce(p_wallet, 0); v_n int;
begin
  perform public.require_auth();
  select * into s from public.pos_sales where id = p_sale for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if not (s.cashier_id = auth.uid() or (public.has_permission('shifts.review') and public._branch_ok(s.branch_id))) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if not exists (select 1 from public.shifts where id = s.shift_id and status = 'open') then raise exception 'SHIFT_CLOSED'; end if;
  if s.tip_minor <> 0 then raise exception 'PAYMENT_LOCKED_TIP'; end if;
  if exists (select 1 from public.pos_refunds r where r.sale_id = s.id) then raise exception 'PAYMENT_LOCKED_REFUND'; end if;
  if v_c < 0 or v_k < 0 or v_w < 0 or v_c + v_k + v_w <> s.total_minor then raise exception 'SPLIT_NOT_TOTAL'; end if;
  v_n := (v_c > 0)::int + (v_k > 0)::int + (v_w > 0)::int;
  if v_n <= 1 then
    -- really one method: store it as a normal single-method sale
    return public.pos_set_sale_payment(p_sale, case when v_k > 0 then 'card' when v_w > 0 then 'wallet' else 'cash' end, p_reason);
  end if;
  update public.pos_sales set payment_method = 'split', paid_cash_minor = v_c, paid_card_minor = v_k, paid_wallet_minor = v_w,
         cash_received_minor = case when v_c = 0 then total_minor else cash_received_minor end,
         change_minor = case when v_c = 0 then 0 else change_minor end
   where id = s.id;
  perform public.audit_write('pos.payment', 'sale', s.number, jsonb_build_object('from', s.payment_method, 'to', 'split', 'cash', v_c, 'card', v_k, 'wallet', v_w,
          'reason', left(btrim(coalesce(p_reason, '')), 200), 'branch_id', s.branch_id, 'shift_id', s.shift_id, 'total_minor', s.total_minor));
  return public._pos_sale_json(s.id);
end $$;
revoke all on function public.pos_set_sale_split(uuid, bigint, bigint, bigint, text) from public, anon;
grant execute on function public.pos_set_sale_split(uuid, bigint, bigint, bigint, text) to authenticated;

-- ---- totals read the parts
create or replace function pg_temp.pf(p_fn regprocedure, p_old text, p_new text) returns void language plpgsql as $$
declare d text;
begin
  d := pg_get_functiondef(p_fn);
  if position(p_old in d) = 0 then raise exception 'patch miss [%] in %', p_old, p_fn; end if;
  execute replace(d, p_old, p_new);
end $$;

select pg_temp.pf('public._shift_totals(uuid)'::regprocedure,
  $q$coalesce((select sum(total_minor) from public.pos_sales x where x.shift_id = s.id and x.payment_method = 'cash'), 0)$q$,
  $q$coalesce((select sum(x.paid_cash_minor) from public.pos_sales x where x.shift_id = s.id), 0)$q$);
select pg_temp.pf('public._shift_totals(uuid)'::regprocedure,
  $q$coalesce((select sum(total_minor) from public.pos_sales x where x.shift_id = s.id and x.payment_method = 'card'), 0)$q$,
  $q$coalesce((select sum(x.paid_card_minor) from public.pos_sales x where x.shift_id = s.id), 0)$q$);
select pg_temp.pf('public._shift_totals(uuid)'::regprocedure,
  $q$coalesce((select sum(total_minor) from public.pos_sales x where x.shift_id = s.id and x.payment_method = 'wallet'), 0)$q$,
  $q$coalesce((select sum(x.paid_wallet_minor) from public.pos_sales x where x.shift_id = s.id), 0)$q$);
select pg_temp.pf('public._shift_totals(uuid)'::regprocedure,
  $q$(select count(*) from public.pos_sales x where x.shift_id = s.id and x.payment_method = 'card')$q$,
  $q$(select count(*) from public.pos_sales x where x.shift_id = s.id and x.paid_card_minor > 0)$q$);

do $$
declare f text;
begin
  foreach f in array array['public.pos_branch_payment_split(timestamptz,timestamptz)', 'public.pos_branch_payment_split2(timestamptz,timestamptz)'] loop
    perform pg_temp.pf(f::regprocedure, $q$sum(s.total_minor) filter (where s.payment_method = 'cash')$q$, $q$sum(s.paid_cash_minor)$q$);
    perform pg_temp.pf(f::regprocedure, $q$sum(s.total_minor) filter (where s.payment_method = 'card')$q$, $q$sum(s.paid_card_minor)$q$);
    perform pg_temp.pf(f::regprocedure, $q$count(s.id) filter (where s.payment_method = 'card')$q$, $q$count(s.id) filter (where s.paid_card_minor > 0)$q$);
  end loop;
  perform pg_temp.pf('public.pos_branch_payment_split2(timestamptz,timestamptz)'::regprocedure,
    $q$sum(s.total_minor) filter (where s.payment_method = 'wallet')$q$, $q$sum(s.paid_wallet_minor)$q$);
end $$;
