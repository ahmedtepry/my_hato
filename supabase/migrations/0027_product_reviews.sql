-- 0027 Product reviews: 1–5 stars + optional comment from signed-in customers.
-- A comment is checked against a banned-words list (Egyptian Arabic + Franco) the moment it is sent:
-- clean -> published right away; otherwise (or with links / phone numbers) -> pending for staff review.
-- Staff approve or remove reviews; removed reviews disappear from the store. Product rating_avg /
-- rating_count always reflect published reviews only. One review per customer per product (editable).

create table public.product_reviews (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  author_name text not null default '',
  rating smallint not null check (rating between 1 and 5),
  comment text check (comment is null or length(comment) <= 1000),
  status text not null default 'pending' check (status in ('published','pending','removed')),
  flagged_words text[] not null default '{}',
  verified_purchase boolean not null default false,
  moderated_by uuid references auth.users(id),
  moderated_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (product_id, user_id)
);
create index product_reviews_product_idx on public.product_reviews(product_id, status, created_at desc);
create index product_reviews_status_idx on public.product_reviews(status, created_at desc);
create trigger product_reviews_updated before update on public.product_reviews
  for each row execute function public.set_updated_at();

alter table public.product_reviews enable row level security;
revoke all on public.product_reviews from anon, authenticated;
grant select (id, product_id, author_name, rating, comment, status, verified_purchase, created_at, updated_at, user_id)
  on public.product_reviews to anon, authenticated;
grant select (flagged_words, moderated_at) on public.product_reviews to authenticated;
create policy product_reviews_read on public.product_reviews for select to anon, authenticated
  using (status = 'published' or user_id = auth.uid() or public.has_permission('products.manage'));

-- ---------------------------------------------------------------- language filter
create table public.review_banned_words (
  word text primary key,           -- stored normalized (see _review_normalize)
  whole_word boolean not null default true
);
alter table public.review_banned_words enable row level security;
revoke all on public.review_banned_words from anon, authenticated;

-- lower-case, unify Arabic letter forms, drop diacritics/tatweel, punctuation -> space, collapse repeats
create or replace function public._review_normalize(p text)
returns text language sql immutable set search_path = public as $$
  select trim(regexp_replace(regexp_replace(regexp_replace(regexp_replace(
           translate(lower(coalesce(p, '')), 'أإآٱىةؤئ', 'ااااييوي'),
           '[ًٌٍَُِّْـ]', '', 'g'),
           '[^ء-يa-z0-9]+', ' ', 'g'),
           '(.)\1+', '\1', 'g'),
           '\s+', ' ', 'g'))
$$;

insert into public.review_banned_words(word, whole_word)
select public._review_normalize(w), ww from (values
  -- whole words (short words that are also parts of normal words are only matched alone)
  ('كس', true), ('كسم', true), ('كسمك', true), ('كسمكم', true), ('زب', true), ('زبي', true), ('طيز', true),
  ('نيك', true), ('انيك', true), ('ينيك', true), ('نيكه', true), ('عرص', true), ('خول', true), ('علق', true),
  ('احا', true), ('لبوه', true), ('قحبه', true), ('خرا', true), ('خره', true), ('حمار', true), ('يا حيوان', true),
  ('يا كلب', true), ('يا زفت', true), ('kos', true), ('ksm', true), ('kosom', true), ('a7a', true), ('ars', true),
  ('teez', true), ('tiz', true), ('zeby', true), ('zeb', true), ('neek', true), ('khawal', true), ('5awal', true),
  -- anywhere in the text
  ('كسمك', false), ('كس امك', false), ('كس اختك', false), ('متناك', false), ('منيوك', false), ('منيك', false),
  ('شرموط', false), ('شراميط', false), ('معرص', false), ('عرص', false), ('ابن الكلب', false), ('ابن الوسخه', false),
  ('بنت الوسخه', false), ('ولاد الوسخه', false), ('ابن المتناكه', false), ('يلعن', false), ('العن ابو', false),
  ('دين امك', false), ('دين ابوك', false), ('كسختك', false), ('خولات', false), ('sharmot', false), ('sharmoot', false),
  ('sharmota', false), ('metnak', false), ('mitnak', false), ('manyak', false), ('manyok', false), ('mo3ars', false),
  ('m3ars', false), ('ibn el kalb', false), ('kosomak', false), ('kosomk', false), ('fuck', false), ('shit', false),
  ('bitch', false)
) as v(w, ww)
on conflict (word) do nothing;

-- banned words found in a text ('{}' = clean)
create or replace function public._review_flags(p text)
returns text[] language plpgsql stable security definer set search_path = public as $$
declare
  v_norm text := ' ' || public._review_normalize(p) || ' ';
  v_flags text[] := '{}';
  r record;
