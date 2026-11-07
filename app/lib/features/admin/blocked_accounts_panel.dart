import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../shared/states.dart';
import 'admin_repository.dart';
import 'team.dart' show teamRepoProvider;

String _t(BuildContext c, String ar, String en) => c.isAr ? ar : en;

/// Accounts locked for guessing the password (15 min / 1 hour), blocked after 10 wrong attempts, or stopped by the owner.
final blockedAccountsProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final r = await ref.read(supabaseProvider).rpc('staff_blocked_accounts');
  return [for (final e in (r as List)) Map<String, dynamic>.from(e as Map)];
});

class BlockedAccountsPanel extends ConsumerWidget {
  const BlockedAccountsPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(blockedAccountsProvider);
    return RefreshIndicator(
      onRefresh: () async => ref.refresh(blockedAccountsProvider.future),
      child: ListView(padding: const EdgeInsets.all(16), children: [
        Row(children: [
          const Icon(Icons.lock_person_rounded, color: Color(0xFFD92D20)),
          const SizedBox(width: 8),
          Expanded(child: Text(_t(context, 'الحسابات المحظورة', 'Blocked accounts'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900))),
          IconButton(tooltip: _t(context, 'تحديث', 'Refresh'), onPressed: () => ref.invalidate(blockedAccountsProvider), icon: const Icon(Icons.refresh_rounded)),
        ]),
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
              _t(context, '5 أرقام سرية غلط = قفل 15 دقيقة، وبعدها ساعة، و10 غلط = حظر لحد ما تفكه إنت. من هنا تفك الحظر أو تغيّر الرقم السري أو توقف الحساب وترجّعه.',
                  '5 wrong passwords = 15 min lock, then 1 hour, 10 wrong = blocked until you unblock. Unblock, reset the password, or stop / restore an account here.'),
              style: const TextStyle(color: BrandColors.textMuted, fontSize: 13)),
        ),
        data.when(
          loading: () => const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())),
          error: (e, _) => Padding(padding: const EdgeInsets.all(24), child: Text(friendlyError(context, e))),
          data: (rows) => rows.isEmpty
              ? EmptyState(icon: Icons.verified_user_rounded, title: _t(context, 'مفيش حسابات محظورة', 'No blocked accounts'), body: _t(context, 'كل الحسابات شغالة', 'All accounts are fine'))
              : Column(children: [for (final r in rows) _AccountCard(r)]),
        ),
      ]),
    );
  }
}

class _AccountCard extends ConsumerWidget {
  const _AccountCard(this.a);
  final Map<String, dynamic> a;

