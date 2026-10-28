// New customer accounts waiting for approval: accept (activates sign-in right away) or reject.
import '../../core/save_file.dart';
import '../../core/appearance.dart';
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:excel/excel.dart' as xl;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:url_launcher/url_launcher.dart';

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/money.dart';
import '../../core/theme.dart';
import '../../shared/states.dart';
import 'admin_repository.dart';
import 'documents.dart' show waDigits;

String _t(BuildContext c, String ar, String en) => c.isAr ? ar : en;

final accountsFilterProvider = StateProvider<String>((_) => 'pending');
final pendingAccountsCountProvider = FutureProvider.autoDispose<int>((ref) => ref.watch(adminRepoProvider).pendingAccountsCount());
final customersSearchProvider = StateProvider<String>((_) => '');
final _accountsProvider = FutureProvider.autoDispose((ref) {
  final filter = ref.watch(accountsFilterProvider);
  final repo = ref.watch(adminRepoProvider);
  return filter == 'all' ? repo.customers(ref.watch(customersSearchProvider)) : repo.accounts(filter);
});

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
          chip('all', _t(context, 'كل العملاء', 'All customers'), Icons.groups_2_outlined),
        ]),
      ),
      if (filter == 'all') const _CustomersToolbar(),
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
                    itemBuilder: (_, i) => filter == 'all' ? _CustomerTile(key: ValueKey(list[i]['user_id']), c: list[i]) : _AccountCard(key: ValueKey(list[i]['user_id']), account: list[i]),
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
                  Uri.parse('https://wa.me/${waDigits(phone)}?text=${Uri.encodeComponent('أهلاً ${_firstName()} 👋\nحسابك على ${AppName.ar} اتوثّق ✅ تقدر تطلب دلوقتي من التطبيق.')}'),
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
                  Text('${a['is_staff'] == true ? '${_t(context, 'موظف', 'Team')} • ' : ''}${a['customer_code']} • ${_ago(context, a['created_at'] as String)}',
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
                          Uri.parse('https://wa.me/${waDigits(phone)}?text=${Uri.encodeComponent('أهلاً ${_firstName()} 👋 معاك ${AppName.ar} بخصوص حسابك الجديد.')}'),
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


/// Search box and "copy all emails" for the full customers list.
class _CustomersToolbar extends ConsumerStatefulWidget {
  const _CustomersToolbar();
  @override
  ConsumerState<_CustomersToolbar> createState() => _CustomersToolbarState();
}

class _CustomersToolbarState extends ConsumerState<_CustomersToolbar> {
  final _c = TextEditingController();
  bool _busy = false;
  bool _exporting = false;
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _c.dispose();
    super.dispose();
  }

  /// Every customer with all the details, as an Excel file (the current search is ignored: it is the whole list).
  Future<void> _export() async {
    setState(() => _exporting = true);
    try {
      final repo = ref.read(adminRepoProvider);
      final rows = <Map<String, dynamic>>[];
      for (var offset = 0; offset < 20000; offset += 500) {
        final page = await repo.customers(null, offset: offset, limit: 500);
        rows.addAll(page);
        if (page.length < 500) break;
      }
      final book = xl.Excel.createExcel();
      final name = _t(context, 'العملاء', 'Customers');
      final sheet = book['Sheet1'];
      book.rename('Sheet1', name);
      final heads = [
        _t(context, 'الاسم', 'Name'), _t(context, 'الإيميل', 'Email'), _t(context, 'الإيميل متأكد منه', 'Email confirmed'),
        _t(context, 'الموبايل', 'Phone'), _t(context, 'اسم المستخدم', 'User name'), _t(context, 'كود العميل', 'Customer code'),
        _t(context, 'الحالة', 'Status'), _t(context, 'بيدخل بـ', 'Signs in with'), _t(context, 'تاريخ التسجيل', 'Registered'),
        _t(context, 'آخر دخول', 'Last sign-in'), _t(context, 'عدد الطلبات', 'Orders'), _t(context, 'اشترى بـ (ج.م)', 'Bought (EGP)'), _t(context, 'آخر طلب', 'Last order'),
      ];
      sheet.appendRow([for (final h in heads) xl.TextCellValue(h)]);
      String d(Object? iso) => iso == null ? '' : DateFormat('yyyy-MM-dd HH:mm').format(DateTime.parse('$iso').toLocal());
      for (final c in rows) {
        final email = (c['email'] as String?) ?? '';
        final status = switch (c['review_status']) {
          'approved' => _t(context, 'موثّق', 'Verified'),
          'rejected' => _t(context, 'مرفوض', 'Rejected'),
          _ => _t(context, 'مستني التوثيق', 'Waiting'),
        };
        sheet.appendRow([
          xl.TextCellValue('${c['full_name'] ?? ''}'),
          xl.TextCellValue(email.endsWith('.myhato.app') ? '' : email),
          xl.TextCellValue(c['email_confirmed'] == true ? _t(context, 'أيوه', 'Yes') : _t(context, 'لأ', 'No')),
          xl.TextCellValue('${c['phone'] ?? ''}'),
          xl.TextCellValue('${c['username'] ?? ''}'),
          xl.TextCellValue('${c['customer_code'] ?? ''}'),
          xl.TextCellValue(status),
          xl.TextCellValue('${c['provider'] ?? ''}'),
          xl.TextCellValue(d(c['created_at'])),
          xl.TextCellValue(d(c['last_sign_in_at'])),
          xl.IntCellValue(((c['orders_count'] as num?) ?? 0).toInt()),
          xl.DoubleCellValue((((c['delivered_total_minor'] as num?) ?? 0) / 100).toDouble()),
          xl.TextCellValue(d(c['last_order_at'])),
        ]);
      }
      final bytes = book.save();
      if (bytes == null) throw StateError('empty file');
      final file = 'myhato-customers-${DateFormat('yyyyMMdd').format(DateTime.now())}.xlsx';
      if (mounted) await deliverFile(context, Uint8List.fromList(bytes), file, xlsxMime);
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(context, e), error: true);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _copyAll() async {
    setState(() => _busy = true);
    try {
      final emails = await ref.read(adminRepoProvider).customerEmails();
      await Clipboard.setData(ClipboardData(text: emails.join('\n')));
      if (mounted) showSnack(context, _t(context, 'اتنسخ ${emails.length} إيميل.', 'Copied ${emails.length} emails.'));
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: _c,
              textInputAction: TextInputAction.search,
              onSubmitted: (v) => ref.read(customersSearchProvider.notifier).state = v,
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search_rounded),
                hintText: _t(context, 'ابحث بالموبايل أو الإيميل أو الاسم', 'Search phone, email or name'),
                suffixIcon: _c.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close_rounded, size: 18),
                        onPressed: () {
                          _c.clear();
                          ref.read(customersSearchProvider.notifier).state = '';
                          setState(() {});
                        }),
              ),
              onChanged: (v) {
                setState(() {});
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 450), () => ref.read(customersSearchProvider.notifier).state = v);
              },
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filledTonal(
            tooltip: _t(context, 'نسخ كل الإيميلات', 'Copy all emails'),
            onPressed: _busy ? null : _copyAll,
            icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.alternate_email_rounded),
          ),
          const SizedBox(width: 4),
          IconButton.filledTonal(
            tooltip: _t(context, 'تصدير كل العملاء Excel', 'Export all customers to Excel'),
            onPressed: _exporting ? null : _export,
            icon: _exporting ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.download_rounded),
          ),
        ]),
      );
}

