-- 0145: the marketing department.
--  * 4 new permissions (marketing.view / segments / campaigns / analytics) and the role 'marketing' with its working set
--  * customer segments, targeted campaigns (logged, rate-limited, audited), campaign and coupon performance, KPI overview
-- A "customer" is a profile with no staff role. Promotions go only to customers who left notify_promotions on.

insert into public.permission_catalog (permission, grp, name_ar, name_en, desc_ar, desc_en, sensitive, inert, sort) values
 ('marketing.view',      'marketing', 'يشوف لوحة التسويق',               'View the marketing dashboard',   'أرقام العملاء والطلبات والأكواد والتقييمات', 'Customer, order, coupon and review numbers', false, false, 60),
 ('marketing.segments',  'marketing', 'يشوف شرائح العملاء بأسمائهم',      'See customer segments by name',  'مين الـ VIP ومين اتأخر ومين جديد',          'Who is VIP, dormant or new',                 true,  false, 61),
 ('marketing.campaigns', 'marketing', 'يبعت حملات لشريحة عملاء',          'Send campaigns to a segment',    'إشعار مستهدف لشريحة (بحد 5 حملات في اليوم)', 'A targeted notification to one segment (max 5 a day)', true, false, 62),
 ('marketing.analytics', 'marketing', 'يشوف نتايج الحملات والأكواد',       'See campaign and coupon results','القراءة والاستخدام والإيراد لكل حملة وكود', 'Reads, uses and revenue per campaign and code', false, false, 63)
on conflict (permission) do update set name_ar = excluded.name_ar, name_en = excluded.name_en, desc_ar = excluded.desc_ar, desc_en = excluded.desc_en, sensitive = excluded.sensitive;

insert into public.role_permissions (role, permission) values
 ('owner','marketing.view'),('owner','marketing.segments'),('owner','marketing.campaigns'),('owner','marketing.analytics'),
 ('manager','marketing.view'),('manager','marketing.segments'),('manager','marketing.analytics'),
 ('sales','marketing.view'),('support','marketing.view'),
 ('marketing','marketing.view'),('marketing','marketing.segments'),('marketing','marketing.campaigns'),('marketing','marketing.analytics'),
 ('marketing','coupons.manage'),('marketing','banners.manage'),('marketing','notifications.broadcast'),('marketing','reviews.moderate'),
 ('marketing','contest.manage'),('marketing','occasions.manage'),('marketing','customers.view'),('marketing','chat.use'),('marketing','pos.remember_login')
on conflict do nothing;

create table if not exists public.marketing_campaigns (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  segment text not null,
  title text not null,
  body text not null,
  coupon_code text,
  audience int not null default 0,
  sent int not null default 0,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);
alter table public.marketing_campaigns enable row level security;
revoke all on public.marketing_campaigns from anon, authenticated;

-- ids of the customers in a segment (internal)
create or replace function public._marketing_segment_ids(p_segment text) returns setof uuid
language sql stable security definer set search_path = public as $$
  with cust as (
    select p.id, p.created_at, p.notify_promotions from public.profiles p
     where not exists (select 1 from public.user_roles ur where ur.user_id = p.id) and p.deletion_requested_at is null),
  spend as (
    select o.customer_id as id, count(*) n, coalesce(sum(o.total_minor),0) s, max(o.created_at) last_at
      from public.orders o where o.status <> 'cancelled' group by o.customer_id)
  select c.id from cust c left join spend s on s.id = c.id
   where case p_segment
     when 'all'        then true
     when 'opted_in'   then c.notify_promotions
     when 'new'        then c.created_at > now() - interval '14 days'
     when 'never'      then s.id is null
     when 'active'     then s.last_at > now() - interval '30 days'
     when 'dormant'    then s.last_at is not null and s.last_at <= now() - interval '60 days'
     when 'vip'        then coalesce(s.n,0) >= 5 or coalesce(s.s,0) >= 500000
     when 'points'     then exists (select 1 from public.loyalty_profiles l where l.user_id = c.id and l.points >= 500)
     else false end;
