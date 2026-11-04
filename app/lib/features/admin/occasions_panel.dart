import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../../core/appearance.dart';
import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/theme.dart';
import '../../shared/occasion_stamp.dart';
import '../../shared/states.dart';
import 'admin_repository.dart';
import '../../shared/motion.dart';

String _t(BuildContext c, String ar, String en) => c.isAr ? ar : en;

class _Occasion {
  const _Occasion(this.key, this.ar, this.en, this.icon, this.dates, this.codeBase, this.titleAr, this.bodyAr);
  final String key, ar, en, codeBase, titleAr, bodyAr;
  final IconData icon;
  final List<DateTime> dates; // expected start dates (lunar ones are confirmed by moon sighting, so the owner starts it on the real day)
}

final _occasions = <_Occasion>[
  _Occasion('ramadan', 'رمضان', 'Ramadan', Icons.nightlight_round, [DateTime(2027, 2, 8), DateTime(2028, 1, 28), DateTime(2029, 1, 16), DateTime(2030, 1, 5)], 'RAMADAN',
      'رمضان كريم من My Hatō 🌙', 'كل سنة وإنت طيب. بمناسبة حلول الشهر المبارك، جهّزنالك مفاجأة جوه التطبيق.'),
  _Occasion('fitr', 'عيد الفطر', 'Eid al-Fitr', Icons.celebration_outlined, [DateTime(2027, 3, 10), DateTime(2028, 2, 26), DateTime(2029, 2, 14), DateTime(2030, 2, 4)], 'FITR',
      'عيد فطر سعيد من My Hatō 🎉', 'كل سنة وإنت طيب وعيدك مبارك. هديتنا ليك بمناسبة العيد جوه التطبيق.'),
  _Occasion('adha', 'عيد الأضحى', 'Eid al-Adha', Icons.star_outline_rounded, [DateTime(2027, 5, 17), DateTime(2028, 5, 5), DateTime(2029, 4, 24), DateTime(2030, 4, 13)], 'ADHA',
      'عيد أضحى مبارك من My Hatō 🌙', 'كل عام وأنت بخير. عيد أضحى مبارك عليك وعلى أسرتك، ولينا معاك هدية جوه التطبيق.'),
  _Occasion('oct6', '٦ أكتوبر', '6 October', Icons.flag_outlined, [DateTime(2026, 10, 6), DateTime(2027, 10, 6), DateTime(2028, 10, 6), DateTime(2029, 10, 6), DateTime(2030, 10, 6)], 'OCT',
      'كل سنة ومصر بخير 🇪🇬', 'بمناسبة ذكرى نصر ٦ أكتوبر، كل سنة وإنت طيب. حبينا نفرّحك بهدية جوه التطبيق.'),
];

DateTime _next(_Occasion o) {
  final from = DateTime.now().subtract(const Duration(days: 30));
  return o.dates.firstWhere((d) => d.isAfter(from), orElse: () => o.dates.last);
}

String _stampName(BuildContext c, String k) => switch (k) {
      'crescent' => _t(c, 'هلال', 'Crescent'),
      'crescent_star' => _t(c, 'هلال ونجمة', 'Crescent and star'),
      'lantern' => _t(c, 'فانوس', 'Lantern'),
      'both' => _t(c, 'هلال وفانوس', 'Crescent and lantern'),
      'stars' => _t(c, 'نجوم العيد', 'Eid stars'),
      'flag' => _t(c, 'شريط العلم', 'Flag ribbon'),
      'bunting' => _t(c, 'رايات', 'Bunting'),
      _ => _t(c, 'نجمة', 'Star'),
    };

/// Owner's "Occasions" page: put the occasion stamp on the logo for every customer, then send the greeting with a code or coins.
class OccasionsPanel extends ConsumerStatefulWidget {
  const OccasionsPanel({super.key});
  @override
  ConsumerState<OccasionsPanel> createState() => _OccasionsPanelState();
}

