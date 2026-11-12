// "بانرات التطبيق": the owner (and anyone holding banners.manage: manager, sales, support, marketing)
// adds, edits, reorders, schedules, hides and deletes the banners shown on the customer home screen.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import '../../shared/motion.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show FileOptions;

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../shared/app_banner.dart';
import '../../shared/states.dart';

String _t(BuildContext c, String ar, String en) => c.isAr ? ar : en;

final _allBannersProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>(
    (ref) async => List<Map<String, dynamic>>.from(await ref.watch(supabaseProvider).from('banners').select().order('sort_order').order('created_at')));
final _bannerProductsProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>(
    (ref) async => List<Map<String, dynamic>>.from(await ref.watch(supabaseProvider).from('products').select('id, name_ar, name_en').order('name_ar').limit(400)));
final _bannerCategoriesProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>(
    (ref) async => List<Map<String, dynamic>>.from(await ref.watch(supabaseProvider).from('categories').select('id, name_ar, name_en').order('name_ar').limit(100)));

String _styleAr(String s) => switch (s) { 'gradient' => 'متدرج (88)', 'pill' => 'كبسولة (56)', 'product' => 'منتج (96)', _ => 'صورة (160)' };
String _styleEn(String s) => switch (s) { 'gradient' => 'Gradient (88)', 'pill' => 'Pill (56)', 'product' => 'Product (96)', _ => 'Picture (160)' };
String _colorAr(String s) => switch (s) { 'navy' => 'كحلي', 'orange' => 'برتقالي', 'green' => 'أخضر', 'red' => 'أحمر', 'purple' => 'بنفسجي', _ => 'أزرق' };
String _colorEn(String s) => switch (s) { 'navy' => 'Navy', 'orange' => 'Orange', 'green' => 'Green', 'red' => 'Red', 'purple' => 'Purple', _ => 'Blue' };

/// What to tell whoever prepares the picture.
String imageSizeHint(BuildContext c, String style) => switch (style) {
      'image' => _t(c, 'مقاس الصورة: 1200 × 500 بكسل (عرض × طول) · الشكل عريض 2.4 : 1 · JPG أو PNG · أقل من 500 كيلو. سيب الكلام المهم في النص عشان الحواف ممكن تتقص شوية.',
          'Picture size: 1200 × 500 px (width × height) · wide 2.4 : 1 · JPG or PNG · under 500 KB. Keep key text in the middle; edges may be cropped.'),
      'product' => _t(c, 'صورة المنتج: 400 × 400 بكسل (مربعة 1 : 1) · خلفية شفافة PNG أو بيضا · أقل من 200 كيلو.',
          'Product picture: 400 × 400 px (square 1 : 1) · transparent PNG or white background · under 200 KB.'),
      _ => _t(c, 'الشكل ده من غير صورة، بيستخدم لون وإيموجي.', 'This look needs no picture; it uses a colour and an emoji.'),
    };

class AppBannersPanel extends ConsumerWidget {
  const AppBannersPanel({super.key});

