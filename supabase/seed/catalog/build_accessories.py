#!/usr/bin/env python3
"""Builds accessories_2026_10.sql (idempotent upsert) and accessories_2026_10.csv from the product sheet.

Prices = "سعر البيع المقترح" (selling price per unit) from the owner's sheet. Cost columns are NOT stored.
Initial stock = "الكمية الموصى بها" (recommended quantity) — change it from the admin dashboard.
Photos: Unsplash (Unsplash License: free for commercial use, no attribution required). They are
illustrative photos of the product type, not photos of the exact item in stock — replace them from
the admin dashboard with real product photos when available.
"""
import csv, json, pathlib

HERE = pathlib.Path(__file__).parent
IMG = "https://images.unsplash.com/{}?auto=format&fit=crop&w=900&h=900&q=80"

# new categories (existing ones are reused by slug)
NEW_CATEGORIES = [
    ("holders", "حوامل وستاندات", "Holders & stands", 19),
    ("gaming", "إكسسوارات الألعاب", "Gaming accessories", 20),
    ("watch-accessories", "إكسسوارات الساعات الذكية", "Smartwatch accessories", 21),
    ("bundles", "باكدجات وعروض", "Bundles", 9),
]
RENAME = {
    "cables": ("كابلات ووصلات", "Cables & adapters"),
    "screen-protectors": ("حماية الشاشة والكاميرا", "Screen & camera protection"),
    "chargers": ("شواحن ورؤوس شحن", "Chargers & power"),
}
CATEGORY_IMAGES = {
    "cases": "photo-1535157412991-2ef801c1748b",
    "screen-protectors": "photo-1567428486597-8c5328fd3816",
    "cables": "photo-1572721546624-05bf65ad7679",
    "chargers": "photo-1770417999831-1c070eb628e6",
    "headphones": "photo-1606220588913-b3aacb4d2f46",
    "speakers": "photo-1547052178-7f2c5a20c332",
    "holders": "photo-1771227241320-8fc5388259c7",
    "gaming": "photo-1564049489314-60d154ff107d",
    "watch-accessories": "photo-1713056878930-c5604da9acfd",
    "other-accessories": "photo-1758218096054-ef3c7b56582c",
    "bundles": "photo-1758218096054-ef3c7b56582c",
}