class _OccasionsPanelState extends ConsumerState<OccasionsPanel> {
  Future<void> _activate(_Occasion o) async {
    final stamp = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => _StampPicker(occasion: o, current: AppOccasion.key == o.key ? AppOccasion.stamp : null),
    );
    if (stamp == null || !mounted) return;
    try {
      await ref.read(adminRepoProvider).setOccasion(o.key, stamp);
      await ref.read(appearanceProvider.notifier).refresh();
      if (!mounted) return;
      showSnack(context, _t(context, 'الختم ظهر عند العملاء. ابعت التهنئة دلوقتي.', 'The stamp is live for customers. Send the greeting now.'));
      await _send(o);
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(context, e), error: true);
    }
  }

  Future<void> _send(_Occasion o) => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (ctx) => _SendSheet(occasion: o),
      );

  Future<void> _end(_Occasion o) async {
    final ok = await showSmoothDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_t(ctx, 'إنهاء ${o.ar}؟', 'End ${o.en}?')),
        content: Text(_t(ctx, 'الختم هيشيل من على الشعار عند كل العملاء.', 'The stamp will be removed from the logo for every customer.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(_t(ctx, 'لأ', 'No'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(_t(ctx, 'أنهي', 'End it'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await ref.read(adminRepoProvider).setOccasion('', '');
      await ref.read(appearanceProvider.notifier).refresh();
      if (mounted) showSnack(context, _t(context, 'المناسبة خلصت والشعار رجع عادي.', 'The occasion ended and the logo is back to normal.'));
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(context, e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = ref.watch(appearanceProvider).occasion;
    final fmt = DateFormat.yMMMMd(context.lang);
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text(
        _t(context, 'اضغط «فعّل» على المناسبة اللي بدأت. الختم بيظهر على الشعار عند كل العملاء في ثواني، وبعدها بتبعت التهنئة بكود خصم أو كوينات. مناسبة واحدة بس تشتغل في الوقت.',
            'Tap Activate on the occasion that has started. The stamp shows on the logo for every customer within seconds, then you send the greeting with a code or coins. Only one occasion runs at a time.'),
        style: const TextStyle(color: BrandColors.gray, fontSize: 13),
      ),
      const SizedBox(height: 12),
      for (final o in _occasions)
        Builder(builder: (context) {
          final isOn = active == o.key;
          final d = _next(o);
          final days = DateTime(d.year, d.month, d.day).difference(DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day)).inDays;
          final when = days > 0
              ? _t(context, 'فاضل $days يوم تقريبًا', 'About $days days away')
              : days == 0
                  ? _t(context, 'النهارده', 'Today')
                  : _t(context, 'بدأت من ${-days} يوم', 'Started ${-days} days ago');
          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: isOn ? BrandColors.success : BrandColors.border, width: isOn ? 2 : 1)),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(o.icon, color: BrandColors.electric),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_t(context, o.ar, o.en), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900))),
                  if (isOn)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                      decoration: BoxDecoration(color: BrandColors.success.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
                      child: Text(_t(context, 'شغّالة دلوقتي', 'Running now'), style: const TextStyle(color: BrandColors.success, fontWeight: FontWeight.w800, fontSize: 12)),
                    ),
                ]),
                const SizedBox(height: 4),
                Text('${fmt.format(d)} · $when', style: const TextStyle(color: BrandColors.gray, fontSize: 13)),
                if (o.key != 'oct6')
                  Text(_t(context, 'التاريخ متوقع، وانت اللي بتفعّل في اليوم الفعلي.', 'The date is expected; you activate on the real day.'), style: const TextStyle(color: BrandColors.gray, fontSize: 12)),
                const SizedBox(height: 10),
                if (isOn)
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    FilledButton.icon(onPressed: () => _send(o), icon: const Icon(Icons.send_rounded, size: 18), label: Text(_t(context, 'ابعت التهنئة', 'Send greeting'))),
                    OutlinedButton(onPressed: () => _activate(o), child: Text(_t(context, 'غيّر الختم', 'Change stamp'))),
                    TextButton(onPressed: () => _end(o), child: Text(_t(context, 'إنهاء المناسبة', 'End occasion'), style: const TextStyle(color: BrandColors.error))),
                  ])
                else
                  FilledButton.icon(
                    onPressed: () => _activate(o),
                    icon: const Icon(Icons.auto_awesome_rounded, size: 18),
                    label: Text(_t(context, 'فعّل ${o.ar} للعملاء', 'Activate ${o.en}')),
                  ),
              ]),
            ),
          );
        }),
    ]);
  }
}

class _StampPicker extends StatefulWidget {
  const _StampPicker({required this.occasion, required this.current});
  final _Occasion occasion;
  final String? current;
  @override
  State<_StampPicker> createState() => _StampPickerState();
}

