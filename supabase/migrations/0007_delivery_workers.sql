-- =====================================================================
-- My Hatō — 0007 device tokens + worker helpers used by Edge Functions
-- (service_role only)
-- =====================================================================

create table public.device_tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  token text not null unique,
  platform text not null check (platform in ('android','ios','web')),
  locale text not null default 'ar' check (locale in ('ar','en')),
  updated_at timestamptz not null default now()
);
create index device_tokens_user_idx on public.device_tokens(user_id);
alter table public.device_tokens enable row level security;
create policy device_tokens_own on public.device_tokens for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Claim a batch of due emails atomically (SKIP LOCKED => safe with parallel workers)
create or replace function public.claim_email_batch(p_limit int default 20)
returns setof public.email_outbox language sql security definer set search_path = public as $$
  update public.email_outbox e set status = 'sending', attempts = e.attempts + 1
   where e.id in (select id from public.email_outbox
                   where status in ('queued','failed') and attempts < 8 and next_attempt_at <= now()
                   order by created_at for update skip locked limit p_limit)
  returning e.*;
$$;

create or replace function public.complete_email(p_id uuid, p_ok boolean, p_provider_id text, p_error text)
returns void language sql security definer set search_path = public as $$
  update public.email_outbox set
    status = case when p_ok then 'sent'::public.email_status else 'failed'::public.email_status end,
    sent_at = case when p_ok then now() end,
    provider_message_id = p_provider_id,
    last_error = left(p_error, 500),
    -- exponential backoff: 1, 2, 4, 8 ... minutes
    next_attempt_at = case when p_ok then next_attempt_at else now() + (power(2, least(attempts, 10)) || ' minutes')::interval end
  where id = p_id;
$$;

-- Reset rows stuck in 'sending' (worker crashed) back to failed so they retry
create or replace function public.requeue_stuck_emails()
returns int language sql security definer set search_path = public as $$
  with x as (update public.email_outbox set status = 'failed', last_error = 'worker timeout'
              where status = 'sending' and next_attempt_at < now() - interval '10 minutes' returning 1)
  select count(*)::int from x;
$$;

-- Full data needed to render emails
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
  end if;
  return v;
end $$;

-- Queued push deliveries with the recipient tokens
create or replace function public.claim_push_batch(p_limit int default 50)
returns table (log_id bigint, notification_id uuid, user_id uuid, title_ar text, title_en text, body_ar text, body_en text,
               deep_link text, tokens jsonb)
language sql security definer set search_path = public as $$
  with c as (
    update public.notification_delivery_logs l set status = 'sent'
     where l.id in (select id from public.notification_delivery_logs
                     where channel = 'push' and status = 'queued' order by id for update skip locked limit p_limit)
    returning l.id, l.notification_id)
  select c.id, n.id, n.user_id, n.title_ar, n.title_en, n.body_ar, n.body_en, n.deep_link,
         coalesce((select jsonb_agg(jsonb_build_object('token', d.token, 'locale', d.locale)) from public.device_tokens d where d.user_id = n.user_id), '[]')
    from c join public.notifications n on n.id = c.notification_id;
$$;

create or replace function public.complete_push(p_log_id bigint, p_status text, p_error text)
returns void language sql security definer set search_path = public as $$
  update public.notification_delivery_logs set status = p_status, error = left(p_error, 500) where id = p_log_id;
$$;

create or replace function public.repair_contact_for_lookup(p_reference text)
returns table (repair_id uuid, contact_phone text, verified_phone text)
language sql stable security definer set search_path = public as $$
  select r.id, r.contact_phone, p.phone
    from public.repair_requests r join public.profiles p on p.id = r.customer_id
   where r.reference = upper(trim(p_reference)) and p.phone_verified
$$;

revoke execute on function public.claim_email_batch(int) from public, anon, authenticated;
revoke execute on function public.complete_email(uuid, boolean, text, text) from public, anon, authenticated;
revoke execute on function public.requeue_stuck_emails() from public, anon, authenticated;
revoke execute on function public.email_render_data(public.email_kind, jsonb) from public, anon, authenticated;
revoke execute on function public.claim_push_batch(int) from public, anon, authenticated;
revoke execute on function public.complete_push(bigint, text, text) from public, anon, authenticated;
revoke execute on function public.repair_contact_for_lookup(text) from public, anon, authenticated;
grant execute on function public.claim_email_batch(int), public.complete_email(uuid, boolean, text, text),
  public.requeue_stuck_emails(), public.email_render_data(public.email_kind, jsonb), public.claim_push_batch(int),
  public.complete_push(bigint, text, text), public.repair_contact_for_lookup(text),
  public.guest_repair_public_view(text), public.hit_rate_limit(text, text, int, int) to service_role;

-- ---------------------------------------------------------------------
-- Scheduling (run once in the Supabase SQL editor after deploying functions;
-- requires pg_cron + pg_net extensions enabled in the dashboard):
--
-- select cron.schedule('myhato-email-outbox', '* * * * *', $$
--   select net.http_post(
--     url := 'https://<PROJECT_REF>.supabase.co/functions/v1/process-email-outbox',
--     headers := jsonb_build_object('Content-Type','application/json','x-cron-secret', '<CRON_SECRET>'),
--     body := '{}'::jsonb) $$);
-- select cron.schedule('myhato-push', '* * * * *', $$
--   select net.http_post(
--     url := 'https://<PROJECT_REF>.supabase.co/functions/v1/send-customer-notification',
--     headers := jsonb_build_object('Content-Type','application/json','x-cron-secret', '<CRON_SECRET>'),
--     body := '{}'::jsonb) $$);
-- ---------------------------------------------------------------------
