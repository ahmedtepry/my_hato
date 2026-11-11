-- Invoice number: random, unique, 8 digits (new sales). Old invoices keep their number.
create or replace function public._pos_new_number() returns text
language plpgsql volatile security definer set search_path = public as $$
declare v text; n int := 0;
begin
  loop
    v := (10000000 + floor(random() * 90000000))::bigint::text;
    exit when not exists (select 1 from public.pos_sales where number = v);
    n := n + 1; if n > 50 then raise exception 'NUMBER_GENERATION_FAILED'; end if;
  end loop;
  return v;
end $$;
revoke all on function public._pos_new_number() from public, anon, authenticated;

do $$
declare d text; old text := $q$v_num := 'POS-' || to_char(now() at time zone 'Africa/Cairo', 'YYMMDD') || '-' || lpad(nextval('public.pos_sale_seq')::text, 5, '0');$q$;
begin
  d := pg_get_functiondef('public.pos_create_sale(text,uuid,jsonb,bigint,bigint,uuid,uuid)'::regprocedure);
  if position(old in d) = 0 then raise exception 'pattern not found'; end if;
  execute replace(d, old, 'v_num := public._pos_new_number();');
end $$;

-- Permission to open the invoices history
insert into public.permission_catalog (permission, grp, name_ar, name_en, desc_ar, desc_en, sensitive, inert, sort) values
  ('invoices.view','pos','يشوف سجل الفواتير','View invoices history','يشوف فواتير فرعه (مدفوعة وملغية) وتفاصيلها ويطبعها','Sees his branch invoices (paid and cancelled), their details, and prints them',false,false,66)
on conflict (permission) do nothing;
insert into public.role_permissions (role, permission) values
  ('owner','invoices.view'),('manager','invoices.view'),('cashier','invoices.view'),('accountant','invoices.view')
on conflict do nothing;

-- History of the caller's branch only. status: paid | cancelled | all
create or replace function public.pos_invoices_list(p_status text default 'all', p_from timestamptz default null, p_to timestamptz default null,
                                                     p_q text default null, p_limit int default 200)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare q text := nullif(btrim(coalesce(p_q, '')), '');
begin
  perform public.require_permission('invoices.view');
  if p_status not in ('paid','cancelled','all') then raise exception 'INVALID_INPUT'; end if;
  return coalesce((select jsonb_agg(x order by (x->>'created_at') desc) from (
    select jsonb_build_object('id', s.id, 'number', s.number, 'total_minor', s.total_minor, 'refunded_minor', s.refunded_minor,
             'status', case when s.refunded_minor >= s.total_minor then 'cancelled' else 'paid' end,
             'created_at', s.created_at, 'payment_method', s.payment_method, 'branch_name_ar', b.name_ar,
             'seller_code', tm.login_name, 'seller_name', coalesce(tm.login_display, p.full_name)) as x
      from public.pos_sales s
      left join public.branches b on b.id = s.branch_id
      left join public.profiles p on p.id = s.cashier_id
      left join public.team_members tm on tm.user_id = s.cashier_id
     where public._branch_ok(s.branch_id)
       and (p_from is null or s.created_at >= p_from) and (p_to is null or s.created_at < p_to)
       and (p_status = 'all' or (p_status = 'cancelled') = (s.refunded_minor >= s.total_minor))
       and (q is null or s.number ilike '%' || replace(replace(q, '%', ''), '_', '') || '%')
     order by s.created_at desc limit least(greatest(coalesce(p_limit, 200), 1), 500)) t), '[]'::jsonb);
end $$;
revoke all on function public.pos_invoices_list(text, timestamptz, timestamptz, text, int) from public, anon;
grant execute on function public.pos_invoices_list(text, timestamptz, timestamptz, text, int) to authenticated;

-- Details of one invoice: only with the permission, only for the caller's branch.
create or replace function public.pos_invoice_detail(p_sale uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s public.pos_sales%rowtype;
begin
  perform public.require_permission('invoices.view');
  select * into s from public.pos_sales where id = p_sale;
  if not found or not public._branch_ok(s.branch_id) then raise exception 'NOT_FOUND'; end if;
  return public._pos_sale_json(s.id) || jsonb_build_object(
    'seller_code', (select login_name from public.team_members where user_id = s.cashier_id),
    'cancelled', s.refunded_minor >= s.total_minor);
end $$;
revoke all on function public.pos_invoice_detail(uuid) from public, anon;
grant execute on function public.pos_invoice_detail(uuid) to authenticated;
