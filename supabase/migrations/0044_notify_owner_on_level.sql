-- 0044: the owner gets a notification the moment a customer reaches a gift level (Bronze, Silver, ...).
-- Points and awards are now updated at once when an order is delivered / cancelled or a review changes,
-- no longer only when the customer opens the rewards page. The notice goes to everyone holding gifts.manage.
-- The owner then decides the gift for that code in the Gifts tab (nothing is shown to the customer until revealed).

create or replace function public._loy_check_awards(p_user uuid) returns void language plpgsql security definer set search_path = public as $$
declare r record; v_pts int; v_name text;
begin
  select points into v_pts from public.loyalty_profiles where user_id = p_user;
  if v_pts is null then return; end if;
  select coalesce(nullif(full_name, ''), email) into v_name from public.profiles where id = p_user;
  for r in
    with ins as (
      insert into public.loyalty_awards (user_id, level_sort, code)
      select p_user, l.sort, public._loy_gift_code() from public.loyalty_levels l where l.min_points <= v_pts and l.sort > 1
      on conflict do nothing returning level_sort, code)
    select ins.level_sort, ins.code, l.name_ar, l.name_en from ins join public.loyalty_levels l on l.sort = ins.level_sort order by ins.level_sort
  loop
    perform public._notify_staff('gifts.manage',
      '🏆 عميل وصل لمستوى ' || r.name_ar, '🏆 A customer reached ' || r.name_en,
      coalesce(v_name, 'عميل') || ' وصل لمستوى ' || r.name_ar || ' (' || v_pts || ' نقطة). الكود ' || r.code || '. حدّد هديته من تبويب الهدايا.',
      coalesce(v_name, 'A customer') || ' reached ' || r.name_en || ' (' || v_pts || ' points). Code ' || r.code || '. Choose the gift in the Gifts tab.',
      r.code);
  end loop;
end $$;
revoke all on function public._loy_check_awards(uuid) from public, anon, authenticated;

create or replace function public._loy_grant(p_user uuid, p_kind text, p_ref text, p_points int, p_vault int)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  insert into public.loyalty_ledger (user_id, kind, ref, points, vault) values (p_user, p_kind, p_ref, p_points, p_vault)
    on conflict (user_id, kind, ref) do nothing;
  get diagnostics v_n = row_count;
  if v_n = 0 then return false; end if;
  update public.loyalty_profiles set points = greatest(points + p_points, 0), vault_progress = greatest(vault_progress + p_vault, 0)
   where user_id = p_user;
  if p_points > 0 then perform public._loy_check_awards(p_user); end if;
  return true;
end $$;
revoke all on function public._loy_grant(uuid, text, text, int, int) from public, anon, authenticated;

-- keep points (and so awards + the owner notice) up to date without waiting for the customer to open the page.
-- A failure here must never block an order or a review, so errors are swallowed.
create or replace function public._loy_on_order() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.customer_id is not null then
    begin
      perform public._loy_ensure(new.customer_id);
      perform public._loy_sync_orders(new.customer_id);
    exception when others then null;
    end;
  end if;
  return new;
end $$;
revoke all on function public._loy_on_order() from public, anon, authenticated;
drop trigger if exists loyalty_order_sync on public.orders;
create trigger loyalty_order_sync after update of status, payment_status on public.orders for each row
  when (new.status in ('delivered', 'cancelled') or new.payment_status in ('refunded', 'partially_refunded'))
  execute function public._loy_on_order();

create or replace function public._loy_on_review() returns trigger language plpgsql security definer set search_path = public as $$
begin
  begin
    perform public._loy_ensure(new.user_id);
    perform public._loy_sync_orders(new.user_id);
  exception when others then null;
  end;
  return new;
end $$;
revoke all on function public._loy_on_review() from public, anon, authenticated;
drop trigger if exists loyalty_review_sync on public.product_reviews;
create trigger loyalty_review_sync after insert or update of status, comment, verified_purchase on public.product_reviews for each row
  execute function public._loy_on_review();
