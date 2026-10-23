// New customer accounts waiting for approval: accept (activates sign-in right away) or reject.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/theme.dart';
import '../../shared/states.dart';
import 'admin_repository.dart';
import 'documents.dart' show waDigits;

String _t(BuildContext c, String ar, String en) => c.isAr ? ar : en;

final accountsFilterProvider = StateProvider<String>((_) => 'pending');
final pendingAccountsCountProvider = FutureProvider.autoDispose<int>((ref) => ref.watch(adminRepoProvider).pendingAccountsCount());
final _accountsProvider = FutureProvider.autoDispose((ref) => ref.watch(adminRepoProvider).accounts(ref.watch(accountsFilterProvider)));

String _ago(BuildContext context, String iso) {
  final d = DateTime.now().difference(DateTime.parse(iso).toLocal());
  final ar = context.isAr;
  if (d.inMinutes < 1) return ar ? 'دلوقتي' : 'just now';
  if (d.inMinutes < 60) return ar ? 'من ${d.inMinutes} دقيقة' : '${d.inMinutes} min ago';
  if (d.inHours < 24) return ar ? 'من ${d.inHours} ساعة' : '${d.inHours} h ago';
  return ar ? 'من ${d.inDays} يوم' : '${d.inDays} d ago';
}

class AccountsTabIcon extends ConsumerWidget {
  const AccountsTabIcon({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final n = ref.watch(pendingAccountsCountProvider).valueOrNull ?? 0;
    return Badge(isLabelVisible: n > 0, label: Text('$n'), child: const Icon(Icons.how_to_reg_outlined));
  }
}

class AccountsTab extends ConsumerWidget {
  const AccountsTab({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(accountsFilterProvider);
    final data = ref.watch(_accountsProvider);
    final pending = ref.watch(pendingAccountsCountProvider).valueOrNull ?? 0;
    Widget chip(String value, String label, IconData icon) => Padding(
          padding: const EdgeInsetsDirectional.only(end: 8),
          child: ChoiceChip(
            avatar: Icon(icon, size: 16),
            label: Text(label),
            selected: filter == value,
            onSelected: (_) => ref.read(accountsFilterProvider.notifier).state = value,
          ),
        );
    return Column(children: [
      SizedBox(
        height: 54,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.fromLTRB(12, 10, 12, 4), children: [
          chip('pending', '${_t(context, 'مستني التوثيق', 'Waiting')}${pending > 0 ? ' ($pending)' : ''}', Icons.hourglass_top_rounded),
          chip('approved', _t(context, 'اتوثّقت', 'Verified'), Icons.verified_user_outlined),
          chip('rejected', _t(context, 'مرفوضة', 'Rejected'), Icons.block_rounded),
        ]),
      ),
      Expanded(
        child: RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(_accountsProvider);
            ref.invalidate(pendingAccountsCountProvider);
          },
          child: data.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(_accountsProvider)),
            data: (list) => list.isEmpty
                ? ListView(children: [
                    const SizedBox(height: 80),
                    Icon(filter == 'pending' ? Icons.celebration_rounded : Icons.inbox_outlined, size: 48, color: BrandColors.gray),
                    const SizedBox(height: 10),
                    Center(
                      child: Text(filter == 'pending'
                          ? _t(context, 'مفيش حسابات مستنية توثيق 👌', 'No accounts waiting 👌')
                          : _t(context, 'مفيش حسابات هنا', 'Nothing here')),
                    ),
                  ])
                : ListView.separated(
                    padding: const EdgeInsets.all(12),
                    itemCount: list.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (_, i) => _AccountCard(key: ValueKey(list[i]['user_id']), account: list[i]),
                  ),
          ),
        ),
      ),
    ]);
  }
}

class _AccountCard extends ConsumerStatefulWidget {
  const _AccountCard({super.key, required this.account});
  final Map<String, dynamic> account;
  @override
  ConsumerState<_AccountCard> createState() => _AccountCardState();
}

class _AccountCardState extends ConsumerState<_AccountCard> {
  bool _busy = false;
  String? _done; // 'approved' | 'rejected' after acting here

  Map<String, dynamic> get a => widget.account;

