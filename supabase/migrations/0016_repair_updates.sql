-- 0016 Friendlier repair workflow: more allowed steps, clearer customer messages, and free
-- customer updates (no status change) from staff.

insert into public.repair_transitions(from_status, to_status) values
  ('received_at_branch','diagnosis_completed'),('received_at_branch','waiting_for_parts'),('received_at_branch','cancelled'),
  ('initial_inspection','waiting_for_parts'),('initial_inspection','repair_in_progress'),('initial_inspection','cancelled'),
  ('diagnosis_completed','waiting_for_parts'),('diagnosis_completed','cancelled'),
  ('repair_in_progress','repair_completed'),('repair_in_progress','ready_for_pickup'),('repair_in_progress','unrepairable'),
  ('waiting_for_parts','quality_testing'),('waiting_for_parts','cancelled'),
  ('quality_testing','ready_for_pickup'),('quality_testing','out_for_delivery'),
  ('repair_approved','quality_testing'),
  ('ready_for_pickup','out_for_delivery')
on conflict do nothing;

update public.repair_status_labels l set label_ar = x.la, message_ar = x.ma, label_en = x.le, message_en = x.me
from (values
  ('received_at_branch', 'استلمنا جهازك', 'استلمنا جهازك في الفرع وهنبدأ نفحصه.', 'Device received', 'We received your device at the branch and will start checking it.'),
  ('initial_inspection', 'بيتفحص دلوقتي', 'جهازك بيتفحص دلوقتي علشان نحدد العطل والتكلفة، وهنبلغك بالسعر.', 'Being checked', 'Your device is being checked to find the fault and the cost — we will let you know the price.'),
  ('diagnosis_completed', 'حددنا العطل', 'خلصنا الفحص وحددنا العطل، وهنبلغك بالتكلفة.', 'Fault found', 'We finished checking and found the fault — we will tell you the cost.'),
  ('repair_in_progress', 'بيتصلح دلوقتي', 'جهازك بيتصلح دلوقتي.', 'Being repaired', 'Your device is being repaired now.'),
  ('waiting_for_parts', 'مستنيين قطعة الغيار', 'طلبنا قطعة الغيار لجهازك وأول ما توصل هنكمّل الإصلاح.', 'Waiting for parts', 'We ordered the part for your device and will continue as soon as it arrives.'),
  ('quality_testing', 'بنختبره بعد الإصلاح', 'بنختبر جهازك بعد الإصلاح علشان نتأكد إن كل حاجة شغالة تمام.', 'Final testing', 'We are testing your device after the repair to make sure everything works.'),
  ('repair_completed', 'اتصلح', 'جهازك اتصلح بنجاح.', 'Repaired', 'Your device has been repaired.'),
  ('ready_for_pickup', 'اتصلح وجاهز تستلمه', 'جهازك اتصلح وجاهز تستلمه من الفرع.', 'Ready for pickup', 'Your device is repaired and ready to collect from the branch.'),
  ('out_for_delivery', 'في الطريق ليك', 'جهازك خرج للتوصيل وفي الطريق ليك.', 'On the way', 'Your device is out for delivery.'),
  ('delivered', 'اتسلّم', 'اتسلّم جهازك. شكرًا لثقتك في My Hatō!', 'Delivered', 'Your device was delivered. Thank you for trusting My Hatō!')
) as x(s, la, ma, le, me)
where l.status = x.s::public.repair_status;

-- Staff message to the customer without changing the status (timeline + notification).
create or replace function public.staff_post_repair_update(p_repair_id uuid, p_message_ar text, p_message_en text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_r public.repair_requests%rowtype;
begin
  select * into v_r from public.repair_requests where id = p_repair_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  if not public._can_update_repair(v_r) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if nullif(trim(p_message_ar), '') is null or length(p_message_ar) > 500 then raise exception 'INVALID_INPUT'; end if;
  insert into public.repair_status_history(repair_id, from_status, to_status, customer_message_ar, customer_message_en, changed_by)
  values (v_r.id, v_r.status, v_r.status, trim(p_message_ar), coalesce(nullif(trim(p_message_en), ''), trim(p_message_ar)), auth.uid());
  perform public.notify_user(v_r.customer_id, 'تحديث على ' || v_r.reference, 'Update on ' || v_r.reference,
    trim(p_message_ar), coalesce(nullif(trim(p_message_en), ''), trim(p_message_ar)), 'repair', v_r.id, v_r.reference, '/repairs/' || v_r.id);
  perform public.audit_write('repair.update', 'repair', v_r.id::text, jsonb_build_object('message', left(p_message_ar, 200)));
end $$;
revoke all on function public.staff_post_repair_update(uuid, text, text) from public, anon;
grant execute on function public.staff_post_repair_update(uuid, text, text) to authenticated;
