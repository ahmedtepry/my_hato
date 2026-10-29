-- 0095: tapping a team notification opens the right place, not just the console. The link becomes /hato-console?tab=<section>
-- (accounts to verify -> accounts, orders -> orders, repairs -> repairs, reviews -> reviews, low stock -> products, shifts/approvals -> shifts,
-- gifts -> gifts, stock transfers -> stock). The app reads ?tab= and opens that section.

create or replace function public._console_link(p_permission text) returns text language sql immutable as $$
  select '/hato-console' || coalesce('?tab=' || case p_permission
    when 'orders.manage' then 'orders' when 'repairs.manage' then 'repairs' when 'products.manage' then 'reviews' when 'inventory.manage' then 'products'
    when 'support.manage' then 'accounts' when 'gifts.manage' then 'gifts'
    when 'shifts.review' then 'shifts' when 'shifts.reports' then 'shifts' when 'pos.approve' then 'shifts' end, '')
$$;

create or replace function public._notify_staff(p_permission text, p_title_ar text, p_title_en text, p_body_ar text, p_body_en text, p_reference text)
returns void language plpgsql security definer set search_path to 'public' as $$
declare r record;
begin
  for r in select distinct ur.user_id from public.user_roles ur
            where public._user_has_permission(ur.user_id, p_permission) loop
    perform public.notify_user(r.user_id, p_title_ar, p_title_en, p_body_ar, p_body_en, 'system', null, p_reference, public._console_link(p_permission));
  end loop;
exception when others then
  null;
end $$;

-- stock transfer notices (reference TR-xxxxx) open the stock section
create or replace function public._notification_link_fix() returns trigger language plpgsql as $$
begin
  if new.deep_link = '/' and new.entity_reference like 'TR-%' then new.deep_link := '/hato-console?tab=stock'; end if;
  return new;
end $$;
drop trigger if exists notifications_link_fix on public.notifications;
create trigger notifications_link_fix before insert on public.notifications for each row execute function public._notification_link_fix();