# sku, category slug, name_ar, name_en, price EGP, initial stock, unsplash photo path, featured, desc_ar, desc_en, keywords
P = [
 # 1. Cases
 ("MH-CASE-001","cases","جراب سيليكون ببطانة مخملية","Silicone case with soft velvet lining",79,500,"photo-1535157412991-2ef801c1748b",False,
  "جراب سيليكون ناعم من بره وبطانة مخملية من جوه بتحمي ضهر الموبايل من الخدوش. خفيف ومريح في الإيد.","Smooth silicone outside and a soft velvet lining inside that protects the back of your phone from scratches. Light and comfortable to hold.",
  ["جراب","كفر","سيليكون","silicone","case","cover"]),
 ("MH-CASE-002","cases","جراب شفاف مقوّى ضد الصدمات","Clear shockproof case",99,300,"photo-1697008230027-5c6ebaf24801",False,
  "جراب أكريليك شفاف بيبيّن لون موبايلك، بأركان مقوّاة بتمتص الصدمات عند الوقوع.","Clear acrylic case that shows off your phone's colour, with reinforced corners that absorb drops.",
  ["جراب","شفاف","ضد الصدمات","clear","shockproof","case"]),
 ("MH-CASE-003","cases","جراب شفاف بحلقة ماج سيف","Clear MagSafe case",99,150,"photo-1697008230028-bce2fce98dfe",True,
  "جراب شفاف بحلقة مغناطيس مدمجة، بيشتغل مع الشواحن اللاسلكية والإكسسوارات المغناطيسية (MagSafe).","Clear case with a built-in magnetic ring for MagSafe wireless chargers and magnetic accessories.",
  ["ماج سيف","مغناطيس","magsafe","clear","case"]),
 ("MH-CASE-004","cases","جراب منفوخ / ملمس جلد","Puffer / leather-look case",99,200,"photo-1764855310912-15dee3625bf2",False,
  "جراب بتصميم منفوخ أو ملمس جلد صناعي، شكل أنيق وحماية إضافية للموبايل.","Puffer or faux-leather finish for a stylish look with extra cushioning.",
  ["جراب جلد","منفوخ","puffer","leather","case"]),
 ("MH-CASE-005","cases","جراب بجيب للكروت","Card holder case",59,100,"photo-1620786963525-4a74f1697a46",False,
  "جراب فيه جيب خلفي يشيل الكارنيه أو الفيزا، علشان تخرج بالموبايل بس.","Case with a back pocket for an ID or bank card, so you can leave the wallet at home.",
  ["جراب محفظة","كروت","card holder","wallet","case"]),
 ("MH-CASE-006","cases","جراب حماية من المية بتعليقة","Waterproof phone pouch with lanyard",49,80,"photo-1551679630-2eed87aefae6",False,
  "شنطة شفافة محكمة بتحمي الموبايل من المية والرمل على البحر والبيسين، ومعاها تعليقة للرقبة.","Sealed clear pouch that keeps your phone safe from water and sand at the beach or pool, with a neck lanyard.",
  ["ضد المية","بحر","waterproof","pouch"]),
 # 2. Protectors
 ("MH-PROT-001","screen-protectors","إسكرينة زجاج كاملة 9D / 11D / 21D","Full-cover tempered glass 9D/11D/21D",49,200,"photo-1567428486597-8c5328fd3816",False,
  "إسكرينة زجاج مقسّى بتغطي الشاشة كلها من الحرف للحرف، بتحمي من الخدوش والكسر.","Edge-to-edge tempered glass that protects the whole screen from scratches and cracks.",
  ["اسكرينة","سكرينة","زجاج","لزقة","9d","21d","tempered glass","screen protector"]),
 ("MH-PROT-002","screen-protectors","إسكرينة خصوصية (Privacy)","Privacy screen protector",49,100,"photo-1618986919459-5f3fe5650c7e",False,
  "إسكرينة بتخلّي الشاشة واضحة ليك بس، واللي جنبك مايقدرش يشوف المحتوى من الجنب.","Keeps your screen visible only to you; people beside you can't see it from an angle.",
  ["اسكرينة خصوصية","privacy","screen protector"]),
 ("MH-PROT-003","screen-protectors","إسكرينة مات للألعاب ضد البصمات","Matte anti-fingerprint gaming protector",49,100,"photo-1544228865-7d73678c0f28",False,
  "سطح مات ناعم بيقلل البصمات وانعكاس الضوء، مثالي للألعاب.","Smooth matte finish that reduces fingerprints and glare — ideal for gaming.",
  ["اسكرينة مات","ألعاب","matte","gaming"]),
 ("MH-PROT-004","screen-protectors","إسكرينة هيدروجيل مرنة","Flexible hydrogel screen protector",49,300,"photo-1784986717521-1171550e9208",False,
  "إسكرينة مرنة بتلبس على الشاشات المنحنية والعادية، وبتتقص على مقاس موبايلك.","Flexible film that fits curved and flat screens, cut to your phone model.",
  ["هيدروجيل","اسكرينة","hydrogel"]),
 ("MH-PROT-005","screen-protectors","حماية عدسات الكاميرا المعدنية","Metal camera lens protector rings",49,150,"photo-1763650287512-da3c19dd0129",False,
  "حلقات معدنية بزجاج بتحمي عدسات الكاميرا من الخدوش من غير ما تأثر على الصور.","Metal rings with glass that protect camera lenses from scratches without affecting photos.",
  ["حماية كاميرا","عدسات","camera lens","protector"]),
 # 3. Cables
 ("MH-CABL-001","cables","كابل قماش مضفّر قوي (Type-C / Lightning)","Braided charging cable (Type-C / Lightning)",59,120,"photo-1572721546624-05bf65ad7679",False,
  "كابل شحن ونقل بيانات مغلّف بقماش مضفّر يستحمل الثني والشد. متاح Type-C و Lightning.","Charging and data cable with a tough braided jacket that resists bending and pulling. Type-C or Lightning.",
  ["كابل","وصلة","تايب سي","type-c","lightning","cable"]),
 ("MH-CABL-002","cables","كابل سيليكون ناعم مقاوم للتآكل","Soft silicone cable",59,120,"photo-1619459072761-496c0812331b",False,
  "كابل سيليكون ناعم مايتعقدش بسهولة ومقاوم للتآكل.","Soft silicone cable that resists tangling and wear.",
  ["كابل سيليكون","cable"]),
 ("MH-CABL-003","cables","كابل 3 في 1 (Type-C + Micro + Lightning)","3-in-1 cable (Type-C + Micro USB + Lightning)",79,80,"photo-1573868388390-2739872961e6",False,
  "كابل واحد بثلاث أطراف يشحن أي موبايل: Type-C و Micro USB و Lightning.","One cable with three tips to charge any phone: Type-C, Micro USB and Lightning.",
  ["كابل 3 في 1","3 in 1","micro","cable"]),
 ("MH-CABL-004","cables","كابل بشاشة عرض قدرة الشحن","Cable with digital wattage display",99,40,"photo-1607125516845-fa8a14db083a",False,
  "كابل فيه شاشة صغيرة بتعرض قدرة الشحن بالوات، علشان تتأكد إن الشحن السريع شغال.","Built-in display shows charging power in watts, so you know fast charging is working.",
  ["كابل شاشة","وات","display","cable"]),
 ("MH-CABL-005","cables","وصلة Type-C / Lightning إلى AUX 3.5mm","Type-C / Lightning to 3.5mm AUX adapter",59,50,"photo-1630955539632-7463e7d65b5b",False,
  "وصلة بتخليك توصّل سماعة سلك أو AUX العربية بالموبايلات اللي مفيهاش مدخل سماعة.","Connect wired headphones or a car AUX to phones without a headphone jack.",
  ["وصلة سماعة","aux","3.5","adapter"]),
 ("MH-CABL-006","cables","محوّلات ووصلات صغيرة (OTG)","OTG adapters",49,60,"photo-1709660850064-0ec82e1a6b5d",False,
  "محوّلات صغيرة لتوصيل الفلاشة أو الماوس بالموبايل وتحويل المداخل.","Small adapters to connect a flash drive or mouse to your phone and convert ports.",
  ["otg","محول","فلاشة","adapter"]),
 # 4. Chargers
 ("MH-CHRG-001","chargers","شاحن GaN سريع 20W / 30W PD","GaN fast charger 20W / 30W PD",149,120,"photo-1770417999831-1c070eb628e6",True,
  "شاحن بتقنية GaN صغير الحجم وبيشحن بسرعة بقدرة 20 أو 30 وات (PD) من غير سخونة زيادة.","Compact GaN charger with 20W or 30W PD fast charging that stays cool.",
  ["شاحن","راس شاحن","شاحن سريع","gan","pd","20w","30w","charger"]),
 ("MH-CHRG-002","chargers","شاحن اقتصادي بمنفذين USB","Budget dual-USB charger",79,60,"photo-1770418000074-fa16c0a53e82",False,
  "شاحن عملي بمنفذين USB تشحن بيهم جهازين في نفس الوقت.","Practical charger with two USB ports to charge two devices at once.",
  ["شاحن","منفذين","usb","charger"]),
 ("MH-CHRG-003","chargers","شاحن سيارة معدني بمنفذين (سريع)","Metal dual-port fast car charger",90,40,"photo-1752552050371-8360f9c78086",False,
  "شاحن عربية بجسم معدني ومنفذين، بيشحن بسرعة وإنت سايق.","Metal car charger with two ports for fast charging on the road.",
  ["شاحن عربية","شاحن سيارة","car charger"]),
 ("MH-CHRG-004","chargers","مشترك كهرباء ذكي بمنافذ USB","Smart power strip with USB ports",240,20,"photo-1581558775369-0fe7925f0035",False,
  "مشترك كهرباء بفتحات عادية ومنافذ USB مدمجة، يشحن كل أجهزتك من مكان واحد.","Power strip with regular sockets and built-in USB ports to charge everything in one place.",
  ["مشترك","مشترك كهرباء","power strip","usb"]),
 # 5. Audio
 ("MH-AUDI-001","headphones","سماعة سلك كلاسيك (3.5mm / Type-C)","Classic wired earphones (3.5mm / Type-C)",40,100,"photo-1728583938892-9f45df2d4986",False,
  "سماعة سلك داخل الأذن بصوت واضح ومايك للمكالمات. متاحة بمدخل 3.5mm أو Type-C.","In-ear wired earphones with clear sound and a mic for calls. 3.5mm or Type-C.",
  ["سماعة","سماعة سلك","هاند فري","earphones","wired"]),
 ("MH-AUDI-002","headphones","سماعة بلوتوث TWS بشاشة لعرض البطارية","TWS Bluetooth earbuds with battery display",250,50,"photo-1606220588913-b3aacb4d2f46",True,
  "سماعة لاسلكية بالكامل وعلبة شحن فيها شاشة بتعرض نسبة البطارية.","True wireless earbuds with a charging case that shows the battery level.",
  ["ايربودز","سماعة بلوتوث","tws","earbuds","wireless"]),
 ("MH-AUDI-003","headphones","سماعة رقبة رياضية بلوتوث","Sports Bluetooth neckband",180,60,"photo-1606220945770-b5b6c2c55bf1",False,
  "سماعة بلوتوث بتتلبس على الرقبة، ثابتة ومريحة للرياضة والمشاوير الطويلة.","Bluetooth neckband that stays put — comfortable for workouts and long days.",
  ["سماعة رقبة","neckband","bluetooth","رياضة"]),
 ("MH-AUDI-004","speakers","سماعة بلوتوث صغيرة (Mini Speaker)","Mini Bluetooth speaker",190,30,"photo-1547052178-7f2c5a20c332",False,
  "سماعة خارجية صغيرة بصوت عالي، سهلة تتحمل في الشنطة.","Small portable speaker with loud sound that fits in your bag.",
  ["سبيكر","سماعة خارجية","speaker","bluetooth"]),
 # 6. Holders
 ("MH-HOLD-001","holders","حامل سيارة مغناطيسي (تابلوه / تكييف)","Magnetic car mount (dashboard / vent)",60,60,"photo-1771227241320-8fc5388259c7",False,
  "حامل مغناطيسي بيتركب على التابلوه أو فتحة التكييف ويمسك الموبايل بثبات.","Magnetic mount for the dashboard or air vent that holds your phone firmly.",
  ["حامل عربية","حامل مغناطيس","car mount","holder"]),
 ("MH-HOLD-002","holders","حامل سيارة أوتوماتيك بشاحن لاسلكي","Auto-clamping car mount with wireless charger",280,15,"photo-1788580210830-dd1644bbc57c",True,
  "حامل بيقفل على الموبايل أوتوماتيك وبيشحنه لاسلكي وإنت سايق.","Automatically clamps your phone and charges it wirelessly while you drive.",
  ["حامل شاحن لاسلكي","wireless charger","car mount"]),
 ("MH-HOLD-003","holders","مسكة موبايل خلفية دائرية (PopSocket / Ring)","Phone grip ring / PopSocket",15,150,"photo-1698336953291-f16c1df744f1",False,
  "مسكة بتتلزق على ضهر الموبايل، تمسكه بإيد واحدة وتستخدمها كستاند.","Sticks to the back of your phone for a one-hand grip and doubles as a stand.",
  ["مسكة","رينج","popsocket","grip","ring"]),
 ("MH-HOLD-004","holders","ستاند مكتب ألومنيوم قابل للطي","Foldable aluminium desk stand",110,30,"photo-1780802369931-d6eee63ea4c2",False,
  "ستاند ألومنيوم للموبايل والتابلت بزاوية قابلة للتعديل، وبيتطوي في الشنطة.","Aluminium stand for phones and tablets with adjustable angle; folds flat for your bag.",
  ["ستاند","حامل مكتب","stand","tablet"]),
 # 7. Gaming & watch
 ("MH-GAME-001","gaming","جوانتي أصابع للألعاب (زوج)","Gaming finger sleeves (pair)",15,200,"photo-1564049489314-60d154ff107d",False,
  "أغطية أصابع بتقلل العرق وبتخلّي اللمس أسرع وأدق في ألعاب زي ببجي.","Finger sleeves that reduce sweat for faster, more precise touch in games like PUBG.",
  ["جوانتي ببجي","ببجي","pubg","finger sleeves","gaming"]),
 ("MH-GAME-002","gaming","مروحة تبريد للموبايل RGB","RGB phone cooler fan",220,20,"photo-1762769152062-9581ad081c4c",False,
  "مروحة بتتركب على ضهر الموبايل وبتبرّده وقت الألعاب الطويلة، بإضاءة RGB.","Clips onto your phone to keep it cool during long gaming sessions, with RGB lighting.",
  ["مروحة","تبريد","cooler","rgb","gaming"]),
 ("MH-WATC-001","watch-accessories","سير ساعة (سيليكون / أوشن / قماش)","Watch strap (silicone / ocean / nylon)",60,100,"photo-1713056878930-c5604da9acfd",False,
  "سير بديل للساعة الذكية بخامات مختلفة: سيليكون أو أوشن أو قماش.","Replacement smartwatch strap in silicone, ocean or nylon.",
  ["سير ساعة","استيك","watch strap","band"]),
 ("MH-WATC-002","watch-accessories","جراب وحماية كاملة للساعة الذكية","Full-cover smartwatch case",45,70,"photo-1616679063640-603332e632cc",False,
  "جراب بحماية للشاشة بيغطي الساعة كلها ويحميها من الخبط والخدوش.","Case with built-in screen protection that covers the whole watch against knocks and scratches.",
  ["جراب ساعة","حماية ساعة","watch case"]),
 # 8. Misc
 ("MH-MISC-001","other-accessories","سلسلة / تعليقة موبايل للرقبة واليد","Phone lanyard (neck / wrist)",30,80,"photo-1756802137435-cfcd2ce56a83",False,
  "تعليقة للموبايل تلبسها على الرقبة أو الإيد، علشان الموبايل مايقعش.","Neck or wrist lanyard so your phone never slips away.",
  ["تعليقة","سلسلة موبايل","lanyard","strap"]),
 ("MH-MISC-002","other-accessories","ميدالية تتبّع بلوتوث","Bluetooth tracker tag",110,30,"photo-1567525884238-30bade6e1482",False,
  "ميدالية صغيرة تتعلّق في المفاتيح أو الشنطة، وتساعدك تلاقيها من الموبايل.","Small tag for keys or bags that helps you find them from your phone.",
  ["ميدالية تتبع","tracker","tag","مفاتيح"]),
 ("MH-MISC-003","other-accessories","طقم تنظيف الشاشات والسماعات","Screen & earbuds cleaning kit",40,40,"photo-1692645214212-ea7fdb37ca6d",False,
  "طقم فيه فرشاة وقماشة وسائل لتنظيف شاشة الموبايل والسماعات بأمان.","Brush, cloth and solution to safely clean your screen and earbuds.",
  ["تنظيف","cleaning kit"]),
 ("MH-BNDL-001","bundles","باكدج حماية متكامل (جراب + إسكرينة + حماية كاميرا + شاحن)","Full protection bundle (case + screen + camera protector + charger)",320,25,"photo-1758218096054-ef3c7b56582c",True,
  "كل اللي موبايلك محتاجه في باكدج واحد: جراب وإسكرينة وحماية كاميرا وشاحن.","Everything your phone needs in one bundle: case, screen protector, camera protector and charger.",
  ["باكدج","عرض","bundle","offer"]),
]

