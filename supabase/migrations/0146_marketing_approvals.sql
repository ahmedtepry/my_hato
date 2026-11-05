-- 0146: nothing the marketing team proposes goes live without the owner.
--  * marketing.request (propose) and marketing.approve (decide, owner only)
--  * (the marketing role's direct-publish grants are removed separately, 0147, after the owner confirms the delete)
--  * marketing_requests: banner / coupon / campaign / idea; the owner gets a notification; approving applies it, rejecting closes it
--  * proposal pictures go to banners/proposals/ and only become a banner when the owner approves

insert into public.permission_catalog (permission, grp, name_ar, name_en, desc_ar, desc_en, sensitive, inert, sort) values
 ('marketing.request', 'marketing', 'يقترح أفكار للمالك (بانر / كود / حملة / فكرة)', 'Propose ideas to the owner (banner / code / campaign / idea)', 'مفيش حاجة بتتفعّل غير بعد موافقة المالك', 'Nothing goes live without the owner''s approval', false, false, 64),
 ('marketing.approve', 'marketing', 'يوافق على أفكار التسويق ويفعّلها', 'Approve and activate marketing ideas', 'المالك بس', 'Owner only', true, false, 65)
on conflict (permission) do update set name_ar = excluded.name_ar, name_en = excluded.name_en, desc_ar = excluded.desc_ar, desc_en = excluded.desc_en, sensitive = excluded.sensitive;

insert into public.role_permissions (role, permission) values
 ('owner','marketing.request'),('owner','marketing.approve'),('marketing','marketing.request'),('manager','marketing.request')
on conflict do nothing;

-- pictures for proposals (public bucket, own folder; they only appear in the app once a banner row points at them)
create policy marketing_proposal_images on storage.objects for insert to authenticated
  with check (bucket_id = 'banners' and (storage.foldername(name))[1] = 'proposals' and public.has_permission('marketing.request'));

create table if not exists public.marketing_requests (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('banner','coupon','campaign','idea')),
  title text not null,
  details jsonb not null default '{}'::jsonb,
  status text not null default 'pending' check (status in ('pending','approved','rejected','cancelled')),
  requested_by uuid not null references auth.users(id),
  requested_at timestamptz not null default now(),
  decided_by uuid references auth.users(id),
  decided_at timestamptz,
  decision_note text,
  result jsonb
);
create index if not exists marketing_requests_status_idx on public.marketing_requests(status, requested_at desc);
alter table public.marketing_requests enable row level security;
revoke all on public.marketing_requests from anon, authenticated;