begin
  if v_norm = '  ' then return v_flags; end if;
  for r in select word, whole_word from public.review_banned_words loop
    if r.whole_word then
      if position(' ' || r.word || ' ' in v_norm) > 0
         or position(' و' || r.word || ' ' in v_norm) > 0
         or position(' ال' || r.word || ' ' in v_norm) > 0 then
        v_flags := array_append(v_flags, r.word);
      end if;
    elsif position(r.word in v_norm) > 0 then
      v_flags := array_append(v_flags, r.word);
    end if;
  end loop;
  -- links / phone numbers are spam-like: send to review too
  if coalesce(p, '') ~* '(https?://|www\.|\.com\b|wa\.me|t\.me|[0-9٠-٩]{9,})' then
    v_flags := array_append(v_flags, 'link/phone');
  end if;
  return (select coalesce(array_agg(distinct f), '{}') from unnest(v_flags) f);
end $$;

-- ---------------------------------------------------------------- rating summary
create or replace function public._refresh_product_rating(p_product_id uuid)
returns void language sql security definer set search_path = public as $$
  update public.products p set
    rating_count = s.n,
    rating_avg = coalesce(s.avg, 0)
  from (select count(*)::int n, round(avg(rating)::numeric, 2) avg
          from public.product_reviews where product_id = p_product_id and status = 'published') s
  where p.id = p_product_id;
$$;

-- ---------------------------------------------------------------- customer: write / edit a review
create or replace function public.submit_review(p_product_id uuid, p_rating int, p_comment text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := public.require_auth();
  v_comment text := nullif(left(trim(coalesce(p_comment, '')), 1000), '');
  v_flags text[];
  v_status text;
  v_name text;
  v_verified boolean;
begin
  if p_rating is null or p_rating not between 1 and 5 then raise exception 'INVALID_RATING'; end if;
  if not exists (select 1 from public.products where id = p_product_id and status = 'published') then
    raise exception 'NOT_FOUND';
  end if;
  -- at most 10 reviews / edits per customer per hour
  if (select count(*) from public.product_reviews where user_id = v_uid and updated_at > now() - interval '1 hour') >= 10 then
    raise exception 'RATE_LIMITED';
  end if;

  v_flags := public._review_flags(v_comment);
  v_status := case when cardinality(v_flags) = 0 then 'published' else 'pending' end;
  select split_part(trim(coalesce(nullif(full_name, ''), 'عميل My Hatō')), ' ', 1) into v_name from public.profiles where id = v_uid;
  v_verified := exists (select 1 from public.order_items oi join public.orders o on o.id = oi.order_id
                         where o.customer_id = v_uid and oi.product_id = p_product_id and o.status = 'delivered');

  insert into public.product_reviews(product_id, user_id, author_name, rating, comment, status, flagged_words, verified_purchase)
  values (p_product_id, v_uid, coalesce(v_name, 'عميل My Hatō'), p_rating, v_comment, v_status, v_flags, v_verified)
  on conflict (product_id, user_id) do update
     set rating = excluded.rating, comment = excluded.comment, status = excluded.status,
         flagged_words = excluded.flagged_words, author_name = excluded.author_name,
         verified_purchase = excluded.verified_purchase, moderated_by = null, moderated_at = null;

  perform public._refresh_product_rating(p_product_id);
  return jsonb_build_object('status', v_status);
end $$;

-- ---------------------------------------------------------------- staff moderation
create or replace function public.staff_moderate_review(p_review_id uuid, p_action text)
returns void language plpgsql security definer set search_path = public as $$
declare v_r public.product_reviews%rowtype;
begin
  perform public.require_permission('products.manage');
  if p_action not in ('approve', 'remove') then raise exception 'INVALID_INPUT'; end if;
  update public.product_reviews
     set status = case when p_action = 'approve' then 'published' else 'removed' end,
         moderated_by = auth.uid(), moderated_at = now()
   where id = p_review_id
  returning * into v_r;
  if not found then raise exception 'NOT_FOUND'; end if;
  perform public._refresh_product_rating(v_r.product_id);
  perform public.audit_write('review.' || p_action, 'product_review', p_review_id::text,
    jsonb_build_object('product_id', v_r.product_id, 'rating', v_r.rating));
end $$;

revoke all on function public._review_flags(text) from public, anon, authenticated;
revoke all on function public._refresh_product_rating(uuid) from public, anon, authenticated;
revoke all on function public.submit_review(uuid, int, text) from public, anon;
grant execute on function public.submit_review(uuid, int, text) to authenticated;
revoke all on function public.staff_moderate_review(uuid, text) from public, anon;
grant execute on function public.staff_moderate_review(uuid, text) to authenticated;
