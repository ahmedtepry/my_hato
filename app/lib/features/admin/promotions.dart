// Offers & discount codes: create codes, and send an offer notification (optionally with a code)
// that lands in every customer's notifications; tapping it opens the cart with the code ready.
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/money.dart';
import '../../core/theme.dart';
import '../../shared/states.dart';
import 'admin_repository.dart';

String _t(BuildContext c, String ar, String en) => c.isAr ? ar : en;

final _couponsProvider = FutureProvider.autoDispose((ref) => ref.watch(adminRepoProvider).coupons());

void openPromotions(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PromotionsScreen()));

String couponValueLabel(BuildContext context, Map<String, dynamic> c) {
  final p = c['percent_off'] as num?;
  if (p != null) return _t(context, 'خصم ${p.toInt()}%', '${p.toInt()}% off');
  return _t(context, 'خصم ${formatEgp((c['amount_off_minor'] as num).toInt(), 'ar')}', '${formatEgp((c['amount_off_minor'] as num).toInt(), 'en')} off');
}

bool _isLive(Map<String, dynamic> c) {
  final ends = c['ends_at'] as String?;
  final max = c['max_uses'] as num?;
  return c['is_active'] == true &&
      (ends == null || DateTime.parse(ends).isAfter(DateTime.now())) &&
      (max == null || (c['uses_count'] as num) < max);
}

class PromotionsScreen extends ConsumerWidget {
  const PromotionsScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(_couponsProvider);
    return Scaffold(
      appBar: AppBar(title: Text(_t(context, 'العروض وأكواد الخصم', 'Offers & codes'))),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _editCoupon(context, ref, null),
        icon: const Icon(Icons.add_rounded),
        label: Text(_t(context, 'كود جديد', 'New code')),
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(_couponsProvider),
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 96), children: [
          // send offer hero
          Material(
            borderRadius: BorderRadius.circular(20),
            clipBehavior: Clip.antiAlias,
            child: Ink(
              decoration: const BoxDecoration(
                gradient: LinearGradient(colors: [BrandColors.navy, Color(0xFF1C5FB8)], begin: Alignment.topRight, end: Alignment.bottomLeft),
              ),
              child: InkWell(
                onTap: () => _sendOffer(context, ref, null),
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Row(children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.15), shape: BoxShape.circle),
                      child: const Icon(Icons.campaign_rounded, color: Colors.white, size: 28),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(_t(context, 'ابعت عرض للعملاء', 'Send an offer'),
                            style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w800)),
                        const SizedBox(height: 3),
                        Text(_t(context, 'إشعار يوصل لكل العملاء في التطبيق، ومعاه كود خصم لو حابب', 'A notification to every customer, with a code if you like'),
                            style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 12.5)),
                      ]),
                    ),
                    const Icon(Icons.chevron_left_rounded, color: Colors.white),
                  ]),
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text(_t(context, 'أكواد الخصم', 'Discount codes'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          data.when(
            loading: () => const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())),
            error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(_couponsProvider)),
            data: (list) => list.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 40),
                    child: Column(children: [
                      const Icon(Icons.local_offer_outlined, size: 44, color: BrandColors.gray),
                      const SizedBox(height: 8),
                      Text(_t(context, 'لسه مفيش أكواد. اعمل أول كود من الزرار تحت.', 'No codes yet. Create one below.')),
                    ]),
                  )
                : Column(children: [for (final c in list) _CouponTile(coupon: c)]),
          ),
        ]),
      ),
    );
  }
}

