-- 0099: the warehouse (head office branch) can send stock to the branches like any branch, and shows its unallocated stock as its own quantity.
create or replace function public.stock_overview(p_branch uuid default null, p_search text default null, p_limit int default 60) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_q text := nullif(btrim(coalesce(p_search, '')), ''); v_all boolean;
begin
  perform public.require_permission('stock.view');
  v_all := public.has_permission('stock.others');
  if p_branch is not null and not (case when v_all then public._branch_view_ok(p_branch) else public._branch_ok(p_branch) end) then raise exception 'FORBIDDEN'; end if;
  return coalesce((select jsonb_agg(x order by x.name_ar) from (
    select p.id as product_id, p.sku, p.name_ar, p.name_en,
           case when v_all then p.stock_quantity end as total,
           case when v_all then greatest(public._stock_unallocated(p.id), 0) end as unallocated,
           coalesce((select jsonb_agg(jsonb_build_object('branch_id', b.id, 'qty', coalesce(bs.quantity, 0) + case when b.is_hq then greatest(public._stock_unallocated(p.id), 0) else 0 end))
                       from public.branches b left join public.branch_stock bs on bs.branch_id = b.id and bs.product_id = p.id
                      where b.is_active and coalesce(bs.quantity, 0) + case when b.is_hq then greatest(public._stock_unallocated(p.id), 0) else 0 end > 0
                        and (v_all or public._branch_ok(b.id))), '[]'::jsonb) as branches
      from public.products p
     where p.status <> 'archived'
       and (v_q is null or p.name_ar ilike '%' || v_q || '%' or p.name_en ilike '%' || v_q || '%' or p.sku ilike '%' || v_q || '%')
       and (p_branch is null or v_q is not null or exists (select 1 from public.branch_stock bs where bs.product_id = p.id and bs.branch_id = p_branch and bs.quantity > 0)
            or (exists (select 1 from public.branches hb where hb.id = p_branch and hb.is_hq) and public._stock_unallocated(p.id) > 0))
       and (v_all or v_q is not null or exists (select 1 from public.branch_stock bs where bs.product_id = p.id and bs.quantity > 0 and public._branch_ok(bs.branch_id)))
     order by p.name_ar limit least(greatest(coalesce(p_limit, 60), 1), 200)) x), '[]'::jsonb);
end $$;
revoke all on function public.stock_overview(uuid, text, int) from public, anon;
grant execute on function public.stock_overview(uuid, text, int) to authenticated;

create or replace function public.stock_transfer_create(p_from uuid, p_to uuid, p_items jsonb, p_note text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := public.require_auth(); v_id uuid; it jsonb; p public.products; v_have int; v_n int := 0; v_seen uuid[] := '{}'; v_pid uuid; v_q int;
        v_from text; v_to text; v_me text; v_num text; v_u uuid;
begin
  perform public.require_permission('stock.transfer');
  if p_from is null or p_to is null or p_from = p_to or not public._branch_ok(p_from) then raise exception 'FORBIDDEN'; end if;
  if not exists (select 1 from public.branches where id = p_to and is_active) or not exists (select 1 from public.branches where id = p_from and is_active) then raise exception 'INVALID_INPUT'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 30 then raise exception 'INVALID_INPUT'; end if;
  if p_note is not null and char_length(p_note) > 300 then raise exception 'INVALID_INPUT'; end if;
  insert into public.stock_transfers (from_branch, to_branch, note, created_by) values (p_from, p_to, nullif(btrim(coalesce(p_note, '')), ''), v_uid) returning id, number into v_id, v_num;
  for it in select * from jsonb_array_elements(p_items) loop
    v_pid := (it ->> 'product_id')::uuid; v_q := (it ->> 'qty')::int;
    if v_q is null or v_q < 1 or v_q > 100000 or v_pid = any (v_seen) then raise exception 'INVALID_INPUT'; end if;
    v_seen := v_seen || v_pid;
    select * into p from public.products where id = v_pid for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    -- the head office branch IS the warehouse: its unallocated stock can be sent without allocating it first
    if exists (select 1 from public.branches where id = p_from and is_hq) then
      select coalesce(quantity, 0) into v_have from public.branch_stock where branch_id = p_from and product_id = v_pid;
      v_have := coalesce(v_have, 0);
      if v_have < v_q and public._stock_unallocated(v_pid) > 0 then
        perform public._branch_stock_add(p_from, v_pid, least(v_q - v_have, public._stock_unallocated(v_pid)));
      end if;
    end if;
    select quantity into v_have from public.branch_stock where branch_id = p_from and product_id = v_pid for update;
    if coalesce(v_have, 0) < v_q then raise exception 'INSUFFICIENT_STOCK:%', p.name_ar; end if;
    perform public._branch_stock_add(p_from, v_pid, -v_q);
    insert into public.stock_transfer_items (transfer_id, product_id, sku, name_ar, name_en, qty_sent) values (v_id, v_pid, p.sku, p.name_ar, p.name_en, v_q);
    v_n := v_n + v_q;
  end loop;
  select name_ar into v_from from public.branches where id = p_from;
  select name_ar into v_to from public.branches where id = p_to;
  select coalesce(nullif(btrim(full_name), ''), email, 'موظف') into v_me from public.profiles where id = v_uid;
  for v_u in select * from public._stock_people(p_to, 'stock.receive') loop
    if v_u <> v_uid then
      perform public.notify_user(v_u, '📦 تحويل جديد لفرعك', '📦 New transfer to your branch',
        v_me || ' حوّل ' || v_n || ' قطعة من فرع ' || v_from || ' إلى فرع ' || v_to || ' (' || v_num || '). افتح «مخزن» وأكّد استلامك.',
        v_me || ' sent ' || v_n || ' pieces from ' || v_from || ' to ' || v_to || ' (' || v_num || '). Open Stock and confirm.',
        'system', null, v_num, '/');
    end if;
  end loop;
  perform public.audit_write('stock.transfer', 'stock_transfer', v_id::text, jsonb_build_object('from', p_from, 'to', p_to, 'pieces', v_n));
  return v_id;
end $$;
revoke all on function public.stock_transfer_create(uuid, uuid, jsonb, text) from public, anon;
grant execute on function public.stock_transfer_create(uuid, uuid, jsonb, text) to authenticated;
