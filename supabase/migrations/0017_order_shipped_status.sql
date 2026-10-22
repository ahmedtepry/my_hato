-- 0017 New order step: handed to the shipping company (between "preparing" and "out for delivery").
-- Kept in its own migration: a new enum value cannot be used in the transaction that adds it.
alter type public.order_status add value if not exists 'shipped' after 'preparing';
