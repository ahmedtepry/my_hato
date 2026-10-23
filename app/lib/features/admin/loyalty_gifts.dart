import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/supabase_providers.dart';
import '../../shared/states.dart';

/// OWNER ONLY. Who reached which loyalty level, the gift codes, and the owner's control of the gift:
/// customers never see levels or gifts until the owner types the gift here and presses "reveal".
String _t(BuildContext c, String ar, String en) => c.isAr ? ar : en;
String _st(BuildContext c, Map<String, dynamic> s) => (c.isAr ? s['ar'] : s['en']).toString();
List<Map<String, dynamic>> _list(Object? v) => [for (final e in (v as List? ?? const [])) Map<String, dynamic>.from(e as Map)];

final ownerGiftsProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  return Map<String, dynamic>.from(await ref.watch(supabaseProvider).rpc('owner_loyalty_overview') as Map);
});

final ownerTuningProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  return Map<String, dynamic>.from(await ref.watch(supabaseProvider).rpc('owner_loyalty_get_tuning') as Map);
});

void openGifts(BuildContext context) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const GiftsAdminScreen()));

class GiftsAdminScreen extends StatelessWidget {
  const GiftsAdminScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: Text(_t(context, 'هدايا العملاء (سري)', 'Customer gifts (private)'))), body: const GiftsPanel());
}

/// Used as the "Gifts" tab of the console and inside the screen above.
class GiftsPanel extends ConsumerWidget {
  const GiftsPanel({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(ownerGiftsProvider);
    return data.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(ownerGiftsProvider)),
      data: (d) {
        // the difficulty dial is secret and belongs to the main owner only (the one who also sees the levels)
        final owner = _list(d['levels']).isNotEmpty;
        return DefaultTabController(
          length: owner ? 4 : 3,
          child: Column(children: [
            Row(children: [
              Expanded(
                child: TabBar(isScrollable: owner, tabs: [
                  Tab(text: _t(context, 'الهدايا', 'Gifts')),
                  Tab(text: _t(context, 'العملاء', 'Customers')),
                  Tab(text: _t(context, 'المستويات', 'Levels')),
                  if (owner) Tab(text: _t(context, 'الصعوبة', 'Difficulty')),
                ]),
              ),
              IconButton(tooltip: _t(context, 'تحديث', 'Refresh'), onPressed: () => ref.invalidate(ownerGiftsProvider), icon: const Icon(Icons.refresh_rounded)),
            ]),
            Expanded(child: TabBarView(children: [_Awards(d: d), _Customers(d: d), _Levels(d: d), if (owner) const _Difficulty()])),
          ]),
        );
      },
    );
  }
}

String _date(BuildContext c, Object? iso) => iso == null ? '' : DateFormat.yMMMd(c.lang).add_Hm().format(DateTime.parse(iso as String).toLocal());

class _Awards extends ConsumerStatefulWidget {
  const _Awards({required this.d});
  final Map<String, dynamic> d;
  @override
  ConsumerState<_Awards> createState() => _AwardsState();
}

