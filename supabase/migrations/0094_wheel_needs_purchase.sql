-- 0094: the wheel is for customers who bought. Someone who never ordered sees the wheel but cannot spin ("buy anything and you get a chance to win");
-- a counter sale linked to the customer counts as a purchase too. The first purchase sends "you can spin now". The owner can still switch the rule off.

create or replace function public._wheel_block(p_user uuid) returns text
language plpgsql stable security definer set search_path = public as $$
declare pr public.profiles; v_review text; s public.wheel_settings;
begin
  select * into pr from public.profiles where id = p_user;
  if not found or not (coalesce(pr.email_verified, false) or coalesce(pr.phone_verified, false)) then return 'NOT_VERIFIED'; end if;
  select review_status into v_review from public.customers where user_id = p_user;
  if coalesce(v_review, 'approved') <> 'approved' then return 'NOT_APPROVED'; end if;
  select * into s from public.wheel_settings where id = 1;
  if s.require_order
     and not exists (select 1 from public.orders o where o.customer_id = p_user and o.status <> 'cancelled')
     and not exists (select 1 from public.pos_sales ps where ps.customer_id = p_user) then return 'NEEDS_ORDER'; end if;
  return null;
end $$;
revoke all on function public._wheel_block(uuid) from public, anon, authenticated;

update public.wheel_settings set require_order = true where id = 1;

create or replace function public._wheel_first_purchase() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_user uuid := new.customer_id;
begin
  if v_user is null or not public._feature_on('wheel') then return null; end if;
  if not (select require_order from public.wheel_settings where id = 1) then return null; end if;
  if (select count(*) from public.orders o where o.customer_id = v_user and o.status <> 'cancelled' and not (TG_TABLE_NAME = 'orders' and o.id = new.id))
     + (select count(*) from public.pos_sales ps where ps.customer_id = v_user and not (TG_TABLE_NAME = 'pos_sales' and ps.id = new.id)) > 0 then return null; end if;
  perform public.notify_user(v_user, '🎡 عجلة الحظ اتفتحتلك!', '🎡 The lucky wheel is open for you!',
    'شكرًا على أول طلب! دلوقتي تقدر تلف العجلة كل يوم وتكسب نقاط أو هدايا. افتح «عجلة الحظ» من حسابك.',
    'Thanks for your first order! You can now spin the wheel every day and win points or gifts. Open "Lucky wheel" from your account.',
    'system', null, null, '/wheel');
  return null;
end $$;
drop trigger if exists orders_wheel_first on public.orders;
create trigger orders_wheel_first after insert on public.orders for each row execute function public._wheel_first_purchase();
drop trigger if exists pos_sales_wheel_first on public.pos_sales;
create trigger pos_sales_wheel_first after insert on public.pos_sales for each row execute function public._wheel_first_purchase();
