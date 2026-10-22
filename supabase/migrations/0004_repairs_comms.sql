-- =====================================================================
-- My Hatō — 0004 repairs, notifications, email outbox, support
-- Repair emails go to myhatoservice@gmail.com (application_settings.repair_notification_email)
-- Order emails go to myhatosales@gmail.com   (application_settings.orders_notification_email)
-- =====================================================================

create sequence public.repair_ref_seq start 75;

create table public.repair_requests (
  id uuid primary key default gen_random_uuid(),
  reference text not null unique,               -- e.g. MY-HATO75 (server generated)
  customer_id uuid not null references auth.users(id),
  idempotency_key text not null,
  status public.repair_status not null default 'pickup_requested',
  device_brand text not null,
  device_model text not null,
  imei_or_serial text,                          -- private, staff only via RLS on this table + views
  problem_description text not null check (char_length(problem_description) between 5 and 2000),
  contact_name text not null,
  contact_phone text not null,
  pickup_address jsonb,                         -- null when customer drops off at branch
  branch_id uuid references public.branches(id),
  preferred_pickup_at timestamptz,
  callback_requested boolean not null default false,
  scheduled_pickup_at timestamptz,
  received_at timestamptz,
  diagnosis text,
  customer_notes text,                          -- visible to customer
  internal_notes text,                          -- NEVER exposed to customers (column privilege revoked below)
  estimated_cost_minor bigint check (estimated_cost_minor is null or estimated_cost_minor >= 0),
  approved_cost_minor bigint check (approved_cost_minor is null or approved_cost_minor >= 0),
  currency char(3) not null default 'EGP',
  expected_completion_at timestamptz,
  warranty_terms text,
  qc_result text,
  assigned_technician_id uuid references auth.users(id),
  cancel_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (customer_id, idempotency_key)
);
create index repair_requests_customer_idx on public.repair_requests(customer_id, created_at desc);
create index repair_requests_status_idx on public.repair_requests(status, updated_at desc);
create index repair_requests_tech_idx on public.repair_requests(assigned_technician_id);
create trigger repair_requests_updated before update on public.repair_requests
  for each row execute function public.set_updated_at();

create table public.repair_status_history (
  id bigint generated always as identity primary key,
  repair_id uuid not null references public.repair_requests(id) on delete cascade,
  from_status public.repair_status,
  to_status public.repair_status not null,
  customer_message_ar text,
  customer_message_en text,
  changed_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);
create index repair_status_history_repair_idx on public.repair_status_history(repair_id, created_at);

create table public.repair_transitions (
  from_status public.repair_status not null,
  to_status public.repair_status not null,
  primary key (from_status, to_status)
);
insert into public.repair_transitions(from_status, to_status) values
  ('pickup_requested','pickup_scheduled'),('pickup_requested','received_at_branch'),('pickup_requested','cancelled'),
  ('pickup_scheduled','device_collected'),('pickup_scheduled','cancelled'),
  ('device_collected','received_at_branch'),
  ('received_at_branch','initial_inspection'),
  ('initial_inspection','diagnosis_completed'),('initial_inspection','unrepairable'),
  ('diagnosis_completed','awaiting_approval'),('diagnosis_completed','repair_in_progress'),('diagnosis_completed','unrepairable'),
  ('awaiting_approval','repair_approved'),('awaiting_approval','cancelled'),('awaiting_approval','diagnosis_completed'),
  ('repair_approved','repair_in_progress'),('repair_approved','waiting_for_parts'),
  ('repair_in_progress','waiting_for_parts'),('repair_in_progress','quality_testing'),('repair_in_progress','awaiting_approval'),
  ('waiting_for_parts','repair_in_progress'),('waiting_for_parts','awaiting_approval'),
  ('quality_testing','repair_completed'),('quality_testing','repair_in_progress'),
  ('repair_completed','ready_for_pickup'),('repair_completed','out_for_delivery'),
  ('ready_for_pickup','delivered'),
  ('out_for_delivery','delivered'),
  ('unrepairable','ready_for_pickup'),('unrepairable','out_for_delivery'),
  ('cancelled','ready_for_pickup'),('cancelled','out_for_delivery');
