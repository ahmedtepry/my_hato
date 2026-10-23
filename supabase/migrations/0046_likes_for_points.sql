-- 0046: likes earn points.
--   * a customer can like any published review of someone else   -> 5 points, at most 3 rewarded likes a day
--   * the heart on a product is the product "like"              -> 5 points, at most 3 rewarded products a day
-- Each review / product pays ONCE ever (the ledger is unique per user+kind+ref), so like-unlike-like never earns twice.
-- Points come from the two missions below (edit them in loyalty_missions); the daily limit is loyalty_like_daily_cap.

insert into public.application_settings (key, value, description) values
 ('loyalty_like_daily_cap', '3', 'Rewarded likes per day, counted separately for reviews and for products')
on conflict (key) do nothing;

insert into public.loyalty_missions (key, kind, title_ar, title_en, desc_ar, desc_en, icon, points, repeat, sort) values
 ('like_review', 'review', 'لايك على تقييم', 'Like a review',
  'اعمل لايك على أي تقييم واكسب ٥ نقاط، بحد أقصى ٣ لايكات في اليوم. النقاط بتتضاف تلقائي.',
  'Like any review and earn 5 points, up to 3 likes a day. Points are added automatically.', 'thumb_up', 5, 'daily', 22),
 ('like_product', 'review', 'لايك على منتج', 'Like a product',
  'دوس على القلب في أي منتج واكسب ٥ نقاط، بحد أقصى ٣ منتجات في اليوم. النقاط بتتضاف تلقائي.',
  'Tap the heart on any product and earn 5 points, up to 3 products a day. Points are added automatically.', 'favorite', 5, 'daily', 23)
on conflict (key) do nothing;

-- ---------------------------------------------------------------- review likes
create table if not exists public.review_likes (
  review_id uuid not null references public.product_reviews(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (review_id, user_id)
);
alter table public.review_likes enable row level security;
revoke all on public.review_likes from anon, authenticated;
grant select on public.review_likes to authenticated;
drop policy if exists review_likes_own on public.review_likes;
create policy review_likes_own on public.review_likes for select to authenticated using (user_id = auth.uid());

alter table public.product_reviews add column if not exists like_count int not null default 0;
grant select (like_count) on public.product_reviews to anon, authenticated;

create or replace function public._review_like_count() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    update public.product_reviews set like_count = like_count + 1 where id = new.review_id;
  else
    update public.product_reviews set like_count = greatest(like_count - 1, 0) where id = old.review_id;
  end if;
  return null;
end $$;
revoke all on function public._review_like_count() from public, anon, authenticated;
drop trigger if exists review_likes_count on public.review_likes;
create trigger review_likes_count after insert or delete on public.review_likes for each row execute function public._review_like_count();

-- ---------------------------------------------------------------- reward helper
-- returns {points, first, remaining}: points actually paid now (0 when already paid before or the daily limit is used)
create or replace function public._loy_like_reward(p_user uuid, p_kind text, p_ref text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_pts int; v_cap int := public._loy_num('loyalty_like_daily_cap', 3)::int; v_today int; v_first boolean; v_paid int := 0;
begin
  select points into v_pts from public.loyalty_missions where key = p_kind and is_active;
  if v_pts is null then return jsonb_build_object('points', 0, 'first', false, 'remaining', 0, 'cap', v_cap); end if;
  perform public._loy_ensure(p_user);
  v_first := not exists (select 1 from public.loyalty_ledger where user_id = p_user and kind = p_kind);
  select count(*) into v_today from public.loyalty_ledger where user_id = p_user and kind = p_kind and created_at >= public._loy_period_start('daily');
  if v_today < v_cap and not exists (select 1 from public.loyalty_ledger where user_id = p_user and kind = p_kind and ref = p_ref) then
    if public._loy_grant(p_user, p_kind, p_ref, v_pts, v_pts) then v_paid := v_pts; v_today := v_today + 1; end if;
  end if;
  return jsonb_build_object('points', v_paid, 'first', v_first and v_paid > 0, 'remaining', greatest(v_cap - v_today, 0), 'cap', v_cap, 'per', v_pts);
end $$;
revoke all on function public._loy_like_reward(uuid, text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------- RPCs
create or replace function public.toggle_review_like(p_review uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := public.require_auth(); r public.product_reviews%rowtype; v_liked boolean; v_res jsonb := '{}'::jsonb;
begin
  select * into r from public.product_reviews where id = p_review and status = 'published';
  if not found then raise exception 'NOT_FOUND'; end if;
  if r.user_id = u then raise exception 'OWN_REVIEW'; end if;
  delete from public.review_likes where review_id = p_review and user_id = u;
  if found then
    v_liked := false;
  else
    insert into public.review_likes (review_id, user_id) values (p_review, u) on conflict do nothing;
    v_liked := true;
    v_res := public._loy_like_reward(u, 'like_review', p_review::text);
  end if;
  return v_res || jsonb_build_object('liked', v_liked, 'count', (select like_count from public.product_reviews where id = p_review));
end $$;
revoke all on function public.toggle_review_like(uuid) from public, anon;
grant execute on function public.toggle_review_like(uuid) to authenticated;

create or replace function public.toggle_product_like(p_product uuid, p_like boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u uuid := public.require_auth(); v_res jsonb := '{}'::jsonb;
begin
  if not exists (select 1 from public.products where id = p_product) then raise exception 'NOT_FOUND'; end if;
  if p_like then
    insert into public.product_favorites (user_id, product_id) values (u, p_product) on conflict do nothing;
    v_res := public._loy_like_reward(u, 'like_product', p_product::text);
  else
    delete from public.product_favorites where user_id = u and product_id = p_product;
  end if;
  return v_res || jsonb_build_object('liked', p_like);
end $$;
revoke all on function public.toggle_product_like(uuid, boolean) from public, anon;
grant execute on function public.toggle_product_like(uuid, boolean) to authenticated;
