-- 0178: my_face_enroll - the loop variable clashed with the jsonb_array_elements alias ("column reference e is ambiguous").
create or replace function public.my_face_enroll(p_prints jsonb, p_model text) returns jsonb
language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare v_uid uuid := public.require_auth(); n int; v_el jsonb;
begin
  if not public._self_service_ok(v_uid) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if jsonb_typeof(p_prints) <> 'array' then raise exception 'INVALID_INPUT'; end if;
  n := jsonb_array_length(p_prints);
  if n < 1 or n > 5 or coalesce(p_model, '') = '' then raise exception 'INVALID_INPUT'; end if;
  for v_el in select x.val from jsonb_array_elements(p_prints) as x(val) loop
    if jsonb_typeof(v_el) <> 'array' or jsonb_array_length(v_el) not in (128, 192, 512) then raise exception 'INVALID_INPUT'; end if;
  end loop;
  delete from public.staff_faces where user_id = v_uid;
  insert into public.staff_faces (user_id, print, model)
    select v_uid, (x.val::text)::extensions.vector, p_model from jsonb_array_elements(p_prints) as x(val);
  perform public.audit_write('staff.face_enrolled', 'user', v_uid::text, jsonb_build_object('prints', n, 'model', p_model));
  return jsonb_build_object('ok', true, 'faces', n);
end $$;
revoke all on function public.my_face_enroll(jsonb, text) from public, anon;
grant execute on function public.my_face_enroll(jsonb, text) to authenticated;
