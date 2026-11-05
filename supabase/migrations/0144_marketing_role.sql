-- 0144: a Marketing role (its permissions follow in 0145; a new enum value cannot be used in the same transaction).
alter type public.app_role add value if not exists 'marketing';
