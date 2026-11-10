-- Drop-off at a branch: the customer no longer picks a branch; the team calls to arrange it.
-- request_repair accepts a request with neither a pickup address nor a branch (branch stays null until staff decide).
create or replace function public.request_repair(p_idempotency_key text, p_device_brand text, p_device_model text, p_imei_or_serial text, p_problem text, p_contact_name text, p_contact_phone text, p_pickup_address_id uuid, p_branch_id uuid, p_preferred_pickup_at timestamp with time zone, p_callback_requested boolean)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := public.require_auth();
  v_existing public.repair_requests%rowtype;
  v_addr public.customer_addresses%rowtype;
  v_id uuid := gen_random_uuid();
  v_ref text;
  v_label record;
begin
  if p_idempotency_key is null or char_length(p_idempotency_key) not between 8 and 100 then
    raise exception 'INVALID_IDEMPOTENCY_KEY';
  end if;
  select * into v_existing from public.repair_requests where customer_id = v_uid and idempotency_key = p_idempotency_key;
  if found then
    return jsonb_build_object('repair_id', v_existing.id, 'reference', v_existing.reference, 'replayed', true);
  end if;

  if char_length(coalesce(trim(p_device_brand), '')) < 2 or char_length(coalesce(trim(p_device_model), '')) < 1
     or char_length(coalesce(trim(p_contact_name), '')) < 2 or coalesce(p_contact_phone, '') !~ '^\+?[0-9]{8,15}$' then
    raise exception 'INVALID_INPUT';
  end if;
  if char_length(trim(coalesce(p_problem, ''))) < 5 then
    raise exception 'INVALID_INPUT';
  end if;
  if p_imei_or_serial is not null and p_imei_or_serial !~ '^[A-Za-z0-9\-]{5,30}$' then
    raise exception 'INVALID_IMEI';
  end if;

  if p_pickup_address_id is not null then
    select * into v_addr from public.customer_addresses where id = p_pickup_address_id and user_id = v_uid;
    if not found then raise exception 'INVALID_ADDRESS'; end if;
  elsif p_branch_id is not null and not exists (select 1 from public.branches where id = p_branch_id and is_active) then
    raise exception 'INVALID_BRANCH';
  end if;

  if p_preferred_pickup_at is not null and p_preferred_pickup_at < now() then
    raise exception 'INVALID_PICKUP_TIME';
  end if;

  v_ref := public.next_repair_reference();
  insert into public.repair_requests(id, reference, customer_id, idempotency_key, device_brand, device_model, imei_or_serial,
       problem_description, contact_name, contact_phone, pickup_address, branch_id, preferred_pickup_at, callback_requested)
  values (v_id, v_ref, v_uid, p_idempotency_key, trim(p_device_brand), trim(p_device_model), nullif(trim(p_imei_or_serial), ''),
       trim(p_problem), trim(p_contact_name), p_contact_phone,
       case when p_pickup_address_id is not null then jsonb_build_object(
         'recipient_name', v_addr.recipient_name, 'phone', v_addr.phone, 'governorate', v_addr.governorate,
         'city', v_addr.city, 'street', v_addr.street, 'building', v_addr.building, 'landmark', v_addr.landmark) end,
       p_branch_id, p_preferred_pickup_at, coalesce(p_callback_requested, false));

  select * into v_label from public.repair_status_labels where status = 'pickup_requested';
  insert into public.repair_status_history(repair_id, from_status, to_status, customer_message_ar, customer_message_en, changed_by)
  values (v_id, null, 'pickup_requested', v_label.message_ar, v_label.message_en, v_uid);

  perform public.enqueue_email('repair_new', 'repair_notification_email',
    jsonb_build_object('repair_id', v_id), 'repair', v_id);

  perform public.notify_user(v_uid, 'تم تسجيل طلب الصيانة', 'Repair request received',
    'تم إرسال طلب الصيانة لفريق الصيانة، وهنكلمك قريب لتأكيد الطلب. رقم الطلب: ' || v_ref,
    'Your repair request was sent to our repair team. We will call you soon to confirm it. Reference: ' || v_ref,
    'repair', v_id, v_ref, '/repairs/' || v_id);

  return jsonb_build_object('repair_id', v_id, 'reference', v_ref, 'replayed', false);
end $function$;
