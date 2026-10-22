#!/usr/bin/env python3
"""Builds electronics_2026_10.sql (idempotent upsert) — the "Electronics" section that replaces "Used".

Computer accessories, storage, smart home / lighting and small electronics, with Egyptian market
selling prices (EGP) and an initial stock that can be changed from the admin dashboard.
Photos: Unsplash (free licence, no attribution required) — illustrative photos of the product type;
replace them from the admin dashboard with real product photos when available.
"""
import pathlib

HERE = pathlib.Path(__file__).parent
IMG = "https://images.unsplash.com/{}?auto=format&fit=crop&w=900&h=900&q=80"

CATEGORIES = [
    ("computer-accessories", "ملحقات الكمبيوتر", "Computer accessories", 1, "photo-1587829741301-dc798b83add3"),
    ("storage", "فلاشات وكروت ميموري", "Flash drives & memory cards", 2, "photo-1587145820098-23e484e69816"),
    ("smart-home", "إضاءة وسمارت هوم", "Lighting & smart home", 3, "photo-1572249930263-64fc5bbdb14b"),
    ("small-electronics", "أجهزة إلكترونية خفيفة", "Small electronics", 4, "photo-1564510182791-29645da7fac4"),
]

# sku, category, name_ar, name_en, price EGP, stock, photo, featured, desc_ar, desc_en, keywords
P = [
 ("MH-PC-001","computer-accessories","ماوس لاسلكي صامت","Silent wireless mouse",250,60,"photo-1527864550417-7fd91fc51a46",True,
  "ماوس لاسلكي بزراير صامتة ومستقبل USB صغير، مريح في الإيد وبطاريته بتعيش شهور.","Wireless mouse with silent clicks and a tiny USB receiver — comfortable, with months of battery life.",
  ["ماوس","فارة","لاسلكي","mouse","wireless"]),
 ("MH-PC-002","computer-accessories","ماوس جيمنج RGB","RGB gaming mouse",550,30,"photo-1605773527852-c546a8584ea3",False,
  "ماوس جيمنج بإضاءة RGB وحساسية قابلة للتغيير (DPI) وزراير جانبية للألعاب.","Gaming mouse with RGB lighting, adjustable DPI and side buttons.",
  ["ماوس جيمنج","جيمنج","gaming mouse","rgb"]),
 ("MH-PC-003","computer-accessories","كيبورد لاسلكي عربي/إنجليزي","Wireless keyboard (Arabic/English)",450,40,"photo-1587829741301-dc798b83add3",False,
  "كيبورد لاسلكي نحيف بحروف عربي وإنجليزي، بيشتغل مع اللابتوب والكمبيوتر والتابلت.","Slim wireless keyboard with Arabic and English keys for laptops, PCs and tablets.",
  ["كيبورد","لوحة مفاتيح","keyboard","wireless"]),
 ("MH-PC-004","computer-accessories","طقم كيبورد وماوس لاسلكي","Wireless keyboard & mouse set",650,30,"photo-1589578228447-e1a4e481c6c8",True,
  "طقم كيبورد وماوس لاسلكي بمستقبل واحد، مناسب للمكتب والبيت.","Wireless keyboard and mouse sharing one receiver — great for home and office.",
  ["طقم كيبورد","كيبورد وماوس","combo","keyboard","mouse"]),
 ("MH-PC-005","computer-accessories","ماوس باد كبير XL","XL desk mouse pad",180,50,"photo-1650566301820-ded93a1bb635",False,
  "ماوس باد كبير بيغطي الكيبورد والماوس، سطح ناعم وقاعدة مطاط مانعة للانزلاق.","Large desk pad for keyboard and mouse, smooth surface and anti-slip rubber base.",
  ["ماوس باد","desk pad","mouse pad"]),
 ("MH-PC-006","computer-accessories","موزع USB بـ 4 مداخل","4-port USB hub",250,40,"photo-1760376789487-994070337c76",False,
  "موزع USB صغير بيحول مدخل واحد لـ 4 مداخل للفلاشات والماوس والكيبورد.","Compact hub that turns one USB port into four for drives, mouse and keyboard.",
  ["موزع usb","هب","usb hub"]),
 ("MH-PC-007","computer-accessories","وصلة Type-C متعددة 6 في 1","6-in-1 USB-C hub",850,25,"photo-1760376789478-c1023d2dc007",False,
  "وصلة USB-C فيها HDMI و USB وقارئ كروت وشحن سريع، مثالية للابتوبات الحديثة.","USB-C hub with HDMI, USB ports, card reader and pass-through charging for modern laptops.",
  ["type-c hub","وصلة","hdmi","usb-c"]),
 ("MH-PC-008","computer-accessories","كاميرا ويب 1080p بمايك","1080p webcam with mic",900,20,"photo-1726127461372-547b9ffa4236",False,
  "كاميرا ويب فل HD بمايك مدمج، مناسبة للمذاكرة أونلاين والاجتماعات.","Full-HD webcam with built-in microphone for online classes and meetings.",
  ["كاميرا ويب","ويب كام","webcam"]),
 ("MH-PC-009","computer-accessories","ستاند لابتوب ألومنيوم","Aluminium laptop stand",550,30,"photo-1652198145075-b41c363792d3",False,
  "ستاند لابتوب قابل للطي والتعديل، بيرفع الشاشة لمستوى العين ويحسن التهوية.","Foldable adjustable stand that raises the screen to eye level and improves airflow.",
  ["ستاند لابتوب","حامل لابتوب","laptop stand"]),
 ("MH-PC-010","computer-accessories","مبرد لابتوب بمراوح","Laptop cooling pad",600,20,"photo-1593640404951-24f6ef605031",False,
  "قاعدة تبريد بمراوح هادية وإضاءة، بتقلل حرارة اللابتوب وقت الشغل والألعاب.","Cooling pad with quiet fans and lights that keeps your laptop cool while working or gaming.",
  ["مبرد لابتوب","تبريد","cooling pad"]),
 ("MH-PC-011","computer-accessories","سماعة جيمنج بمايك","Gaming headset with mic",950,20,"photo-1610041321327-b794c052db27",True,
  "سماعة رأس جيمنج بصوت محيطي ومايك قابل للتحريك، مريحة لساعات طويلة.","Over-ear gaming headset with surround sound and a flexible mic, comfortable for long sessions.",
  ["سماعة جيمنج","هيدسيت","headset","gaming"]),
 ("MH-ST-001","storage","فلاشة 64 جيجا USB 3.0","64GB USB 3.0 flash drive",250,80,"photo-1587145820098-23e484e69816",False,
  "فلاشة سريعة 64 جيجا بمدخل USB 3.0 لنقل الملفات والصور.","Fast 64GB USB 3.0 flash drive for files and photos.",
  ["فلاشة","فلاش","flash drive","usb"]),
 ("MH-ST-002","storage","فلاشة 128 جيجا معدن","128GB metal flash drive",400,60,"photo-1551818014-7c8ace9c1b5c",False,
  "فلاشة 128 جيجا بجسم معدن متين وتعليقة للمفاتيح.","128GB flash drive with a durable metal body and key ring.",
  ["فلاشة 128","فلاش","flash drive"]),
 ("MH-ST-003","storage","كارت ميموري 128 جيجا","128GB microSD memory card",450,60,"photo-1499336969384-ebe67b79faa8",False,
  "كارت ميموري microSD سريع للموبايل والكاميرا والتابلت، معاه أدابتر SD.","Fast microSD card for phones, cameras and tablets, with SD adapter.",
  ["كارت ميموري","ميموري","sd card","microsd"]),
 ("MH-SH-001","smart-home","شريط إضاءة LED RGB بريموت 5 متر","5m RGB LED strip with remote",400,40,"photo-1572249930263-64fc5bbdb14b",True,
  "شريط LED بألوان متغيرة وريموت، يتركب بسهولة ورا التلفزيون أو في الأوضة.","Colour-changing LED strip with remote, easy to stick behind a TV or around a room.",
  ["ليد","اضاءة","شريط ليد","led strip","rgb"]),
 ("MH-SH-002","smart-home","لمبة ذكية واي فاي","Wi-Fi smart bulb",350,50,"photo-1532007271951-c487760934ae",False,
  "لمبة ذكية تتحكم فيها من الموبايل: تشغيل وإطفاء، تغيير اللون والإضاءة ومواعيد.","Smart bulb controlled from your phone — on/off, colour, brightness and schedules.",
  ["لمبة ذكية","سمارت","smart bulb"]),
 ("MH-SH-003","smart-home","فيشة ذكية واي فاي","Wi-Fi smart plug",500,40,"photo-1586943029669-98ae685c5c4c",False,
  "فيشة ذكية تشغل وتطفي أي جهاز من الموبايل أو بمواعيد، ومناسبة للسخان والتكييف الصغير.","Smart plug to switch any appliance from your phone or on a schedule.",
  ["فيشة ذكية","سمارت بلج","smart plug"]),
 ("MH-SH-004","smart-home","مشترك كهرباء بمداخل USB","Power strip with USB ports",450,40,"photo-1781331534854-c75885f01c01",False,
  "مشترك 4 مخارج ومعاه مداخل USB للشحن، بحماية من زيادة الحمل.","4-outlet power strip with USB charging ports and overload protection.",
  ["مشترك","مشترك كهرباء","power strip","usb"]),
 ("MH-SH-005","smart-home","مقوي إشارة واي فاي","Wi-Fi range extender",900,20,"photo-1606904825846-647eb07f5be2",False,
  "مقوي واي فاي بيوصل النت للأوض البعيدة في البيت، تركيبه سهل في الفيشة.","Plug-in Wi-Fi extender that brings internet to far rooms.",
  ["مقوي واي فاي","راوتر","wifi extender","repeater"]),
 ("MH-SE-001","small-electronics","مروحة USB صغيرة","Mini USB desk fan",200,60,"photo-1564510182791-29645da7fac4",False,
  "مروحة مكتب صغيرة بتشتغل من USB، هادية ومناسبة للمكتب واللابتوب.","Quiet mini desk fan powered by USB — perfect next to a laptop.",
  ["مروحة","مروحة usb","fan","mini fan"]),
 ("MH-SE-002","small-electronics","مروحة محمولة بشحن","Rechargeable portable fan",550,40,"photo-1565151443833-29bf2ba5dd8d",True,
  "مروحة محمولة ببطارية بتشحن، 3 سرعات، تنفع للبيت والخروج والعربية.","Rechargeable portable fan with 3 speeds for home, outings and the car.",
  ["مروحة محمولة","مروحة شحن","portable fan"]),
 ("MH-SE-003","small-electronics","رينج لايت 10 بوصة بحامل","10-inch ring light with stand",650,25,"photo-1673196649671-eb09066ad6c1",False,
  "رينج لايت بإضاءة 3 ألوان وحامل موبايل، للتصوير والفيديوهات واللايفات.","3-tone ring light with phone holder for photos, videos and live streams.",
  ["رينج لايت","اضاءة تصوير","ring light"]),
 ("MH-SE-004","small-electronics","حامل موبايل ترايبود","Phone tripod",350,40,"photo-1696355607944-650405f2aa2e",False,
  "ترايبود خفيف للموبايل بأرجل قابلة للطي وريموت بلوتوث للتصوير.","Lightweight phone tripod with foldable legs and a Bluetooth remote.",
  ["ترايبود","حامل تصوير","tripod"]),
]