  void _refresh() {
    ref.invalidate(_accountsProvider);
    ref.invalidate(pendingAccountsCountProvider);
  }

  Future<void> _approve() async {
    setState(() => _busy = true);
    try {
      await ref.read(adminRepoProvider).activateAccount(a['user_id'] as String);
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      setState(() => _done = 'approved');
      final phone = a['phone'] as String?;
      showSnack(
        context,
        _t(context, 'اتوثّق الحساب ✅ يقدر يطلب دلوقتي', 'Verified ✅ they can order now'),
        action: phone == null
            ? null
            : SnackBarAction(
                label: _t(context, 'بلّغه واتساب', 'Tell on WhatsApp'),
                onPressed: () => launchUrl(
                  Uri.parse('https://wa.me/${waDigits(phone)}?text=${Uri.encodeComponent('أهلاً ${_firstName()} 👋\nحسابك على My Hatō اتوثّق ✅ تقدر تطلب دلوقتي من التطبيق.')}'),
                  mode: LaunchMode.externalApplication,
                ),
              ),
      );
      Future.delayed(const Duration(milliseconds: 900), _refresh);
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reject() async {
    final reason = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _RejectSheet(),
    );
    if (reason == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(adminRepoProvider).rejectAccount(a['user_id'] as String, reason);
      if (!mounted) return;
      setState(() => _done = 'rejected');
      showSnack(context, _t(context, 'اترفض الحساب', 'Account rejected'));
      Future.delayed(const Duration(milliseconds: 900), _refresh);
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _firstName() => ((a['full_name'] as String?) ?? '').trim().split(' ').first;

  Widget _info(IconData icon, String text, {bool ltr = false, bool copy = false}) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(children: [
          Icon(icon, size: 16, color: BrandColors.gray),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                textDirection: ltr ? TextDirection.ltr : null,
                textAlign: ltr && context.isAr ? TextAlign.right : null,
                style: const TextStyle(fontSize: 13.5)),
          ),
          if (copy)
            InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () {
                Clipboard.setData(ClipboardData(text: text));
                showSnack(context, _t(context, 'اتنسخ', 'Copied'));
              },
              child: const Padding(padding: EdgeInsets.all(4), child: Icon(Icons.copy_rounded, size: 16, color: BrandColors.gray)),
            ),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final status = _done ?? a['review_status'] as String;
    final name = ((a['full_name'] as String?) ?? '').trim();
    final phone = a['phone'] as String?;
    final email = a['email'] as String?;
    final username = a['username'] as String?;
    final initial = name.isNotEmpty ? name.characters.first : '?';
    final (Color color, String label, IconData icon) = switch (status) {
      'approved' => (BrandColors.success, _t(context, 'موثّق', 'Verified'), Icons.verified_rounded),
      'rejected' => (BrandColors.error, _t(context, 'مرفوض', 'Rejected'), Icons.block_rounded),
      _ => (BrandColors.warning, _t(context, 'مستني التوثيق', 'Waiting'), Icons.hourglass_top_rounded),
    };

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 300),
      opacity: _done != null ? 0.55 : 1,
      child: Material(
        color: Colors.white,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: BrandColors.border)),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: BrandColors.navy.withValues(alpha: 0.08),
                child: Text(initial, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18, color: BrandColors.navy)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(name.isEmpty ? _t(context, 'بدون اسم', 'No name') : name,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                  const SizedBox(height: 2),
                  Text('${a['customer_code']} • ${_ago(context, a['created_at'] as String)}',
                      style: const TextStyle(color: BrandColors.gray, fontSize: 12)),
                ]),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(icon, size: 14, color: color),
                  const SizedBox(width: 4),
                  Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 12)),
                ]),
              ),
            ]),
            const SizedBox(height: 4),
            if (phone != null) _info(Icons.phone_iphone_rounded, phone, ltr: true, copy: true),
            if (username != null) _info(Icons.alternate_email_rounded, username, ltr: true),
            if (email != null && !email.endsWith('.myhato.app')) _info(Icons.mail_outline_rounded, email, ltr: true),
            if (status == 'rejected' && (a['reject_reason'] as String?) != null)
              _info(Icons.info_outline_rounded, '${_t(context, 'السبب', 'Reason')}: ${a['reject_reason']}'),
            const SizedBox(height: 12),
            if (_busy)
              const Center(child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator()))
            else if (_done == null) ...[
              if (status != 'approved')
                Row(children: [
                  Expanded(
                    flex: 3,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(backgroundColor: BrandColors.success, minimumSize: const Size.fromHeight(46)),
                      icon: const Icon(Icons.check_circle_rounded, size: 20),
                      label: Text(_t(context, 'توثيق الحساب', 'Verify')),
                      onPressed: _approve,
                    ),
                  ),
                  if (status == 'pending') ...[
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: BrandColors.error,
                          side: const BorderSide(color: BrandColors.error),
                          minimumSize: const Size.fromHeight(46),
                        ),
                        icon: const Icon(Icons.close_rounded, size: 20),
                        label: Text(_t(context, 'رفض', 'Reject')),
                        onPressed: _reject,
                      ),
                    ),
                  ],
                ]),
              if (phone != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(children: [
                    Expanded(
                      child: TextButton.icon(
                        icon: const Icon(Icons.call_rounded, size: 18),
                        label: Text(_t(context, 'اتصال', 'Call')),
                        onPressed: () => launchUrl(Uri.parse('tel:${phone.replaceAll(' ', '')}')),
                      ),
                    ),
                    Expanded(
                      child: TextButton.icon(
                        style: TextButton.styleFrom(foregroundColor: const Color(0xFF1DA851)),
                        icon: const Icon(Icons.chat_rounded, size: 18),
                        label: Text(_t(context, 'واتساب', 'WhatsApp')),
                        onPressed: () => launchUrl(
                          Uri.parse('https://wa.me/${waDigits(phone)}?text=${Uri.encodeComponent('أهلاً ${_firstName()} 👋 معاك My Hatō بخصوص حسابك الجديد.')}'),
                          mode: LaunchMode.externalApplication,
                        ),
                      ),
                    ),
                  ]),
                ),
            ] else
              Center(
                child: Text(_done == 'approved' ? _t(context, 'اتوثّق ✅', 'Verified ✅') : _t(context, 'اترفض', 'Rejected'),
                    style: TextStyle(fontWeight: FontWeight.w800, color: _done == 'approved' ? BrandColors.success : BrandColors.error)),
              ),
          ]),
        ),
      ),
    );
  }
}