class _StampPickerState extends State<_StampPicker> {
  late String _sel = widget.current ?? occasionStampKinds[widget.occasion.key]!.first;

  @override
  Widget build(BuildContext context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_t(context, 'اختار ختم الشعار', 'Pick the logo stamp'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
            const SizedBox(height: 12),
            Row(children: [
              for (final k in occasionStampKinds[widget.occasion.key]!)
                Expanded(
                  child: GestureDetector(
                    onTap: () => setState(() => _sel = k),
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), border: Border.all(color: _sel == k ? BrandColors.electric : BrandColors.border, width: _sel == k ? 2.5 : 1)),
                      child: Column(children: [
                        Container(
                          width: 72,
                          height: 72,
                          decoration: BoxDecoration(color: BrandColors.navy, borderRadius: BorderRadius.circular(18)),
                          child: Stack(children: [
                            const Center(child: Text('M', style: TextStyle(color: Colors.white, fontSize: 34, fontWeight: FontWeight.w900))),
                            PositionedDirectional(end: 4, top: 4, child: OccasionStamp(kind: k, size: 30)),
                          ]),
                        ),
                        const SizedBox(height: 6),
                        Text(_stampName(context, k), textAlign: TextAlign.center, style: TextStyle(fontSize: 12, fontWeight: _sel == k ? FontWeight.w900 : FontWeight.w500)),
                      ]),
                    ),
                  ),
                ),
            ]),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(onPressed: () => Navigator.pop(context, _sel), child: Text(_t(context, 'فعّل للعملاء', 'Activate for customers'))),
            ),
          ]),
        ),
      );
}

class _SendSheet extends ConsumerStatefulWidget {
  const _SendSheet({required this.occasion});
  final _Occasion occasion;
  @override
  ConsumerState<_SendSheet> createState() => _SendSheetState();
}

