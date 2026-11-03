// "استقبال المحافظ": money arriving in the office wallets, live. The phone stays in the office; staff only SEE the transfers and link each one to its
// order. The accountant records refunds and withdrawals and compares the expected balance; the owner switches the inbox on and gets its secret key.
// Windows team app only.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../shared/states.dart';
import 'admin_repository.dart' show staffContextProvider;

String _t(BuildContext c, String ar, String en) => c.isAr ? ar : en;
num _n(Object? v) => v is num ? v : 0;
String _egp(BuildContext c, num minor) {
  final v = (minor / 100).toStringAsFixed(minor % 100 == 0 ? 0 : 2);
  final parts = v.split('.');
  final b = StringBuffer();
  for (var i = 0; i < parts[0].length; i++) {
    if (i > 0 && (parts[0].length - i) % 3 == 0 && parts[0][i - 1] != '-') b.write(',');
    b.write(parts[0][i]);
  }
  return _t(c, '$b${parts.length > 1 ? '.${parts[1]}' : ''} ج.م', '$b${parts.length > 1 ? '.${parts[1]}' : ''} EGP');
}

String _walletName(BuildContext c, String? w) => switch (w) {
      'vodafone' => _t(c, 'فودافون كاش', 'Vodafone Cash'),
      'etisalat' => _t(c, 'اتصالات كاش', 'Etisalat Cash'),
      'instapay' => _t(c, 'إنستا باي', 'InstaPay'),
      _ => _t(c, 'محفظة', 'Wallet'),
    };

const _hookUrl = 'https://efdomvgypdkpqubkkjwm.supabase.co/functions/v1/wallet-sms';

final _inboxProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async =>
    Map<String, dynamic>.from(await ref.watch(supabaseProvider).rpc('wallet_inbox_list', params: {'p_limit': 60}) as Map));
final _balanceProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final r = await ref.watch(supabaseProvider).rpc('wallet_balance') as List;
  return [for (final e in r) Map<String, dynamic>.from(e as Map)];
});
final _stateProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async =>
    Map<String, dynamic>.from(await ref.watch(supabaseProvider).rpc('wallet_inbox_state') as Map));

String _err(BuildContext c, Object e) {
  final t = '$e';
  if (t.contains('AMOUNT_MISMATCH')) return _t(c, 'المبلغ مش بيساوي إجمالي الأوردر.', 'The amount does not equal the order total.');
  if (t.contains('INVALID_INPUT')) return _t(c, 'البيانات مش مظبوطة. راجع المبلغ والأوردر.', 'The details are not right. Check the amount and the order.');
  if (t.contains('FORBIDDEN')) return _t(c, 'مش مسموحلك.', 'Not allowed.');
  return friendlyError(c, e);
}

class WalletInboxPanel extends ConsumerStatefulWidget {
  const WalletInboxPanel({super.key});
  @override
  ConsumerState<WalletInboxPanel> createState() => _WalletInboxPanelState();
}

