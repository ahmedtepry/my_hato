-- 0147 (NOT applied yet, waits for the owner's confirmation): the marketing role keeps no permission that publishes directly.
-- Everything goes through marketing_requests and the owner's approval.
delete from public.role_permissions where role = 'marketing' and permission in
  ('banners.manage','coupons.manage','notifications.broadcast','contest.manage','occasions.manage','reviews.moderate','marketing.campaigns');