class _SendSheetState extends ConsumerState<_SendSheet> {
  late final _title = TextEditingController(text: widget.occasion.titleAr);
  late final _body = TextEditingController(text: widget.occasion.bodyAr);
  late final _code = TextEditingController(text: '${widget.occasion.codeBase}${_next(widget.occasion).year % 100}');
  final _percent = TextEditingController(text: '10');
  final _days = TextEditingController(text: '7');
  final _coins = TextEditingController(text: '500');
  String _gift = 'code';
  String _scope = 'all';
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [_title, _body, _code, _percent, _days, _coins]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _go() async {
    final title = _title.text.trim(), body = _body.text.trim();
    if (title.isEmpty || body.isEmpty) {
      showSnack(context, _t(context, 'اكتب العنوان والنص.', 'Write the title and the text.'), error: true);
      return;
    }
    final code = _code.text.trim().toUpperCase();
    final percent = int.tryParse(_percent.text) ?? 0;
    final days = int.tryParse(_days.text) ?? 0;
    final coins = int.tryParse(_coins.text) ?? 0;
    if (_gift == 'code' && (!RegExp(r'^[A-Z0-9_-]{3,24}$').hasMatch(code) || percent < 1 || percent > 90 || days < 1 || days > 90)) {
      showSnack(context, _t(context, 'الكود حروف إنجليزي وأرقام (٣–٢٤)، والخصم من ١ لـ٩٠٪، والمدة من ١ لـ٩٠ يوم.', 'Code: 3–24 letters or digits, discount 1–90%, validity 1–90 days.'), error: true);
      return;
    }
    if (_gift == 'coins' && (coins < 1 || coins > 5000)) {
      showSnack(context, _t(context, 'الكوينات من ١ لـ٥٠٠٠.', 'Coins must be between 1 and 5000.'), error: true);
      return;
    }
    final ok = await showSmoothDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_t(ctx, 'تبعت لكل العملاء؟', 'Send to all customers?')),
        content: Text(_gift == 'code'
            ? _t(ctx, 'هيتعمل كود $code بخصم $percent٪ لمدة $days يوم، والتهنئة هتوصل لكل العملاء.', 'Creates code $code for $percent% off for $days days, and sends the greeting to every customer.')
            : _gift == 'coins'
                ? _t(ctx, 'هيتضاف $coins كوين لكل عميل ${_scope == 'all' ? '' : '(اللي طلبوا آخر ٩٠ يوم)'}، والتهنئة هتوصل.', '$coins coins are added to each customer ${_scope == 'all' ? '' : '(ordered in the last 90 days)'} and the greeting is sent.')
                : _t(ctx, 'التهنئة هتوصل لكل العملاء من غير هدية.', 'The greeting is sent to every customer with no gift.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(_t(ctx, 'رجوع', 'Back'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(_t(ctx, 'ابعت', 'Send'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final n = await ref.read(adminRepoProvider).occasionSend(
            key: widget.occasion.key,
            year: _next(widget.occasion).year,
            title: title,
            body: body,
            gift: _gift,
            code: code,
            percent: percent,
            validDays: days,
            coins: coins,
            scope: _scope,
          );
      if (!mounted) return;
      Navigator.pop(context);
      showSnack(context, _t(context, 'اتبعتت لـ$n عميل.', 'Sent to $n customers.'));
    } catch (e) {
      if (mounted) {
        showSnack(context, friendlyError(context, e), error: true);
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_t(context, 'تهنئة ${widget.occasion.ar}', '${widget.occasion.en} greeting'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
            const SizedBox(height: 10),
            TextField(controller: _title, maxLength: 120, decoration: InputDecoration(labelText: _t(context, 'عنوان الإشعار', 'Notification title'))),
            TextField(controller: _body, maxLength: 500, minLines: 3, maxLines: 5, decoration: InputDecoration(labelText: _t(context, 'نص التهنئة', 'Greeting text'))),
            const SizedBox(height: 8),
            Text(_t(context, 'هدية المناسبة', 'Occasion gift'), style: const TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            SegmentedButton<String>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(value: 'code', label: Text(_t(context, 'كود خصم', 'Discount code'))),
                ButtonSegment(value: 'coins', label: Text(_t(context, 'كوينات', 'Coins'))),
                ButtonSegment(value: 'none', label: Text(_t(context, 'رسالة بس', 'Message only'))),
              ],
              selected: {_gift},
              onSelectionChanged: (s) => setState(() => _gift = s.first),
            ),
            const SizedBox(height: 8),
            if (_gift == 'code') ...[
              TextField(controller: _code, textDirection: TextDirection.ltr, textCapitalization: TextCapitalization.characters, decoration: InputDecoration(labelText: _t(context, 'كود الخصم', 'Discount code'))),
              Row(children: [
                Expanded(child: TextField(controller: _percent, keyboardType: TextInputType.number, inputFormatters: [FilteringTextInputFormatter.digitsOnly], decoration: InputDecoration(labelText: _t(context, 'نسبة الخصم ٪', 'Discount %')))),
                const SizedBox(width: 10),
                Expanded(child: TextField(controller: _days, keyboardType: TextInputType.number, inputFormatters: [FilteringTextInputFormatter.digitsOnly], decoration: InputDecoration(labelText: _t(context, 'صالح كام يوم', 'Valid days')))),
              ]),
              Text(_t(context, 'الكود بيتعمل جديد، لكل عميل استخدام واحد، وبيظهر في الإشعار.', 'A new code is created, one use per customer, and it appears in the notification.'), style: const TextStyle(color: BrandColors.gray, fontSize: 12)),
            ],
            if (_gift == 'coins') ...[
              TextField(controller: _coins, keyboardType: TextInputType.number, inputFormatters: [FilteringTextInputFormatter.digitsOnly], decoration: InputDecoration(labelText: _t(context, 'كوينات لكل عميل', 'Coins per customer'))),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(value: 'all', label: Text(_t(context, 'كل العملاء', 'All customers'))),
                  ButtonSegment(value: 'active', label: Text(_t(context, 'طلبوا آخر ٩٠ يوم', 'Ordered in 90 days'))),
                ],
                selected: {_scope},
                onSelectionChanged: (s) => setState(() => _scope = s.first),
              ),
              const SizedBox(height: 6),
              Text(_t(context, 'الكوينات بتزوّد مستوى الحساب بس، والمستويات نفسها سرية. كل عميل بياخدها مرة واحدة لكل مناسبة في السنة.', 'Coins only raise the account level; the levels themselves stay secret. Each customer gets them once per occasion per year.'),
                  style: const TextStyle(color: BrandColors.gray, fontSize: 12)),
            ],
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _busy ? null : _go,
                icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.send_rounded),
                label: Text(_t(context, 'ابعت للعملاء', 'Send to customers')),
              ),
            ),
          ]),
        ),
      );
}
