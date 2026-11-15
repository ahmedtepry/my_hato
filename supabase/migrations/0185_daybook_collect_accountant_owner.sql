-- Only the accountant and the owner record daily collections by default (owner's request). The owner can still
-- grant it to someone else from Permissions. Applied live.
delete from public.role_permissions where role = 'manager' and permission = 'daybook.collect';