-- (cancelled/unrepairable -> return device to customer)

-- Customer-facing bilingual descriptions per status
create table public.repair_status_labels (
  status public.repair_status primary key,
  label_ar text not null,
  label_en text not null,
  message_ar text not null,
  message_en text not null,
  sort_order int not null
);
insert into public.repair_status_labels values
  ('pickup_requested','تم طلب الاستلام','Pickup requested','تم استلام طلبك وسيتم التواصل معك لتحديد موعد الاستلام.','We received your request and will contact you to schedule pickup.',1),
  ('pickup_scheduled','تم تحديد موعد الاستلام','Pickup scheduled','تم تحديد موعد استلام جهازك.','Your device pickup has been scheduled.',2),
  ('device_collected','تم استلام الجهاز من المندوب','Device collected','المندوب استلم جهازك وفي الطريق للفرع.','Our courier collected your device and is heading to the branch.',3),
  ('received_at_branch','تم استلام الجهاز','Device received','تم استلام جهازك في الفرع.','Your device has arrived at the branch.',4),
  ('initial_inspection','الجهاز تحت الفحص','Under inspection','تم استلام جهازك وهو الآن تحت الفحص.','Your device is now being inspected.',5),
  ('diagnosis_completed','تم تحديد العطل','Diagnosis completed','تم تحديد العطل.','The fault has been diagnosed.',6),
  ('awaiting_approval','في انتظار موافقتك على التكلفة','Awaiting your approval','في انتظار موافقتك على التكلفة. برجاء مراجعة التفاصيل والموافقة.','Waiting for your approval of the cost. Please review and approve.',7),
  ('repair_approved','تمت الموافقة على الصيانة','Repair approved','تم تسجيل موافقتك على تكلفة الصيانة.','Your approval of the repair cost has been recorded.',8),
  ('repair_in_progress','الجهاز تحت التصليح','Repair in progress','جهازك تحت التصليح حاليًا.','Your device is being repaired.',9),
  ('waiting_for_parts','في انتظار قطع الغيار','Waiting for parts','في انتظار وصول قطع الغيار.','Waiting for spare parts to arrive.',10),
  ('quality_testing','اختبار الجودة','Quality testing','الجهاز في مرحلة اختبار الجودة.','Your device is in quality testing.',11),
  ('repair_completed','تم الإصلاح','Repair completed','تم الانتهاء من إصلاح جهازك.','Your device repair is complete.',12),
  ('ready_for_pickup','جاهز للاستلام','Ready for pickup','جهازك جاهز للاستلام.','Your device is ready for pickup.',13),
  ('out_for_delivery','في الطريق إليك','Out for delivery','جهازك في الطريق إليك.','Your device is out for delivery.',14),
  ('delivered','تم التسليم','Delivered','تم تسليم الجهاز.','Your device has been delivered.',15),
  ('cancelled','ملغي','Cancelled','تم إلغاء طلب الصيانة.','The repair request was cancelled.',16),
  ('unrepairable','غير قابل للإصلاح','Unrepairable','للأسف الجهاز غير قابل للإصلاح.','Unfortunately the device cannot be repaired.',17);

create table public.repair_quotes (
  id uuid primary key default gen_random_uuid(),
  repair_id uuid not null references public.repair_requests(id) on delete cascade,
  amount_minor bigint not null check (amount_minor >= 0),
  currency char(3) not null default 'EGP',
  description text,
  status public.quote_status not null default 'pending',
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);
create index repair_quotes_repair_idx on public.repair_quotes(repair_id, created_at desc);
create unique index repair_quotes_one_pending on public.repair_quotes(repair_id) where status = 'pending';