# extra gallery photos (same licence), sort_order 1, 2, …
EXTRA = {
    "MH-CASE-001": ["photo-1542219550-76864b1bc385"],
    "MH-CASE-002": ["photo-1583291023438-41cef6453b1f"],
    "MH-CASE-004": ["photo-1574683189522-9c5a95f78b76"],
    "MH-PROT-005": ["photo-1761906975713-326457551c3a"],
    "MH-CABL-001": ["photo-1492107376256-4026437926cd"],
    "MH-CABL-002": ["photo-1603539444875-76e7684265f6"],
    "MH-CABL-003": ["photo-1595756630452-736bc8ef3693"],
    "MH-CABL-004": ["photo-1615086169217-83e1c06c9f4f"],
    "MH-CHRG-001": ["photo-1770417999483-e5a313b33468"],
    "MH-CHRG-002": ["photo-1770417999317-64fb254c9e3a"],
    "MH-CHRG-003": ["photo-1559232212-9c37e0b94ba7"],
    "MH-CHRG-004": ["photo-1781331534854-c75885f01c01"],
    "MH-AUDI-001": ["photo-1728583938904-7124b3e1e428", "photo-1632835746204-22f652dac3af"],
    "MH-AUDI-002": ["photo-1578319439584-104c94d37305"],
    "MH-AUDI-004": ["photo-1589003077984-894e133dabab"],
    "MH-HOLD-001": ["photo-1764347923709-fc48487f2486"],
    "MH-HOLD-002": ["photo-1759256243611-502772ac391b"],
    "MH-HOLD-004": ["photo-1698314440014-3badb1e9c938"],
    "MH-GAME-001": ["photo-1639656333010-b6a054423b63"],
    "MH-GAME-002": ["photo-1758874383909-9b46bfb2dc65"],
    "MH-WATC-001": ["photo-1609951894313-1390909edc11", "photo-1554116154-e733de92fe4b"],
    "MH-WATC-002": ["photo-1598516802414-50a01bee818d"],
    "MH-MISC-001": ["photo-1634878656461-bcf0b954d8b3"],
    "MH-BNDL-001": ["photo-1573739022854-abceaeb585dc"],
}

