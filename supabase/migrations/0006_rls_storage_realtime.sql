-- =====================================================================
-- My Hatō — 0006 Row Level Security, column privileges, function
-- privileges, storage buckets & policies, realtime publication.
-- =====================================================================

-- ---------- enable RLS on every table ----------
do $$
declare t text;
begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;

-- ---------- internal functions: not callable from the API ----------
revoke execute on function public.notify_user(uuid,text,text,text,text,text,uuid,text,text) from public, anon, authenticated;
revoke execute on function public.enqueue_email(public.email_kind,text,jsonb,text,uuid) from public, anon, authenticated;
revoke execute on function public._restock_order(uuid) from public, anon, authenticated;
revoke execute on function public._apply_order_status(public.orders, public.order_status, text) from public, anon, authenticated;
revoke execute on function public._apply_repair_status(public.repair_requests, public.repair_status, text, text) from public, anon, authenticated;
revoke execute on function public._decide_quote(uuid,text,text,text) from public, anon, authenticated;
revoke execute on function public._can_update_repair(public.repair_requests) from public, anon, authenticated;
revoke execute on function public.audit_write(text,text,text,jsonb) from public, anon, authenticated;
revoke execute on function public.next_order_reference() from public, anon, authenticated;
revoke execute on function public.next_repair_reference() from public, anon, authenticated;
revoke execute on function public.handle_new_user() from public, anon, authenticated;
revoke execute on function public.sync_profile_from_auth() from public, anon, authenticated;
-- customer/staff RPCs: authenticated only (anon cannot call)
revoke execute on function public.place_order(text, public.fulfillment_method, public.payment_method, uuid, uuid, text) from public, anon;
revoke execute on function public.request_repair(text,text,text,text,text,text,text,uuid,uuid,timestamptz,boolean) from public, anon;
revoke execute on function public.cart_set_item(uuid,uuid,int) from public, anon;
revoke execute on function public.cart_merge(jsonb) from public, anon;
revoke execute on function public.ensure_cart() from public, anon;
revoke execute on function public.get_cart() from public, anon;
revoke execute on function public.customer_cancel_order(uuid) from public, anon;
revoke execute on function public.customer_respond_to_quote(uuid,text) from public, anon;
revoke execute on function public.add_repair_attachment(uuid,text) from public, anon;
revoke execute on function public.request_account_deletion() from public, anon;
revoke execute on function public.staff_update_order_status(uuid, public.order_status, text) from public, anon;
revoke execute on function public.staff_adjust_stock(uuid,uuid,int,text,text) from public, anon;
revoke execute on function public.staff_update_repair_status(uuid, public.repair_status, text) from public, anon;
revoke execute on function public.staff_update_repair_details(uuid, jsonb) from public, anon;
revoke execute on function public.staff_assign_technician(uuid, uuid) from public, anon;
revoke execute on function public.staff_create_repair_quote(uuid, bigint, text, text) from public, anon;
revoke execute on function public.staff_record_quote_decision(uuid, text, text) from public, anon;
revoke execute on function public.staff_get_repair(uuid) from public, anon;
revoke execute on function public.staff_set_role(uuid, public.app_role, boolean) from public, anon;
revoke execute on function public.staff_dashboard_stats() from public, anon;

-- ---------- profiles ----------
create policy profiles_select on public.profiles for select to authenticated
  using (id = auth.uid() or public.has_permission('customers.view'));
create policy profiles_update_own on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());
-- column privileges: customers can only edit these fields (phone/phone_verified/email are synced from Auth)
revoke insert, update, delete on public.profiles from anon, authenticated;
grant update (full_name, avatar_path, preferred_locale, notify_orders, notify_repairs, notify_promotions) on public.profiles to authenticated;

-- ---------- addresses ----------
create policy addresses_own on public.customer_addresses for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy addresses_staff_read on public.customer_addresses for select to authenticated
  using (public.has_permission('customers.view'));

-- ---------- roles ----------
create policy user_roles_select on public.user_roles for select to authenticated
  using (user_id = auth.uid() or public.has_permission('staff.manage'));
