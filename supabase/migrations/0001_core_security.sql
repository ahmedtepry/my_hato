-- =====================================================================
-- My Hatō — 0001 core: extensions, enums, roles/permissions, profiles
-- All money is stored as integer piasters (1 EGP = 100 piasters) in
-- *_minor columns. Never use floats for money. Timestamps are UTC.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;
create extension if not exists pg_trgm with schema extensions;

-- ---------- enums ----------
create type public.app_role as enum ('owner', 'manager', 'sales', 'technician', 'support');

create type public.fulfillment_method as enum ('pickup', 'delivery');
create type public.payment_method as enum ('cash_on_delivery', 'pay_at_branch');
create type public.payment_status as enum ('unpaid', 'paid', 'refunded');

create type public.order_status as enum (
  'pending_confirmation', 'confirmed', 'preparing', 'ready_for_pickup',
  'out_for_delivery', 'delivered', 'cancelled'
);

create type public.repair_status as enum (
  'pickup_requested', 'pickup_scheduled', 'device_collected', 'received_at_branch',
  'initial_inspection', 'diagnosis_completed', 'awaiting_approval', 'repair_approved',
  'repair_in_progress', 'waiting_for_parts', 'quality_testing', 'repair_completed',
  'ready_for_pickup', 'out_for_delivery', 'delivered', 'cancelled', 'unrepairable'
);

create type public.quote_status as enum ('pending', 'approved', 'rejected', 'superseded');
create type public.email_kind as enum ('order_new', 'repair_new', 'repair_customer_response', 'generic');
create type public.email_status as enum ('queued', 'sending', 'sent', 'failed');

-- ---------- generic helpers ----------
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

-- ---------- staff roles & permissions ----------
create table public.role_permissions (
  role public.app_role not null,
  permission text not null,
  primary key (role, permission)
);

create table public.user_roles (
  user_id uuid not null references auth.users(id) on delete cascade,
  role public.app_role not null,
  granted_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  primary key (user_id, role)
);
create index user_roles_user_idx on public.user_roles(user_id);

-- Permission matrix (enforced server side by has_permission()).
insert into public.role_permissions(role, permission) values
  -- owner: everything
  ('owner','products.manage'),('owner','inventory.manage'),('owner','orders.view'),('owner','orders.manage'),
  ('owner','repairs.view'),('owner','repairs.manage'),('owner','repairs.update_assigned'),
  ('owner','customers.view'),('owner','staff.manage'),('owner','settings.manage'),
  ('owner','audit.view'),('owner','banners.manage'),('owner','support.manage'),
  -- manager: everything except staff/settings
  ('manager','products.manage'),('manager','inventory.manage'),('manager','orders.view'),('manager','orders.manage'),
  ('manager','repairs.view'),('manager','repairs.manage'),('manager','repairs.update_assigned'),
  ('manager','customers.view'),('manager','audit.view'),('manager','banners.manage'),('manager','support.manage'),
  -- sales
  ('sales','products.manage'),('sales','inventory.manage'),('sales','orders.view'),('sales','orders.manage'),
  ('sales','customers.view'),('sales','banners.manage'),
  -- technician: only assigned repairs
  ('technician','repairs.view'),('technician','repairs.update_assigned'),
  -- read-only support
  ('support','orders.view'),('support','repairs.view'),('support','customers.view'),('support','support.manage');

-- SECURITY DEFINER so RLS on these tables cannot recurse; search_path pinned.
create or replace function public.has_role(p_role public.app_role)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.user_roles where user_id = auth.uid() and role = p_role)
$$;

create or replace function public.has_permission(p_permission text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.user_roles ur
    join public.role_permissions rp on rp.role = ur.role
    where ur.user_id = auth.uid() and rp.permission = p_permission
  )
$$;

create or replace function public.is_staff()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.user_roles where user_id = auth.uid())
$$;