class _AwardsState extends ConsumerState<_Awards> {
  String _q = '';
  @override
  Widget build(BuildContext context) {
    final statuses = {for (final s in _list(widget.d['statuses'])) s['key'] as String: s};
    final q = _q.trim().toLowerCase();
    final rows = [
      for (final a in _list(widget.d['awards']))
        if (q.isEmpty || '${a['code']} ${a['customer']} ${a['email']}'.toLowerCase().contains(q)) a
    ];
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: TextField(
          decoration: InputDecoration(prefixIcon: const Icon(Icons.search_rounded), hintText: _t(context, 'ابحث بالكود أو اسم العميل', 'Search by code or customer name')),
          onChanged: (v) => setState(() => _q = v),
        ),
      ),
      Expanded(
        child: rows.isEmpty
            ? Center(child: Text(_t(context, 'مفيش هدايا مطابقة', 'No matching gifts')))
            : ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: rows.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (_, i) {
                  final a = rows[i];
                  final done = a['status'] == 'delivered';
                  return Card(
                    child: ListTile(
                      leading: Icon(done ? Icons.check_circle_rounded : Icons.card_giftcard_rounded, color: done ? Colors.green : Colors.amber[800]),
                      title: Text('${a['customer'] ?? '—'}  •  ${context.pick(a, 'level')}', style: const TextStyle(fontWeight: FontWeight.w800)),
                      subtitle: Text(
                        '${a['code']}\n${_date(context, a['awarded_at'])}  •  ${a['points']} ${_t(context, 'نقطة', 'pts')}\n'
                        '${_t(context, 'الحالة', 'Status')}: ${statuses[a['status']] == null ? a['status'] : _st(context, statuses[a['status']]!)}\n'
                        '${_t(context, 'المخطط', 'Planned')}: ${a['plan_ar'] ?? '—'}'
                        '${a['prize_ar'] != null ? '\n${_t(context, 'الهدية', 'Gift')}: ${a['prize_ar']}${a['revealed'] == true ? ' (${_t(context, 'ظاهرة للعميل', 'shown to customer')})' : ''}' : ''}',
                      ),
                      isThreeLine: true,
                      trailing: Icon(done ? Icons.lock_rounded : Icons.edit_outlined),
                      onTap: done
                          ? () => showSnack(context, _t(context, 'الهدية اتسلمت والكود اتقفل ومينفعش يتستخدم تاني', 'Delivered: this code is locked and cannot be used again'))
                          : () => showModalBottomSheet<void>(context: context, isScrollControlled: true, builder: (_) => _EditAward(award: a, statuses: statuses.values.toList())),
                    ),
                  );
                },
              ),
      ),
    ]);
  }
}

class _EditAward extends ConsumerStatefulWidget {
  const _EditAward({required this.award, required this.statuses});
  final Map<String, dynamic> award;
  final List<Map<String, dynamic>> statuses;
  @override
  ConsumerState<_EditAward> createState() => _EditAwardState();
}

class _EditAwardState extends ConsumerState<_EditAward> {
  late final _ar = TextEditingController(text: (widget.award['prize_ar'] ?? widget.award['plan_ar'] ?? '') as String);
  late final _en = TextEditingController(text: (widget.award['prize_en'] ?? '') as String);
  late final _noteAr = TextEditingController(text: (widget.award['note_ar'] ?? '') as String);
  late final _noteEn = TextEditingController(text: (widget.award['note_en'] ?? '') as String);
  late bool _reveal = widget.award['revealed'] == true;
  late String _status = widget.award['status'] as String;
  bool _busy = false;