/// One customer in the full list: name and email on top, everything else when opened.
class _CustomerTile extends ConsumerWidget {
  const _CustomerTile({super.key, required this.c});
  final Map<String, dynamic> c;

  String _date(BuildContext context, String? iso) => iso == null ? '—' : DateFormat('yyyy-MM-dd HH:mm', context.lang).format(DateTime.parse(iso).toLocal());

  Widget _row(BuildContext context, String label, String? value, {bool copy = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 108, child: Text(label, style: const TextStyle(color: BrandColors.gray, fontSize: 12.5))),
          Expanded(child: SelectableText(value == null || value.isEmpty ? '—' : value, textDirection: copy ? TextDirection.ltr : null, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600))),
          if (copy && value != null && value.isNotEmpty)
            InkWell(
              onTap: () async {
                await Clipboard.setData(ClipboardData(text: value));
                if (context.mounted) showSnack(context, _t(context, 'اتنسخ', 'Copied'));
              },
              child: const Padding(padding: EdgeInsets.all(4), child: Icon(Icons.copy_rounded, size: 16, color: BrandColors.gray)),
            ),
        ]),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canReset = ref.watch(staffContextProvider).valueOrNull?.permissions.contains('customers.reset_password') ?? false;
    final name = ((c['full_name'] as String?) ?? '').trim();
    final email = c['email'] as String?;
    final hasEmail = email != null && email.isNotEmpty && !email.endsWith('.myhato.app');
    final status = c['review_status'] as String? ?? 'pending';
    final (Color color, String label) = switch (status) {
      'approved' => (BrandColors.success, _t(context, 'موثّق', 'Verified')),
      'rejected' => (BrandColors.error, _t(context, 'مرفوض', 'Rejected')),
      _ => (BrandColors.warning, _t(context, 'مستني التوثيق', 'Waiting')),
    };
    final provider = switch (c['provider']) {
      'google' => 'Google',
      'facebook' => 'Facebook',
      'email' => _t(context, 'إيميل وكلمة سر', 'Email and password'),
      final p? => '$p',
      _ => null,
    };
    final orders = (c['orders_count'] as num?)?.toInt() ?? 0;
    final spent = (c['delivered_total_minor'] as num?)?.toInt() ?? 0;
    return Material(
      color: Colors.white,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: BrandColors.border)),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
          childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
          expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
          title: Text(name.isEmpty ? _t(context, 'بدون اسم', 'No name') : name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800)),
          subtitle: Text(hasEmail ? email : _t(context, 'دخول باسم مستخدم، من غير إيميل', 'Signs in with a user name, no email'),
              maxLines: 1, overflow: TextOverflow.ellipsis, textDirection: hasEmail ? TextDirection.ltr : null, style: TextStyle(fontSize: 13, color: hasEmail ? BrandColors.navy : BrandColors.gray)),
          trailing: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
            child: Text(c['is_staff'] == true ? '${_t(context, 'موظف', 'Team')} • $label' : label,
                style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 11.5)),
          ),
          children: [
            _row(context, _t(context, 'الإيميل', 'Email'), hasEmail ? email : null, copy: true),
            _row(context, _t(context, 'الإيميل متأكد منه', 'Email confirmed'), hasEmail ? (c['email_confirmed'] == true ? _t(context, 'أيوه', 'Yes') : _t(context, 'لأ', 'No')) : null),
            _row(context, _t(context, 'الموبايل', 'Phone'), c['phone'] as String?, copy: true),
            _row(context, _t(context, 'اسم المستخدم', 'User name'), c['username'] as String?, copy: true),
            _row(context, _t(context, 'كود العميل', 'Customer code'), c['customer_code'] as String?, copy: true),
            _row(context, _t(context, 'بيدخل بـ', 'Signs in with'), provider),
            _row(context, _t(context, 'اتسجّل', 'Registered'), _date(context, c['created_at'] as String?)),
            _row(context, _t(context, 'آخر دخول', 'Last sign-in'), _date(context, c['last_sign_in_at'] as String?)),
            _row(context, _t(context, 'عدد الطلبات', 'Orders'), '$orders'),
            _row(context, _t(context, 'اشترى بـ', 'Bought (delivered)'), orders == 0 ? '—' : formatEgp(spent, context.lang)),
            _row(context, _t(context, 'آخر طلب', 'Last order'), _date(context, c['last_order_at'] as String?)),
            if (canReset && c['is_staff'] != true) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => showDialog<void>(context: context, builder: (_) => _ResetPasswordDialog(customer: c)),
                icon: const Icon(Icons.lock_reset_rounded, size: 18),
                label: Text(_t(context, 'تغيير الرقم السري', 'Change password')),
              ),
            ],
          ],
        ),
      ),
    );
  }
}