-- ---------- customer profiles ----------
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text,
  phone text,
  phone_verified boolean not null default false,
  email text,
  avatar_path text,
  preferred_locale text not null default 'ar' check (preferred_locale in ('ar','en')),
  notify_orders boolean not null default true,
  notify_repairs boolean not null default true,
  notify_promotions boolean not null default false,
  deletion_requested_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger profiles_updated before update on public.profiles
  for each row execute function public.set_updated_at();

-- Create a profile row for every new auth user. NEVER grants roles.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name, phone, phone_verified, email)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name'),
    nullif(new.phone, ''),
    new.phone_confirmed_at is not null,
    nullif(new.email, '')
  )
  on conflict (id) do nothing;
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Keep phone verification in sync with Supabase Auth (server-controlled; clients cannot write it).
create or replace function public.sync_profile_from_auth()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.profiles
     set phone = coalesce(nullif(new.phone, ''), phone),
         phone_verified = (new.phone_confirmed_at is not null),
         email = coalesce(nullif(new.email, ''), email)
   where id = new.id;
  return new;
end $$;

create trigger on_auth_user_updated
  after update of phone, phone_confirmed_at, email on auth.users
  for each row execute function public.sync_profile_from_auth();

create table public.customer_addresses (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  label text,
  recipient_name text not null,
  phone text not null,
  governorate text not null,
  city text not null,
  street text not null,
  building text,
  landmark text,
  is_default boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index customer_addresses_user_idx on public.customer_addresses(user_id);
create unique index customer_addresses_one_default on public.customer_addresses(user_id) where is_default;
create trigger customer_addresses_updated before update on public.customer_addresses
  for each row execute function public.set_updated_at();

-- ---------- application settings ----------
create table public.application_settings (
  key text primary key,
  value jsonb not null,
  description text,
  updated_by uuid references auth.users(id),
  updated_at timestamptz not null default now()
);

insert into public.application_settings(key, value, description) values
  ('orders_notification_email', '"myhatosales@gmail.com"', 'Recipient of new-order emails'),
  ('repair_notification_email', '"myhatoservice@gmail.com"', 'Recipient of repair-service emails (new pickup requests, customer quote responses)'),
  ('default_currency', '"EGP"', 'Currency code'),
  ('default_delivery_fee_minor', '5000', 'Fallback delivery fee in piasters (50.00 EGP)'),
  ('free_delivery_threshold_minor', '0', '0 = disabled'),
  ('repair_requires_approval', 'true', 'Chargeable repairs need explicit customer approval'),
  ('enabled_payment_methods', '["cash_on_delivery","pay_at_branch"]', 'Online card payment is NOT enabled'),
  ('low_stock_threshold', '5', 'Dashboard low-stock threshold'),
  ('supported_locales', '["ar","en"]', 'App and dashboard languages'),
  ('used_devices_enabled', 'false', 'false = the "Used / مستعمل" tab shows a Coming Soon page; true = it lists products from categories of kind used');

-- ---------- audit log (append-only) ----------
create table public.audit_logs (
  id bigint generated always as identity primary key,
  actor_id uuid references auth.users(id),
  action text not null,
  entity_type text not null,
  entity_id text,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index audit_logs_entity_idx on public.audit_logs(entity_type, entity_id);
create index audit_logs_created_idx on public.audit_logs(created_at desc);

create or replace function public.audit_write(p_action text, p_entity_type text, p_entity_id text, p_details jsonb default '{}')
returns void language sql security definer set search_path = public as $$
  insert into public.audit_logs(actor_id, action, entity_type, entity_id, details)
  values (auth.uid(), p_action, p_entity_type, p_entity_id, coalesce(p_details, '{}'::jsonb));
$$;

-- append-only enforcement, even for privileged roles reaching it via the API
create or replace function public.audit_logs_immutable()
returns trigger language plpgsql as $$
begin
  raise exception 'audit_logs is append-only';
end $$;
create trigger audit_logs_no_update before update or delete on public.audit_logs
  for each row execute function public.audit_logs_immutable();