def q(s):
    return "null" if s is None else "'" + str(s).replace("'", "''") + "'"

def arr(a):
    return "array[" + ",".join(q(x) for x in a) + "]::text[]"

sql = ["-- Accessories catalog import (generated by build_accessories.py). Idempotent: safe to run again.",
       "-- Prices from the owner's product sheet (selling price per unit, EGP). Cost is not stored.",
       "begin;", ""]
for slug, ar, en, sort in NEW_CATEGORIES:
    sql.append(f"insert into public.categories(kind, slug, name_ar, name_en, sort_order) values ('accessories', {q(slug)}, {q(ar)}, {q(en)}, {sort}) on conflict (slug) do nothing;")
for slug, (ar, en) in RENAME.items():
    sql.append(f"update public.categories set name_ar = {q(ar)}, name_en = {q(en)} where slug = {q(slug)};")
for slug, path in CATEGORY_IMAGES.items():
    sql.append(f"update public.categories set image_path = {q(IMG.format(path))} where slug = {q(slug)} and (image_path is null or image_path like 'https://images.unsplash.com/%');")
sql.append("")
for i, (sku, cat, ar, en, price, stock, img, feat, dar, den, kw) in enumerate(P):
    slug = sku.lower()
    sql.append(f"""insert into public.products(sku, slug, category_id, name_ar, name_en, description_ar, description_en, price_minor, stock_quantity, keywords, status, is_featured)
values ({q(sku)}, {q(slug)}, (select id from public.categories where slug = {q(cat)}), {q(ar)}, {q(en)}, {q(dar)}, {q(den)}, {price*100}, {stock}, {arr(kw)}, 'published', {str(feat).lower()})
on conflict (sku) do update set category_id = excluded.category_id, name_ar = excluded.name_ar, name_en = excluded.name_en,
  description_ar = excluded.description_ar, description_en = excluded.description_en, price_minor = excluded.price_minor,
  keywords = excluded.keywords, status = 'published', is_featured = excluded.is_featured;""")
    url = IMG.format(img)
    sql.append(f"""insert into public.product_images(product_id, storage_path, alt_ar, alt_en, sort_order)
select p.id, {q(url)}, {q(ar)}, {q(en)}, 0 from public.products p
 where p.sku = {q(sku)} and not exists (select 1 from public.product_images i where i.product_id = p.id);""")