  Future<void> _edit(BuildContext context, WidgetRef ref, [Map<String, dynamic>? row]) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => _BannerForm(row: row),
    );
    if (saved == true) ref.invalidate(_allBannersProvider);
  }

  Future<void> _run(BuildContext context, WidgetRef ref, Future<void> Function() f) async {
    try {
      await f();
      ref.invalidate(_allBannersProvider);
    } catch (e) {
      if (context.mounted) showSnack(context, friendlyError(context, e), error: true);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.watch(supabaseProvider);
    final list = ref.watch(_allBannersProvider);
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context, ref),
        icon: const Icon(Icons.add_rounded),
        label: Text(_t(context, 'بانر جديد', 'New banner')),
      ),
      body: list.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(_allBannersProvider)),
        data: (rows) => rows.isEmpty
            ? EmptyState(icon: Icons.view_carousel_rounded, title: _t(context, 'مفيش بانرات لسه', 'No banners yet'), body: _t(context, 'اضغط "بانر جديد" وهيظهر في الصفحة الرئيسية لتطبيق العملا.', 'Tap "New banner" and it shows on the customer home screen.'))
            : ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
                itemCount: rows.length,
                itemBuilder: (_, i) {
                  final b = rows[i];
                  final style = (b['style'] ?? 'image').toString();
                  final now = DateTime.now();
                  final start = DateTime.tryParse('${b['starts_at'] ?? ''}')?.toLocal();
                  final end = DateTime.tryParse('${b['ends_at'] ?? ''}')?.toLocal();
                  final active = b['is_active'] == true;
                  final live = active && (start == null || !start.isAfter(now)) && (end == null || end.isAfter(now));
                  final status = !active
                      ? _t(context, 'مخفي', 'Hidden')
                      : (start != null && start.isAfter(now))
                          ? _t(context, 'مجدول', 'Scheduled')
                          : (end != null && !end.isAfter(now))
                              ? _t(context, 'انتهى', 'Ended')
                              : _t(context, 'ظاهر للعملا', 'Live');
                  return Card(
                    margin: const EdgeInsets.only(bottom: 12),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Opacity(opacity: live ? 1 : .5, child: IgnorePointer(child: AppBannerCard(banner: b, onTap: () {}))),
                        const SizedBox(height: 8),
                        Row(children: [
                          Chip(
                            label: Text(status, style: TextStyle(color: live ? BrandColors.success : BrandColors.gray, fontWeight: FontWeight.w700, fontSize: 12)),
                            visualDensity: VisualDensity.compact,
                            side: BorderSide(color: live ? BrandColors.success : BrandColors.border),
                          ),
                          const SizedBox(width: 6),
                          Text(_t(context, _styleAr(style), _styleEn(style)), style: const TextStyle(color: BrandColors.gray, fontSize: 12)),
                          const Spacer(),
                          IconButton(
                            tooltip: _t(context, 'فوق', 'Up'),
                            icon: const Icon(Icons.arrow_upward_rounded),
                            onPressed: i == 0
                                ? null
                                : () => _run(context, ref, () async {
                                      await db.from('banners').update({'sort_order': i - 1}).eq('id', b['id']);
                                      await db.from('banners').update({'sort_order': i}).eq('id', rows[i - 1]['id']);
                                    }),
                          ),
                          IconButton(
                            tooltip: _t(context, 'تحت', 'Down'),
                            icon: const Icon(Icons.arrow_downward_rounded),
                            onPressed: i == rows.length - 1
                                ? null
                                : () => _run(context, ref, () async {
                                      await db.from('banners').update({'sort_order': i + 1}).eq('id', b['id']);
                                      await db.from('banners').update({'sort_order': i}).eq('id', rows[i + 1]['id']);
                                    }),
                          ),
                          Switch(value: active, onChanged: (v) => _run(context, ref, () async => db.from('banners').update({'is_active': v}).eq('id', b['id']))),
                          IconButton(tooltip: _t(context, 'تعديل', 'Edit'), icon: const Icon(Icons.edit_rounded), onPressed: () => _edit(context, ref, b)),
                          IconButton(
                            tooltip: _t(context, 'حذف', 'Delete'),
                            icon: const Icon(Icons.delete_outline_rounded, color: BrandColors.error),
                            onPressed: () async {
                              final ok = await showDialog<bool>(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  title: Text(_t(ctx, 'حذف البانر؟', 'Delete this banner?')),
                                  content: Text(_t(ctx, 'هيختفي من تطبيق العملا نهائي.', 'It disappears from the customer app for good.')),
                                  actions: [
                                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(_t(ctx, 'إلغاء', 'Cancel'))),
                                    FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(_t(ctx, 'حذف', 'Delete'))),
                                  ],
                                ),
                              );
                              if (ok == true && context.mounted) await _run(context, ref, () async => db.from('banners').delete().eq('id', b['id']));
                            },
                          ),
                        ]),
                      ]),
                    ),
                  );
                },
              ),
      ),
    );
  }
}

class _BannerForm extends ConsumerStatefulWidget {
  const _BannerForm({this.row});
  final Map<String, dynamic>? row;
  @override
  ConsumerState<_BannerForm> createState() => _BannerFormState();
}

class _BannerFormState extends ConsumerState<_BannerForm> {
  late String _style = (widget.row?['style'] ?? 'gradient').toString();
  late String _color = (widget.row?['color'] ?? 'blue').toString();
  late String _link = (widget.row?['link_type'] ?? '').toString();
  late String? _linkValue = widget.row?['link_value'] as String?;
  late bool _active = widget.row?['is_active'] != false;
  late List<String> _pids = [for (final e in (widget.row?['product_ids'] as List? ?? const [])) '$e'];
  DateTime? _from, _to;
  Uint8List? _img;
  bool _busy = false;
  late final Map<String, TextEditingController> _c = {
    for (final k in ['title_ar', 'title_en', 'subtitle_ar', 'subtitle_en', 'cta_ar', 'cta_en', 'badge', 'emoji', 'price_text', 'old_price_text'])
      k: TextEditingController(text: (widget.row?[k] ?? '').toString()),
  };

