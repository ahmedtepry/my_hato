-- 0082: a small discount (default up to 10 EGP, the owner can change it) needs no approval, whatever its % of the invoice.
-- A cashier with the pos.discount permission gives it straight away; anything above both the % limit and this amount still waits for an approval.
insert into public.application_settings (key, value, description) values
  ('pos_discount_free_minor', '1000', 'Cashier discount up to this amount (minor units) never needs approval')
on conflict (key) do nothing;

create or replace function public.pos_create_sale(p_idempotency_key text, p_shift uuid, p_items jsonb, p_discount_minor bigint default 0,
                                                  p_cash_received_minor bigint default 0, p_customer uuid default null, p_approval uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := public.require_auth(); sh public.shifts%rowtype; v_sale public.pos_sales%rowtype; ap public.approvals%rowtype;
  v_lines jsonb; v_sub bigint; v_disc bigint := coalesce(p_discount_minor, 0); v_total bigint; v_pct numeric; v_need boolean := false;
  v_neg boolean; v_id uuid; v_num text; v_n int; v_rem bigint; v_share bigint; v_net bigint; l jsonb; v_i int := 0; v_cnt int;
begin
  perform public.require_permission('pos.sell');
  if p_idempotency_key is null or char_length(p_idempotency_key) not between 8 and 80 then raise exception 'INVALID_INPUT'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v_uid::text || p_idempotency_key, 0));
  select * into v_sale from public.pos_sales where cashier_id = v_uid and idempotency_key = p_idempotency_key;
  if found then return public._pos_sale_json(v_sale.id); end if;      -- a repeated tap / re-sent request: same invoice, no second sale

  select * into sh from public.shifts where id = p_shift;
  if not found or sh.cashier_id <> v_uid or sh.status <> 'open' then raise exception 'NO_OPEN_SHIFT'; end if;
  if not public._branch_ok(sh.branch_id) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;

  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 60 then raise exception 'INVALID_INPUT'; end if;
  if exists (select 1 from jsonb_array_elements(p_items) e
              where jsonb_typeof(e) <> 'object' or jsonb_typeof(e -> 'quantity') <> 'number'
                 or (e ->> 'quantity')::numeric <> trunc((e ->> 'quantity')::numeric) or (e ->> 'quantity')::numeric not between 1 and 999
                 or coalesce(e ->> 'product_id', '') !~ '^[0-9a-fA-F-]{36}$') then raise exception 'INVALID_INPUT'; end if;

  perform 1 from public.products where id in (select (e ->> 'product_id')::uuid from jsonb_array_elements(p_items) e) order by id for update;

  select jsonb_agg(jsonb_build_object('pid', x.pid, 'q', x.q, 'sku', p.sku, 'name_ar', p.name_ar, 'name_en', p.name_en,
                   'price', p.price_minor, 'stock', p.stock_quantity, 'status', p.status) order by x.pid),
         coalesce(sum(p.price_minor * x.q), 0), count(*)
    into v_lines, v_sub, v_cnt
    from (select (e ->> 'product_id')::uuid as pid, sum((e ->> 'quantity')::int)::int as q from jsonb_array_elements(p_items) e group by 1) x
    join public.products p on p.id = x.pid;
  if v_cnt <> (select count(distinct (e ->> 'product_id')::uuid) from jsonb_array_elements(p_items) e) then raise exception 'NOT_FOUND'; end if;
  if v_sub <= 0 then raise exception 'INVALID_INPUT'; end if;

  v_neg := exists (select 1 from public.application_settings where key = 'pos_allow_negative_stock' and value = 'true'::jsonb);
  for l in select * from jsonb_array_elements(v_lines) loop
    if l ->> 'status' <> 'published' then raise exception 'NOT_FOUND'; end if;
    if not v_neg and (l ->> 'stock')::int < (l ->> 'q')::int then raise exception 'OUT_OF_STOCK' using detail = l ->> 'sku'; end if;
  end loop;

  if v_disc < 0 or v_disc > v_sub then raise exception 'INVALID_INPUT'; end if;
  if v_disc > 0 and not public.has_role('owner') then
    v_pct := v_disc * 100.0 / v_sub;
    v_need := not (public.has_permission('pos.discount') and (v_pct <= public._pos_num('pos_discount_approval_pct', 10) or v_disc <= public._pos_num('pos_discount_free_minor', 1000)));
    if v_need then
      if p_approval is null then raise exception 'APPROVAL_REQUIRED'; end if;
      select * into ap from public.approvals where id = p_approval for update;
      if not found or ap.kind <> 'discount' or ap.status <> 'approved' or ap.requested_by <> v_uid
         or ap.branch_id <> sh.branch_id or ap.amount_minor < v_disc then raise exception 'APPROVAL_REQUIRED'; end if;
    end if;
  end if;

  v_total := v_sub - v_disc;
  if p_cash_received_minor is null or p_cash_received_minor < v_total or p_cash_received_minor > 10000000000 then raise exception 'CASH_SHORT'; end if;

  v_num := 'POS-' || to_char(now() at time zone 'Africa/Cairo', 'YYMMDD') || '-' || lpad(nextval('public.pos_sale_seq')::text, 5, '0');
  insert into public.pos_sales (number, branch_id, shift_id, cashier_id, customer_id, idempotency_key, subtotal_minor, discount_minor, total_minor,
                                cash_received_minor, change_minor, approval_id)
  values (v_num, sh.branch_id, sh.id, v_uid, p_customer, p_idempotency_key, v_sub, v_disc, v_total, p_cash_received_minor,
          p_cash_received_minor - v_total, case when v_need then ap.id end)
  returning id into v_id;

  v_n := jsonb_array_length(v_lines); v_rem := v_disc;
  perform set_config('myhato.stock_ctx', 'pos', true);
  for l in select * from jsonb_array_elements(v_lines) loop
    v_i := v_i + 1;
    v_share := case when v_i = v_n then v_rem else round(v_disc * ((l ->> 'price')::bigint * (l ->> 'q')::int)::numeric / v_sub) end;
    v_rem := v_rem - v_share;
    v_net := (l ->> 'price')::bigint * (l ->> 'q')::int - v_share;
    insert into public.pos_sale_items (sale_id, product_id, sku, name_ar, name_en, quantity, unit_price_minor, line_total_minor, net_line_minor)
    values (v_id, (l ->> 'pid')::uuid, l ->> 'sku', l ->> 'name_ar', l ->> 'name_en', (l ->> 'q')::int, (l ->> 'price')::bigint,
            (l ->> 'price')::bigint * (l ->> 'q')::int, v_net);
    update public.products set stock_quantity = stock_quantity - (l ->> 'q')::int where id = (l ->> 'pid')::uuid;
    insert into public.inventory_movements (product_id, delta, reason, note, created_by, pos_sale_id)
    values ((l ->> 'pid')::uuid, -(l ->> 'q')::int, 'pos_sale', v_num, v_uid, v_id);
  end loop;
  perform set_config('myhato.stock_ctx', '', true);

  if v_need then update public.approvals set status = 'used', used_at = now() where id = ap.id; end if;
  perform public.audit_write('pos.sale', 'pos_sale', v_id::text, jsonb_build_object('branch_id', sh.branch_id, 'number', v_num, 'shift_id', sh.id,
          'total_minor', v_total, 'discount_minor', v_disc, 'approval_id', case when v_need then ap.id end, 'lines', v_n));
  return public._pos_sale_json(v_id);