  @override
  void dispose() {
    _ar.dispose();
    _en.dispose();
    _noteAr.dispose();
    _noteEn.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    if (_status == 'delivered') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(_t(c, 'تأكيد التسليم', 'Confirm delivery')),
          content: Text(_t(c, 'بعد التسليم الكود بيتقفل ومينفعش يتغير أو يتستخدم تاني. متأكد إنك سلّمت الهدية للعميل ده؟', 'After delivery the code is locked and cannot be changed or used again. Are you sure you handed the gift to this customer?')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: Text(_t(c, 'إلغاء', 'Cancel'))),
            FilledButton(style: FilledButton.styleFrom(minimumSize: const Size(96, 44)), onPressed: () => Navigator.pop(c, true), child: Text(_t(c, 'أيوه، اتسلمت', 'Yes, delivered'))),
          ],
        ),
      );
      if (ok != true) return;
    }
    setState(() => _busy = true);
    try {
      await ref.read(supabaseProvider).rpc('owner_loyalty_set_award', params: {
        'p_code': widget.award['code'],
        'p_prize_ar': _ar.text,
        'p_prize_en': _en.text,
        'p_reveal': _reveal,
        'p_status': _status,
        'p_note_ar': _noteAr.text,
        'p_note_en': _noteEn.text,
      });
      ref.invalidate(ownerGiftsProvider);
      if (mounted) {
        Navigator.pop(context);
        showSnack(context, _t(context, 'اتحفظ والعميل اتبلّغ', 'Saved, customer notified'));
      }
    } catch (e) {
      final m = e is PostgrestException ? e.message : '';
      if (mounted) showSnack(context, m.startsWith('ALREADY_DELIVERED') ? _t(context, 'الكود ده اتسلم قبل كده وبقى مقفول', 'This code was already delivered and is locked') : friendlyError(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.award;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${a['customer'] ?? '—'}  •  ${context.pick(a, 'level')}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
          Text('${a['email'] ?? ''}', style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 4),
          Row(children: [
            Expanded(child: SelectableText(a['code'] as String, style: const TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1.5))),
            IconButton(onPressed: () => Clipboard.setData(ClipboardData(text: a['code'] as String)), icon: const Icon(Icons.copy_rounded, size: 20)),
          ]),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            value: _status,
            decoration: InputDecoration(labelText: _t(context, 'الحالة (العميل بيشوفها)', 'Status (the customer sees it)')),
            items: [for (final s in widget.statuses) DropdownMenuItem(value: s['key'] as String, child: Text(_st(context, s)))],
            onChanged: (v) => setState(() => _status = v ?? _status),
          ),
          TextField(controller: _noteAr, maxLength: 200, decoration: InputDecoration(labelText: _t(context, 'رسالة مخصصة للعميل بدل الجاهزة (اختياري)', 'Custom message instead of the preset (optional)'))),
          TextField(controller: _noteEn, maxLength: 200, decoration: InputDecoration(labelText: _t(context, 'نفس الرسالة بالإنجليزي (اختياري)', 'Same message in English (optional)'))),
          const Divider(),
          TextField(controller: _ar, maxLength: 120, decoration: InputDecoration(labelText: _t(context, 'الهدية (عربي)', 'Gift (Arabic)'))),
          TextField(controller: _en, maxLength: 120, decoration: InputDecoration(labelText: _t(context, 'الهدية (إنجليزي، اختياري)', 'Gift (English, optional)'))),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _reveal,
            onChanged: (v) => setState(() => _reveal = v),
            title: Text(_t(context, 'اظهر اسم الهدية للعميل', 'Show the gift name to the customer')),
            subtitle: Text(_t(context, 'لو مقفول العميل بيشوف الكود والحالة بس', 'When off, the customer only sees the code and status')),
          ),
          const SizedBox(height: 8),
          SizedBox(width: double.infinity, child: FilledButton(onPressed: _busy ? null : _save, child: Text(_t(context, 'حفظ وإبلاغ العميل', 'Save and notify customer')))),
        ]),
      ),
    );
  }
}

class _Customers extends ConsumerStatefulWidget {
  const _Customers({required this.d});
  final Map<String, dynamic> d;
  @override
  ConsumerState<_Customers> createState() => _CustomersState();
}

class _CustomersState extends ConsumerState<_Customers> {
  final _q = TextEditingController();
  late Future<List<Map<String, dynamic>>> _f = _load();

  Future<List<Map<String, dynamic>>> _load() async =>
      _list(await ref.read(supabaseProvider).rpc('owner_loyalty_customers', params: {'p_q': _q.text.trim()}));

  void _reload() => setState(() => _f = _load());

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // only the main owner (who also sees the levels) may change points
    final isOwner = _list(widget.d['levels']).isNotEmpty;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: TextField(
          controller: _q,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _reload(),
          decoration: InputDecoration(
            hintText: _t(context, 'دوّر على أي عميل بالاسم أو الإيميل', 'Search any customer by name or email'),
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: IconButton(onPressed: _reload, icon: const Icon(Icons.arrow_forward_rounded)),
          ),
        ),
      ),
      Expanded(
        child: FutureBuilder<List<Map<String, dynamic>>>(
          future: _f,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
            if (snap.hasError) return ErrorView(error: snap.error!, onRetry: _reload);
            final rows = snap.data!;
            if (rows.isEmpty) return Center(child: Text(_t(context, 'مفيش نتائج', 'No results')));
            return ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: rows.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final c = rows[i];
                return ListTile(
                  leading: CircleAvatar(child: Text('${i + 1}')),
                  title: Text('${c['customer'] ?? '—'}'),
                  subtitle: Text('${c['email'] ?? ''}'),
                  trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text('${c['points']} ${_t(context, 'نقطة', 'pts')}', style: const TextStyle(fontWeight: FontWeight.w900)),
                    Text('${c['level_ar'] ?? ''}', style: const TextStyle(fontSize: 12)),
                  ]),
                  onTap: !isOwner
                      ? null
                      : () async {
                          final done = await showModalBottomSheet<bool>(context: context, isScrollControlled: true, builder: (_) => _AdjustPoints(customer: c));
                          if (done == true) {
                            ref.invalidate(ownerGiftsProvider);
                            _reload();
                          }
                        },
                );
              },
            );
          },
        ),
      ),
    ]);
  }
}