def q(s: str) -> str:
    return "'" + s.replace("'", "''") + "'"

out = ["-- Generated by build_electronics.py — Electronics section (replaces Used). Safe to re-run.", "begin;"]
for slug, ar, en, order, img in CATEGORIES:
    out.append(f"insert into public.categories(kind, slug, name_ar, name_en, sort_order, image_path) values ('electronics', {q(slug)}, {q(ar)}, {q(en)}, {order}, {q(IMG.format(img))}) on conflict (slug) do nothing;")
for sku, cat, ar, en, price, stock, img, feat, dar, den, kw in P:
    kws = "array[" + ",".join(q(k) for k in kw) + "]::text[]"
    out.append(
        "insert into public.products(sku, slug, category_id, name_ar, name_en, description_ar, description_en, price_minor, stock_quantity, keywords, status, is_featured)\n"
        f"values ({q(sku)}, {q(sku.lower())}, (select id from public.categories where slug = {q(cat)}), {q(ar)}, {q(en)}, {q(dar)}, {q(den)}, {price*100}, {stock}, {kws}, 'published', {'true' if feat else 'false'})\n"
        "on conflict (sku) do update set category_id = excluded.category_id, name_ar = excluded.name_ar, name_en = excluded.name_en,\n"
        "  description_ar = excluded.description_ar, description_en = excluded.description_en, price_minor = excluded.price_minor,\n"
        "  keywords = excluded.keywords, status = 'published', is_featured = excluded.is_featured;")
    out.append(
        "insert into public.product_images(product_id, storage_path, alt_ar, alt_en, sort_order)\n"
        f"select p.id, {q(IMG.format(img))}, {q(ar)}, {q(en)}, 0 from public.products p\n"
        f" where p.sku = {q(sku)} and not exists (select 1 from public.product_images i where i.product_id = p.id);")
out.append("commit;")
(HERE / "electronics_2026_10.sql").write_text("\n".join(out) + "\n", encoding="utf-8")
print(len(P), "products,", len(CATEGORIES), "categories")
