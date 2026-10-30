-- 0108: a new payment method, "wallet" (transfer to Vodafone Cash / Etisalat Cash / InstaPay).
alter type public.payment_method add value if not exists 'wallet';
