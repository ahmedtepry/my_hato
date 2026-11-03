// The owner's wheel page: difficulty, spins per day, the slices on the wheel (name, kind, weight, daily limit) and the gifts customers won.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/supabase_providers.dart';
import '../../shared/states.dart';

class _Seg {
  _Seg({String labelAr = '', String labelEn = '', this.kind = 'lose', int? points, int? percent, int hours = 24, int weight = 10, int? limit, this.active = true})
      : ar = TextEditingController(text: labelAr),
        en = TextEditingController(text: labelEn),
        pts = TextEditingController(text: points?.toString() ?? ''),
        pct = TextEditingController(text: percent?.toString() ?? ''),
        hrs = TextEditingController(text: '$hours'),
        w = TextEditingController(text: '$weight'),
        lim = TextEditingController(text: limit?.toString() ?? '');
  final TextEditingController ar, en, pts, pct, hrs, w, lim;
  String kind;
  bool active;
  int get weight => int.tryParse(w.text) ?? 0;
  void dispose() {
    for (final c in [ar, en, pts, pct, hrs, w, lim]) {
      c.dispose();
    }
  }

  Map<String, dynamic> toJson() => {
        'label_ar': ar.text.trim(),
        'label_en': en.text.trim().isEmpty ? ar.text.trim() : en.text.trim(),
        'kind': kind,
        'points': kind == 'points' ? int.tryParse(pts.text) : null,
        'discount_percent': kind == 'discount' ? int.tryParse(pct.text) : null,
        'valid_hours': kind == 'discount' ? (int.tryParse(hrs.text) ?? 24) : null,
        'weight': weight,
        'daily_limit': lim.text.trim().isEmpty ? null : int.tryParse(lim.text),
        'active': active,
      };
}

class WheelAdminPanel extends ConsumerStatefulWidget {
  const WheelAdminPanel({super.key});
  @override
  ConsumerState<WheelAdminPanel> createState() => _WheelAdminPanelState();
}