$$;
revoke all on function public._marketing_segment_ids(text) from public, anon, authenticated;

create or replace function public.marketing_segments() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare k text; out jsonb := '[]'::jsonb; n int; m int;
begin
  perform public.require_permission('marketing.view');
  foreach k in array array['all','opted_in','new','never','active','dormant','vip','points'] loop
    select count(*) into n from public._marketing_segment_ids(k);
    select count(*) into m from public._marketing_segment_ids(k) i join public.profiles p on p.id = i where p.notify_promotions;
    out := out || jsonb_build_array(jsonb_build_object('key', k, 'count', n, 'reachable', m));
  end loop;
  return out;
end $$;

create or replace function public.marketing_segment_sample(p_segment text, p_limit int default 8) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_permission('marketing.segments');
  return coalesce((select jsonb_agg(x) from (
    select p.full_name as name, (select count(*) from public.orders o where o.customer_id = p.id and o.status <> 'cancelled') as orders,
           (select coalesce(sum(o.total_minor),0) from public.orders o where o.customer_id = p.id and o.status <> 'cancelled') as spent_minor
      from public._marketing_segment_ids(p_segment) i join public.profiles p on p.id = i
     order by spent_minor desc limit greatest(1, least(coalesce(p_limit, 8), 25))) x), '[]'::jsonb);
end $$;

create or replace function public.marketing_overview() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r jsonb;
begin
  perform public.require_permission('marketing.view');
  with cust as (select p.id, p.created_at, p.notify_promotions from public.profiles p
                 where not exists (select 1 from public.user_roles ur where ur.user_id = p.id) and p.deletion_requested_at is null),
  ord as (select o.* from public.orders o where o.status <> 'cancelled'),
  per as (select customer_id, count(*) n from ord group by customer_id)
  select jsonb_build_object(
    'customers',        (select count(*) from cust),
    'new_30d',          (select count(*) from cust where created_at > now() - interval '30 days'),
    'new_prev_30d',     (select count(*) from cust where created_at > now() - interval '60 days' and created_at <= now() - interval '30 days'),
    'opted_in',         (select count(*) from cust where notify_promotions),
    'buyers_30d',       (select count(distinct customer_id) from ord where created_at > now() - interval '30 days'),
    'orders_30d',       (select count(*) from ord where created_at > now() - interval '30 days'),
    'revenue_30d',      (select coalesce(sum(total_minor),0) from ord where created_at > now() - interval '30 days'),
    'revenue_prev_30d', (select coalesce(sum(total_minor),0) from ord where created_at > now() - interval '60 days' and created_at <= now() - interval '30 days'),
    'repeat_rate',      (select case when count(*) = 0 then 0 else round(100.0 * count(*) filter (where n >= 2) / count(*)) end from per),
    'coupon_uses_30d',  (select count(*) from public.coupon_redemptions where created_at > now() - interval '30 days'),
    'coupon_discount_30d', (select coalesce(sum(discount_minor),0) from public.coupon_redemptions where created_at > now() - interval '30 days'),
    'promo_sent_30d',   (select count(*) from public.notifications where entity_type = 'promo' and created_at > now() - interval '30 days'),
    'promo_read_30d',   (select count(*) from public.notifications where entity_type = 'promo' and read_at is not null and created_at > now() - interval '30 days'),
    'rating_avg',       (select coalesce(round(avg(rating)::numeric, 2), 0) from public.product_reviews where status = 'approved'),
    'reviews',          (select count(*) from public.product_reviews where status = 'approved'),
    'reviews_pending',  (select count(*) from public.product_reviews where status = 'pending'),
    'wheel_spins_30d',  (select count(*) from public.wheel_spins where created_at > now() - interval '30 days'),
    'points_total',     (select coalesce(sum(points),0) from public.loyalty_profiles),
    'campaigns_30d',    (select count(*) from public.marketing_campaigns where created_at > now() - interval '30 days')
  ) into r;
  return r;
end $$;