class _AdjustPoints extends ConsumerStatefulWidget {
  const _AdjustPoints({required this.customer});
  final Map<String, dynamic> customer;
  @override
  ConsumerState<_AdjustPoints> createState() => _AdjustPointsState();
}

class _AdjustPointsState extends ConsumerState<_AdjustPoints> {
  late final _pts = TextEditingController(text: '${widget.customer['points']}');
  final _note = TextEditingController();
  bool _notify = true;
  bool _busy = false;

  @override
  void dispose() {
    _pts.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final target = int.tryParse(_pts.text.trim());
    final now = (widget.customer['points'] as num).toInt();
    if (target == null || target < 0 || target > 10000000) {
      showSnack(context, _t(context, 'اكتب رقم صحيح', 'Enter a valid number'), error: true);
      return;
    }
    if (target == now) {
      Navigator.pop(context, false);
      return;
    }
    setState(() => _busy = true);
    try {
      await ref.read(supabaseProvider).rpc('owner_loyalty_adjust_points', params: {
        'p_user': widget.customer['user_id'],
        'p_delta': target - now,
        'p_note': _note.text.trim(),
        'p_notify': _notify,
      });
      if (mounted) {
        Navigator.pop(context, true);
        showSnack(context, _t(context, 'اتعدّلت النقاط', 'Points updated'));
      }
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.customer;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${c['customer'] ?? '—'}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
          Text('${c['email'] ?? ''}', style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 10),
          TextField(
            controller: _pts,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: _t(context, 'رصيد النقاط الجديد', 'New points balance'), helperText: _t(context, 'دلوقتي: ${c['points']} نقطة', 'Now: ${c['points']} points')),
          ),
          TextField(controller: _note, maxLength: 200, decoration: InputDecoration(labelText: _t(context, 'السبب (بتسجّل عندك بس)', 'Reason (kept in your log only)'))),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _notify,
            onChanged: (v) => setState(() => _notify = v),
            title: Text(_t(context, 'ابلّغ العميل بإشعار', 'Notify the customer')),
          ),
          const SizedBox(height: 6),
          SizedBox(width: double.infinity, child: FilledButton(onPressed: _busy ? null : _save, child: Text(_t(context, 'حفظ', 'Save')))),
        ]),
      ),
    );
  }
}

class _Levels extends ConsumerWidget {
  const _Levels({required this.d});
  final Map<String, dynamic> d;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = _list(d['levels']);
    return ListView(padding: const EdgeInsets.all(16), children: [
      if (rows.isEmpty) Text(_t(context, 'المستويات يشوفها المالك الأساسي بس.', 'Levels are visible to the main owner only.')),
      Text(_t(context, 'المستويات سرية، العميل مبيشوفش الحدود ولا الهدايا. اضغط على أي مستوى تعدّل اسمه ونقاطه والهدية المخططة.', 'Levels are secret. Customers never see thresholds or gifts. Tap a level to edit its name, points and planned gift.'),
          style: const TextStyle(fontSize: 12.5)),
      const SizedBox(height: 10),
      for (final l in rows)
        Card(
          child: ListTile(
            leading: CircleAvatar(child: Text('${l['sort']}')),
            title: Text('${context.pick(l, 'name')}  •  ${l['min_points']} ${_t(context, 'نقطة', 'pts')}', style: const TextStyle(fontWeight: FontWeight.w800)),
            subtitle: Text('${_t(context, 'المخطط', 'Planned')}: ${l['plan_ar'] ?? '—'}'),
            trailing: const Icon(Icons.edit_rounded, size: 20),
            onTap: () async {
              final done = await showModalBottomSheet<bool>(context: context, isScrollControlled: true, builder: (_) => _EditLevel(level: l));
              if (done == true) ref.invalidate(ownerGiftsProvider);
            },
          ),
        ),
    ]);
  }
}

class _EditLevel extends ConsumerStatefulWidget {
  const _EditLevel({required this.level});
  final Map<String, dynamic> level;
  @override
  ConsumerState<_EditLevel> createState() => _EditLevelState();
}

