-- Refund flow: the invoice is found by its 8-digit number, a reason is required, the money goes back the way the customer chooses
-- (cash from the drawer / card / wallet), the invoice shows as cancelled when everything is returned, and the return window is 14 days
-- (the owner is not limited). pos_find_sale had gone missing in the live database, which made every refund search fail.

alter table public.pos_refunds add column if not exists refund_method text not null default 'cash' check (refund_method in ('cash','card','wallet'));
update public.pos_refunds r set refund_method = case when s.payment_method in ('card','wallet') then s.payment_method else 'cash' end
  from public.pos_sales s where s.id = r.sale_id;

insert into public.application_settings (key, value, description) values
  ('pos_refund_days', '14'::jsonb, 'Days after the sale during which a refund is accepted (owner is not limited)')
on conflict (key) do nothing;

create or replace function public._pos_sale_json(p_sale uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select to_jsonb(s) || jsonb_build_object(
    'branch_name_ar', (select name_ar from public.branches where id = s.branch_id),
    'cashier_name', (select coalesce(tm.login_display, p.full_name) from public.profiles p left join public.team_members tm on tm.user_id = p.id where p.id = s.cashier_id),
    'cancelled', s.refunded_minor >= s.total_minor,
    'refunds', coalesce((select jsonb_agg(jsonb_build_object('amount_minor', r.amount_minor, 'reason', r.reason, 'method', r.refund_method, 'at', r.created_at,
                          'by', (select coalesce(tm2.login_display, p2.full_name) from public.profiles p2 left join public.team_members tm2 on tm2.user_id = p2.id where p2.id = r.requested_by)) order by r.created_at)
                         from public.pos_refunds r where r.sale_id = s.id), '[]'::jsonb),
    'items', coalesce((select jsonb_agg(to_jsonb(i) order by i.name_ar) from public.pos_sale_items i where i.sale_id = s.id), '[]'::jsonb))
  from public.pos_sales s where s.id = p_sale
$$;

create or replace function public.pos_find_sale(p_number text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s public.pos_sales%rowtype;
begin
  perform public.require_auth();
  select * into s from public.pos_sales where number = upper(btrim(coalesce(p_number, '')));
  if not found then raise exception 'NOT_FOUND'; end if;
  if not (s.cashier_id = auth.uid()
          or ((public.has_permission('shifts.review') or public.has_permission('pos.refund') or public.has_permission('invoices.view')) and public._branch_ok(s.branch_id))) then
    raise exception 'NOT_FOUND';
  end if;
  return public._pos_sale_json(s.id);
end $$;
revoke all on function public.pos_find_sale(text) from public, anon;
grant execute on function public.pos_find_sale(text) to authenticated;

drop function if exists public.pos_refund(uuid, jsonb, text, boolean, uuid);
create or replace function public.pos_refund(p_sale uuid, p_items jsonb, p_reason text, p_restock boolean default true, p_approval uuid default null, p_method text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := public.require_auth(); s public.pos_sales%rowtype; sh public.shifts%rowtype; ap public.approvals%rowtype;
  e jsonb; it public.pos_sale_items%rowtype; v_q int; v_amt bigint; v_total bigint := 0; v_lines jsonb := '[]'::jsonb; v_id uuid; v_need boolean := false;
  v_method text;
begin
  perform public.require_permission('pos.refund');
  if char_length(btrim(coalesce(p_reason, ''))) < 3 then raise exception 'REASON_REQUIRED'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 60 then raise exception 'INVALID_INPUT'; end if;
  select * into sh from public.shifts where cashier_id = v_uid and status = 'open';
  if not found then raise exception 'NO_OPEN_SHIFT'; end if;
  select * into s from public.pos_sales where id = p_sale for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if s.branch_id <> sh.branch_id or not public._branch_ok(s.branch_id) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if s.created_at < now() - make_interval(days => public._pos_num('pos_refund_days', 14)::int) and not public.has_role('owner') then
    raise exception 'REFUND_WINDOW_PASSED';
  end if;
  v_method := coalesce(nullif(btrim(p_method), ''), case when s.payment_method in ('card','wallet') then s.payment_method else 'cash' end);
  if v_method not in ('cash','card','wallet') then raise exception 'INVALID_INPUT'; end if;

  for e in select * from jsonb_array_elements(p_items) loop
    if jsonb_typeof(e -> 'quantity') <> 'number' or (e ->> 'quantity')::numeric <> trunc((e ->> 'quantity')::numeric)
       or (e ->> 'quantity')::numeric < 1 or coalesce(e ->> 'item_id', '') !~ '^[0-9a-fA-F-]{36}$' then raise exception 'INVALID_INPUT'; end if;
    select * into it from public.pos_sale_items where id = (e ->> 'item_id')::uuid and sale_id = s.id for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    v_q := (e ->> 'quantity')::int;
    if v_q > it.quantity - it.refunded_qty then raise exception 'REFUND_EXCEEDS_SOLD'; end if;
    v_amt := case when v_q = it.quantity - it.refunded_qty then it.net_line_minor - it.refunded_amount_minor
                  else round(it.net_line_minor::numeric * v_q / it.quantity) end;
    v_total := v_total + v_amt;
    v_lines := v_lines || jsonb_build_array(jsonb_build_object('item_id', it.id, 'product_id', it.product_id, 'quantity', v_q, 'amount_minor', v_amt));
    update public.pos_sale_items set refunded_qty = refunded_qty + v_q, refunded_amount_minor = refunded_amount_minor + v_amt where id = it.id;
  end loop;
  if v_total <= 0 or s.refunded_minor + v_total > s.total_minor then raise exception 'REFUND_EXCEEDS_SOLD'; end if;

  if v_total > public._pos_num('pos_refund_approval_minor', 50000) and not public.has_role('owner') then
    v_need := true;
    if p_approval is null then raise exception 'APPROVAL_REQUIRED'; end if;
    select * into ap from public.approvals where id = p_approval for update;
    if not found or ap.kind <> 'refund' or ap.status <> 'approved' or ap.requested_by <> v_uid or ap.branch_id <> s.branch_id
       or ap.amount_minor < v_total then raise exception 'APPROVAL_REQUIRED'; end if;
  end if;

  insert into public.pos_refunds (sale_id, shift_id, branch_id, amount_minor, reason, items, restocked, requested_by, approval_id, refund_method)
  values (s.id, sh.id, s.branch_id, v_total, left(btrim(p_reason), 300), v_lines, coalesce(p_restock, true), v_uid, case when v_need then ap.id end, v_method)
  returning id into v_id;
  update public.pos_sales set refunded_minor = refunded_minor + v_total where id = s.id;

  if coalesce(p_restock, true) then
    perform set_config('myhato.stock_ctx', 'pos', true);
    for e in select * from jsonb_array_elements(v_lines) loop
      update public.products set stock_quantity = stock_quantity + (e ->> 'quantity')::int where id = (e ->> 'product_id')::uuid;
      insert into public.inventory_movements (product_id, delta, reason, note, created_by, pos_sale_id)
      values ((e ->> 'product_id')::uuid, (e ->> 'quantity')::int, 'pos_refund', s.number, v_uid, s.id);
    end loop;
    perform set_config('myhato.stock_ctx', '', true);
  end if;
  if v_need then update public.approvals set status = 'used', used_at = now() where id = ap.id; end if;
  perform public.audit_write('pos.refund', 'pos_sale', s.id::text, jsonb_build_object('branch_id', s.branch_id, 'number', s.number, 'refund_id', v_id,
          'amount_minor', v_total, 'reason', left(btrim(p_reason), 300), 'method', v_method, 'approval_id', case when v_need then ap.id end, 'restocked', coalesce(p_restock, true)));
  return jsonb_build_object('refund_id', v_id, 'amount_minor', v_total, 'method', v_method, 'cancelled', s.refunded_minor + v_total >= s.total_minor, 'sale', public._pos_sale_json(s.id));
end $$;
revoke all on function public.pos_refund(uuid, jsonb, text, boolean, uuid, text) from public, anon;
grant execute on function public.pos_refund(uuid, jsonb, text, boolean, uuid, text) to authenticated;

-- the drawer only loses the cash that was really handed back in cash (card / wallet refunds do not touch the drawer)
do $$
declare d text; old text := $q$where r.shift_id = s.id and x.payment_method = 'cash'), 0)$q$;
begin
  d := pg_get_functiondef('public._shift_totals(uuid)'::regprocedure);
  if position(old in d) = 0 then raise exception 'shift totals pattern'; end if;
  execute replace(d, old, $q$where r.shift_id = s.id and r.refund_method = 'cash'), 0)$q$);
end $$;