create table public.repair_approvals (
  id uuid primary key default gen_random_uuid(),
  repair_id uuid not null references public.repair_requests(id) on delete cascade,
  quote_id uuid not null references public.repair_quotes(id),
  decision text not null check (decision in ('approved','rejected')),
  quoted_amount_minor bigint not null,
  decided_by uuid not null references auth.users(id),
  via text not null check (via in ('customer_app','staff_recorded')),
  staff_note text,                              -- required when via = staff_recorded (phone approval)
  created_at timestamptz not null default now(),
  unique (quote_id),
  check (via = 'customer_app' or staff_note is not null)
);

create table public.repair_attachments (
  id uuid primary key default gen_random_uuid(),
  repair_id uuid not null references public.repair_requests(id) on delete cascade,
  storage_path text not null,                   -- private bucket repair-photos/{customer_id}/{repair_id}/...
  uploaded_by uuid references auth.users(id),
  is_internal boolean not null default false,
  created_at timestamptz not null default now()
);
create index repair_attachments_repair_idx on public.repair_attachments(repair_id);

create table public.repair_assignments (
  id bigint generated always as identity primary key,
  repair_id uuid not null references public.repair_requests(id) on delete cascade,
  technician_id uuid not null references auth.users(id),
  assigned_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);

create table public.repair_parts (
  id uuid primary key default gen_random_uuid(),
  repair_id uuid not null references public.repair_requests(id) on delete cascade,
  part_name text not null,
  cost_minor bigint not null default 0 check (cost_minor >= 0),
  status text not null default 'ordered' check (status in ('ordered','received','installed')),
  created_at timestamptz not null default now()
);

-- guest lookup verification challenges (codes are hashed, never stored in clear)
create table public.repair_lookup_challenges (
  id uuid primary key default gen_random_uuid(),
  repair_id uuid not null references public.repair_requests(id) on delete cascade,
  code_hash text not null,
  attempts int not null default 0,
  expires_at timestamptz not null,
  consumed_at timestamptz,
  requester_ip_hash text,
  created_at timestamptz not null default now()
);
create index repair_lookup_challenges_repair_idx on public.repair_lookup_challenges(repair_id, created_at desc);

-- ---------- notifications ----------
create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  title_ar text not null,
  title_en text not null,
  body_ar text not null,
  body_en text not null,
  entity_type text check (entity_type in ('order','repair','promo','system')),
  entity_id uuid,
  entity_reference text,
  deep_link text,
  read_at timestamptz,
  created_at timestamptz not null default now()
);
create index notifications_user_idx on public.notifications(user_id, created_at desc);

create table public.notification_delivery_logs (
  id bigint generated always as identity primary key,
  notification_id uuid references public.notifications(id) on delete cascade,
  channel text not null check (channel in ('in_app','push','sms','email')),
  status text not null check (status in ('queued','sent','delivered','failed','skipped_not_configured')),
  provider_message_id text,
  error text,
  created_at timestamptz not null default now()
);

create table public.email_outbox (
  id uuid primary key default gen_random_uuid(),
  kind public.email_kind not null,
  to_email text not null,
  payload jsonb not null,                        -- rendered into subject/html by the send-email Edge Function
  related_type text,
  related_id uuid,
  status public.email_status not null default 'queued',
  attempts int not null default 0,
  last_error text,
  next_attempt_at timestamptz not null default now(),
  sent_at timestamptz,
  provider_message_id text,
  created_at timestamptz not null default now(),
  unique (kind, related_id)                      -- never two "new order"/"new repair" mails for the same record
);
create index email_outbox_due_idx on public.email_outbox(status, next_attempt_at);

create table public.customer_support_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete set null,
  subject text not null check (char_length(subject) between 3 and 200),
  message text not null check (char_length(message) between 5 and 4000),
  contact_phone text,
  status text not null default 'open' check (status in ('open','in_progress','closed')),
  created_at timestamptz not null default now()
);

create table public.staff_assignments (
  id bigint generated always as identity primary key,
  staff_id uuid not null references auth.users(id) on delete cascade,
  branch_id uuid references public.branches(id),
  created_at timestamptz not null default now()
);

create table public.rate_limits (
  bucket text not null,
  key_hash text not null,
  window_start timestamptz not null,
  count int not null default 0,
  primary key (bucket, key_hash, window_start)
);