class _WalletInboxPanelState extends ConsumerState<WalletInboxPanel> {
  Timer? _live;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // live: re-read every 8 seconds while the page is open
    _live = Timer.periodic(const Duration(seconds: 8), (_) {
      if (mounted) ref.invalidate(_inboxProvider);
    });
  }

  @override
  void dispose() {
    _live?.cancel();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() job) async {
    setState(() => _busy = true);
    try {
      await job();
    } catch (e) {
      if (mounted) showSnack(context, _err(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _refreshAll() {
    ref.invalidate(_inboxProvider);
    ref.invalidate(_balanceProvider);
  }

  Future<void> _match(Map<String, dynamic> t, Map<String, dynamic> o) => _run(() async {
        await ref.read(supabaseProvider).rpc('wallet_transfer_match', params: {'p_transfer': t['id'], 'p_order': o['order_id']});
        _refreshAll();
        if (mounted) showSnack(context, _t(context, 'اتأكد الدفع وربطناه بالأوردر ${o['reference']}', 'Payment confirmed and linked to order ${o['reference']}'));
      });

  Future<void> _ignore(Map<String, dynamic> t) => _run(() async {
        await ref.read(supabaseProvider).rpc('wallet_transfer_ignore', params: {'p_transfer': t['id']});
        _refreshAll();
      });

  Future<void> _withdraw() async {
    String wallet = 'vodafone';
    final amount = TextEditingController(), note = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => StatefulBuilder(
        builder: (d, set) => AlertDialog(
          title: Text(_t(d, 'تسجيل سحب فلوس من محفظة', 'Record a withdrawal from a wallet')),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            DropdownButton<String>(
              value: wallet,
              isExpanded: true,
              items: [for (final w in const ['vodafone', 'etisalat', 'instapay']) DropdownMenuItem(value: w, child: Text(_walletName(d, w)))],
              onChanged: (v) => set(() => wallet = v ?? wallet),
            ),
            TextField(controller: amount, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: _t(d, 'المبلغ (جنيه)', 'Amount (EGP)'))),
            const SizedBox(height: 8),
            TextField(controller: note, decoration: InputDecoration(labelText: _t(d, 'ملاحظة (مثلا: سحب للخزنة)', 'Note (e.g. cashed out to the safe)'))),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: Text(_t(d, 'إلغاء', 'Cancel'))),
            FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(_t(d, 'تسجيل', 'Record'))),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final v = double.tryParse(amount.text.trim().replaceAll(',', ''));
    if (v == null || v <= 0) {
      if (mounted) showSnack(context, _t(context, 'اكتب مبلغ صحيح.', 'Enter a valid amount.'), error: true);
      return;
    }
    await _run(() async {
      await ref.read(supabaseProvider).rpc('wallet_withdrawal_log', params: {'p_wallet': wallet, 'p_amount_minor': (v * 100).round(), 'p_note': note.text.trim()});
      _refreshAll();
      if (mounted) showSnack(context, _t(context, 'اتسجل السحب', 'Withdrawal recorded'));
    });
  }

  Future<void> _refund() async {
    final ref0 = TextEditingController(), amount = TextEditingController(), txn = TextEditingController(), note = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(_t(d, 'مرتجع أوردر اتدفع بمحفظة', 'Refund a wallet order')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: ref0, decoration: InputDecoration(labelText: _t(d, 'رقم الأوردر (مثلا MH-1234)', 'Order number (e.g. MH-1234)'))),
          const SizedBox(height: 8),
          TextField(controller: amount, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: _t(d, 'المبلغ المرتجع (جنيه)', 'Refund amount (EGP)'))),
          const SizedBox(height: 8),
          TextField(controller: txn, decoration: InputDecoration(labelText: _t(d, 'رقم عملية التحويل الراجع', 'Reference of the transfer you sent back'))),
          const SizedBox(height: 8),
          TextField(controller: note, decoration: InputDecoration(labelText: _t(d, 'السبب', 'Reason'))),
          const SizedBox(height: 8),
          Text(_t(d, 'التحويل الفعلي للعميل بيتعمل من تليفون المحفظة. هنا بنسجّله بس.', 'The actual transfer is made from the wallet phone. Here we only record it.'), style: const TextStyle(fontSize: 12, color: BrandColors.gray)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(_t(d, 'إلغاء', 'Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(_t(d, 'تسجيل المرتجع', 'Record refund'))),
        ],
      ),
    );
    if (ok != true) return;
    final v = double.tryParse(amount.text.trim().replaceAll(',', ''));
    if (v == null || v <= 0 || ref0.text.trim().isEmpty) {
      if (mounted) showSnack(context, _t(context, 'اكتب رقم الأوردر ومبلغ صحيح.', 'Enter the order number and a valid amount.'), error: true);
      return;
    }
    await _run(() async {
      final o = await ref.read(supabaseProvider).from('orders').select('id').eq('reference', ref0.text.trim()).maybeSingle();
      if (o == null) throw 'INVALID_INPUT';
      await ref.read(supabaseProvider).rpc('wallet_refund', params: {'p_order': o['id'], 'p_amount_minor': (v * 100).round(), 'p_reference': txn.text.trim(), 'p_note': note.text.trim()});
      _refreshAll();
      if (mounted) showSnack(context, _t(context, 'اتسجل المرتجع', 'Refund recorded'));
    });
  }

  Future<void> _setEnabled(bool on) => _run(() async {
        await ref.read(supabaseProvider).rpc('wallet_inbox_set', params: {'p_enabled': on});
        ref.invalidate(_stateProvider);
        ref.invalidate(_inboxProvider);
      });

  Future<void> _setAuto(bool on) => _run(() async {
        await ref.read(supabaseProvider).rpc('wallet_inbox_set_auto', params: {'p_on': on});
        ref.invalidate(_stateProvider);
      });

  Future<void> _newKey() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(_t(d, 'مفتاح جديد؟', 'New key?')),
        content: Text(_t(d, 'المفتاح القديم هيقف شغال فورًا، ولازم تحط الجديد في تطبيق الرسايل على تليفون المكتب. المفتاح الجديد بيظهر مرة واحدة بس.',
            'The old key stops working at once, and you must put the new one in the SMS app on the office phone. The new key is shown only once.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(_t(d, 'لأ', 'No'))),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(_t(d, 'أيوه، اعمل مفتاح', 'Yes, make a key'))),
        ],
      ),
    );
    if (sure != true) return;
    await _run(() async {
      final tok = await ref.read(supabaseProvider).rpc('wallet_inbox_token_rotate') as String;
      ref.invalidate(_stateProvider);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (d) => AlertDialog(
          title: Text(_t(d, 'المفتاح السري (بيظهر مرة واحدة)', 'The secret key (shown once)')),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SelectableText(tok, style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                OutlinedButton.icon(onPressed: () => Clipboard.setData(ClipboardData(text: tok)), icon: const Icon(Icons.copy_rounded, size: 16), label: Text(_t(d, 'نسخ المفتاح', 'Copy the key'))),
                const Divider(height: 24),
                Text(_t(d, 'الرابط اللي تحطه في تطبيق الرسايل:', 'The address to put in the SMS app:'), style: const TextStyle(fontWeight: FontWeight.w700)),
                SelectableText(_hookUrl),
                const SizedBox(height: 6),
                OutlinedButton.icon(onPressed: () => Clipboard.setData(const ClipboardData(text: _hookUrl)), icon: const Icon(Icons.copy_rounded, size: 16), label: Text(_t(d, 'نسخ الرابط', 'Copy the address'))),
                const SizedBox(height: 12),
                Text(_t(d, 'احفظ المفتاح في مكان آمن ومتبعتوش لحد. لو ضاع، اعمل مفتاح جديد.', 'Keep the key safe and share it with nobody. If lost, make a new one.')),
              ]),
            ),
          ),
          actions: [FilledButton(onPressed: () => Navigator.pop(d), child: Text(_t(d, 'تمام، حفظته', 'Done, I saved it')))],
        ),
      );
    });
  }

  Future<void> _howTo() async {
    await showDialog<void>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(_t(d, 'إزاي أركّب الاستقبال على تليفون المكتب', 'How to set up the inbox on the office phone')),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Text(_t(d,
                '1) على تليفون المكتب (اللي فيه شريحة المحفظة) نزّل تطبيق «SMS Forwarder» أو أي تطبيق بيبعت الرسايل لرابط ويب (Webhook).\n'
                '2) اديله إذن قراءة الرسايل واتركه شغال في الخلفية، وشيّل عنه توفير البطارية.\n'
                '3) اعمل قاعدة: لو الرسالة جاية من فودافون كاش أو اتصالات كاش، ابعتها بطريقة POST للرابط (انسخه من زرار «مفتاح جديد»).\n'
                '4) أضف في الـ Headers: x-hook-token ومعاه المفتاح السري. ولو التطبيق ما بيدعمش Headers حط المفتاح في آخر الرابط هكذا: ‎?token=المفتاح‎\n'
                '5) شكل البيانات (JSON): {"from":"اسم المرسل","text":"نص الرسالة"}. لو التطبيق عنده متغيرات، "from" هو المرسل و"text" هو نص الرسالة.\n'
                '6) شغّل «تفعيل الاستقبال» من هنا، وابعت تحويل صغير لنفسك وشوفه يظهر خلال ثواني.\n\n'
                'مهم: لازم رسايل المحفظة توصل على نفس التليفون. والتطبيق ده بيسجّل الرسايل بس ومايقدرش يحوّل فلوس.',
                '1) On the office phone (with the wallet SIM) install an "SMS Forwarder" app, or any app that sends SMS to a web address (webhook).\n'
                '2) Give it permission to read SMS, keep it running in the background and turn off battery saving for it.\n'
                '3) Make a rule: if the SMS comes from Vodafone Cash or Etisalat Cash, POST it to the address (copy it from "New key").\n'
                '4) Add a header x-hook-token with the secret key. If the app has no headers, add ?token=KEY to the end of the address.\n'
                '5) Body (JSON): {"from":"sender name","text":"the SMS text"}.\n'
                '6) Switch the inbox on here, send a small transfer to yourself and watch it appear within seconds.\n\n'
                'Important: the wallet SMS must arrive on that same phone. This only records messages; it cannot move money.')),
          ),
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(d), child: Text(_t(d, 'تمام', 'OK')))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final perms = ref.watch(staffContextProvider).valueOrNull?.permissions ?? const <String>{};
    final canLink = perms.contains('orders.confirm_wallet');
    final acct = perms.contains('wallet.refund');
    final owner = perms.contains('wallet.manage');
    final async = ref.watch(_inboxProvider);
    return ListView(padding: const EdgeInsets.all(16), children: [
      if (owner) _ownerCard(context),
      if (acct) _balanceCard(context),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(child: Text(_t(context, 'التحويلات الواصلة (بتتحدّث لوحدها)', 'Incoming transfers (updates by itself)'), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
        if (acct) TextButton.icon(onPressed: _busy ? null : _refund, icon: const Icon(Icons.undo_rounded, size: 18), label: Text(_t(context, 'مرتجع محفظة', 'Wallet refund'))),
      ]),
      async.when(
        loading: () => const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
        error: (e, _) => ErrorView(error: _err(context, e), onRetry: () => ref.invalidate(_inboxProvider)),
        data: (r) {
          final list = [for (final e in (r['transfers'] as List? ?? const [])) Map<String, dynamic>.from(e as Map)];
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (r['enabled'] != true)
              Card(
                color: const Color(0xFFFFF7E6),
                child: Padding(padding: const EdgeInsets.all(14), child: Text(_t(context, 'استقبال الرسايل لسه مش مفعّل. المالك هيفعّله ويركّبه على تليفون المكتب.', 'The SMS inbox is not switched on yet. The owner will switch it on and set it up on the office phone.'))),
              ),
            if (list.isEmpty && r['enabled'] == true) Padding(padding: const EdgeInsets.all(20), child: Text(_t(context, 'لسه مفيش تحويلات وصلت.', 'No transfers yet.'))),
            for (final t in list) _transferCard(context, t, canLink, acct),
          ]);
        },
      ),
    ]);
  }

  Widget _ownerCard(BuildContext context) {
    final st = ref.watch(_stateProvider);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: st.when(
          loading: () => const LinearProgressIndicator(),
          error: (e, _) => Text(_err(context, e)),
          data: (s) {
            final has = s['has_token'] == true;
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_t(context, 'تشغيل الاستقبال (للمالك)', 'Inbox setup (owner)'), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              const SizedBox(height: 6),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(_t(context, 'تفعيل استقبال رسايل المحافظ', 'Switch the wallet SMS inbox on')),
                subtitle: Text(has ? _t(context, 'لو قفلته، أي رسالة جاية هتتجاهل.', 'When off, any incoming message is ignored.') : _t(context, 'اعمل مفتاح الأول.', 'Make a key first.')),
                value: s['enabled'] == true,
                onChanged: (_busy || !has) ? null : _setEnabled,
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(_t(context, 'تأكيد الدفع تلقائي', 'Confirm payments automatically')),
                subtitle: Text(_t(context, 'لما توصل رسالة حقيقية من المحفظة بنفس المبلغ ومن نفس رقم العميل، الأوردر يتأكد لوحده. أي حالة مش واضحة بتفضل لمراجعة الفريق.',
                    'When the real wallet SMS arrives with the same amount and from the customer\'s number, the order is confirmed by itself. Unclear cases stay for the team.')),
                value: s['auto_confirm'] == true,
                onChanged: (_busy || !has || s['enabled'] != true) ? null : _setAuto,
              ),
              Wrap(spacing: 8, children: [
                OutlinedButton.icon(onPressed: _busy ? null : _newKey, icon: const Icon(Icons.vpn_key_outlined, size: 18), label: Text(has ? _t(context, 'مفتاح جديد', 'New key') : _t(context, 'اعمل المفتاح', 'Make the key'))),
                TextButton.icon(onPressed: _howTo, icon: const Icon(Icons.help_outline_rounded, size: 18), label: Text(_t(context, 'إزاي أركّبه؟', 'How do I set it up?'))),
              ]),
              if (s['last_received'] != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(_t(context, 'آخر رسالة وصلت: ${_ago(context, s['last_received'])}', 'Last message: ${_ago(context, s['last_received'])}'), style: const TextStyle(color: BrandColors.gray, fontSize: 12.5))),
            ]);
          },
        ),
      ),
    );
  }

  Widget _balanceCard(BuildContext context) {
    final b = ref.watch(_balanceProvider);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(_t(context, 'الرصيد المتوقع في كل محفظة', 'Expected balance per wallet'), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
            TextButton.icon(onPressed: _busy ? null : _withdraw, icon: const Icon(Icons.north_east_rounded, size: 18), label: Text(_t(context, 'سجّل سحب', 'Record withdrawal'))),
          ]),
          Text(_t(context, 'المتوقع = اللي وصل - المرتجعات - اللي اتسحب. قارنه برصيد المحفظة الحقيقي على التليفون.', 'Expected = received - refunds - withdrawn. Compare it with the real balance on the phone.'), style: const TextStyle(color: BrandColors.gray, fontSize: 12.5)),
          const SizedBox(height: 8),
          b.when(
            loading: () => const LinearProgressIndicator(),
            error: (e, _) => Text(_err(context, e)),
            data: (rows) => Column(children: [
              for (final w in rows)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(_walletName(context, '${w['wallet']}'), style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text(_t(context, 'وصل ${_egp(context, _n(w['received_minor']))} - مرتجع ${_egp(context, _n(w['refunds_minor']))} - اتسحب ${_egp(context, _n(w['withdrawn_minor']))}${_n(w['unlinked_minor']) > 0 ? ' - لسه مش مربوط ${_egp(context, _n(w['unlinked_minor']))}' : ''}',
                      'In ${_egp(context, _n(w['received_minor']))} - refunds ${_egp(context, _n(w['refunds_minor']))} - withdrawn ${_egp(context, _n(w['withdrawn_minor']))}${_n(w['unlinked_minor']) > 0 ? ' - not linked ${_egp(context, _n(w['unlinked_minor']))}' : ''}')),
                  trailing: Text(_egp(context, _n(w['received_minor']) - _n(w['refunds_minor']) - _n(w['withdrawn_minor'])), style: const TextStyle(fontWeight: FontWeight.w800)),
                ),
            ]),
          ),
        ]),
      ),
    );
  }

  String _ago(BuildContext c, Object? at) {
    final d = DateTime.tryParse('$at')?.toLocal();
    if (d == null) return '';
    final m = DateTime.now().difference(d).inMinutes;
    if (m < 1) return _t(c, 'دلوقتي', 'just now');
    if (m < 60) return _t(c, 'من $m دقيقة', '$m min ago');
    if (m < 1440) return _t(c, 'من ${m ~/ 60} ساعة', '${m ~/ 60} h ago');
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  Widget _transferCard(BuildContext context, Map<String, dynamic> t, bool canLink, bool acct) {
    final matched = t['status'] == 'matched';
    final sug = [for (final e in (t['suggest'] as List? ?? const [])) Map<String, dynamic>.from(e as Map)];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(matched ? Icons.check_circle_rounded : Icons.fiber_new_rounded, color: matched ? const Color(0xFF12B76A) : const Color(0xFFE8A317)),
            const SizedBox(width: 8),
            Expanded(child: Text(t['amount_minor'] == null ? _t(context, 'رسالة مش مفهومة', 'Unreadable message') : _egp(context, _n(t['amount_minor'])), style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 17))),
            Text(_walletName(context, '${t['wallet']}')),
          ]),
          const SizedBox(height: 4),
          Wrap(spacing: 14, runSpacing: 2, children: [
            Text(_t(context, 'من: ${t['sender'] ?? 'غير معروف'}', 'From: ${t['sender'] ?? 'unknown'}')),
            if (t['reference'] != null) Text(_t(context, 'رقم العملية: ${t['reference']}', 'Ref: ${t['reference']}')),
            Text(_ago(context, t['at']), style: const TextStyle(color: BrandColors.gray)),
          ]),
          if (t['raw'] != null) Padding(padding: const EdgeInsets.only(top: 4), child: SelectableText('${t['raw']}', style: const TextStyle(fontSize: 12.5, color: BrandColors.gray))),
          if (matched) Padding(padding: const EdgeInsets.only(top: 4), child: Text(_t(context, 'اتربط بالأوردر ${t['order']}', 'Linked to order ${t['order']}'), style: const TextStyle(color: Color(0xFF12B76A), fontWeight: FontWeight.w700))),
          if (!matched) ...[
            const SizedBox(height: 6),
            if (sug.isEmpty) Text(_t(context, 'مفيش أوردر مطابق بالمبلغ ده لسه.', 'No order matches this amount yet.'), style: const TextStyle(color: BrandColors.gray)),
            Wrap(spacing: 8, runSpacing: 6, children: [
              for (final o in sug)
                if (canLink)
                  FilledButton.icon(
                    onPressed: _busy ? null : () => _match(t, o),
                    icon: const Icon(Icons.link_rounded, size: 18),
                    label: Text(_t(context, 'استلمت وربطها بـ ${o['reference']}${o['exact'] == true ? ' (نفس الرقم)' : ''}', 'Received, link to ${o['reference']}${o['exact'] == true ? ' (same number)' : ''}')),
                  )
                else
                  Chip(label: Text(_t(context, 'يطابق ${o['reference']}', 'Matches ${o['reference']}'))),
              if (acct) TextButton(onPressed: _busy ? null : () => _ignore(t), child: Text(_t(context, 'مش دفعة أوردر، إخفاء', 'Not an order payment, hide'))),
            ]),
          ],
        ]),
      ),
    );
  }
}