/// Sets a new password for a customer. The owner types one or taps Generate, and can pass it on by WhatsApp.
class _ResetPasswordDialog extends ConsumerStatefulWidget {
  const _ResetPasswordDialog({required this.customer});
  final Map<String, dynamic> customer;
  @override
  ConsumerState<_ResetPasswordDialog> createState() => _ResetPasswordDialogState();
}

class _ResetPasswordDialogState extends ConsumerState<_ResetPasswordDialog> {
  final _pw = TextEditingController();
  bool _show = true;
  bool _busy = false;
  String? _done;

  @override
  void dispose() {
    _pw.dispose();
    super.dispose();
  }

  void _generate() {
    const letters = 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ';
    const digits = '23456789';
    final r = math.Random.secure();
    final chars = [for (var i = 0; i < 7; i++) letters[r.nextInt(letters.length)], for (var i = 0; i < 3; i++) digits[r.nextInt(digits.length)]]..shuffle(r);
    setState(() => _pw.text = chars.join());
  }

  bool get _valid {
    final v = _pw.text;
    return v.length >= 8 && v.length <= 72 && RegExp(r'[A-Za-z؀-ۿ]').hasMatch(v) && RegExp(r'\d').hasMatch(v);
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await ref.read(adminRepoProvider).setCustomerPassword(widget.customer['user_id'] as String, _pw.text);
      if (mounted) setState(() => _done = _pw.text);
    } catch (e) {
      if (mounted) {
        showSnack(context, friendlyError(context, e), error: true);
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = ((widget.customer['full_name'] as String?) ?? '').trim();
    final phone = widget.customer['phone'] as String?;
    if (_done != null) {
      return AlertDialog(
        title: Text(_t(context, 'اتغيّر الرقم السري', 'Password changed')),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_t(context, 'العميل اتسجّل خروج من كل أجهزته. ابعتله الرقم الجديد:', 'The customer was signed out everywhere. Send them the new password:')),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: BrandColors.offWhite, borderRadius: BorderRadius.circular(12), border: Border.all(color: BrandColors.border)),
            child: SelectableText(_done!, textDirection: TextDirection.ltr, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900, letterSpacing: 1)),
          ),
        ]),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: _done!));
              if (context.mounted) showSnack(context, _t(context, 'اتنسخ', 'Copied'));
            },
            child: Text(_t(context, 'نسخ', 'Copy')),
          ),
          if (phone != null && phone.isNotEmpty)
            TextButton(
              onPressed: () => launchUrl(
                Uri.parse('https://wa.me/${waDigits(phone)}?text=${Uri.encodeComponent('أهلاً ${name.isEmpty ? '' : name} 👋\nكلمة السر الجديدة لحسابك على ${AppName.ar}: $_done\nادخل بيها وغيّرها من حسابك.')}'),
                mode: LaunchMode.externalApplication,
              ),
              child: Text(_t(context, 'ابعت واتساب', 'Send on WhatsApp')),
            ),
          FilledButton(onPressed: () => Navigator.pop(context), child: Text(_t(context, 'تم', 'Done'))),
        ],
      );
    }
    return AlertDialog(
      title: Text(_t(context, 'رقم سري جديد', 'New password')),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(name.isEmpty ? '${widget.customer['email'] ?? ''}' : name, style: const TextStyle(fontWeight: FontWeight.w800)),
        const SizedBox(height: 10),
        TextField(
          controller: _pw,
          obscureText: !_show,
          textDirection: TextDirection.ltr,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: _t(context, 'الرقم السري الجديد', 'New password'),
            helperText: _t(context, '٨ حروف على الأقل، فيها حرف ورقم', 'At least 8 characters with a letter and a digit'),
            suffixIcon: IconButton(icon: Icon(_show ? Icons.visibility_off_outlined : Icons.visibility_outlined), onPressed: () => setState(() => _show = !_show)),
          ),
        ),
        Align(alignment: AlignmentDirectional.centerStart, child: TextButton.icon(onPressed: _generate, icon: const Icon(Icons.auto_fix_high_rounded, size: 18), label: Text(_t(context, 'اعمل رقم سري عشوائي', 'Generate one')))),
        Text(_t(context, 'العميل هيتسجّل خروج من كل أجهزته وهيوصله إشعار.', 'The customer is signed out everywhere and gets a notification.'), style: const TextStyle(color: BrandColors.gray, fontSize: 12)),
      ]),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: Text(_t(context, 'إلغاء', 'Cancel'))),
        FilledButton(
          onPressed: _busy || !_valid ? null : _save,
          child: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : Text(_t(context, 'غيّر الرقم السري', 'Change password')),
        ),
      ],
    );
  }
}