class _CouponTile extends ConsumerWidget {
  const _CouponTile({required this.coupon});
  final Map<String, dynamic> coupon;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = coupon;
    final live = _isLive(c);
    final max = c['max_uses'] as num?;
    final ends = c['ends_at'] as String?;
    final min = (c['min_order_minor'] as num).toInt();
    final details = <String>[
      '${_t(context, 'استُخدم', 'Used')} ${c['uses_count']}${max == null ? '' : ' / $max'}',
      if (min > 0) '${_t(context, 'أقل طلب', 'Min')} ${formatEgp(min, context.lang)}',
      if (ends != null) '${_t(context, 'لحد', 'Until')} ${MaterialLocalizations.of(context).formatShortDate(DateTime.parse(ends).toLocal())}',
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: Colors.white,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: BrandColors.border)),
        child: InkWell(
          onTap: () => _editCoupon(context, ref, c),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: (live ? BrandColors.success : BrandColors.gray).withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: (live ? BrandColors.success : BrandColors.gray).withValues(alpha: 0.4)),
                  ),
                  child: Text(c['code'] as String,
                      textDirection: TextDirection.ltr,
                      style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1.2, color: live ? BrandColors.success : BrandColors.gray)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(couponValueLabel(context, c), style: const TextStyle(fontWeight: FontWeight.w800)),
                    if ((c['title_ar'] as String?) != null)
                      Text(c['title_ar'] as String, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: BrandColors.gray)),
                  ]),
                ),
                Text(live ? _t(context, 'شغال', 'Live') : _t(context, 'متوقف', 'Off'),
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: live ? BrandColors.success : BrandColors.gray)),
              ]),
              const SizedBox(height: 8),
              Text(details.join('  •  '), style: const TextStyle(fontSize: 12, color: BrandColors.gray)),
              const SizedBox(height: 6),
              Row(children: [
                TextButton.icon(
                  icon: const Icon(Icons.copy_rounded, size: 16),
                  label: Text(_t(context, 'نسخ', 'Copy')),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: c['code'] as String));
                    showSnack(context, _t(context, 'اتنسخ الكود', 'Code copied'));
                  },
                ),
                const Spacer(),
                if (live)
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.send_rounded, size: 16),
                    label: Text(_t(context, 'ابعته للعملاء', 'Send to customers')),
                    onPressed: () => _sendOffer(context, ref, c),
                  ),
              ]),
            ]),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- create / edit a code
Future<void> _editCoupon(BuildContext context, WidgetRef ref, Map<String, dynamic>? c) async {
  final saved = await showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (_) => _CouponForm(coupon: c),
  );
  if (saved == null || !context.mounted) return;
  ref.invalidate(_couponsProvider);
  if (c == null && saved['is_active'] == true) {
    final send = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(_t(context, 'الكود ${saved['code']} جاهز 🎉', 'Code ${saved['code']} is ready 🎉')),
        content: Text(_t(context, 'تحب تبعته للعملاء دلوقتي في إشعار؟', 'Send it to customers now as a notification?')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(_t(context, 'بعدين', 'Later'))),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(_t(context, 'ابعته', 'Send'))),
        ],
      ),
    );
    if (send == true && context.mounted) await _sendOffer(context, ref, saved);
  }
}

class _CouponForm extends ConsumerStatefulWidget {
  const _CouponForm({this.coupon});
  final Map<String, dynamic>? coupon;
  @override
  ConsumerState<_CouponForm> createState() => _CouponFormState();
}

class _CouponFormState extends ConsumerState<_CouponForm> {
  final _form = GlobalKey<FormState>();
  late final _code = TextEditingController(text: widget.coupon?['code'] as String? ?? _generate());
  late final _title = TextEditingController(text: widget.coupon?['title_ar'] as String? ?? '');
  late final _value = TextEditingController(
      text: widget.coupon == null
          ? '10'
          : (widget.coupon!['percent_off'] as num?)?.toInt().toString() ?? ((widget.coupon!['amount_off_minor'] as num) / 100).round().toString());
  late final _min = TextEditingController(text: widget.coupon == null ? '' : _egp(widget.coupon!['min_order_minor']));
  late final _maxUses = TextEditingController(text: (widget.coupon?['max_uses'] as num?)?.toString() ?? '');
  late final _perCustomer = TextEditingController(text: (widget.coupon?['per_customer_limit'] as num?)?.toString() ?? '1');
  late bool _percent = widget.coupon == null || widget.coupon!['percent_off'] != null;
  late bool _active = widget.coupon?['is_active'] as bool? ?? true;
  late DateTime? _ends = widget.coupon == null
      ? DateTime.now().add(const Duration(days: 7))
      : (widget.coupon!['ends_at'] == null ? null : DateTime.parse(widget.coupon!['ends_at'] as String).toLocal());
  bool _saving = false;

  bool get _editing => widget.coupon != null;

  static String _egp(Object? minor) {
    final v = ((minor as num?) ?? 0).toInt();
    return v == 0 ? '' : (v / 100).round().toString();
  }