class _WheelAdminPanelState extends ConsumerState<WheelAdminPanel> {
  final List<_Seg> _segs = [];
  double _ease = 50;
  int _perDay = 1;
  bool _requireOrder = false;
  bool _loading = true, _saving = false;
  String? _error;
  int _spinsToday = 0;
  List<Map<String, dynamic>> _gifts = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final s in _segs) {
      s.dispose();
    }
    super.dispose();
  }

  List<Map<String, dynamic>> _maps(Object? v) => (v as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();

  Future<void> _load() async {
    try {
      final db = ref.read(supabaseProvider);
      final d = Map<String, dynamic>.from(await db.rpc('wheel_admin_get') as Map);
      final g = _maps(await db.rpc('wheel_gifts_list'));
      for (final s in _segs) {
        s.dispose();
      }
      _segs
        ..clear()
        ..addAll(_maps(d['segments']).map((s) => _Seg(
            labelAr: '${s['label_ar']}', labelEn: '${s['label_en']}', kind: '${s['kind']}', points: (s['points'] as num?)?.toInt(),
            percent: (s['discount_percent'] as num?)?.toInt(), hours: (s['valid_hours'] as num?)?.toInt() ?? 24,
            weight: (s['weight'] as num).toInt(), limit: (s['daily_limit'] as num?)?.toInt(), active: s['active'] == true)));
      if (!mounted) return;
      setState(() {
        _ease = (d['ease'] as num).toDouble();
        _perDay = (d['spins_per_day'] as num).toInt();
        _requireOrder = d['require_order'] == true;
        _spinsToday = (d['spins_today'] as num).toInt();
        _gifts = g;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() {
        _loading = false;
        _error = friendlyError(context, e);
      });
    }
  }

  // same maths as the server: everything except "better luck" is scaled by 0.25 (hard) .. 1.75 (easy)
  List<double> _odds() {
    final f = 0.25 + 1.5 * _ease / 100;
    final w = _segs.map((s) => !s.active ? 0.0 : (s.kind == 'lose' ? s.weight.toDouble() : s.weight * f)).toList();
    final t = w.fold<double>(0, (a, b) => a + b);
    return w.map((x) => t == 0 ? 0.0 : x / t).toList();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ref.read(supabaseProvider).rpc('wheel_admin_save', params: {
        'p': {'ease': _ease.round(), 'spins_per_day': _perDay, 'require_order': _requireOrder, 'segments': _segs.map((s) => s.toJson()).toList()},
      });
      if (mounted) showSnack(context, context.isAr ? 'اتحفظت' : 'Saved');
      await _load();
    } catch (e) {
      if (mounted) showSnack(context, context.isAr ? 'مش قادر يحفظ: لازم 3 خانات شغّالة على الأقل، والأسماء مكتوبة، والنقاط رقم، والخصم من 1 لـ 90% ومن 1 لـ 48 ساعة.' : friendlyError(context, e), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _deliver(Map<String, dynamic> g, bool done) async {
    try {
      await ref.read(supabaseProvider).rpc('wheel_gift_set_status', params: {'p_spin': g['id'], 'p_status': done ? 'delivered' : 'pending'});
      await _load();
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(context, e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ar = context.isAr;
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return ErrorView(error: _error!, onRetry: _load);
    final odds = _odds();
    var win = 0.0;
    for (var i = 0; i < _segs.length; i++) {
      if (_segs[i].kind != 'lose') win += odds[i];
    }
    return ListView(padding: const EdgeInsets.all(16), children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(ar ? 'مدى سهولة العجلة: ${_ease.round()}%' : 'Wheel ease: ${_ease.round()}%', style: const TextStyle(fontWeight: FontWeight.w800)),
            Slider(value: _ease, min: 0, max: 100, divisions: 20, label: '${_ease.round()}%', onChanged: (v) => setState(() => _ease = v)),
            Text(ar ? 'العميل بيكسب حاجة في ${(win * 100).round()}% من اللفّات. كل ما سهّلتها بتكلّفك أكتر وبيرجعوا أكتر.' : 'Customers win something in ${(win * 100).round()}% of spins.', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: Text(ar ? 'عدد اللفّات في اليوم' : 'Spins per day')),
              IconButton(onPressed: _perDay > 1 ? () => setState(() => _perDay--) : null, icon: const Icon(Icons.remove_circle_outline)),
              Text('$_perDay', style: const TextStyle(fontWeight: FontWeight.w800)),
              IconButton(onPressed: _perDay < 5 ? () => setState(() => _perDay++) : null, icon: const Icon(Icons.add_circle_outline)),
            ]),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(ar ? 'لازم يكون عمل طلب قبل كده' : 'Require at least one order'),
              subtitle: Text(ar ? 'حماية إضافية من الحسابات المزيفة. العجلة أصلًا للحسابات الموثّقة والمقبولة بس.' : 'Extra protection against fake accounts. The wheel is already for verified, approved accounts only.'),
              value: _requireOrder,
              onChanged: (v) => setState(() => _requireOrder = v),
            ),
            Text(ar ? 'لفّات النهارده: $_spinsToday' : 'Spins today: $_spinsToday', style: Theme.of(context).textTheme.bodySmall),
          ]),
        ),
      ),
      const SizedBox(height: 8),
      Text(ar ? 'اللي بيظهر في العجلة' : 'On the wheel', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
      Text(ar ? 'الوزن = أهمية الخانة بين الباقي. «حد/يوم» = أقصى عدد مرات تتوزع في اليوم. الأوزان والحدود سرّية ومحدّش من العملا بيشوفها.' : 'Weight = how likely a slice is relative to the others. Limits and weights are secret.', style: Theme.of(context).textTheme.bodySmall),
      for (var i = 0; i < _segs.length; i++) _segCard(context, i, odds[i]),
      Wrap(spacing: 8, children: [
        OutlinedButton.icon(onPressed: _segs.length >= 12 ? null : () => setState(() => _segs.add(_Seg(labelAr: 'جايزة جديدة', labelEn: 'New prize', kind: 'gift', weight: 5))), icon: const Icon(Icons.card_giftcard), label: Text(ar ? 'هدية' : 'Gift')),
        OutlinedButton.icon(onPressed: _segs.length >= 12 ? null : () => setState(() => _segs.add(_Seg(labelAr: '50 نقطة', labelEn: '50 points', kind: 'points', points: 50, weight: 10))), icon: const Icon(Icons.star_rounded), label: Text(ar ? 'نقاط' : 'Points')),
        OutlinedButton.icon(onPressed: _segs.length >= 12 ? null : () => setState(() => _segs.add(_Seg(labelAr: 'خصم 10%', labelEn: '10% off', kind: 'discount', percent: 10, hours: 24, weight: 8))), icon: const Icon(Icons.local_offer_outlined), label: Text(ar ? 'خصم' : 'Discount')),
        OutlinedButton.icon(onPressed: _segs.length >= 12 ? null : () => setState(() => _segs.add(_Seg(labelAr: 'حظ أوفر', labelEn: 'Better luck', kind: 'lose', weight: 20))), icon: const Icon(Icons.eco_outlined), label: Text(ar ? 'حظ أوفر' : 'Better luck')),
        OutlinedButton.icon(onPressed: _segs.length >= 12 ? null : () => setState(() => _segs.add(_Seg(labelAr: 'لفّة تانية', labelEn: 'Spin again', kind: 'again', weight: 8))), icon: const Icon(Icons.replay), label: Text(ar ? 'لفّة تانية' : 'Spin again')),
      ]),
      const SizedBox(height: 12),
      FilledButton.icon(onPressed: _saving ? null : _save, icon: const Icon(Icons.save_rounded), label: Text(ar ? 'احفظ العجلة' : 'Save wheel')),
      const SizedBox(height: 24),
      Text(ar ? 'الهدايا اللي العملا كسبوها' : 'Gifts won', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
      if (_gifts.isEmpty) Padding(padding: const EdgeInsets.all(12), child: Text(ar ? 'لسه محدّش كسب هدية.' : 'No gifts yet.')),
      for (final g in _gifts) _giftCard(context, g),
    ]);
  }

  Widget _segCard(BuildContext context, int i, double odd) {
    final ar = context.isAr;
    final s = _segs[i];
    return Card(
      color: s.active ? null : Theme.of(context).disabledColor.withValues(alpha: .08),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(children: [
          Row(children: [
            Expanded(child: TextField(controller: s.ar, maxLength: 30, decoration: InputDecoration(labelText: ar ? 'الاسم' : 'Name', counterText: ''), onChanged: (_) => setState(() {}))),
            const SizedBox(width: 8),
            Expanded(child: TextField(controller: s.en, maxLength: 30, decoration: InputDecoration(labelText: 'English', counterText: ''))),
            IconButton(
              tooltip: ar ? 'امسح' : 'Delete',
              onPressed: _segs.length <= 3 ? null : () => setState(() => _segs.removeAt(i)),
              icon: const Icon(Icons.delete_outline, color: Colors.red),
            ),
          ]),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            DropdownButton<String>(
              value: s.kind,
              items: [
                DropdownMenuItem(value: 'points', child: Text(ar ? 'نقاط' : 'Points')),
                DropdownMenuItem(value: 'gift', child: Text(ar ? 'هدية' : 'Gift')),
                DropdownMenuItem(value: 'discount', child: Text(ar ? 'خصم' : 'Discount')),
                DropdownMenuItem(value: 'lose', child: Text(ar ? 'حظ أوفر' : 'Better luck')),
                DropdownMenuItem(value: 'again', child: Text(ar ? 'لفّة تانية' : 'Spin again')),
              ],
              onChanged: (v) => setState(() => s.kind = v ?? s.kind),
            ),
            if (s.kind == 'points') SizedBox(width: 80, child: TextField(controller: s.pts, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: ar ? 'نقاط' : 'Points'), onChanged: (_) => setState(() {}))),
            if (s.kind == 'discount') ...[
              SizedBox(width: 80, child: TextField(controller: s.pct, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: ar ? 'نسبة %' : 'Percent %'))),
              SizedBox(width: 90, child: TextField(controller: s.hrs, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: ar ? 'أقصى ساعات (1-24)' : 'Max hours (1-24)'))),
            ],
            SizedBox(width: 72, child: TextField(controller: s.w, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: ar ? 'الوزن' : 'Weight'), onChanged: (_) => setState(() {}))),
            if (s.kind == 'gift' || s.kind == 'points' || s.kind == 'discount')
              SizedBox(width: 90, child: TextField(controller: s.lim, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: ar ? 'حد/يوم' : 'Per day'))),
            Column(children: [Text('${(odd * 100).toStringAsFixed(1)}%', style: const TextStyle(fontWeight: FontWeight.w800)), Text(ar ? 'الفرصة' : 'chance', style: Theme.of(context).textTheme.bodySmall)]),
            Switch(value: s.active, onChanged: (v) => setState(() => s.active = v)),
          ]),
        ]),
      ),
    );
  }

  Widget _giftCard(BuildContext context, Map<String, dynamic> g) {
    final ar = context.isAr;
    final done = g['status'] == 'delivered';
    final phone = '${g['phone'] ?? ''}'.trim();
    return Card(
      child: ListTile(
        leading: Text(done ? '✅' : '🎁', style: const TextStyle(fontSize: 24)),
        title: Text('${g['label_ar']}'),
        subtitle: Text('${g['name']}${phone.isNotEmpty ? ' · $phone' : ''}\n${'${g['created_at']}'.split('T').first}'),
        isThreeLine: true,
        trailing: Wrap(spacing: 0, children: [
          if (phone.isNotEmpty) IconButton(onPressed: () => launchUrl(Uri.parse('tel:$phone')), icon: const Icon(Icons.call_rounded)),
          TextButton(onPressed: () => _deliver(g, !done), child: Text(done ? (ar ? 'رجّعها' : 'Undo') : (ar ? 'اتسلّمت' : 'Delivered'))),
        ]),
      ),
    );
  }
}