create or replace function public.marketing_request_create(p_kind text, p_title text, p_details jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid; d jsonb := coalesce(p_details, '{}'::jsonb); v_name text; v_kind_ar text;
begin
  perform public.require_permission('marketing.request');
  if p_kind not in ('banner','coupon','campaign','idea') or nullif(trim(p_title), '') is null or length(p_title) > 120 or length(d::text) > 6000 then raise exception 'INVALID_INPUT'; end if;
  if p_kind = 'banner' and (nullif(d->>'image_path','') is null or (d->>'image_path') not like 'proposals/%' or nullif(d->>'title_ar','') is null) then raise exception 'INVALID_INPUT'; end if;
  if p_kind = 'banner' and coalesce(d->>'link_type','') not in ('','product','category','repair','url') then raise exception 'INVALID_INPUT'; end if;
  if p_kind = 'coupon' and ((d->>'code') !~ '^[A-Za-z0-9_-]{3,24}$' or ((d->>'percent_off') is null) = ((d->>'amount_off_minor') is null)) then raise exception 'INVALID_INPUT'; end if;
  if p_kind = 'campaign' and (nullif(d->>'segment','') is null or nullif(d->>'title','') is null or nullif(d->>'body','') is null or nullif(d->>'name','') is null) then raise exception 'INVALID_INPUT'; end if;
  if p_kind = 'idea' and nullif(trim(d->>'text'), '') is null then raise exception 'INVALID_INPUT'; end if;
  if (select count(*) from public.marketing_requests where requested_by = auth.uid() and status = 'pending') >= 20 then raise exception 'RATE_LIMITED'; end if;
  insert into public.marketing_requests (kind, title, details, requested_by) values (p_kind, trim(p_title), d, auth.uid()) returning id into v_id;
  select coalesce(nullif(full_name, ''), 'التسويق') into v_name from public.profiles where id = auth.uid();
  v_kind_ar := case p_kind when 'banner' then 'بانر' when 'coupon' then 'كود خصم' when 'campaign' then 'حملة' else 'فكرة' end;
  perform public._notify_staff('marketing.approve', '📣 طلب تسويق: ' || v_kind_ar, '📣 Marketing request',
    v_name || ' عايز ' || v_kind_ar || ': ' || trim(p_title) || ' (محتاج موافقتك)', v_name || ' proposes: ' || trim(p_title) || ' (needs your approval)', v_id::text);
  perform public.audit_write('marketing.request', 'marketing_request', v_id::text, jsonb_build_object('kind', p_kind, 'title', p_title));
  return v_id;
end $$;

create or replace function public.marketing_requests_list() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_all boolean := public.has_permission('marketing.approve');
begin
  if not (v_all or public.has_permission('marketing.request')) then raise exception 'FORBIDDEN'; end if;
  return coalesce((select jsonb_agg(x order by (x->>'sort') , (x->>'requested_at') desc) from (
    select jsonb_build_object('id', r.id, 'kind', r.kind, 'title', r.title, 'details', r.details, 'status', r.status, 'requested_at', r.requested_at,
             'requester', coalesce(nullif(p.full_name, ''), '—'), 'decided_at', r.decided_at, 'note', r.decision_note, 'result', r.result,
             'mine', r.requested_by = auth.uid(), 'sort', case when r.status = 'pending' then '0' else '1' end) x
      from public.marketing_requests r left join public.profiles p on p.id = r.requested_by
     where v_all or r.requested_by = auth.uid()
     order by (r.status = 'pending') desc, r.requested_at desc limit 60) s), '[]'::jsonb);
end $$;

create or replace function public.marketing_request_cancel(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.require_permission('marketing.request');
  update public.marketing_requests set status = 'cancelled', decided_at = now() where id = p_id and requested_by = auth.uid() and status = 'pending';
end $$;

create or replace function public.marketing_request_decide(p_id uuid, p_approve boolean, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r public.marketing_requests; d jsonb; v_res jsonb := '{}'::jsonb; v_bid uuid; v_msg text;
begin
  perform public.require_permission('marketing.approve');
  select * into r from public.marketing_requests where id = p_id for update;
  if r.id is null then raise exception 'NOT_FOUND'; end if;
  if r.status <> 'pending' then raise exception 'ALREADY_DECIDED'; end if;
  d := r.details;
  if p_approve then
    if r.kind = 'banner' then
      insert into public.banners (title_ar, title_en, image_path, link_type, link_value, sort_order, is_active, starts_at, ends_at)
      values (d->>'title_ar', coalesce(nullif(d->>'title_en',''), d->>'title_ar'), d->>'image_path', nullif(d->>'link_type',''), nullif(d->>'link_value',''),
              coalesce((select min(sort_order) - 1 from public.banners), 0), true,
              nullif(d->>'starts_at','')::timestamptz, nullif(d->>'ends_at','')::timestamptz) returning id into v_bid;
      v_res := jsonb_build_object('banner_id', v_bid);
    elsif r.kind = 'coupon' then
      insert into public.coupons (code, title_ar, percent_off, amount_off_minor, min_order_minor, max_uses, ends_at, created_by)
      values (upper(d->>'code'), nullif(d->>'title_ar',''), nullif(d->>'percent_off','')::int, nullif(d->>'amount_off_minor','')::bigint,
              coalesce(nullif(d->>'min_order_minor','')::bigint, 0), nullif(d->>'max_uses','')::int, nullif(d->>'ends_at','')::timestamptz, r.requested_by);
      v_res := jsonb_build_object('code', upper(d->>'code'));
    elsif r.kind = 'campaign' then
      v_res := public.marketing_send_campaign(d->>'name', d->>'segment', d->>'title', d->>'body', nullif(d->>'coupon_code',''));
    end if;
  end if;
  update public.marketing_requests set status = case when p_approve then 'approved' else 'rejected' end, decided_by = auth.uid(), decided_at = now(),
         decision_note = nullif(trim(coalesce(p_note, '')), ''), result = v_res where id = p_id;
  v_msg := case when p_approve then (case r.kind when 'idea' then 'اتوافق على فكرتك وهتتنفذ' else 'اتوافق عليه واتفعّل' end) else 'اترفض' end;
  perform public.notify_user(r.requested_by, case when p_approve then '✅ ' else '❌ ' end || r.title, r.title, r.title || ' — ' || v_msg || coalesce(' · ' || nullif(trim(coalesce(p_note, '')), ''), ''),
                             r.title || ' — ' || case when p_approve then 'approved' else 'rejected' end, 'system', null, p_id::text, '/hato-console');
  perform public.audit_write('marketing.decide', 'marketing_request', p_id::text, jsonb_build_object('approve', p_approve, 'kind', r.kind));
  return jsonb_build_object('status', case when p_approve then 'approved' else 'rejected' end, 'result', v_res);
end $$;

do $$ declare f text; begin
  foreach f in array array['marketing_request_create(text,text,jsonb)','marketing_requests_list()','marketing_request_cancel(uuid)','marketing_request_decide(uuid,boolean,text)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
