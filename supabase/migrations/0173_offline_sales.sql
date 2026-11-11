-- 0173: selling without internet. The till keeps the invoice on the computer and sends it when the connection is back
-- (same idempotency key: never recorded twice). pos_create_sale learns:
--   p_sold_at : when it was really sold (kept if inside the open shift and the last 3 days) -> targets and reports use the true day
--   p_seller  : who was the seller on the screen at that moment (a cashier of the same branch)
--   p_number  : the 8-digit invoice number already printed on the customer's receipt (used when still free)
-- An offline sale is never refused for stock: the goods already left the shop (stock may go negative, visible to the owner).
-- pos_catalog_snapshot: the full price list kept on the computer so search and barcode work offline.

create or replace function pg_temp.edit(d text, p_old text, p_new text) returns text language plpgsql as $$
begin
  if position(p_old in d) = 0 then raise exception 'patch miss [%]', p_old; end if;
  return replace(d, p_old, p_new);
end $$;

do $$
declare d text;
begin
  d := pg_get_functiondef('public.pos_create_sale(text,uuid,jsonb,bigint,bigint,uuid,uuid)'::regprocedure);
  d := pg_temp.edit(d, 'p_approval uuid DEFAULT NULL::uuid)',
       'p_approval uuid DEFAULT NULL::uuid, p_sold_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_seller uuid DEFAULT NULL::uuid, p_number text DEFAULT NULL::text)');
  d := pg_temp.edit(d, $q$if not v_neg and (l ->> 'stock')::int$q$, $q$if not v_neg and p_sold_at is null and (l ->> 'stock')::int$q$);
  d := pg_temp.edit(d, 'v_num := public._pos_new_number();',
       $q$v_num := case when p_number ~ '^[0-9]{8}$' and not exists (select 1 from public.pos_sales where number = p_number) then p_number else public._pos_new_number() end;$q$);
  d := pg_temp.edit(d, 'and public._seller_ok(sh.id, user_id);',
       'and public._seller_ok(sh.id, user_id); if p_seller is not null and public._seller_ok(sh.id, p_seller) then v_seller := p_seller; end if;');
  d := pg_temp.edit(d, 'cash_received_minor, change_minor, approval_id, seller_id)', 'cash_received_minor, change_minor, approval_id, seller_id, created_at)');
  d := pg_temp.edit(d, 'case when v_seller is distinct from v_uid then v_seller end)',
       $q$case when v_seller is distinct from v_uid then v_seller end,
          case when p_sold_at is not null and p_sold_at >= greatest(sh.opened_at, now() - interval '3 days') and p_sold_at <= now() + interval '5 minutes'
               then least(p_sold_at, now()) else now() end)$q$);
  d := pg_temp.edit(d, $q$'lines', v_n)$q$, $q$'lines', v_n, 'offline', p_sold_at is not null)$q$);
  drop function public.pos_create_sale(text,uuid,jsonb,bigint,bigint,uuid,uuid);
  execute d;
end $$;
revoke all on function public.pos_create_sale(text,uuid,jsonb,bigint,bigint,uuid,uuid,timestamptz,uuid,text) from public, anon;
grant execute on function public.pos_create_sale(text,uuid,jsonb,bigint,bigint,uuid,uuid,timestamptz,uuid,text) to authenticated;

create or replace function public.pos_catalog_snapshot() returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
begin
  perform public.require_permission('pos.sell');
  return coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'sku', p.sku, 'barcode', p.barcode, 'name_ar', p.name_ar, 'name_en', p.name_en,
                                                      'price_minor', p.price_minor, 'stock_quantity', p.stock_quantity) order by p.name_ar)
                     from (select * from public.products where status = 'published' order by name_ar limit 5000) p), '[]'::jsonb);
end $$;
revoke all on function public.pos_catalog_snapshot() from public, anon;
grant execute on function public.pos_catalog_snapshot() to authenticated;
