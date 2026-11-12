-- offline sale of an item already at 0 on the system: nothing to take off, so no (zero) line in the stock log
create or replace function pg_temp.edit(d text, p_old text, p_new text) returns text language plpgsql as $$
begin
  if position(p_old in d) = 0 then raise exception 'patch miss [%]', p_old; end if;
  return replace(d, p_old, p_new);
end $$;
do $$
declare d text;
begin
  d := pg_get_functiondef('public.pos_create_sale(text,uuid,jsonb,bigint,bigint,uuid,uuid,timestamptz,uuid,text)'::regprocedure);
  d := pg_temp.edit(d, 'insert into public.inventory_movements (product_id, delta, reason, note, created_by, pos_sale_id)',
    $q$if p_sold_at is null or least((l ->> 'q')::int, greatest((l ->> 'stock')::int, 0)) > 0 then
    insert into public.inventory_movements (product_id, delta, reason, note, created_by, pos_sale_id)$q$);
  d := pg_temp.edit(d, $q$else (l ->> 'q')::int end), 'pos_sale', v_num, v_uid, v_id);$q$,
    $q$else (l ->> 'q')::int end), 'pos_sale', v_num, v_uid, v_id);
    end if;$q$);
  execute d;
end $$;
