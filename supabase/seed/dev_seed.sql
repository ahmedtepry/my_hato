-- =====================================================================
-- DEVELOPMENT / DEMO SEED ONLY — do not run on production.
-- Production catalog is created from the admin dashboard.
-- =====================================================================

insert into public.categories (kind, slug, name_ar, name_en, sort_order) values
  ('phones','iphone','آيفون','Apple iPhone',1),
  ('phones','samsung','سامسونج','Samsung',2),
  ('phones','xiaomi','شاومي','Xiaomi',3),
  ('phones','oppo','أوبو','Oppo',4),
  ('phones','vivo','فيفو','Vivo',5),
  ('phones','huawei','هواوي','Huawei',6),
  ('phones','other-phones','ماركات أخرى','Other brands',7),
  ('accessories','chargers','شواحن','Chargers',10),
  ('accessories','cables','كابلات','Cables',11),
  ('accessories','cases','جرابات','Cases',12),
  ('accessories','screen-protectors','اسكرينات حماية','Screen protectors',13),
  ('accessories','headphones','سماعات','Headphones',14),
  ('accessories','power-banks','باور بانك','Power banks',15),
  ('accessories','speakers','سماعات خارجية','Speakers',16),
  ('accessories','smartwatches','ساعات ذكية','Smartwatches',17),
  ('accessories','other-accessories','إكسسوارات أخرى','Other accessories',18),
  ('used','used-phones','موبايلات مستعملة','Used phones',30)
on conflict (slug) do nothing;

insert into public.brands (slug, name_ar, name_en, sort_order) values
  ('apple','أبل','Apple',1),('samsung','سامسونج','Samsung',2),('xiaomi','شاومي','Xiaomi',3),
  ('oppo','أوبو','Oppo',4),('vivo','فيفو','Vivo',5),('huawei','هواوي','Huawei',6),('anker','أنكر','Anker',7)
on conflict (slug) do nothing;

insert into public.branches (name_ar, name_en, address_ar, address_en, phone, hours_ar, hours_en, pickup_instructions_ar, pickup_instructions_en) values
  ('الفرع الرئيسي','Main branch','(عنوان تجريبي — يُستبدل من لوحة التحكم)','(Demo address — replace from dashboard)','+201000000000',
   'يوميًا ١١ص – ١١م','Daily 11am – 11pm','اعرض رقم الطلب عند الكاشير.','Show your order number at the counter.');

insert into public.delivery_zones (governorate, fee_minor, eta_ar, eta_en) values
  ('القاهرة', 5000, '١-٢ يوم', '1-2 days'),
  ('الجيزة', 5000, '١-٢ يوم', '1-2 days'),
  ('الإسكندرية', 7000, '٢-٣ أيام', '2-3 days');

insert into public.products (sku, slug, category_id, brand_id, model, name_ar, name_en, description_ar, description_en,
                             price_minor, compare_at_price_minor, stock_quantity, warranty_ar, warranty_en, status, is_featured, keywords)
select v.sku, v.slug, c.id, b.id, v.model, v.name_ar, v.name_en, v.d_ar, v.d_en, v.price, v.cmp, v.stock,
       'ضمان سنة من الوكيل','1-year official warranty','published', v.featured, v.kw
from (values
  ('IPH15-128','iphone-15-128','iphone','apple','iPhone 15','آيفون 15 - 128 جيجا','iPhone 15 128GB','شاشة 6.1 بوصة وكاميرا 48 ميجابكسل.','6.1" display, 48MP camera.', 4500000::bigint, 4799900::bigint, 8, true, array['ايفون','iphone']),
  ('SGS24-256','galaxy-s24-256','samsung','samsung','Galaxy S24','سامسونج جالاكسي S24 - 256 جيجا','Samsung Galaxy S24 256GB','معالج قوي وشاشة AMOLED.','Flagship performance, AMOLED display.', 3899900, null, 5, true, array['جالكسي','galaxy']),
  ('RN13-128','redmi-note-13','xiaomi','xiaomi','Redmi Note 13','شاومي ريدمي نوت 13','Xiaomi Redmi Note 13','بطارية 5000 مللي أمبير.','5000mAh battery.', 1099900, 1199900, 20, false, array['ريدمي','redmi']),
  ('ANK-20W','anker-20w-charger','chargers','anker','PowerPort III','شاحن أنكر 20 وات','Anker 20W USB-C charger','شحن سريع للآيفون والأندرويد.','Fast charging for iPhone and Android.', 79900, 99900, 50, false, array['شاحن','charger']),
  ('CBL-C2L','usb-c-lightning-cable','cables','apple',null,'كابل USB-C إلى Lightning','USB-C to Lightning cable','طول 1 متر.','1 meter.', 49900, null, 3, false, array['كابل','cable'])
) as v(sku, slug, cat, brand, model, name_ar, name_en, d_ar, d_en, price, cmp, stock, featured, kw)
join public.categories c on c.slug = v.cat
join public.brands b on b.slug = v.brand
on conflict (sku) do nothing;

insert into public.product_specifications (product_id, label_ar, label_en, value_ar, value_en, sort_order)
select id, 'الشاشة', 'Display', '6.1 بوصة', '6.1 inch', 1 from public.products where sku = 'IPH15-128'
union all
select id, 'الذاكرة', 'Storage', '128 جيجا', '128 GB', 2 from public.products where sku = 'IPH15-128';
