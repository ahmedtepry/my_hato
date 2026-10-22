-- =====================================================================
-- Run ONCE in Supabase Dashboard → SQL Editor (project myhato-store).
-- The automated deployment tool refused this one statement (it contains a
-- DELETE inside a function body), so it must be pasted manually.
-- Needed for: customers removing a saved card (Account → Saved cards).
-- =====================================================================
create or replace function public.payment_remove_method(p_user_id uuid, p_method_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v_pm text;
begin
  select provider_payment_method_id into v_pm from public.payment_methods where id = p_method_id and user_id = p_user_id;
  if v_pm is null then raise exception 'NOT_FOUND'; end if;
  delete from public.payment_methods where id = p_method_id;
  return v_pm;
end $$;
revoke execute on function public.payment_remove_method(uuid, uuid) from public, anon, authenticated;
grant execute on function public.payment_remove_method(uuid, uuid) to service_role;
