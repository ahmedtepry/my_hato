-- Marketing email campaigns: queued to opted-in, verified-email customers; the worker (process-email-outbox) renders kind 'generic'.
alter table public.marketing_campaigns add column if not exists channel text not null default 'app' check (channel in ('app','email'));

create or replace function public.email_render_data(p_kind public.email_kind, p_payload jsonb)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if p_kind = 'order_new' then
    select to_jsonb(o) || jsonb_build_object(
      'items', (select jsonb_agg(to_jsonb(i) order by i.name_en) from public.order_items i where i.order_id = o.id),
      'branch', (select to_jsonb(b) from public.branches b where b.id = o.branch_id))
      into v from public.orders o where o.id = (p_payload->>'order_id')::uuid;
  elsif p_kind in ('repair_new','repair_customer_response') then
    select jsonb_build_object(
      'id', r.id, 'reference', r.reference, 'status', r.status, 'created_at', r.created_at,
      'device_brand', r.device_brand, 'device_model', r.device_model, 'imei_or_serial', r.imei_or_serial,
      'problem_description', r.problem_description, 'contact_name', r.contact_name, 'contact_phone', r.contact_phone,
      'pickup_address', r.pickup_address, 'preferred_pickup_at', r.preferred_pickup_at,
      'callback_requested', r.callback_requested,
      'branch', (select to_jsonb(b) from public.branches b where b.id = r.branch_id),
      'photo_count', (select count(*) from public.repair_attachments a where a.repair_id = r.id),
      'quote', (select to_jsonb(q) from public.repair_quotes q where q.id = nullif(p_payload->>'quote_id','')::uuid),
      'decision', p_payload->>'decision', 'via', p_payload->>'via')
      into v from public.repair_requests r where r.id = (p_payload->>'repair_id')::uuid;
  elsif p_kind = 'generic' then
    v := jsonb_build_object('subject', p_payload->>'subject', 'body', p_payload->>'body', 'coupon', p_payload->>'coupon');
  end if;
  return v;
end $$;

revoke execute on function public.email_render_data(public.email_kind, jsonb) from public, anon, authenticated;

create or replace function public.marketing_send_campaign_email(p_name text, p_segment text, p_title text, p_body text, p_coupon_code text default null)
 returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_code text := nullif(upper(trim(coalesce(p_coupon_code, ''))), '');
  v_aud int := 0; v_q int := 0; r record; v_id uuid;
begin
  perform public.require_permission('marketing.campaigns');
  if nullif(trim(p_name), '') is null or nullif(trim(p_title), '') is null or nullif(trim(p_body), '') is null
     or length(p_name) > 80 or length(p_title) > 120 or length(p_body) > 1500
     or p_segment not in ('all','opted_in','new','never','active','dormant','vip','points') then
    raise exception 'INVALID_INPUT';
  end if;
  if v_code is not null and not exists (select 1 from public.coupons where code = v_code and is_active) then raise exception 'COUPON_INVALID'; end if;
  if (select count(*) from public.marketing_campaigns where channel = 'email' and created_at > now() - interval '24 hours') >= 2 then raise exception 'RATE_LIMITED'; end if;
  for r in select i as id, p.notify_promotions, p.email, p.email_verified from public._marketing_segment_ids(p_segment) i join public.profiles p on p.id = i loop
    v_aud := v_aud + 1;
    if r.notify_promotions and r.email_verified and r.email is not null and r.email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' and v_q < 500 then
      insert into public.email_outbox (kind, to_email, payload, related_type)
      values ('generic', lower(r.email), jsonb_build_object('subject', trim(p_title), 'body', trim(p_body), 'coupon', v_code), 'campaign');
      v_q := v_q + 1;
    end if;
  end loop;
  insert into public.marketing_campaigns (name, segment, title, body, coupon_code, audience, sent, created_by, channel)
  values (trim(p_name), p_segment, trim(p_title), trim(p_body), v_code, v_aud, v_q, auth.uid(), 'email') returning id into v_id;
  perform public.audit_write('marketing.campaign_email', 'campaign', v_id::text, jsonb_build_object('segment', p_segment, 'audience', v_aud, 'queued', v_q, 'coupon', v_code));
  return jsonb_build_object('id', v_id, 'audience', v_aud, 'queued', v_q);
end $$;
revoke execute on function public.marketing_send_campaign_email(text,text,text,text,text) from public, anon;
grant execute on function public.marketing_send_campaign_email(text,text,text,text,text) to authenticated;
