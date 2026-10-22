-- =====================================================================
-- My Hatō — 0010 online payments: enum values (separate migration because
-- new enum values cannot be used in the same transaction they are added)
-- =====================================================================
alter type public.payment_method add value if not exists 'online';          -- card / Apple Pay / Google Pay via provider
alter type public.payment_status add value if not exists 'pending';
alter type public.payment_status add value if not exists 'failed';
alter type public.payment_status add value if not exists 'partially_refunded';
