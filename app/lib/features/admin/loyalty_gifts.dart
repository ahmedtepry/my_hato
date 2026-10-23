import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/supabase_providers.dart';
import '../../shared/states.dart';

/// OWNER ONLY. Who reached which loyalty level, the gift codes, and the owner's control of the gift:
/// customers never see levels or gifts until the owner types the gift here and presses "reveal".
String _t(BuildContext c, String ar, String en) => c.isAr ? ar : en;
List<Map<String, dynamic>> _list(Object? v) => [for (final e in (v as List? ?? const [])) Map<String, dynamic>.from(e as Map)];

final ownerGiftsProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  return Map<String, dynamic>.from(await ref.watch(supabaseProvider).rpc('owner_loyalty_overview') as Map);
});

void openGifts(BuildContext context) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const GiftsAdminScreen()));

class GiftsAdminScreen extends ConsumerWidget {
  const GiftsAdminScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(ownerGiftsProvider);
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(_t(context, 'هدايا العملاء (سري)', 'Customer gifts (private)')),
          actions: [IconButton(tooltip: _t(context, 'تحديث', 'Refresh'), onPressed: () => ref.invalidate(ownerGiftsProvider), icon: const Icon(Icons.refresh_rounded))],
          bottom: TabBar(tabs: [
            Tab(text: _t(context, 'الهدايا', 'Gifts')),
            Tab(text: _t(context, 'العملاء', 'Customers')),
            Tab(text: _t(context, 'المستويات', 'Levels')),
          ]),
        ),
        body: data.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(ownerGiftsProvider)),
          data: (d) => TabBarView(children: [_Awards(d: d), _Customers(d: d), _Levels(d: d)]),
        ),
      ),
    );
  }
}

String _date(BuildContext c, Object? iso) => iso == null ? '' : DateFormat.yMMMd(c.lang).add_Hm().format(DateTime.parse(iso as String).toLocal());

class _Awards extends ConsumerWidget {
  const _Awards({required this.d});
  final Map<String, dynamic> d;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = _list(d['awards']);
    if (rows.isEmpty) return Center(child: Text(_t(context, 'لسه محدش وصل لمستوى فيه هدية', 'Nobody has reached a gift level yet')));
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: rows.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, i) {
        final a = rows[i];
        final done = a['delivered'] == true;
        return Card(
          child: ListTile(
            leading: Icon(done ? Icons.check_circle_rounded : Icons.card_giftcard_rounded, color: done ? Colors.green : Colors.amber[800]),
            title: Text('${a['customer'] ?? '—'}  •  ${context.pick(a, 'level')}', style: const TextStyle(fontWeight: FontWeight.w800)),
            subtitle: Text(
              '${a['code']}\n${_date(context, a['awarded_at'])}  •  ${a['points']} ${_t(context, 'نقطة', 'pts')}\n'
              '${_t(context, 'المخطط', 'Planned')}: ${a['plan_ar'] ?? '—'}'
              '${a['prize_ar'] != null ? '\n${_t(context, 'الهدية', 'Gift')}: ${a['prize_ar']}${a['revealed'] == true ? ' (${_t(context, 'ظاهرة للعميل', 'shown to customer')})' : ''}' : ''}',
            ),
            isThreeLine: true,
            trailing: const Icon(Icons.edit_outlined),
            onTap: () => showModalBottomSheet<void>(context: context, isScrollControlled: true, builder: (_) => _EditAward(award: a)),
          ),
        );
      },
    );
  }
}

class _EditAward extends ConsumerStatefulWidget {
  const _EditAward({required this.award});
  final Map<String, dynamic> award;
  @override
  ConsumerState<_EditAward> createState() => _EditAwardState();
}

class _EditAwardState extends ConsumerState<_EditAward> {
  late final _ar = TextEditingController(text: (widget.award['prize_ar'] ?? widget.award['plan_ar'] ?? '') as String);
  late final _en = TextEditingController(text: (widget.award['prize_en'] ?? '') as String);
  late bool _reveal = widget.award['revealed'] == true;
  late bool _delivered = widget.award['delivered'] == true;
  bool _busy = false;

  @override
  void dispose() {
    _ar.dispose();
    _en.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ref.read(supabaseProvider).rpc('owner_loyalty_set_award', params: {
        'p_code': widget.award['code'],
        'p_prize_ar': _ar.text,
        'p_prize_en': _en.text,
        'p_reveal': _reveal,
        'p_delivered': _delivered,
      });
      ref.invalidate(ownerGiftsProvider);
      if (mounted) {
        Navigator.pop(context);
        showSnack(context, _t(context, 'اتحفظ', 'Saved'));
      }
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(context, e), error: true);
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
          const SizedBox(height: 4),
          Row(children: [
            Expanded(child: SelectableText(a['code'] as String, style: const TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1.5))),
            IconButton(onPressed: () => Clipboard.setData(ClipboardData(text: a['code'] as String)), icon: const Icon(Icons.copy_rounded, size: 20)),
          ]),
          const SizedBox(height: 8),
          TextField(controller: _ar, maxLength: 120, decoration: InputDecoration(labelText: _t(context, 'الهدية (عربي)', 'Gift (Arabic)'))),
          TextField(controller: _en, maxLength: 120, decoration: InputDecoration(labelText: _t(context, 'الهدية (إنجليزي، اختياري)', 'Gift (English, optional)'))),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _reveal,
            onChanged: (v) => setState(() => _reveal = v),
            title: Text(_t(context, 'اظهر الهدية للعميل', 'Show the gift to the customer')),
            subtitle: Text(_t(context, 'لو مقفول العميل بيشوف الكود بس ومبيعرفش الهدية', 'When off, the customer only sees the code, not the gift')),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _delivered,
            onChanged: (v) => setState(() => _delivered = v),
            title: Text(_t(context, 'الهدية اتسلمت', 'Gift delivered')),
          ),
          const SizedBox(height: 8),
          SizedBox(width: double.infinity, child: FilledButton(onPressed: _busy ? null : _save, child: Text(_t(context, 'حفظ', 'Save')))),
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
