-- "بانرات التطبيق": the existing banners table now supports three looks and richer text.
-- Who can manage: banners.manage (owner, manager, sales, support, marketing already hold it).
alter table public.banners alter column image_path drop not null;
alter table public.banners
  add column if not exists style text not null default 'image',
  add column if not exists subtitle_ar text,
  add column if not exists subtitle_en text,
  add column if not exists cta_ar text,
  add column if not exists cta_en text,
  add column if not exists badge text,
  add column if not exists emoji text,
  add column if not exists color text not null default 'blue',
  add column if not exists price_text text,
  add column if not exists old_price_text text;
alter table public.banners drop constraint if exists banners_style_chk;
alter table public.banners add constraint banners_style_chk check (style in ('image','gradient','pill','product'));
alter table public.banners drop constraint if exists banners_color_chk;
alter table public.banners add constraint banners_color_chk check (color in ('blue','navy','orange','green','red','purple'));
alter table public.banners drop constraint if exists banners_len_chk;
alter table public.banners add constraint banners_len_chk check (
  char_length(title_ar) <= 80 and char_length(title_en) <= 80
  and coalesce(char_length(subtitle_ar),0) <= 120 and coalesce(char_length(subtitle_en),0) <= 120
  and coalesce(char_length(cta_ar),0) <= 20 and coalesce(char_length(cta_en),0) <= 20
  and coalesce(char_length(badge),0) <= 12 and coalesce(char_length(emoji),0) <= 8
  and coalesce(char_length(price_text),0) <= 20 and coalesce(char_length(old_price_text),0) <= 20);