revoke insert, update, delete on public.user_roles from anon, authenticated;   -- only via staff_set_role()
create policy role_permissions_select on public.role_permissions for select to authenticated using (true);
revoke insert, update, delete on public.role_permissions from anon, authenticated;

-- ---------- settings ----------
create policy settings_public_read on public.application_settings for select to anon, authenticated
  using (key in ('default_currency','default_delivery_fee_minor','free_delivery_threshold_minor',
                 'enabled_payment_methods','repair_requires_approval','supported_locales','used_devices_enabled') or public.is_staff());
create policy settings_manage on public.application_settings for update to authenticated
  using (public.has_permission('settings.manage')) with check (public.has_permission('settings.manage'));

-- ---------- audit ----------
create policy audit_read on public.audit_logs for select to authenticated using (public.has_permission('audit.view'));
revoke insert, update, delete on public.audit_logs from anon, authenticated;

-- ---------- catalog (public read of active/published) ----------
create policy categories_read on public.categories for select to anon, authenticated using (is_active or public.has_permission('products.manage'));
create policy categories_write on public.categories for all to authenticated
  using (public.has_permission('products.manage')) with check (public.has_permission('products.manage'));
create policy brands_read on public.brands for select to anon, authenticated using (is_active or public.has_permission('products.manage'));
create policy brands_write on public.brands for all to authenticated
  using (public.has_permission('products.manage')) with check (public.has_permission('products.manage'));

create policy products_read on public.products for select to anon, authenticated
  using (status = 'published' or public.has_permission('products.manage') or public.has_permission('orders.view'));
create policy products_insert on public.products for insert to authenticated with check (public.has_permission('products.manage'));
create policy products_update on public.products for update to authenticated
  using (public.has_permission('products.manage')) with check (public.has_permission('products.manage'));
-- no delete policy: products are archived, not deleted (order history keeps snapshots anyway)

create or replace function public.product_is_public(p_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.products where id = p_id and status = 'published')
$$;

create policy variants_read on public.product_variants for select to anon, authenticated
  using (public.product_is_public(product_id) or public.has_permission('products.manage'));
create policy variants_write on public.product_variants for all to authenticated
  using (public.has_permission('products.manage')) with check (public.has_permission('products.manage'));
create policy images_read on public.product_images for select to anon, authenticated
  using (public.product_is_public(product_id) or public.has_permission('products.manage'));
create policy images_write on public.product_images for all to authenticated
  using (public.has_permission('products.manage')) with check (public.has_permission('products.manage'));
create policy p360_read on public.product_360_assets for select to anon, authenticated
  using (public.product_is_public(product_id) or public.has_permission('products.manage'));
create policy p360_write on public.product_360_assets for all to authenticated
  using (public.has_permission('products.manage')) with check (public.has_permission('products.manage'));
create policy specs_read on public.product_specifications for select to anon, authenticated
  using (public.product_is_public(product_id) or public.has_permission('products.manage'));
create policy specs_write on public.product_specifications for all to authenticated
  using (public.has_permission('products.manage')) with check (public.has_permission('products.manage'));

create policy favorites_own on public.product_favorites for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy recently_viewed_own on public.recently_viewed for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy banners_read on public.banners for select to anon, authenticated
  using ((is_active and (starts_at is null or starts_at <= now()) and (ends_at is null or ends_at > now()))
         or public.has_permission('banners.manage'));
create policy banners_write on public.banners for all to authenticated
  using (public.has_permission('banners.manage')) with check (public.has_permission('banners.manage'));

create policy branches_read on public.branches for select to anon, authenticated using (is_active or public.is_staff());
create policy branches_write on public.branches for all to authenticated
  using (public.has_permission('settings.manage')) with check (public.has_permission('settings.manage'));
create policy zones_read on public.delivery_zones for select to anon, authenticated using (is_active or public.is_staff());
create policy zones_write on public.delivery_zones for all to authenticated
  using (public.has_permission('settings.manage')) with check (public.has_permission('settings.manage'));

