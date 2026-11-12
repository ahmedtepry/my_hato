-- An offline sale is never refused for stock, but stock cannot go below zero: take what is there (down to 0),
-- record the real decrease in the stock log, and note the shortfall in the audit so the owner can count/adjust.
create or replace function pg_temp.edit(d text, p_old text, p_new text) returns text language plpgsql as $$
begin
  if position(p_old in d) = 0 then raise exception 'patch miss [%]', p_old; end if;
  return replace(d, p_old, p_new);
end $$;
do $$
declare d text;
begin
  d := pg_get_functiondef('public.pos_create_sale(text,uuid,jsonb,bigint,bigint,uuid,uuid,timestamptz,uuid,text)'::regprocedure);
  d := pg_temp.edit(d, $q$update public.products set stock_quantity = stock_quantity - (l ->> 'q')::int where id = (l ->> 'pid')::uuid;$q$,
    $q$update public.products set stock_quantity = case when p_sold_at is not null then greatest(stock_quantity - (l ->> 'q')::int, 0) else stock_quantity - (l ->> 'q')::int end where id = (l ->> 'pid')::uuid;
    if p_sold_at is not null and (l ->> 'stock')::int < (l ->> 'q')::int then
      perform public.audit_write('pos.offline_oversold', 'product', l ->> 'pid', jsonb_build_object('sale', v_num, 'sold', (l ->> 'q')::int, 'had', (l ->> 'stock')::int, 'sku', l ->> 'sku'));
    end if;$q$);
  d := pg_temp.edit(d, $q$values ((l ->> 'pid')::uuid, -(l ->> 'q')::int, 'pos_sale', v_num, v_uid, v_id);$q$,
    $q$values ((l ->> 'pid')::uuid, -(case when p_sold_at is not null then least((l ->> 'q')::int, greatest((l ->> 'stock')::int, 0)) else (l ->> 'q')::int end), 'pos_sale', v_num, v_uid, v_id);$q$);
  execute d;
end $$;
