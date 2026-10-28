-- 0062: two new team roles. Run this file ALONE first (a new enum value cannot be used in the same step that adds it), then run 0063.
alter type public.app_role add value if not exists 'cashier';
alter type public.app_role add value if not exists 'accountant';
