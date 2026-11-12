-- 0180: a face check stays usable for 10 minutes for closing the shift (the review takes a few minutes); used up once.
create or replace function public._face_recent_self() returns boolean
language plpgsql security definer set search_path to 'public' as $$
declare v_uid uuid := auth.uid(); n int;
begin
  if v_uid is null then return false; end if;
  delete from public.staff_face_tries where caller = v_uid and target = v_uid and ok and at > now() - interval '10 minutes';
  get diagnostics n = row_count;
  return n > 0;
end $$;
revoke all on function public._face_recent_self() from public, anon, authenticated;