  static String _generate() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final r = Random.secure();
    return 'HATO${List.generate(4, (_) => chars[r.nextInt(chars.length)]).join()}';
  }

  int? _int(String s) => int.tryParse(s.trim().replaceAllMapped(RegExp('[٠-٩]'), (m) => '${m[0]!.codeUnitAt(0) - 0x0660}'));

  @override
  void dispose() {
    for (final c in [_code, _title, _value, _min, _maxUses, _perCustomer]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final v = _int(_value.text)!;
      final code = await ref.read(adminRepoProvider).saveCoupon(
            code: _code.text,
            title: _title.text.trim().isEmpty ? null : _title.text.trim(),
            percentOff: _percent ? v : null,
            amountOffMinor: _percent ? null : v * 100,
            minOrderMinor: (_int(_min.text) ?? 0) * 100,
            maxUses: _int(_maxUses.text),
            perCustomer: _int(_perCustomer.text) ?? 1,
            endsAt: _ends == null ? null : DateTime(_ends!.year, _ends!.month, _ends!.day, 23, 59),
            active: _active,
          );
      if (!mounted) return;
      Navigator.pop(context, {
        'code': code,
        'is_active': _active,
        'percent_off': _percent ? v : null,
        'amount_off_minor': _percent ? null : v * 100,
        'title_ar': _title.text.trim(),
      });
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(context, e), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    String? required(String? s) => (s == null || s.trim().isEmpty) ? _t(context, 'مطلوب', 'Required') : null;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.viewInsetsOf(context).bottom + 20),
      child: Form(
        key: _form,
        child: ListView(shrinkWrap: true, children: [
          Text(_editing ? _t(context, 'تعديل الكود', 'Edit code') : _t(context, 'كود خصم جديد', 'New discount code'),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 14),
          TextFormField(
            controller: _code,
            enabled: !_editing,
            textDirection: TextDirection.ltr,
            textCapitalization: TextCapitalization.characters,
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp('[A-Za-z0-9_-]')), LengthLimitingTextInputFormatter(24)],
            decoration: InputDecoration(
              labelText: _t(context, 'الكود', 'Code'),
              helperText: _t(context, 'حروف إنجليزي وأرقام (٣ لـ ٢٤)', 'Letters and digits (3–24)'),
              suffixIcon: _editing
                  ? null
                  : IconButton(
                      tooltip: _t(context, 'كود عشوائي', 'Random'),
                      icon: const Icon(Icons.casino_outlined),
                      onPressed: () => setState(() => _code.text = _generate()),
                    ),
            ),
            validator: (s) => (s == null || s.trim().length < 3) ? _t(context, '٣ حروف على الأقل', 'At least 3 characters') : null,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _title,
            decoration: InputDecoration(labelText: _t(context, 'وصف داخلي (اختياري)', 'Label (optional)'), hintText: _t(context, 'مثلاً: عرض الجمعة', 'e.g. Friday offer')),
          ),
          const SizedBox(height: 14),
          SegmentedButton<bool>(
            segments: [
              ButtonSegment(value: true, icon: const Icon(Icons.percent_rounded), label: Text(_t(context, 'نسبة %', 'Percent'))),
              ButtonSegment(value: false, icon: const Icon(Icons.payments_outlined), label: Text(_t(context, 'مبلغ ثابت', 'Fixed amount'))),
            ],
            selected: {_percent},
            onSelectionChanged: (s) => setState(() => _percent = s.first),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _value,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: _percent ? _t(context, 'نسبة الخصم', 'Percent off') : _t(context, 'قيمة الخصم', 'Amount off'),
              suffixText: _percent ? '%' : _t(context, 'ج.م', 'EGP'),
            ),
            validator: (s) {
              final v = _int(s ?? '');
              if (v == null || v <= 0) return _t(context, 'رقم أكبر من صفر', 'A number above zero');
              if (_percent && v > 90) return _t(context, 'أقصى نسبة 90%', 'Max 90%');
              return null;
            },
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: TextFormField(
                controller: _min,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: _t(context, 'أقل قيمة طلب', 'Min order'), suffixText: _t(context, 'ج.م', 'EGP')),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextFormField(
                controller: _maxUses,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: _t(context, 'عدد مرات الاستخدام', 'Total uses'), hintText: _t(context, 'مفتوح', 'Unlimited')),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          TextFormField(
            controller: _perCustomer,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: _t(context, 'مرات لكل عميل', 'Uses per customer')),
            validator: required,
          ),
          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.event_outlined),
            title: Text(_t(context, 'ينتهي في', 'Ends')),
            subtitle: Text(_ends == null ? _t(context, 'من غير تاريخ انتهاء', 'No end date') : MaterialLocalizations.of(context).formatFullDate(_ends!)),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              if (_ends != null) IconButton(icon: const Icon(Icons.close_rounded), onPressed: () => setState(() => _ends = null)),
              const Icon(Icons.edit_calendar_outlined),
            ]),
            onTap: () async {
              final d = await showDatePicker(
                context: context,
                initialDate: _ends ?? DateTime.now().add(const Duration(days: 7)),
                firstDate: DateTime.now(),
                lastDate: DateTime.now().add(const Duration(days: 365)),
              );
              if (d != null) setState(() => _ends = d);
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(_t(context, 'الكود شغال', 'Active')),
            value: _active,
            onChanged: (v) => setState(() => _active = v),
          ),
          const SizedBox(height: 8),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white))
                : Text(_t(context, 'حفظ', 'Save')),
          ),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------- send an offer