-- ---------- cart (writes via RPC; reads own) ----------
create policy carts_own_read on public.carts for select to authenticated using (user_id = auth.uid());
create policy cart_items_own_read on public.cart_items for select to authenticated
  using (exists (select 1 from public.carts c where c.id = cart_id and c.user_id = auth.uid()));
revoke insert, update, delete on public.carts, public.cart_items from anon, authenticated;

-- ---------- orders (read own / staff; writes only via RPC) ----------
create policy orders_read on public.orders for select to authenticated
  using (customer_id = auth.uid() or public.has_permission('orders.view'));
revoke insert, update, delete on public.orders, public.order_items, public.order_status_history from anon, authenticated;
create policy order_items_read on public.order_items for select to authenticated
  using (exists (select 1 from public.orders o where o.id = order_id and (o.customer_id = auth.uid() or public.has_permission('orders.view'))));
create policy order_history_read on public.order_status_history for select to authenticated
  using (exists (select 1 from public.orders o where o.id = order_id and (o.customer_id = auth.uid() or public.has_permission('orders.view'))));
create policy order_transitions_read on public.order_transitions for select to authenticated using (true);
create policy inventory_read on public.inventory_movements for select to authenticated using (public.has_permission('inventory.manage'));
revoke insert, update, delete on public.inventory_movements, public.order_transitions from anon, authenticated;

-- ---------- repairs ----------
create policy repairs_read on public.repair_requests for select to authenticated
  using (customer_id = auth.uid()
         or public.has_permission('repairs.manage')
         or public.has_role('support')
         or (public.has_permission('repairs.update_assigned') and assigned_technician_id = auth.uid()));
revoke all on public.repair_requests from anon, authenticated;
-- internal_notes intentionally NOT granted: staff read it through staff_get_repair()
grant select (id, reference, customer_id, status, device_brand, device_model, imei_or_serial, problem_description,
              contact_name, contact_phone, pickup_address, branch_id, preferred_pickup_at, callback_requested,
              scheduled_pickup_at, received_at, diagnosis, customer_notes, estimated_cost_minor, approved_cost_minor,
              currency, expected_completion_at, warranty_terms, qc_result, assigned_technician_id, cancel_reason,
              created_at, updated_at) on public.repair_requests to authenticated;

create or replace function public.can_read_repair(p_repair_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.repair_requests r where r.id = p_repair_id and (
      r.customer_id = auth.uid() or public.has_permission('repairs.manage') or public.has_role('support')
      or (public.has_permission('repairs.update_assigned') and r.assigned_technician_id = auth.uid())))
$$;

create policy repair_history_read on public.repair_status_history for select to authenticated using (public.can_read_repair(repair_id));
create policy repair_quotes_read on public.repair_quotes for select to authenticated using (public.can_read_repair(repair_id));
create policy repair_approvals_read on public.repair_approvals for select to authenticated using (public.can_read_repair(repair_id));
create policy repair_attachments_read on public.repair_attachments for select to authenticated
  using (public.can_read_repair(repair_id) and (not is_internal or public.has_permission('repairs.view')));
create policy repair_assignments_read on public.repair_assignments for select to authenticated using (public.has_permission('repairs.view'));
create policy repair_parts_read on public.repair_parts for select to authenticated using (public.has_permission('repairs.view'));
create policy repair_parts_write on public.repair_parts for all to authenticated
  using (public.has_permission('repairs.manage')) with check (public.has_permission('repairs.manage'));
create policy repair_transitions_read on public.repair_transitions for select to anon, authenticated using (true);
create policy repair_labels_read on public.repair_status_labels for select to anon, authenticated using (true);
revoke insert, update, delete on public.repair_status_history, public.repair_quotes, public.repair_approvals,
  public.repair_attachments, public.repair_assignments, public.repair_transitions, public.repair_status_labels from anon, authenticated;
-- repair_lookup_challenges, rate_limits: RLS enabled with NO policies => service_role only
revoke all on public.repair_lookup_challenges, public.rate_limits from anon, authenticated;

