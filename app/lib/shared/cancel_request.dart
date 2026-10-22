import 'package:flutter/material.dart';

import '../core/errors.dart';
import '../core/l10n.dart';
import '../core/theme.dart';

String _t(BuildContext c, String ar, String en) => c.isAr ? ar : en;

const _orderReasons = [
  ('غيرت رأيي', 'I changed my mind'),
  ('لقيت سعر أحسن', 'I found a better price'),
  ('طلبت منتج غلط', 'I ordered the wrong item'),
  ('عايز أعدّل الطلب', 'I want to change the order'),
  ('التوصيل هياخد وقت طويل', 'Delivery takes too long'),
];

const _repairReasons = [
  ('غيرت رأيي', 'I changed my mind'),
  ('التكلفة عالية', 'The cost is too high'),
  ('المدة طويلة', 'It takes too long'),
  ('الجهاز اشتغل لوحده', 'The device works again'),
  ('هصلحه في مكان تاني', 'I will repair it elsewhere'),
];

/// Customer side of cancellation: a request with a reason that staff approve or reject.
/// Shows "under review" while a request is open (from the server, or right after sending it here),
/// otherwise the request button (when allowed). The request is sent from inside the reason sheet,
/// so it never depends on the page behind it staying on screen.
class CancelRequestBlock extends StatefulWidget {
  const CancelRequestBlock({super.key, required this.requests, required this.canRequest, required this.repair, required this.submit});
  final List<Map<String, dynamic>> requests;
  final bool canRequest;
  final bool repair;
  final Future<void> Function(String reason) submit;

  @override
  State<CancelRequestBlock> createState() => _CancelRequestBlockState();
}

class _CancelRequestBlockState extends State<CancelRequestBlock> {
  /// Reason just sent from this screen — keeps the button locked until the server copy arrives.
  String? _sentReason;

  Future<void> _open() async {
    final sent = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useRootNavigator: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => CancelReasonSheet(repair: widget.repair, submit: widget.submit),
    );
    if (sent != null && mounted) setState(() => _sentReason = sent);
  }

  @override
  Widget build(BuildContext context) {
    final serverOpen = widget.requests.where((r) => r['status'] == 'pending').firstOrNull;
    // a decided request from the server replaces the local "just sent" marker
    final decided = _sentReason != null && widget.requests.any((r) => r['status'] != 'pending' && r['reason'] == _sentReason);
    final openReason = serverOpen?['reason'] as String? ?? (decided ? null : _sentReason);
    if (openReason != null) {
      return Container(
        key: const ValueKey('cancel-under-review'),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: BrandColors.warning.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: BrandColors.warning.withValues(alpha: 0.35)),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.hourglass_top_rounded, color: BrandColors.warning),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_t(context, 'طلب الإلغاء بيتراجع', 'Cancellation request under review'), style: const TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              Text('${_t(context, 'السبب', 'Reason')}: $openReason', style: const TextStyle(color: BrandColors.gray)),
              const SizedBox(height: 4),
              Text(_t(context, 'مش هتقدر تبعت طلب تاني لحد ما نرد عليك. ممكن نكلمك، وهيوصلك إشعار بالرد.',
                      'You can send another request after we reply. We may call you; you will be notified.'),
                  style: const TextStyle(fontSize: 13, height: 1.5)),
            ]),
          ),
        ]),
      );
    }
    if (!widget.canRequest) return const SizedBox.shrink();
    return OutlinedButton.icon(
      key: const ValueKey('cancel-request-button'),
      style: OutlinedButton.styleFrom(foregroundColor: BrandColors.error),
      icon: const Icon(Icons.cancel_outlined),
      label: Text(widget.repair ? _t(context, 'طلب إلغاء الصيانة', 'Request cancellation') : _t(context, 'طلب إلغاء الطلب', 'Request cancellation')),
      onPressed: _open,
    );
  }
}

/// Reason picker that sends the request itself; pops with the reason once the server saved it.
class CancelReasonSheet extends StatefulWidget {
  const CancelReasonSheet({super.key, required this.repair, required this.submit});
  final bool repair;
  final Future<void> Function(String reason) submit;
  @override
  State<CancelReasonSheet> createState() => _CancelReasonSheetState();
}

class _CancelReasonSheetState extends State<CancelReasonSheet> {
  int? _selected; // index in reasons, or -1 = other
  final _other = TextEditingController();
  bool _busy = false;
  String? _error;

  Future<void> _send(String reason) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.submit(reason);
      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      final done = _t(context, 'طلب الإلغاء وصلنا، وهنراجعه ونرد عليك قريب', 'Cancellation request sent — we will get back to you soon');
      Navigator.of(context).pop(reason);
      messenger?.showSnackBar(SnackBar(
        content: Text(done),
        duration: const Duration(seconds: 3),
        persist: false,
      ));
    } catch (e) {
      final msg = friendlyError(context, e);
      // already requested (e.g. from another device): treat as sent so the page locks the button
      if (e.toString().contains('CANCEL_ALREADY_REQUESTED') && mounted) {
        Navigator.of(context).pop(reason);
        return;
      }
      if (mounted) setState(() => _error = msg);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _other.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reasons = widget.repair ? _repairReasons : _orderReasons;
    final options = [for (final r in reasons) context.isAr ? r.$1 : r.$2, _t(context, 'سبب تاني', 'Other reason')];
    final reason = _selected == null
        ? null
        : _selected == -1
            ? (_other.text.trim().length >= 2 ? _other.text.trim() : null)
            : reasons[_selected!].$1; // stored in Arabic for the team
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(_t(context, 'ليه عايز تلغي؟', 'Why do you want to cancel?'),
              style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text(_t(context, 'هنراجع طلب الإلغاء وممكن نكلمك قبل ما نرد عليك.', 'We will review the request and may call you before replying.'),
              style: const TextStyle(color: BrandColors.gray, height: 1.5)),
          const SizedBox(height: 14),
          Material(
            color: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: BrandColors.border)),
            clipBehavior: Clip.antiAlias,
            child: Column(children: [
              for (var i = 0; i < options.length; i++) ...[
                if (i > 0) const Divider(height: 1),
                Builder(builder: (_) {
                  final idx = i == options.length - 1 ? -1 : i;
                  final sel = _selected == idx;
                  return ListTile(
                    onTap: _busy ? null : () => setState(() => _selected = idx),
                    selected: sel,
                    selectedTileColor: BrandColors.electric.withValues(alpha: 0.06),
                    leading: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      child: Icon(sel ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                          key: ValueKey(sel), color: sel ? BrandColors.electric : BrandColors.gray),
                    ),
                    title: Text(options[i], style: TextStyle(fontWeight: sel ? FontWeight.w700 : FontWeight.w500)),
                  );
                }),
              ],
            ]),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            child: _selected == -1
                ? Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: TextField(
                      controller: _other,
                      autofocus: true,
                      maxLines: 3,
                      maxLength: 500,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(hintText: _t(context, 'اكتب السبب…', 'Write the reason…')),
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, key: const ValueKey('cancel-error'), style: const TextStyle(color: BrandColors.error, fontWeight: FontWeight.w600)),
          ],
          const SizedBox(height: 16),
          FilledButton(
            key: const ValueKey('cancel-send'),
            style: FilledButton.styleFrom(backgroundColor: BrandColors.error),
            onPressed: (reason == null || _busy) ? null : () => _send(reason),
            child: _busy
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white))
                : Text(_t(context, 'ابعت طلب الإلغاء', 'Send cancellation request')),
          ),
        ]),
      ),
    );
  }
}
