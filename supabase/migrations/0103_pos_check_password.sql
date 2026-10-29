-- Lets the shift robot confirm the closer's own password BEFORE the 30-second review, so a wrong password is caught at once.
-- It only answers true / false (same rate limit and attempt log as closing a shift). Nothing is changed.
create or replace function public.pos_check_password(p_password text) returns boolean
language plpgsql volatile security definer set search_path = public as $$
begin
  perform public.require_auth();
  return public._confirm_my_password(p_password);
end $$;
revoke all on function public.pos_check_password(text) from public, anon;
grant execute on function public.pos_check_password(text) to authenticated;
