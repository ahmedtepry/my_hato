-- 0043: a review of ANY product earns points. Products the customer really received earn the bigger reward.
--   review      (verified purchase)  = 40 points, no weekly limit (limited by real purchases)
--   review_any  (any other product)  = 10 points, at most loyalty_review_any_weekly_cap per week (default 3)
-- Both need a published review with a comment of 10+ characters, once per product. A review pays once in total.
-- A removed review takes its points back.

insert into public.loyalty_missions (key, kind, title_ar, title_en, desc_ar, desc_en, icon, points, repeat, sort) values
 ('review_any','review','قيّم أي منتج','Review any product',
  'اكتب رأيك (١٠ حروف على الأقل) في أي منتج واكسب ١٠ نقاط، بحد أقصى ٣ تقييمات في الأسبوع. لو المنتج اتسلّمك فعلًا بتكسب ٤٠.',
  'Write your opinion (10+ characters) on any product and earn 10 points, up to 3 reviews a week. If you actually received the product you earn 40.',
  'rate_review',10,'weekly',21)
on conflict (key) do nothing;
update public.loyalty_missions set
  desc_ar = 'قيّم منتج اتسلّمك فعلًا واكتب رأيك (١٠ حروف على الأقل) واكسب ٤٠ نقطة. النقاط بتتضاف تلقائي بعد نشر التقييم.',
  desc_en = 'Review a product you actually received and write your opinion (10+ characters) to earn 40 points. Points are added automatically once the review is published.'
 where key = 'review';
insert into public.application_settings (key, value, description) values
 ('loyalty_review_any_weekly_cap','3','Max rewarded reviews per week for products the customer did not buy')
on conflict (key) do nothing;

create or replace function public._loy_sync_orders(p_user uuid) returns void language plpgsql security definer set search_path = public as $$
declare o record; v_rp int; v_ra int; v_pts int; v_left int; v_per numeric := public._loy_num('loyalty_order_points_per_10egp', 1);
begin
  for o in select id, total_minor from public.orders
            where customer_id = p_user and status = 'delivered' and payment_status not in ('refunded','partially_refunded','failed')
              and not exists (select 1 from public.loyalty_ledger l where l.user_id = p_user and l.kind = 'order' and l.ref = orders.id::text)
            order by created_at limit 50 loop
    v_pts := floor(o.total_minor / 1000.0 * v_per)::int;
    perform public._loy_grant(p_user, 'order', o.id::text, v_pts, v_pts);
  end loop;
  for o in select l.ref, l.points, l.vault from public.loyalty_ledger l join public.orders r on r.id::text = l.ref
            where l.user_id = p_user and l.kind = 'order'
              and (r.status = 'cancelled' or r.payment_status in ('refunded','partially_refunded'))
              and not exists (select 1 from public.loyalty_ledger x where x.user_id = p_user and x.kind = 'order_reversal' and x.ref = l.ref) loop
    perform public._loy_grant(p_user, 'order_reversal', o.ref, -o.points, -o.vault);
  end loop;

  -- reviews: verified purchase pays the 'review' reward, any other product pays 'review_any' (weekly cap)
  select points into v_rp from public.loyalty_missions where key = 'review' and is_active;
  select points into v_ra from public.loyalty_missions where key = 'review_any' and is_active;
  if v_rp is not null then
    for o in select r.id from public.product_reviews r
              where r.user_id = p_user and r.status = 'published' and r.verified_purchase and length(trim(coalesce(r.comment, ''))) >= 10
                and not exists (select 1 from public.loyalty_ledger l where l.user_id = p_user and l.kind in ('review', 'review_any') and l.ref = r.id::text)
              order by r.created_at limit 20 loop
      perform public._loy_grant(p_user, 'review', o.id::text, v_rp, v_rp);
    end loop;
  end if;
  if v_ra is not null then
    v_left := public._loy_num('loyalty_review_any_weekly_cap', 3)::int
              - (select count(*) from public.loyalty_ledger where user_id = p_user and kind = 'review_any' and created_at >= public._loy_period_start('weekly'))::int;
    for o in select r.id from public.product_reviews r
              where r.user_id = p_user and r.status = 'published' and not r.verified_purchase and length(trim(coalesce(r.comment, ''))) >= 10
                and not exists (select 1 from public.loyalty_ledger l where l.user_id = p_user and l.kind in ('review', 'review_any') and l.ref = r.id::text)
              order by r.created_at limit 20 loop
      exit when v_left <= 0;
      if public._loy_grant(p_user, 'review_any', o.id::text, v_ra, v_ra) then v_left := v_left - 1; end if;
    end loop;
  end if;
  for o in select l.ref, l.points, l.vault, l.kind from public.loyalty_ledger l join public.product_reviews r on r.id::text = l.ref
            where l.user_id = p_user and l.kind in ('review', 'review_any') and r.status = 'removed'
              and not exists (select 1 from public.loyalty_ledger x where x.user_id = p_user and x.kind = 'review_reversal' and x.ref = l.ref) loop
    perform public._loy_grant(p_user, 'review_reversal', o.ref, -o.points, -o.vault);
  end loop;
end $$;
revoke all on function public._loy_sync_orders(uuid) from public, anon, authenticated;