Future<void> _sendOffer(BuildContext context, WidgetRef ref, Map<String, dynamic>? coupon) async {
  final n = await showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (_) => _OfferComposer(coupon: coupon),
  );
  if (n != null && context.mounted) {
    showSnack(context, _t(context, 'العرض وصل لـ $n عميل 🎉', 'Offer sent to $n customers 🎉'));
  }
}

class _OfferComposer extends ConsumerStatefulWidget {
  const _OfferComposer({this.coupon});
  final Map<String, dynamic>? coupon;
  @override
  ConsumerState<_OfferComposer> createState() => _OfferComposerState();
}

class _OfferComposerState extends ConsumerState<_OfferComposer> {
  late final _title = TextEditingController();
  late final _body = TextEditingController();
  String? _code;
  bool _sending = false;
  Uint8List? _image; // optional picture sent with the offer

  Future<void> _pickImage() async {
    try {
      final x = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 80, maxWidth: 1200);
      if (x == null) return;
      final bytes = await x.readAsBytes();
      if (bytes.lengthInBytes > 5 * 1024 * 1024) {
        if (mounted) showSnack(context, _t(context, 'الصورة كبيرة، اختار صورة أصغر من ٥ ميجا', 'Picture too large, pick one under 5 MB'), error: true);
        return;
      }
      if (mounted) setState(() => _image = bytes);
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(context, e), error: true);
    }
  }

  @override
  void initState() {
    super.initState();
    _code = widget.coupon?['code'] as String?;
    if (widget.coupon != null) _fillFor(widget.coupon!);
  }

  void _fillFor(Map<String, dynamic> c) {
    final p = c['percent_off'] as num?;
    final v = p != null ? '${p.toInt()}%' : formatEgp((c['amount_off_minor'] as num).toInt(), 'ar');
    _title.text = '🎁 خصم $v مستنيك!';
    _body.text = 'استخدم الكود ${c['code']} عند الدفع ووفّر $v على طلبك من My Hatō. العرض لفترة محدودة ⏳';
  }

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_title.text.trim().isEmpty || _body.text.trim().isEmpty) {
      showSnack(context, _t(context, 'اكتب عنوان ونص العرض', 'Write a title and a message'), error: true);
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(_t(context, 'إرسال لكل العملاء؟', 'Send to all customers?')),
        content: Text(_t(
            context,
            'الإشعار هيوصل لكل العملاء في التطبيق، وهيختفي من عندهم لوحده بعد نص ساعة. (أقصى ٥ عروض في اليوم)',
            'Every customer will get this notification and it disappears by itself after 30 minutes. (Max 5 offers a day)')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(_t(context, 'رجوع', 'Back'))),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(_t(context, 'ابعت', 'Send'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _sending = true);
    try {
      final repo = ref.read(adminRepoProvider);
      final imageUrl = _image == null ? null : await repo.uploadOfferImage(_image!);
      final n = await repo.broadcastOffer(title: _title.text, body: _body.text, couponCode: _code, imageUrl: imageUrl);
      if (mounted) Navigator.pop(context, n);
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(context, e), error: true);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final coupons = ref.watch(_couponsProvider).valueOrNull?.where(_isLive).toList() ?? const <Map<String, dynamic>>[];
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.viewInsetsOf(context).bottom + 20),
      child: ListView(shrinkWrap: true, children: [
        Text(_t(context, 'عرض جديد للعملاء', 'New offer'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        const SizedBox(height: 14),
        DropdownButtonFormField<String?>(
          value: coupons.any((c) => c['code'] == _code) ? _code : null,
          decoration: InputDecoration(labelText: _t(context, 'كود الخصم', 'Discount code'), prefixIcon: const Icon(Icons.local_offer_outlined)),
          items: [
            DropdownMenuItem(value: null, child: Text(_t(context, 'من غير كود (إعلان بس)', 'No code (announcement)'))),
            for (final c in coupons)
              DropdownMenuItem(value: c['code'] as String, child: Text('${c['code']} — ${couponValueLabel(context, c)}')),
          ],
          onChanged: (v) => setState(() {
            _code = v;
            final c = coupons.where((x) => x['code'] == v).firstOrNull;
            if (c != null) _fillFor(c);
          }),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _title,
          maxLength: 120,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(labelText: _t(context, 'العنوان', 'Title')),
        ),
        TextField(
          controller: _body,
          maxLength: 500,
          minLines: 3,
          maxLines: 5,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(labelText: _t(context, 'نص العرض', 'Message')),
        ),
        const SizedBox(height: 8),
        if (_image == null)
          OutlinedButton.icon(
            onPressed: _sending ? null : _pickImage,
            icon: const Icon(Icons.add_photo_alternate_outlined),
            label: Text(_t(context, 'إضافة صورة (اختياري)', 'Add a picture (optional)')),
          )
        else
          Row(children: [
            ClipRRect(borderRadius: BorderRadius.circular(10), child: Image.memory(_image!, width: 56, height: 56, fit: BoxFit.cover)),
            const SizedBox(width: 10),
            Expanded(child: Text(_t(context, 'الصورة هتظهر مع العرض', 'The picture is sent with the offer'))),
            TextButton(onPressed: _sending ? null : _pickImage, child: Text(_t(context, 'غيّر', 'Change'))),
            IconButton(
              tooltip: _t(context, 'شيل الصورة', 'Remove picture'),
              onPressed: _sending ? null : () => setState(() => _image = null),
              icon: const Icon(Icons.close_rounded),
            ),
          ]),
        const SizedBox(height: 12),
        Text(_t(context, 'شكل الإشعار عند العميل', 'Preview'), style: const TextStyle(fontSize: 12.5, color: BrandColors.gray, fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: BrandColors.offWhite,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: BrandColors.border),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: BrandColors.navy.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(10)),
              child: const Icon(Icons.local_offer_rounded, color: BrandColors.navy, size: 20),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(_title.text.isEmpty ? '…' : _title.text, style: const TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(height: 2),
                Text(_body.text.isEmpty ? '…' : _body.text, style: const TextStyle(fontSize: 13)),
                if (_image != null) ...[
                  const SizedBox(height: 8),
                  ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.memory(_image!, height: 130, width: double.infinity, fit: BoxFit.cover)),
                ],
                const SizedBox(height: 6),
                Text(_t(context, 'بيختفي من عند العميل بعد نص ساعة', 'Disappears from the customer after 30 minutes'),
                    style: const TextStyle(fontSize: 11.5, color: BrandColors.gray)),
                if (_code != null) ...[
                  const SizedBox(height: 6),
                  Text(_t(context, 'لما يدوس عليه: السلة تفتح والكود يتطبق لوحده ✨', 'Tapping it opens the cart with the code applied ✨'),
                      style: const TextStyle(fontSize: 11.5, color: BrandColors.success, fontWeight: FontWeight.w700)),
                ],
              ]),
            ),
          ]),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
          icon: _sending
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white))
              : const Icon(Icons.send_rounded),
          label: Text(_t(context, 'ابعت لكل العملاء', 'Send to all customers')),
          onPressed: _sending ? null : _send,
        ),
      ]),
    );
  }
}