  Future<void> _run(BuildContext context, WidgetRef ref, Future<void> Function() f, String ok) async {
    try {
      await f();
      ref.invalidate(blockedAccountsProvider);
      if (context.mounted) showSnack(context, ok);
    } catch (e) {
      if (context.mounted) showSnack(context, friendlyError(context, e), error: true);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = '${a['status']}';
    final (label, color) = switch (status) {
      'blocked' => (_t(context, 'محظور', 'Blocked'), const Color(0xFFD92D20)),
      'suspended' => (_t(context, 'موقوف', 'Stopped'), const Color(0xFF667085)),
      _ => (_t(context, 'مقفول مؤقتًا', 'Locked for now'), const Color(0xFFDC6803)),
    };
    final uid = a['user_id'] as String;
    final db = ref.read(supabaseProvider);
    final fmt = DateFormat('d/M HH:mm');
    final last = DateTime.tryParse('${a['last_failed_at'] ?? ''}')?.toLocal();
    final until = DateTime.tryParse('${a['locked_until'] ?? ''}')?.toLocal();
    final isStaff = a['kind'] == 'staff';
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text('${a['name'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16))),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
              child: Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 12)),
            ),
          ]),
          const SizedBox(height: 4),
          Text([
            if (isStaff) _t(context, 'موظف', 'Team'),
            if ('${a['phone'] ?? ''}'.isNotEmpty) '${a['phone']}',
            if ('${a['email'] ?? ''}'.isNotEmpty) '${a['email']}',
            if ('${a['code'] ?? ''}'.isNotEmpty) '${a['code']}',
          ].join('  •  '), style: const TextStyle(color: BrandColors.textMuted, fontSize: 12.5)),
          const SizedBox(height: 6),
          Text([
            if (status != 'suspended') '${_t(context, 'محاولات غلط', 'Wrong attempts')}: ${a['failed_count'] ?? 0}',
            if (last != null && status != 'suspended') '${_t(context, 'آخر محاولة', 'Last try')}: ${fmt.format(last)}',
            if (until != null && status == 'locked') '${_t(context, 'يتفتح', 'Opens')}: ${fmt.format(until)}',
          ].join('   '), style: const TextStyle(fontSize: 12.5)),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (status != 'suspended')
              FilledButton.icon(
                onPressed: () => _run(context, ref, () async => db.rpc('staff_account_unblock', params: {'p_user_id': uid}), _t(context, 'اتفك الحظر', 'Unblocked')),
                icon: const Icon(Icons.lock_open_rounded, size: 18),
                label: Text(_t(context, 'فك الحظر', 'Unblock')),
              ),
            OutlinedButton.icon(
              onPressed: () => showDialog(context: context, builder: (_) => _NewPasswordDialog(a: a)).then((_) => ref.invalidate(blockedAccountsProvider)),
              icon: const Icon(Icons.password_rounded, size: 18),
              label: Text(_t(context, 'رقم سري جديد', 'New password')),
            ),
            OutlinedButton.icon(
              onPressed: () => _run(context, ref, () async => db.rpc('staff_account_set_suspended', params: {'p_user_id': uid, 'p_suspended': status != 'suspended'}),
                  status == 'suspended' ? _t(context, 'اتشغّل الحساب', 'Account restored') : _t(context, 'اتوقف الحساب', 'Account stopped')),
              icon: Icon(status == 'suspended' ? Icons.play_circle_outline_rounded : Icons.pause_circle_outline_rounded, size: 18),
              label: Text(status == 'suspended' ? _t(context, 'تشغيل / استرجاع', 'Restore') : _t(context, 'إيقاف الحساب', 'Stop account')),
            ),
          ]),
        ]),
      ),
    );
  }
}

class _NewPasswordDialog extends ConsumerStatefulWidget {
  const _NewPasswordDialog({required this.a});
  final Map<String, dynamic> a;
  @override
  ConsumerState<_NewPasswordDialog> createState() => _NewPasswordDialogState();
}

class _NewPasswordDialogState extends ConsumerState<_NewPasswordDialog> {
  final _pw = TextEditingController();
  bool _busy = false;
  String? _done;

  @override
  void initState() {
    super.initState();
    _generate();
  }

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
    _pw.text = chars.join();
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    final uid = widget.a['user_id'] as String;
    try {
      if (widget.a['kind'] == 'staff') {
        await ref.read(teamRepoProvider).resetPassword(uid, _pw.text);
      } else {
        await ref.read(adminRepoProvider).setCustomerPassword(uid, _pw.text);
      }
      // a new password also clears the lock
      await ref.read(supabaseProvider).rpc('staff_account_unblock', params: {'p_user_id': uid});
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
    if (_done != null) {
      return AlertDialog(
        title: Text(_t(context, 'اتغيّر الرقم السري', 'Password changed')),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_t(context, 'الحساب اتفك وخرج من كل أجهزته. ابعتله الرقم الجديد:', 'The account is unlocked and signed out everywhere. Send the new password:')),
          const SizedBox(height: 10),
          SelectableText(_done!, textDirection: TextDirection.ltr, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, letterSpacing: 1)),
        ]),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: _done!));
              if (context.mounted) showSnack(context, _t(context, 'اتنسخ', 'Copied'));
            },
            child: Text(_t(context, 'نسخ', 'Copy')),
          ),
          FilledButton(onPressed: () => Navigator.pop(context), child: Text(_t(context, 'تم', 'Done'))),
        ],
      );
    }
    return AlertDialog(
      title: Text('${_t(context, 'رقم سري جديد لـ', 'New password for')} ${widget.a['name'] ?? ''}'),
      content: TextField(
        controller: _pw,
        textDirection: TextDirection.ltr,
        decoration: InputDecoration(
          labelText: _t(context, 'الرقم السري (8 حروف وأرقام على الأقل)', 'Password (min 8, letters and digits)'),
          suffixIcon: IconButton(icon: const Icon(Icons.casino_rounded), onPressed: () => setState(_generate)),
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: Text(_t(context, 'إلغاء', 'Cancel'))),
        FilledButton(
          onPressed: _busy || _pw.text.length < 8 ? null : _save,
          child: Text(_t(context, 'حفظ', 'Save')),
        ),
      ],
    );
  }
}
