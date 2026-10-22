-- =====================================================================
-- My Hatō — 0009 tighten function grants (Supabase security advisor)
-- =====================================================================
-- setting() can read notification e-mail settings: only used inside SECURITY DEFINER functions
revoke execute on function public.setting(text) from public, anon, authenticated;
revoke execute on function public.require_permission(text) from public, anon;
revoke execute on function public.quote_delivery_fee(text, bigint) from public, anon;
revoke execute on function public.has_role(public.app_role) from public, anon;
revoke execute on function public.can_read_repair(uuid) from public, anon;
-- has_permission / is_staff / product_is_public stay executable by anon because public
-- catalog RLS policies call them; they only reveal facts about the caller.
