// Search by meaning: each page and each quick action has the words people actually type (Arabic, English, Franco),
// so "face id", "وش", "بصمه" or "فيس" all find the Face ID pages, and "خصم" finds offers and approvals.
import 'package:flutter/material.dart';

/// Lower case, Arabic letters unified (أ إ آ -> ا, ة -> ه, ى -> ي, ؤ -> و, ئ -> ي), marks and tatweel removed.
String searchNorm(String s) {
  final b = StringBuffer();
  for (final r in s.toLowerCase().runes) {
    if ((r >= 0x064B && r <= 0x065F) || r == 0x0670 || r == 0x0640) continue; // harakat, superscript alef, tatweel
    b.write(switch (r) {
      0x0623 || 0x0625 || 0x0622 || 0x0671 => 'ا',
      0x0629 => 'ه',
      0x0649 => 'ي',
      0x0624 => 'و',
      0x0626 => 'ي',
      _ => String.fromCharCode(r),
    });
  }
  return b.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// Does [query] hit any of [words]? Every word of the query must appear (in any order) in some word or phrase.
bool searchHit(String query, Iterable<String> words) {
  final q = searchNorm(query);
  if (q.length < 2) return false;
  final hay = searchNorm(words.join(' | '));
  if (hay.contains(q)) return true;
  final parts = q.split(' ').where((p) => p.length >= 2).toList();
  return parts.isNotEmpty && parts.every(hay.contains);
}

/// Extra words per page (besides its name and description).
const sectionKeywords = <String, List<String>>{
  'pos': ['كاشير', 'بيع', 'فاتوره', 'باركود', 'سله', 'درج', 'pos', 'cashier', 'sell', 'barcode', 'kasher', 'تبديل البائع', 'البائع', 'seller', 'face id', 'وش', 'فيس', 'بصمه الوش', 'وردية', 'قفل الوردية', 'shift'],
  'invoices': ['فواتير', 'فاتوره', 'مرتجع', 'استرجاع', 'refund', 'return', 'طباعه', 'print', 'invoice', 'receipt', 'دفع مقسم', 'split'],
  'shifts': ['ورديه', 'ورديات', 'موافقه', 'موافقات', 'خصم', 'مرتجع', 'فرق الدرج', 'shift', 'approval', 'discount', 'drawer'],
  'daybook': ['يوميه', 'اليوميه', 'تحصيل', 'حصل', 'محاسب', 'تقفيل', 'تقفيله', 'ورديه', 'جلسه', 'session', 'daybook', 'collection', 'collect', 'كاش', 'فيزا', 'محفظه', 'odoo', 'اودو', 'سطر اليوم'],
  'books': ['محاسبه', 'حسابات الفلوس', 'ارباح', 'مكسب', 'صافي', 'accounting', 'profit', 'money', 'فلوس'],
  'orders': ['طلبات', 'اوردر', 'اوردرات', 'order', 'orders', 'توصيل', 'delivery', 'شحن'],
  'repairs': ['صيانه', 'تصليح', 'فني', 'repair', 'technician', 'fix', 'شاشه مكسوره'],
  'ops': ['عمليات', 'مباشر', 'لايف', 'live', 'ops', 'اونلاين دلوقتي', 'مين فاتح'],
  'kpi': ['عموله', 'عمولات', 'kpi', 'commission', 'اداء', 'performance', 'بقشيش', 'tips'],
  'targets': ['تارجت', 'هدف', 'target', 'مكافاه', 'bonus', 'تحدي'],
  'mysales': ['مبيعاتي', 'مبيعات', 'بعت كام', 'اللي بعته', 'اكسسوارات', 'براند', 'صيانه', 'كود الموظف', 'كود', 'my sales', 'sales', 'cons', 'brand', 'accessories'],
  'server': ['سيرفر', 'السيرفر', 'مساحه', 'استهلاك', 'سوبابيز', 'نسخه احتياطيه', 'باك اب', 'server', 'usage', 'storage', 'backup', 'supabase'],
  'mytarget': ['تارجتي', 'عمولتي', 'my target'],
  'sales': ['مبيعات', 'تقرير', 'تقارير', 'اكسيل', 'excel', 'sales', 'report'],
  'wallets': ['محفظه', 'محافظ', 'فودافون كاش', 'اتصالات كاش', 'انستا باي', 'instapay', 'vodafone cash', 'wallet'],
  'wallet_inbox': ['تحويلات', 'استقبال', 'فلوس وصلت', 'wallet inbox', 'تحويل'],
  'online': ['اونلاين', 'ساعات', 'شيفت', 'online hours'],
  'online_review': ['اونلاين', 'online', 'اوردرات الاونلاين', 'استلام من فرع'],
  'storefront': ['واجهه', 'عرض المنتجات', 'شكل التطبيق', 'storefront', 'layout', 'مظهر التطبيق'],
  'assistant': ['روبوت', 'مساعد', 'ذكاء اصطناعي', 'ai', 'bot', 'robot', 'assistant', 'محاسب الي'],
  'app_banners': ['بانر', 'بانرات', 'اعلان', 'banner', 'slider', 'مظهر التطبيق'],
  'shortcuts': ['اختصار', 'جرد', 'استلام بضاعه', 'تعديل اسعار', 'تصدير', 'shortcut', 'stocktake', 'export'],
  'purchases': ['مشتريات', 'مورد', 'موردين', 'شراء', 'supplier', 'purchase'],
  'stock': ['مخزن', 'مخزون', 'تحويل بين الفروع', 'stock', 'inventory', 'warehouse', 'كميه'],
  'wheel': ['عجله', 'حظ', 'wheel', 'lucky', 'جوايز'],
  'features': ['مفاتيح', 'تشغيل', 'تفعيل', 'قفل', 'switch', 'نقاط', 'points'],
  'blocked': ['محظور', 'حظر', 'مقفول', 'باسورد غلط', 'فك الحظر', 'blocked', 'unblock', 'password', 'باسورد', 'كلمه السر', 'الحسابات'],
  'marketing': ['تسويق', 'حمله', 'حملات', 'شرايح', 'marketing', 'campaign', 'رسايل'],
  'contests': ['مسابقه', 'مسابقات', 'contest', 'quiz', 'اسئله'],
  'occasions': ['مناسبه', 'رمضان', 'عيد', 'لوجو', 'occasion', 'ramadan', 'eid', 'مظهر التطبيق'],
  'appearance': ['مظهر', 'لون', 'الوان', 'ثيم', 'شكل', 'ايقونه', 'دارك', 'داكن', 'فاتح', 'اسود', 'زجاج', 'ويندوز', 'theme', 'colour', 'color', 'dark', 'icon', 'look', 'windows', 'فاتوره شكل', 'شاشه الدخول', 'مظهر الويندوز', 'مظهر التطبيق'],
  'products': ['منتج', 'منتجات', 'سعر', 'اسعار', 'صور', 'product', 'price', 'باركود'],
  'reviews': ['تقييم', 'تقييمات', 'ريفيو', 'review', 'rating', 'نجوم'],
  'accounts': ['حساب', 'حسابات', 'عميل', 'عملاء', 'عملا', 'توثيق', 'account', 'customer', 'verify', 'الفريق', 'موظف', 'موظفين'],
  'gifts': ['هدايا', 'هديه', 'نقاط', 'مستويات', 'gift', 'points', 'reward', 'كوينز', 'coins'],
  'offers': ['عرض', 'عروض', 'كود', 'كوبون', 'خصم', 'offer', 'coupon', 'discount', 'promo'],
  'team': ['فريق', 'موظف', 'موظفين', 'صلاحيات', 'صلاحيه', 'دور', 'team', 'staff', 'role', 'permission', 'pin', 'رقم سري', 'face id', 'وش', 'فيس', 'بصمه', 'تفعيل الوش', 'الحسابات'],
};

/// A quick action the search can offer besides opening a page.
class SearchAction {
  const SearchAction(this.id, this.icon, this.ar, this.en, this.whereAr, this.whereEn, this.words, {this.section, this.ownerOnly = false});
  final String id;
  final IconData icon;
  final String ar, en, whereAr, whereEn;
  final List<String> words;

  /// the page it lives in (offered only when the user has that page); null = always
  final String? section;
  final bool ownerOnly;
}

const _face = ['face id', 'faceid', 'face', 'فيس', 'فيس اي دي', 'وش', 'الوش', 'وجه', 'بصمه', 'بصمه الوش', 'بصمة', 'كاميرا', 'camera', 'تعرف على الوش'];

const searchActions = <SearchAction>[
  SearchAction('my_profile', Icons.face_retouching_natural_rounded, 'ملفي: سجّل وشّك وغيّر الرقم السري والاسم', 'My profile: record your face, change PIN and name', 'ملفي', 'My profile',
      [..._face, 'ملفي', 'ملف', 'بروفايل', 'profile', 'اسمي', 'غير اسمي', 'رقم سري', 'الرقم السري', 'pin', 'بين']),
  SearchAction('face_team', Icons.how_to_reg_rounded, 'تفعيل الوش والملف الشخصي للموظفين', 'Turn on face and self service for staff', 'الحسابات ← الفريق', 'Accounts → Team',
      [..._face, 'تفعيل', 'موظف', 'staff', 'self service', 'يعدل ملفه'], section: 'team', ownerOnly: true),
  SearchAction('face_style', Icons.waves_rounded, 'شكل مسح الوش', 'Face scan look', 'المظهر ← الويندوز', 'Appearance → Windows',
      [..._face, 'شكل المسح', 'انيميشن', 'animation', 'موجه', 'wave', 'ليزر', 'ضباب', 'مظهر الويندوز'], ownerOnly: true),
  SearchAction('seller_face', Icons.swap_horiz_rounded, 'تبديل البائع بالوش', 'Switch the seller by face', 'الكاشير ← اسم البائع', 'Cashier → seller name',
      [..._face, 'تبديل البائع', 'البائع', 'seller', 'switch seller'], section: 'pos'),
  SearchAction('close_face', Icons.lock_clock_rounded, 'قفل الوردية بالوش', 'Close the shift by face', 'الكاشير ← قفل الوردية', 'Cashier → close shift',
      [..._face, 'قفل الورديه', 'اقفل الورديه', 'close shift', 'ورديه'], section: 'pos'),
  SearchAction('dark', Icons.dark_mode_rounded, 'الوضع الداكن / الفاتح', 'Dark / light mode', 'الشريط الجانبي', 'Side bar',
      ['داكن', 'دارك', 'فاتح', 'ليل', 'dark', 'light', 'night', 'الوان', 'مظهر', 'مظهر الويندوز']),
  SearchAction('language', Icons.translate_rounded, 'تغيير اللغة', 'Switch language', 'الشريط الجانبي', 'Side bar', ['لغه', 'انجليزي', 'عربي', 'english', 'arabic', 'language']),
];