sql.append("")
sql.append("-- extra gallery photos")
for sku, imgs in EXTRA.items():
    for n, img in enumerate(imgs, 1):
        url = IMG.format(img)
        sql.append(f"""insert into public.product_images(product_id, storage_path, alt_ar, alt_en, sort_order)
select p.id, {q(url)}, p.name_ar, p.name_en, {n} from public.products p
 where p.sku = {q(sku)} and not exists (select 1 from public.product_images i where i.product_id = p.id and i.storage_path = {q(url)});""")
sql.append("")
sql.append("-- opening stock recorded once in the inventory log")
sql.append("""insert into public.inventory_movements(product_id, delta, reason, note)
select p.id, p.stock_quantity, 'restock', 'opening stock (product sheet 2026-10)' from public.products p
 where p.sku like 'MH-%' and p.stock_quantity > 0
   and not exists (select 1 from public.inventory_movements m where m.product_id = p.id);""")
sql += ["", "commit;", ""]
(HERE / "accessories_2026_10.sql").write_text("\n".join(sql), encoding="utf-8")

with open(HERE / "accessories_2026_10.csv", "w", newline="", encoding="utf-8-sig") as f:
    w = csv.writer(f)
    w.writerow(["sku", "category", "name_ar", "name_en", "price_egp", "initial_stock", "featured", "photo_url"])
    for sku, cat, ar, en, price, stock, img, feat, *_ in P:
        w.writerow([sku, cat, ar, en, price, stock, "yes" if feat else "", IMG.format(img)])
print(len(P), "products")