end $$;

create or replace function public.pos_get_limits() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_auth();
  if not (public.has_permission('pos.sell') or public.has_permission('settings.manage')) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return jsonb_build_object('discount_approval_pct', public._pos_num('pos_discount_approval_pct', 10),
    'discount_free_minor', public._pos_num('pos_discount_free_minor', 1000),
    'refund_approval_minor', public._pos_num('pos_refund_approval_minor', 50000),
    'allow_negative_stock', exists (select 1 from public.application_settings where key = 'pos_allow_negative_stock' and value = 'true'::jsonb),
    'can_discount', public.has_permission('pos.discount'), 'is_owner', public.has_role('owner'));
end $$;

drop function if exists public.pos_set_limits(numeric, bigint, boolean);
create or replace function public.pos_set_limits(p_discount_pct numeric, p_refund_minor bigint, p_allow_negative boolean, p_free_minor bigint default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.require_permission('settings.manage');
  if not public.has_role('owner') then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_discount_pct is null or p_discount_pct < 0 or p_discount_pct > 100 or p_refund_minor is null or p_refund_minor < 0 or coalesce(p_free_minor, 0) < 0 then raise exception 'INVALID_INPUT'; end if;
  insert into public.application_settings (key, value, updated_by, updated_at) values
    ('pos_discount_approval_pct', to_jsonb(p_discount_pct), auth.uid(), now()),
    ('pos_refund_approval_minor', to_jsonb(p_refund_minor), auth.uid(), now()),
    ('pos_allow_negative_stock', to_jsonb(coalesce(p_allow_negative, false)), auth.uid(), now()),
    ('pos_discount_free_minor', to_jsonb(coalesce(p_free_minor, public._pos_num('pos_discount_free_minor', 1000))), auth.uid(), now())
  on conflict (key) do update set value = excluded.value, updated_by = excluded.updated_by, updated_at = now();
  perform public.audit_write('pos.limits', 'settings', 'pos', jsonb_build_object('discount_pct', p_discount_pct, 'refund_minor', p_refund_minor, 'allow_negative', p_allow_negative, 'free_minor', p_free_minor));
end $$;
revoke all on function public.pos_set_limits(numeric, bigint, boolean, bigint) from public, anon;
grant execute on function public.pos_set_limits(numeric, bigint, boolean, bigint) to authenticated;