create or replace function public.marketing_send_campaign(p_name text, p_segment text, p_title text, p_body text, p_coupon_code text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_code text := nullif(upper(trim(coalesce(p_coupon_code, ''))), '');
  v_link text; v_aud int := 0; v_sent int := 0; r record; v_id uuid;
begin
  perform public.require_permission('marketing.campaigns');
  if nullif(trim(p_name), '') is null or nullif(trim(p_title), '') is null or nullif(trim(p_body), '') is null
     or length(p_name) > 80 or length(p_title) > 120 or length(p_body) > 500
     or p_segment not in ('all','opted_in','new','never','active','dormant','vip','points') then
    raise exception 'INVALID_INPUT';
  end if;
  if v_code is not null and not exists (select 1 from public.coupons where code = v_code and is_active) then raise exception 'COUPON_INVALID'; end if;
  if (select count(*) from public.audit_logs where action = 'marketing.campaign' and created_at > now() - interval '24 hours') >= 5 then raise exception 'RATE_LIMITED'; end if;
  v_link := case when v_code is null then '/' else '/cart?coupon=' || v_code end;
  for r in select i as id, p.notify_promotions from public._marketing_segment_ids(p_segment) i join public.profiles p on p.id = i loop
    v_aud := v_aud + 1;
    if r.notify_promotions then
      perform public.notify_user(r.id, trim(p_title), trim(p_title), trim(p_body), trim(p_body), 'promo', null, v_code, v_link);
      v_sent := v_sent + 1;
    end if;
  end loop;
  insert into public.marketing_campaigns (name, segment, title, body, coupon_code, audience, sent, created_by)
  values (trim(p_name), p_segment, trim(p_title), trim(p_body), v_code, v_aud, v_sent, auth.uid()) returning id into v_id;
  perform public.audit_write('marketing.campaign', 'campaign', v_id::text, jsonb_build_object('segment', p_segment, 'audience', v_aud, 'sent', v_sent, 'coupon', v_code));
  return jsonb_build_object('id', v_id, 'audience', v_aud, 'sent', v_sent);
end $$;

create or replace function public.marketing_campaigns_list() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_permission('marketing.analytics');
  return coalesce((select jsonb_agg(x order by (x->>'created_at') desc) from (
    select jsonb_build_object('id', c.id, 'name', c.name, 'segment', c.segment, 'title', c.title, 'coupon', c.coupon_code,
             'audience', c.audience, 'sent', c.sent, 'created_at', c.created_at,
             'reads', (select count(*) from public.notifications n where n.entity_type = 'promo' and n.title_ar = c.title and n.read_at is not null and n.created_at between c.created_at - interval '2 minutes' and c.created_at + interval '5 minutes'),
             'uses',  case when c.coupon_code is null then 0 else (select count(*) from public.coupon_redemptions r where r.coupon_code = c.coupon_code and r.created_at >= c.created_at) end,
             'revenue_minor', case when c.coupon_code is null then 0 else (select coalesce(sum(o.total_minor),0) from public.orders o where o.coupon_code = c.coupon_code and o.status <> 'cancelled' and o.created_at >= c.created_at) end) x
      from public.marketing_campaigns c order by c.created_at desc limit 30) s), '[]'::jsonb);
end $$;

create or replace function public.marketing_coupon_performance() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_permission('marketing.analytics');
  return coalesce((select jsonb_agg(x) from (
    select c.code, c.title_ar as title, c.percent_off, c.amount_off_minor, c.is_active, c.ends_at, c.uses_count, c.max_uses,
           coalesce((select sum(r.discount_minor) from public.coupon_redemptions r where r.coupon_code = c.code), 0) as discount_minor,
           coalesce((select sum(o.total_minor) from public.orders o where o.coupon_code = c.code and o.status <> 'cancelled'), 0) as revenue_minor
      from public.coupons c order by c.created_at desc limit 30) x), '[]'::jsonb);
end $$;

do $$ declare f text; begin
  foreach f in array array['marketing_segments()','marketing_segment_sample(text,int)','marketing_overview()','marketing_send_campaign(text,text,text,text,text)','marketing_campaigns_list()','marketing_coupon_performance()'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
