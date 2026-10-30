-- 0106: the contact phone can no longer be changed straight from the app. The customer's own session has no UPDATE right on
-- profiles.contact_phone any more; the only way is the account-change-phone function, which checks the account password first.
-- (Done with a column privilege instead of a trigger: nothing in the other profile columns changes.)
revoke update (contact_phone) on public.profiles from authenticated;
-- the helper function created while trying a trigger first is not used: drop function if exists public.guard_profile_phone();