-- ---------- notifications ----------
create policy notifications_own_read on public.notifications for select to authenticated
  using (user_id = auth.uid() or public.has_permission('customers.view'));
create policy notifications_own_mark_read on public.notifications for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
revoke insert, update, delete on public.notifications from anon, authenticated;
grant update (read_at) on public.notifications to authenticated;
create policy delivery_logs_staff on public.notification_delivery_logs for select to authenticated using (public.is_staff());
revoke insert, update, delete on public.notification_delivery_logs from anon, authenticated;

create policy outbox_staff_read on public.email_outbox for select to authenticated
  using (public.has_permission('orders.view') or public.has_permission('repairs.view'));
revoke insert, update, delete on public.email_outbox from anon, authenticated;

-- ---------- support ----------
create policy support_insert_own on public.customer_support_requests for insert to authenticated
  with check (user_id = auth.uid());
create policy support_read on public.customer_support_requests for select to authenticated
  using (user_id = auth.uid() or public.has_permission('support.manage'));
create policy support_update on public.customer_support_requests for update to authenticated
  using (public.has_permission('support.manage')) with check (public.has_permission('support.manage'));

create policy staff_assignments_manage on public.staff_assignments for all to authenticated
  using (public.has_permission('staff.manage')) with check (public.has_permission('staff.manage'));

-- =====================================================================
-- STORAGE
-- =====================================================================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('product-images', 'product-images', true,  5242880,  array['image/jpeg','image/png','image/webp']),
  ('product-360',    'product-360',    true,  3145728,  array['image/jpeg','image/png','image/webp']),
  ('banners',        'banners',        true,  5242880,  array['image/jpeg','image/png','image/webp']),
  ('avatars',        'avatars',        false, 2097152,  array['image/jpeg','image/png','image/webp']),
  ('repair-photos',  'repair-photos',  false, 8388608,  array['image/jpeg','image/png','image/webp','image/heic'])
on conflict (id) do nothing;

-- public catalog assets: anyone reads, products.manage writes
-- public buckets are served via public URLs; no broad SELECT policy (prevents bucket listing)
create policy "catalog assets write" on storage.objects for insert to authenticated
  with check (bucket_id in ('product-images','product-360') and public.has_permission('products.manage')
              or bucket_id = 'banners' and public.has_permission('banners.manage'));
create policy "catalog assets update" on storage.objects for update to authenticated
  using (bucket_id in ('product-images','product-360') and public.has_permission('products.manage')
         or bucket_id = 'banners' and public.has_permission('banners.manage'));
create policy "catalog assets delete" on storage.objects for delete to authenticated
  using (bucket_id in ('product-images','product-360') and public.has_permission('products.manage')
         or bucket_id = 'banners' and public.has_permission('banners.manage'));

-- avatars: avatars/{uid}/file
create policy "avatars own rw" on storage.objects for all to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

-- repair photos: repair-photos/{customer_uid}/{repair_id}/file  (private, signed URLs only)
create policy "repair photos customer upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'repair-photos'
              and (storage.foldername(name))[1] = auth.uid()::text
              and exists (select 1 from public.repair_requests r
                           where r.id::text = (storage.foldername(name))[2] and r.customer_id = auth.uid()));
create policy "repair photos staff upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'repair-photos' and public.can_read_repair(((storage.foldername(name))[2])::uuid)
              and public.has_permission('repairs.update_assigned'));
create policy "repair photos read" on storage.objects for select to authenticated
  using (bucket_id = 'repair-photos'
         and exists (select 1 from public.repair_attachments a
                      where a.storage_path = name and public.can_read_repair(a.repair_id)
                        and (not a.is_internal or public.has_permission('repairs.view')))
         or bucket_id = 'repair-photos' and (storage.foldername(name))[1] = auth.uid()::text);

-- =====================================================================
-- REALTIME (only tables without sensitive columns; RLS applies to postgres_changes)
-- repair_requests/orders themselves are not published; clients refetch on history events.
-- =====================================================================
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.notifications, public.order_status_history,
      public.repair_status_history, public.repair_quotes;
  end if;
end $$;