class _RejectSheet extends StatefulWidget {
  const _RejectSheet();
  @override
  State<_RejectSheet> createState() => _RejectSheetState();
}

class _RejectSheetState extends State<_RejectSheet> {
  final _ctl = TextEditingController();
  String? _picked;

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reasons = context.isAr
        ? ['بيانات ناقصة أو غلط', 'رقم الموبايل مش شغال', 'حساب مكرر', 'حساب وهمي / تجريبي']
        : ['Missing or wrong details', 'Phone number not reachable', 'Duplicate account', 'Fake / test account'];
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.viewInsetsOf(context).bottom + 20),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(_t(context, 'رفض الحساب', 'Reject account'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Text(_t(context, 'العميل مش هيقدر يطلب. تقدر توثّقه بعدين من تبويب "مرفوضة".', 'They will not be able to order. You can still verify later from "Rejected".'),
            style: const TextStyle(color: BrandColors.gray, fontSize: 13)),
        const SizedBox(height: 14),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final r in reasons)
            ChoiceChip(
              label: Text(r),
              selected: _picked == r,
              onSelected: (_) => setState(() {
                _picked = r;
                _ctl.text = r;
              }),
            ),
        ]),
        const SizedBox(height: 12),
        TextField(
          controller: _ctl,
          maxLength: 300,
          decoration: InputDecoration(hintText: _t(context, 'سبب الرفض (اختياري)', 'Reason (optional)')),
        ),
        const SizedBox(height: 8),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: BrandColors.error, minimumSize: const Size.fromHeight(48)),
          onPressed: () => Navigator.pop(context, _ctl.text.trim()),
          child: Text(_t(context, 'تأكيد الرفض', 'Confirm reject')),
        ),
      ]),
    );
  }
}
