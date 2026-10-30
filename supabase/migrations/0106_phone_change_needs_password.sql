-- A customer can no longer change the contact phone straight from the app: it goes through the
-- account-change-phone function, which checks the account password first (service role only).
create or replace function public.guard_profile_phone()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.contact_phone is distinct from old.contact_phone and coalesce(auth.role(), '') = 'authenticated' then
    raise exception 'PASSWORD_REQUIRED';
  end if;
  return new;
end $$;
revoke all on function public.guard_profile_phone() from public, anon, authenticated;
drop trigger if exists profiles_guard_phone on public.profiles;
create trigger profiles_guard_phone before update of contact_phone on public.profiles
  for each row execute function public.guard_profile_phone();
