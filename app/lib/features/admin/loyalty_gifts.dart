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
    return DefaultTabController(
      length: 3,
      child: Column(children: [
        Row(children: [
          Expanded(
            child: TabBar(tabs: [
              Tab(text: _t(context, 'الهدايا', 'Gifts')),
              Tab(text: _t(context, 'العملاء', 'Customers')),
              Tab(text: _t(context, 'المستويات', 'Levels')),
            ]),
          ),
          IconButton(tooltip: _t(context, 'تحديث', 'Refresh'), onPressed: () => ref.invalidate(ownerGiftsProvider), icon: const Icon(Icons.refresh_rounded)),
        ]),
        Expanded(
          child: data.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(ownerGiftsProvider)),
            data: (d) => TabBarView(children: [_Awards(d: d), _Customers(d: d), _Levels(d: d)]),
          ),
        ),
      ]),
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
            FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(_t(c, 'أيوه، اتسلمت', 'Yes, delivered'))),
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

class _Customers extends StatelessWidget {
  const _Customers({required this.d});
  final Map<String, dynamic> d;
  @override
  Widget build(BuildContext context) {
    final rows = _list(d['customers']);
    if (rows.isEmpty) return Center(child: Text(_t(context, 'مفيش عملاء جمعوا نقاط لسه', 'No customer has points yet')));
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
        );
      },
    );
  }
}

class _Levels extends StatelessWidget {
  const _Levels({required this.d});
  final Map<String, dynamic> d;
  @override
  Widget build(BuildContext context) {
    final rows = _list(d['levels']);
    return ListView(padding: const EdgeInsets.all(16), children: [
      if (rows.isEmpty) Text(_t(context, 'المستويات يشوفها المالك الأساسي بس.', 'Levels are visible to the main owner only.')),
      Text(_t(context, 'المستويات سرية. العميل مبيشوفش الحدود ولا الهدايا. عدّل الأسماء والحدود والخطة من جدول loyalty_levels في Supabase.', 'Levels are secret. Customers never see thresholds or gifts. Edit names, thresholds and the plan in the loyalty_levels table in Supabase.'),
          style: const TextStyle(fontSize: 12.5)),
      const SizedBox(height: 10),
      for (final l in rows)
        Card(
          child: ListTile(
            leading: CircleAvatar(child: Text('${l['sort']}')),
            title: Text('${context.pick(l, 'name')}  •  ${l['min_points']} ${_t(context, 'نقطة', 'pts')}', style: const TextStyle(fontWeight: FontWeight.w800)),
            subtitle: Text('${_t(context, 'المخطط', 'Planned')}: ${l['plan_ar'] ?? '—'}'),
          ),
        ),
    ]);
  }
}