class _EditLevelState extends ConsumerState<_EditLevel> {
  late final _nameAr = TextEditingController(text: '${widget.level['name_ar'] ?? ''}');
  late final _nameEn = TextEditingController(text: '${widget.level['name_en'] ?? ''}');
  late final _pts = TextEditingController(text: '${widget.level['min_points']}');
  late final _planAr = TextEditingController(text: '${widget.level['plan_ar'] ?? ''}');
  late final _planEn = TextEditingController(text: '${widget.level['plan_en'] ?? ''}');
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [_nameAr, _nameEn, _pts, _planAr, _planEn]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final pts = int.tryParse(_pts.text.trim());
    if (pts == null || _nameAr.text.trim().isEmpty) {
      showSnack(context, _t(context, 'اكتب الاسم وعدد النقاط', 'Enter a name and the points'), error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      await ref.read(supabaseProvider).rpc('owner_loyalty_set_level', params: {
        'p_sort': widget.level['sort'],
        'p_name_ar': _nameAr.text,
        'p_name_en': _nameEn.text,
        'p_min_points': pts,
        'p_plan_ar': _planAr.text,
        'p_plan_en': _planEn.text,
      });
      if (mounted) {
        Navigator.pop(context, true);
        showSnack(context, _t(context, 'اتحفظ المستوى', 'Level saved'));
      }
    } catch (e) {
      final m = e is PostgrestException ? e.message : '';
      final txt = m.startsWith('LEVEL_ORDER')
          ? _t(context, 'النقاط لازم تكون أكتر من المستوى اللي قبله وأقل من اللي بعده', 'Points must be above the previous level and below the next one')
          : m.startsWith('INVALID_POINTS')
              ? _t(context, 'عدد النقاط مش مظبوط (المستوى الأول لازم يبقى صفر)', 'Invalid points (the first level must be 0)')
              : friendlyError(context, e);
      if (mounted) showSnack(context, txt, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final first = widget.level['sort'] == 1;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_t(context, 'مستوى ${widget.level['sort']}', 'Level ${widget.level['sort']}'), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
          TextField(controller: _nameAr, maxLength: 40, decoration: InputDecoration(labelText: _t(context, 'اسم المستوى (عربي)', 'Level name (Arabic)'))),
          TextField(controller: _nameEn, maxLength: 40, decoration: InputDecoration(labelText: _t(context, 'اسم المستوى (إنجليزي)', 'Level name (English)'))),
          TextField(
            controller: _pts,
            enabled: !first,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: _t(context, 'النقاط المطلوبة للوصول', 'Points needed to reach it')),
          ),
          TextField(controller: _planAr, maxLength: 120, decoration: InputDecoration(labelText: _t(context, 'الهدية المخططة (ليك بس)', 'Planned gift (private)'))),
          TextField(controller: _planEn, maxLength: 120, decoration: InputDecoration(labelText: _t(context, 'الهدية المخططة بالإنجليزي (اختياري)', 'Planned gift in English (optional)'))),
          const SizedBox(height: 6),
          SizedBox(width: double.infinity, child: FilledButton(onPressed: _busy ? null : _save, child: Text(_t(context, 'حفظ', 'Save')))),
        ]),
      ),
    );
  }
}

/// SECRET (main owner only): one dial that makes every point customers earn bigger or smaller, live at once.
/// Customers never see it; they only see the amounts it produces.
class _Difficulty extends ConsumerStatefulWidget {
  const _Difficulty();
  @override
  ConsumerState<_Difficulty> createState() => _DifficultyState();
}

class _DifficultyState extends ConsumerState<_Difficulty> {
  double? _pct;
  bool _busy = false;

  int _scale(num p, double pct) => p <= 0 ? p.toInt() : (p * pct / 100).round().clamp(1, 1 << 30);