  @override
  void initState() {
    super.initState();
    _from = DateTime.tryParse('${widget.row?['starts_at'] ?? ''}')?.toLocal();
    _to = DateTime.tryParse('${widget.row?['ends_at'] ?? ''}')?.toLocal();
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, dynamic> get _preview => {
        for (final e in _c.entries) e.key: e.value.text.trim(),
        'style': _style,
        'color': _color,
        'image_path': widget.row?['image_path'],
      };

  Future<void> _pickImage() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 85, maxWidth: _style == 'image' ? 1200 : 600);
    if (x == null) return;
    final b = await x.readAsBytes();
    if (mounted) setState(() => _img = b);
  }

  Future<void> _addProduct(List<Map<String, dynamic>> products) async {
    final q = TextEditingController();
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        final t = q.text.trim().toLowerCase();
        final list = [for (final p in products) if (!_pids.contains(p['id']) && (t.isEmpty || '${p['name_ar']} ${p['name_en']}'.toLowerCase().contains(t))) p].take(60).toList();
        return AlertDialog(
          title: Text(_t(ctx, 'اختار منتج', 'Pick a product')),
          content: SizedBox(
            width: 420,
            height: 420,
            child: Column(children: [
              TextField(controller: q, autofocus: true, onChanged: (_) => set(() {}), decoration: InputDecoration(prefixIcon: const Icon(Icons.search_rounded), hintText: _t(ctx, 'ابحث بالاسم', 'Search by name'))),
              const SizedBox(height: 8),
              Expanded(child: ListView(children: [for (final p in list) ListTile(dense: true, title: Text(ctx.pick(p, 'name'), maxLines: 2, overflow: TextOverflow.ellipsis), onTap: () => Navigator.pop(ctx, p['id'] as String))])),
            ]),
          ),
        );
      }),
    );
    disposeLater(q);
    if (picked != null && _pids.length < 10) setState(() => _pids.add(picked));
  }

  Future<void> _date(bool from) async {
    final now = DateTime.now();
    final d = await showDatePicker(context: context, initialDate: (from ? _from : _to) ?? now, firstDate: DateTime(now.year - 1), lastDate: DateTime(now.year + 3));
    if (d == null) return;
    setState(() => from ? _from = DateTime(d.year, d.month, d.day) : _to = DateTime(d.year, d.month, d.day, 23, 59));
  }

  Future<void> _save() async {
    final ar = _c['title_ar']!.text.trim();
    if (ar.isEmpty) {
      showSnack(context, _t(context, 'اكتب عنوان البانر بالعربي', 'Write the banner title in Arabic'), error: true);
      return;
    }
    final needsPic = _style == 'image';
    if (needsPic && _img == null && (widget.row?['image_path'] ?? '').toString().isEmpty) {
      showSnack(context, _t(context, 'اختار صورة البانر', 'Pick the banner picture'), error: true);
      return;
    }
    if ((_link == 'product' || _link == 'category') && _linkValue == null) {
      showSnack(context, _t(context, 'اختار اللي البانر يفتحه', 'Pick what the banner opens'), error: true);
      return;
    }
    if (_from != null && _to != null && _to!.isBefore(_from!)) {
      showSnack(context, _t(context, 'تاريخ النهاية قبل البداية', 'End date is before the start'), error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      final db = ref.read(supabaseProvider);
      String? path = widget.row?['image_path'] as String?;
      if (_img != null) {
        path = 'app/${DateTime.now().microsecondsSinceEpoch}.jpg';
        await db.storage.from('banners').uploadBinary(path, _img!, fileOptions: const FileOptions(contentType: 'image/jpeg'));
      }
      String? n(String k) => _c[k]!.text.trim().isEmpty ? null : _c[k]!.text.trim();
      final data = {
        'style': _style,
        'color': _color,
        'title_ar': ar,
        'title_en': n('title_en') ?? ar,
        'subtitle_ar': n('subtitle_ar'),
        'subtitle_en': n('subtitle_en') ?? n('subtitle_ar'),
        'cta_ar': n('cta_ar'),
        'cta_en': n('cta_en') ?? n('cta_ar'),
        'badge': n('badge'),
        'emoji': n('emoji'),
        'price_text': n('price_text'),
        'old_price_text': n('old_price_text'),
        'image_path': (_style == 'image' || _style == 'product') ? path : null,
        'product_ids': _style == 'product' ? _pids : <String>[],
        'link_type': _link.isEmpty ? null : _link,
        'link_value': (_link == 'product' || _link == 'category') ? _linkValue : null,
        'is_active': _active,
        'starts_at': _from?.toUtc().toIso8601String(),
        'ends_at': _to?.toUtc().toIso8601String(),
      };
      if (widget.row == null) {
        final last = (await db.from('banners').select('sort_order').order('sort_order', ascending: false).limit(1)) as List;
        await db.from('banners').insert({...data, 'sort_order': last.isEmpty ? 0 : ((last.first['sort_order'] as int?) ?? 0) + 1});
      } else {
        await db.from('banners').update(data).eq('id', widget.row!['id']);
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showSnack(context, friendlyError(context, e), error: true);
      }
    }
  }

  Widget _f(String k, String ar, String en, {int max = 80, TextInputType? type}) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextField(
          controller: _c[k],
          maxLength: max,
          keyboardType: type,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(labelText: _t(context, ar, en), counterText: ''),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final products = ref.watch(_bannerProductsProvider).valueOrNull ?? const [];
    final cats = ref.watch(_bannerCategoriesProvider).valueOrNull ?? const [];
    final pic = _style == 'image' || _style == 'product';
    final fmt = (DateTime? d) => d == null ? _t(context, 'من غير', 'None') : '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), children: [
        Text(widget.row == null ? _t(context, 'بانر جديد', 'New banner') : _t(context, 'تعديل البانر', 'Edit banner'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        const SizedBox(height: 10),
        // live preview
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: panelColor(context), borderRadius: BorderRadius.circular(16), border: Border.all(color: panelLine(context))),
          child: Column(children: [
            Text(_t(context, 'معاينة (زي ما هتظهر للعميل)', 'Preview (as customers see it)'), style: const TextStyle(color: BrandColors.gray, fontSize: 12)),
            const SizedBox(height: 8),
            if (_img != null && pic)
              ClipRRect(borderRadius: BorderRadius.circular(18), child: SizedBox(height: _style == 'image' ? 160 : 96, width: double.infinity, child: Image.memory(_img!, fit: BoxFit.cover)))
            else
              IgnorePointer(child: AppBannerCard(banner: _preview, onTap: () {})),
          ]),
        ),
        const SizedBox(height: 12),
        Text(_t(context, 'الشكل', 'Look'), style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Wrap(spacing: 8, children: [
          for (final s in bannerStyles)
            ChoiceChip(label: Text(_t(context, _styleAr(s), _styleEn(s))), selected: _style == s, onSelected: (_) => setState(() {
                  _style = s;
                  _img = null;
                })),
        ]),
        const SizedBox(height: 12),
        _f('title_ar', 'العنوان (عربي)', 'Title (Arabic)'),
        _f('title_en', 'العنوان (إنجليزي) - اختياري', 'Title (English) - optional'),
        if (_style != 'image') ...[
          _f('subtitle_ar', 'سطر تحته (عربي)', 'Sub line (Arabic)', max: 120),
          _f('subtitle_en', 'سطر تحته (إنجليزي)', 'Sub line (English)', max: 120),
          if (_style != 'product') ...[
            _f('cta_ar', 'كلمة الزر (عربي)', 'Button word (Arabic)', max: 20),
            _f('cta_en', 'كلمة الزر (إنجليزي)', 'Button word (English)', max: 20),
          ],
          _f('emoji', 'إيموجي (🔥 🎁 📱)', 'Emoji (🔥 🎁 📱)', max: 8),
        ],
        if (_style == 'product') ...[
          Text(_t(context, 'المنتجات (كل منتج سلايد، والضغط عليه يفتح المنتج فورًا)', 'Products (one slide each; tapping opens the product)'), style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 6, children: [
            for (final id in _pids)
              InputChip(
                label: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 200), child: Text(context.pick(products.firstWhere((e) => e['id'] == id, orElse: () => {'name_ar': '؟'}), 'name'), overflow: TextOverflow.ellipsis)),
                onDeleted: () => setState(() => _pids.remove(id)),
              ),
            if (_pids.length < 10) ActionChip(avatar: const Icon(Icons.add_rounded, size: 18), label: Text(_t(context, 'أضف منتج', 'Add product')), onPressed: () => _addProduct(products)),
          ]),
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 10),
            child: Text(_t(context, 'الاسم والسعر والخصم والصورة بتتسحب من المنتج نفسه وتتحدث لوحدها. لو سيبتها فاضية هيظهر البانر اللي بتكتبه تحت.', 'Name, price, discount and photo come from the product and stay up to date. If empty, the banner you type below is shown.'),
                style: const TextStyle(fontSize: 12, color: BrandColors.gray, height: 1.5)),
          ),
          _f('badge', 'الشارة (مثلًا -25%)', 'Badge (e.g. -25%)', max: 12),
          Row(children: [
            Expanded(child: _f('price_text', 'السعر بعد الخصم', 'Price now', max: 20)),
            const SizedBox(width: 10),
            Expanded(child: _f('old_price_text', 'السعر قبل', 'Old price', max: 20)),
          ]),
        ],
        if (_style != 'image' && _style != 'product') ...[
          Text(_t(context, 'اللون', 'Colour'), style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 6, children: [
            for (final c in bannerColors)
              ChoiceChip(
                avatar: CircleAvatar(radius: 8, backgroundColor: bannerGradient(c).last),
                label: Text(_t(context, _colorAr(c), _colorEn(c))),
                selected: _color == c,
                onSelected: (_) => setState(() => _color = c),
              ),
          ]),
          const SizedBox(height: 12),
        ],
        if (pic) ...[
          OutlinedButton.icon(
            onPressed: _busy ? null : _pickImage,
            icon: const Icon(Icons.add_photo_alternate_outlined),
            label: Text(_img != null || (widget.row?['image_path'] ?? '').toString().isNotEmpty ? _t(context, 'غيّر الصورة', 'Change picture') : _t(context, 'اختار صورة', 'Pick a picture')),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 12),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.straighten_rounded, size: 18, color: BrandColors.electric),
              const SizedBox(width: 6),
              Expanded(child: Text(imageSizeHint(context, _style), style: const TextStyle(fontSize: 12, height: 1.5, color: BrandColors.gray))),
            ]),
          ),
        ],
        if (_style != 'product' || _pids.isEmpty) ...[
        Text(_t(context, 'لما العميل يدوس عليه يفتح', 'When tapped it opens'), style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Wrap(spacing: 8, children: [
          for (final (k, ar, en) in const [('', 'مفيش', 'Nothing'), ('product', 'منتج', 'Product'), ('category', 'قسم', 'Category'), ('repair', 'طلب صيانة', 'Repair request'), ('wheel', 'عجلة الحظ', 'Lucky wheel')])
            ChoiceChip(label: Text(_t(context, ar, en)), selected: _link == k, onSelected: (_) => setState(() {
                  _link = k;
                  _linkValue = null;
                })),
        ]),
        if (_link == 'product' || _link == 'category')
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: DropdownButtonFormField<String>(
              initialValue: ((_link == 'product' ? products : cats).any((e) => e['id'] == _linkValue)) ? _linkValue : null,
              isExpanded: true,
              decoration: InputDecoration(labelText: _link == 'product' ? _t(context, 'المنتج', 'Product') : _t(context, 'القسم', 'Category')),
              items: [for (final e in (_link == 'product' ? products : cats)) DropdownMenuItem(value: e['id'] as String, child: Text(context.pick(e, 'name'), overflow: TextOverflow.ellipsis))],
              onChanged: (v) => setState(() => _linkValue = v),
            ),
          ),
        ],
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: OutlinedButton(onPressed: () => _date(true), child: Text('${_t(context, 'يبدأ', 'Starts')}: ${fmt(_from)}'))),
          if (_from != null) IconButton(onPressed: () => setState(() => _from = null), icon: const Icon(Icons.close_rounded, size: 18)),
          const SizedBox(width: 8),
          Expanded(child: OutlinedButton(onPressed: () => _date(false), child: Text('${_t(context, 'ينتهي', 'Ends')}: ${fmt(_to)}'))),
          if (_to != null) IconButton(onPressed: () => setState(() => _to = null), icon: const Icon(Icons.close_rounded, size: 18)),
        ]),
        SwitchListTile(contentPadding: EdgeInsets.zero, value: _active, onChanged: (v) => setState(() => _active = v), title: Text(_t(context, 'ظاهر للعملا', 'Visible to customers'))),
        const SizedBox(height: 4),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: _busy ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2)) : Text(_t(context, 'حفظ', 'Save')),
        ),
      ]),
    );
  }
}