  Future<void> _save(int saved) async {
    final v = _pct!.round();
    if (v == saved) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(_t(c, 'تطبيق الصعوبة؟', 'Apply difficulty?')),
        content: Text(_t(c, 'هتتطبق فورًا على أي نقاط العملاء يكسبوها من دلوقتي. النقاط اللي معاهم فعلًا مش بتتغير، والعملاء مش هيعرفوا إن في تحكم.', 'It applies at once to every point customers earn from now on. Existing balances do not change and customers cannot tell a dial exists.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(_t(c, 'إلغاء', 'Cancel'))),
          FilledButton(style: FilledButton.styleFrom(minimumSize: const Size(96, 44)), onPressed: () => Navigator.pop(c, true), child: Text(_t(c, 'تطبيق', 'Apply'))),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await ref.read(supabaseProvider).rpc('owner_loyalty_set_tuning', params: {'p_pct': v});
      ref.invalidate(ownerTuningProvider);
      if (mounted) showSnack(context, _t(context, 'اتطبقت دلوقتي', 'Applied now'));
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(ownerTuningProvider);
    return data.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(ownerTuningProvider)),
      data: (d) {
        final saved = (d['pct'] as num).toInt();
        final pct = _pct ?? saved.toDouble();
        final missions = _list(d['missions']);
        final rewards = (d['rewards'] as List? ?? const []).map((e) => (e as num).toInt()).toList();
        final per10 = (d['order_per_10egp'] as num?) ?? 1;
        final diff = pct.round() - 100;
        final label = diff == 0
            ? _t(context, 'عادي', 'Normal')
            : diff > 0
                ? _t(context, 'أسهل بـ $diff%', 'Easier by $diff%')
                : _t(context, 'أصعب بـ ${-diff}%', 'Harder by ${-diff}%');
        Widget row(String name, num base) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                Expanded(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis)),
                Text('$base', style: const TextStyle(color: Colors.grey)),
                const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Icon(Icons.arrow_forward_rounded, size: 16)),
                Text('${_scale(base, pct)}', style: const TextStyle(fontWeight: FontWeight.w900)),
              ]),
            );
        return ListView(padding: const EdgeInsets.all(16), children: [
          Row(children: [
            const Icon(Icons.lock_rounded, size: 18),
            const SizedBox(width: 6),
            Expanded(child: Text(_t(context, 'سري: ليك إنت بس. العميل مش بيشوفه ومش بيعرف إنه موجود.', 'Secret: for you only. Customers never see it or know it exists.'), style: const TextStyle(fontSize: 12.5))),
          ]),
          const SizedBox(height: 14),
          Center(child: Text('${pct.round()}%', style: const TextStyle(fontSize: 44, fontWeight: FontWeight.w900))),
          Center(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700))),
          Directionality(
            textDirection: TextDirection.ltr,
            child: Column(children: [
              Slider(
                value: pct.clamp(25, 300),
                min: 25,
                max: 300,
                divisions: 55,
                label: '${pct.round()}%',
                onChanged: _busy ? null : (v) => setState(() => _pct = v),
              ),
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Text(_t(context, 'أصعب (نقاط أقل)', 'Harder (fewer points)'), style: const TextStyle(fontSize: 12)),
                Text(_t(context, 'أسهل (نقاط أكتر)', 'Easier (more points)'), style: const TextStyle(fontSize: 12)),
              ]),
            ]),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: FilledButton(
                onPressed: _busy || pct.round() == saved ? null : () => _save(saved),
                child: Text(_t(context, 'تطبيق دلوقتي', 'Apply now')),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              style: OutlinedButton.styleFrom(minimumSize: const Size(96, 48)),
              onPressed: _busy ? null : () => setState(() => _pct = 100),
              child: Text(_t(context, 'رجّع 100%', 'Reset 100%')),
            ),
          ]),
          const SizedBox(height: 18),
          Text(_t(context, 'العميل هياخد بعد التطبيق:', 'Customers will earn after applying:'), style: const TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          for (final m in missions) row(context.pick(m, 'title'), (m['points'] as num)),
          row(_t(context, 'أوردر 1000 جنيه', 'Order of 1000 EGP'), (100 * per10).round()),
          if (rewards.isNotEmpty) ...[
            const Divider(),
            Text(_t(context, 'مكافآت علبة النقاط', 'Reward box'), style: const TextStyle(fontWeight: FontWeight.w800)),
            for (final r in rewards) row('$r ${_t(context, 'نقطة', 'pts')}', r),
          ],
          const SizedBox(height: 10),
          Text(_t(context, 'التعديلات اليدوية على رصيد عميل مش بتتأثر بالمؤشر. وأي استرجاع أوردر أو تقييم بيسحب نفس النقاط اللي اتدفعت.', 'Manual balance changes are never scaled. Reversals take back exactly what was paid.'), style: const TextStyle(fontSize: 12, color: Colors.grey)),
        ]);
      },
    );
  }
}
