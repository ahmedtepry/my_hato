import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/money.dart';
import '../../core/theme.dart';
import '../../shared/copy_code.dart';
import '../../shared/delivery_location.dart';
import '../../shared/account_review.dart';
import '../../shared/brand_logo.dart';
import '../../shared/states.dart';
import '../../shared/support_contact.dart';
import '../auth/auth_repository.dart';
import '../cart/cart_repository.dart';
import '../orders/orders_repository.dart';
import '../payments/payment_flow.dart';
import '../payments/payments_repository.dart';
import '../profile/profile_repository.dart';

class CheckoutScreen extends ConsumerStatefulWidget {
  const CheckoutScreen({super.key});
  @override
  ConsumerState<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends ConsumerState<CheckoutScreen> {
  String _fulfillment = 'pickup';
  String? _branchId;
  String? _addressId;
  String _payment = 'pay_at_branch';
  bool _saveCard = false; // explicit opt-in, unchecked by default
  final _notes = TextEditingController();
  int? _deliveryFee;
  bool _submitting = false;
  final _couponCtl = TextEditingController();
  String? _coupon; // applied code
  int _couponDiscount = 0;
  int? _couponForSubtotal;
  String? _couponError;
  bool _checkingCoupon = false;
  bool _pendingCouponTried = false;
  // stable across retries of THIS checkout => server never creates duplicates
  final String _idempotencyKey = OrdersRepository.newIdempotencyKey();

  @override
  void dispose() {
    _couponCtl.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _refreshFee(List<Map<String, dynamic>> addresses, int subtotal) async {
    final a = addresses.where((x) => x['id'] == _addressId).firstOrNull;
    if (a == null) {
      setState(() => _deliveryFee = null);
      return;
    }
    final fee = await ref.read(ordersRepoProvider).deliveryFee(a['governorate'] as String, subtotal);
    if (mounted) setState(() => _deliveryFee = fee);
  }

  String _couponMessage(Object e) {
    final m = e.toString();
    final ar = context.isAr;
    if (m.contains('COUPON_MIN_ORDER')) {
      final min = int.tryParse(RegExp(r'COUPON_MIN_ORDER:(\d+)').firstMatch(m)?.group(1) ?? '');
      return ar ? 'الكود ده محتاج طلب بـ ${min == null ? 'مبلغ أكبر' : formatEgp(min, 'ar')} على الأقل' : 'Needs an order of at least ${min == null ? 'more' : formatEgp(min, 'en')}';
    }
    if (m.contains('COUPON_EXPIRED')) return ar ? 'الكود ده انتهت صلاحيته' : 'This code has expired';
    if (m.contains('COUPON_USED_UP')) return ar ? 'الكود ده خلص' : 'This code is used up';
    if (m.contains('COUPON_ALREADY_USED')) return ar ? 'انت استخدمت الكود ده قبل كده' : 'You already used this code';
    if (m.contains('COUPON_INVALID')) return ar ? 'الكود ده مش صالح' : 'Invalid code';
    return friendlyError(context, e);
  }

  Future<void> _applyCoupon(int subtotal, {String? code}) async {
    final c = (code ?? _couponCtl.text).trim().toUpperCase();
    if (c.isEmpty) return;
    setState(() {
      _checkingCoupon = true;
      _couponError = null;
    });
    try {
      final r = await ref.read(ordersRepoProvider).checkCoupon(c, subtotal);
      if (!mounted) return;
      setState(() {
        _coupon = c;
        _couponCtl.text = c;
        _couponDiscount = (r['discount_minor'] as num).toInt();
        _couponForSubtotal = subtotal;
      });
      HapticFeedback.lightImpact();
    } catch (e) {
      if (mounted) {
        setState(() {
          _coupon = null;
          _couponDiscount = 0;
          _couponError = _couponMessage(e);
        });
      }
    } finally {
      if (mounted) setState(() => _checkingCoupon = false);
    }
  }

  void _removeCoupon() => setState(() {
        _coupon = null;
        _couponDiscount = 0;
        _couponError = null;
        _couponCtl.clear();
      });

  Future<void> _submit() async {
    setState(() => _submitting = true);
    try {
      final res = await ref.read(ordersRepoProvider).placeOrder(
            idempotencyKey: _idempotencyKey,
            fulfillment: _fulfillment,
            paymentMethod: _payment,
            branchId: _fulfillment == 'pickup' ? _branchId : null,
            addressId: _fulfillment == 'delivery' ? _addressId : null,
            notes: _notes.text,
            couponCode: _coupon,
          );
      ref.read(pendingCouponProvider.notifier).state = null;
      ref.invalidate(cartProvider);
      ref.invalidate(myOrdersProvider);
      if (!mounted) return;
      if (_payment == 'online') {
        // order is saved (unpaid); now collect payment securely. Paid status comes only from the server.
        await startOnlinePayment(context, ref, orderId: res['order_id'] as String, saveCard: _saveCard);
        return;
      }
      // The confirmation animation is shown ONLY after the backend confirmed creation.
      context.go('/order-confirmed?id=${res['order_id']}&ref=${Uri.encodeComponent(res['reference'] as String)}');
    } catch (e) {
      if (!mounted) return;
      if (isAccountPendingError(e)) {
        ref.invalidate(accountReviewProvider);
        showAccountPendingSheet(context);
        return;
      }
      if (e.toString().contains('COUPON_')) {
        setState(() {
          _coupon = null;
          _couponDiscount = 0;
          _couponError = _couponMessage(e);
        });
      }
      showSnack(context, e.toString().contains('COUPON_') ? _couponMessage(e) : friendlyError(context, e), error: true);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final lang = context.lang;
    final cart = ref.watch(cartProvider).valueOrNull;
    final profile = ref.watch(profileProvider);
    final branches = ref.watch(branchesProvider);
    final addresses = ref.watch(addressesProvider);
    final p = profile.valueOrNull;
    final onlineEnabled = ref.watch(onlinePaymentsEnabledProvider).valueOrNull ?? false;
    final verified = isAccountVerified(p);
    final reviewStatus = ref.watch(accountReviewProvider).valueOrNull ?? 'approved';
    final phone = reachablePhone(p);
    final hasPhone = phone != null || _fulfillment == 'delivery';
    final subtotal = cart?.subtotal ?? 0;
    final pending = ref.watch(pendingCouponProvider);
    if (cart != null && subtotal > 0) {
      if (!_pendingCouponTried && pending != null && _coupon == null) {
        _pendingCouponTried = true;
        WidgetsBinding.instance.addPostFrameCallback((_) => _applyCoupon(subtotal, code: pending));
      } else if (_coupon != null && _couponForSubtotal != subtotal && !_checkingCoupon) {
        final c = _coupon!;
        WidgetsBinding.instance.addPostFrameCallback((_) => _applyCoupon(subtotal, code: c));
      }
    }
    final fee = _fulfillment == 'delivery' ? (_deliveryFee ?? 0) : 0;
    // pick sensible defaults so the customer is never stuck on a greyed-out button
    final branchList = branches.valueOrNull ?? const <Map<String, dynamic>>[];
    if (_branchId == null && branchList.isNotEmpty) _branchId = branchList.first['id'] as String;
    final addressList = addresses.valueOrNull ?? const <Map<String, dynamic>>[];
    if (_fulfillment == 'delivery' && _addressId == null && addressList.isNotEmpty) {
      _addressId = addressList.first['id'] as String;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _refreshFee(addressList, subtotal);
      });
    }
    final selectedAddress = addressList.where((x) => x['id'] == _addressId).firstOrNull;
    final ready = verified &&
        hasPhone &&
        (cart?.lines.isNotEmpty ?? false) &&
        ((_fulfillment == 'pickup' && _branchId != null) || (_fulfillment == 'delivery' && _addressId != null && _deliveryFee != null && addressHasLocation(selectedAddress)));
    // tell the customer exactly what is missing instead of a silent disabled button
    final String? missing = !verified
        ? context.tr('err_account_not_verified')
        : !hasPhone
            ? context.tr('err_phone_required')
            : (cart?.lines.isEmpty ?? true)
                ? context.tr('err_cart_empty')
                : _fulfillment == 'pickup' && _branchId == null
                    ? (branches.isLoading ? null : context.tr('checkout_no_branch'))
                    : _fulfillment == 'delivery' && _addressId == null
                        ? context.tr('checkout_add_address')
                        : _fulfillment == 'delivery' && !addressHasLocation(selectedAddress)
                            ? context.tr('checkout_need_location')
                            : null;

    return Scaffold(
      appBar: AppBar(title: Text(context.tr('checkout'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const PendingAccountBanner(margin: EdgeInsets.only(bottom: 12)),
        _h(context.tr('contact_info')),
        Card(
          child: ListTile(
            leading: const Icon(Icons.person_outline),
            title: Text((p?['full_name'] as String?) ?? '—'),
            subtitle: Directionality(
              textDirection: TextDirection.ltr,
              child: Text(phone ?? (p?['email'] as String?) ?? '—', textAlign: context.isAr ? TextAlign.end : TextAlign.start),
            ),
            trailing: verified
                ? (reviewStatus == 'approved'
                    ? StatusChip(label: context.tr('verified'), color: BrandColors.success)
                    : StatusChip(
                        label: reviewStatus == 'rejected' ? (context.isAr ? 'مرفوض' : 'Rejected') : (context.isAr ? 'قيد التوثيق' : 'Being verified'),
                        color: reviewStatus == 'rejected' ? BrandColors.error : BrandColors.warning))
                : TextButton(
                    onPressed: () => showSupportSheet(context,
                        title: context.tr('account_pending_title'), body: context.tr('account_pending_body'), whatsappMessage: context.tr('account_pending_wa')),
                    child: Text(context.tr('help')),
                  ),
          ),
        ),
        if (!verified)
          Padding(padding: const EdgeInsets.only(top: 6), child: Text(context.tr('err_account_not_verified'), style: const TextStyle(color: BrandColors.error))),
        if (verified && !hasPhone)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(children: [
              Expanded(child: Text(context.tr('err_phone_required'), style: const TextStyle(color: BrandColors.error))),
              TextButton(onPressed: () => context.push('/account/edit'), child: Text(context.tr('add_contact_phone'))),
            ]),
          ),
        _h(context.tr('fulfillment')),
        SegmentedButton<String>(
          segments: [
            ButtonSegment(value: 'pickup', icon: const Icon(Icons.storefront_outlined), label: Text(context.tr('branch_pickup'))),
            ButtonSegment(value: 'delivery', icon: const Icon(Icons.local_shipping_outlined), label: Text(context.tr('home_delivery'))),
          ],
          selected: {_fulfillment},
          onSelectionChanged: (s) => setState(() {
            _fulfillment = s.first;
            if (_payment != 'online') _payment = _fulfillment == 'pickup' ? 'pay_at_branch' : 'cash_on_delivery';
          }),
        ),
        const SizedBox(height: 12),
        if (_fulfillment == 'pickup')
          branches.when(
            loading: () => const Skeleton(height: 80),
            error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(branchesProvider)),
            data: (list) => Column(children: [
              if (list.isEmpty)
                Card(child: ListTile(leading: const Icon(Icons.store_mall_directory_outlined), title: Text(context.tr('checkout_no_branch')))),
              for (final b in list)
                Card(
                  child: RadioListTile<String>(
                    value: b['id'] as String,
                    groupValue: _branchId,
                    onChanged: (v) => setState(() => _branchId = v),
                    title: Text(context.pick(b, 'name'), style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text([context.pick(b, 'address'), b['phone'] ?? '', context.pick(b, 'hours')].where((s) => s.toString().isNotEmpty).join('\n')),
                  ),
                ),
            ]),
          )
        else
          addresses.when(
            loading: () => const Skeleton(height: 80),
            error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(addressesProvider)),
            data: (list) => Column(children: [
              for (final a in list)
                Card(
                  child: RadioListTile<String>(
                    value: a['id'] as String,
                    groupValue: _addressId,
                    onChanged: (v) {
                      setState(() => _addressId = v);
                      _refreshFee(list, subtotal);
                    },
                    title: Text('${a['label'] ?? a['recipient_name']}', style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text('${a['governorate']} — ${a['city']} — ${a['street']}'),
                    secondary: addressHasLocation(a)
                        ? const Icon(Icons.location_on_rounded, color: BrandColors.success)
                        : TextButton(
                            onPressed: () async {
                              await context.push('/account/addresses/edit', extra: a);
                              ref.invalidate(addressesProvider);
                            },
                            child: Text(context.tr('location_missing')),
                          ),
                  ),
                ),
              OutlinedButton.icon(
                icon: const Icon(Icons.add_location_alt_outlined),
                label: Text(context.tr('add_address')),
                onPressed: () async {
                  await context.push('/account/addresses/new');
                  ref.invalidate(addressesProvider);
                },
              ),
              const SizedBox(height: 12),
              TextField(controller: _notes, maxLength: 500, maxLines: 2, decoration: InputDecoration(labelText: context.tr('delivery_notes'))),
            ]),
          ),
        _h(context.tr('payment_method')),
        Card(
          child: Column(children: [
            if (_fulfillment == 'delivery')
              RadioListTile<String>(value: 'cash_on_delivery', groupValue: _payment, onChanged: (v) => setState(() => _payment = v!), title: Text(context.tr('cod'))),
            if (_fulfillment == 'pickup')
              RadioListTile<String>(value: 'pay_at_branch', groupValue: _payment, onChanged: (v) => setState(() => _payment = v!), title: Text(context.tr('pay_branch'))),
            if (onlineEnabled) ...[
              RadioListTile<String>(
                value: 'online',
                groupValue: _payment,
                onChanged: (v) => setState(() => _payment = v!),
                title: Text(context.tr('pay_online')),
                subtitle: Text(context.tr('pay_online_sub'), style: const TextStyle(fontSize: 12)),
                secondary: const Icon(Icons.credit_card_rounded, color: BrandColors.electric),
              ),
              if (_payment == 'online')
                CheckboxListTile(
                  value: _saveCard,
                  onChanged: (v) => setState(() => _saveCard = v ?? false),
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(context.tr('save_card')),
                  subtitle: Text(context.tr('save_card_sub'), style: const TextStyle(fontSize: 12)),
                ),
            ] else
              ListTile(
                dense: true,
                leading: const Icon(Icons.credit_card_off_outlined, color: BrandColors.gray),
                title: Text(context.tr('online_payment_soon'), style: const TextStyle(color: BrandColors.gray)),
              ),
          ]),
        ),
        _h(context.tr('items')),
        // discount code
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: _coupon != null
                ? Row(children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(color: BrandColors.success.withValues(alpha: 0.12), shape: BoxShape.circle),
                      child: const Icon(Icons.local_offer_rounded, color: BrandColors.success, size: 20),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(context.isAr ? 'اتطبق الكود $_coupon ✅' : 'Code $_coupon applied ✅', style: const TextStyle(fontWeight: FontWeight.w800, color: BrandColors.success)),
                        Text(context.isAr ? 'وفّرت ${formatEgp(_couponDiscount, lang)}' : 'You save ${formatEgp(_couponDiscount, lang)}', style: const TextStyle(fontSize: 12.5)),
                      ]),
                    ),
                    TextButton(onPressed: _removeCoupon, child: Text(context.isAr ? 'إزالة' : 'Remove')),
                  ])
                : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Row(children: [
                      Expanded(
                        child: TextField(
                          controller: _couponCtl,
                          textCapitalization: TextCapitalization.characters,
                          textDirection: TextDirection.ltr,
                          decoration: InputDecoration(
                            hintText: context.isAr ? 'عندك كود خصم؟' : 'Have a discount code?',
                            prefixIcon: const Icon(Icons.local_offer_outlined),
                            errorText: _couponError,
                          ),
                          onSubmitted: (_) => _applyCoupon(subtotal),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        height: 52,
                        child: FilledButton(
                          style: FilledButton.styleFrom(minimumSize: const Size(80, 52), backgroundColor: BrandColors.navy),
                          onPressed: _checkingCoupon ? null : () => _applyCoupon(subtotal),
                          child: _checkingCoupon
                              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white))
                              : Text(context.isAr ? 'تطبيق' : 'Apply'),
                        ),
                      ),
                    ]),
                  ]),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(children: [
              for (final l in cart?.lines ?? const <CartLine>[])
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(children: [
                    Expanded(child: Text('${lang == 'ar' ? l.nameAr : l.nameEn} × ${l.quantity}', maxLines: 2)),
                    Text(formatEgp(l.lineTotal, lang), style: const TextStyle(fontWeight: FontWeight.w700)),
                  ]),
                ),
              const Divider(height: 20),
              _sum(context.tr('subtotal'), formatEgp(cart?.listTotal ?? 0, lang)),
              if ((cart?.discount ?? 0) > 0) _sum(context.tr('discount'), '- ${formatEgp(cart!.discount, lang)}'),
              if (_couponDiscount > 0) _sum('${context.isAr ? 'كود الخصم' : 'Discount code'} ($_coupon)', '- ${formatEgp(_couponDiscount, lang)}'),
              _sum(context.tr('delivery_fee'), _fulfillment == 'pickup' ? formatEgp(0, lang) : (_deliveryFee == null ? '—' : formatEgp(_deliveryFee, lang))),
              const Divider(height: 20),
              _sum(context.tr('total'), formatEgp(subtotal - _couponDiscount + fee, lang), bold: true),
            ]),
          ),
        ),
        const SizedBox(height: 100),
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (missing != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(children: [
                  const Icon(Icons.info_outline, size: 18, color: BrandColors.warning),
                  const SizedBox(width: 6),
                  Expanded(child: Text(missing, style: const TextStyle(color: BrandColors.warning, fontWeight: FontWeight.w600))),
                ]),
              ),
            if (ref.watch(accountReviewProvider).valueOrNull == 'pending' || ref.watch(accountReviewProvider).valueOrNull == 'rejected')
              FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: BrandColors.gray),
                icon: const Icon(Icons.hourglass_top_rounded),
                label: Text(context.isAr ? 'الطلب هيتفتح أول ما حسابك يتوثّق' : 'Ordering opens once your account is verified'),
                onPressed: () => showAccountPendingSheet(context),
              )
            else
            FilledButton(
            onPressed: (!ready || _submitting) ? null : _submit,
            child: _submitting
                ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white))
                : Text('${context.tr(_payment == 'online' ? 'place_and_pay' : 'place_order')} • ${formatEgp(subtotal - _couponDiscount + fee, lang)}'),
          ),
          ]),
        ),
      ),
    );
  }

  Widget _h(String t) => Padding(padding: const EdgeInsets.fromLTRB(4, 20, 4, 8), child: Text(t, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)));

  Widget _sum(String k, String v, {bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Text(k, style: TextStyle(fontWeight: bold ? FontWeight.w800 : FontWeight.w500)),
          const Spacer(),
          Text(v, style: TextStyle(fontWeight: bold ? FontWeight.w900 : FontWeight.w600, fontSize: bold ? 18 : 14, color: bold ? BrandColors.electric : null)),
        ]),
      );
}

/// Animated My Hatō "M" confirmation, shown only after the server saved the order or repair request.
class OrderConfirmationScreen extends StatefulWidget {
  const OrderConfirmationScreen({super.key, required this.orderId, required this.reference, this.isRepair = false});
  final String orderId;
  final String reference;
  final bool isRepair;
  @override
  State<OrderConfirmationScreen> createState() => _OrderConfirmationScreenState();
}

class _OrderConfirmationScreenState extends State<OrderConfirmationScreen> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: false,
        child: Scaffold(
          backgroundColor: BrandColors.navy,
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: AnimatedBuilder(
                animation: _c,
                builder: (_, __) {
                  final draw = Curves.easeInOut.transform((_c.value / 0.65).clamp(0.0, 1.0));
                  final reveal = Curves.easeOut.transform(((_c.value - 0.55) / 0.45).clamp(0.0, 1.0));
                  return Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Transform.scale(
                      scale: 0.8 + 0.2 * draw,
                      child: Container(
                        padding: const EdgeInsets.all(30),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white.withOpacity(0.06),
                          boxShadow: [BoxShadow(color: BrandColors.electric.withOpacity(0.45 * draw), blurRadius: 50, spreadRadius: 4)],
                        ),
                        child: BrandMark(size: 110, onDark: true, progress: draw),
                      ),
                    ),
                    const SizedBox(height: 36),
                    Opacity(
                      opacity: reveal,
                      child: Transform.translate(
                        offset: Offset(0, 20 * (1 - reveal)),
                        child: Column(children: [
                          const Icon(Icons.check_circle_rounded, color: BrandColors.success, size: 40),
                          const SizedBox(height: 16),
                          // Exact required message (Arabic), English translation in EN mode
                          Text(context.tr(widget.isRepair ? 'repair_sent_msg' : 'order_sent_msg'),
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800, height: 1.6)),
                          const SizedBox(height: 18),
                          Text(context.tr(widget.isRepair ? 'repair_number' : 'order_number'), style: const TextStyle(color: Colors.white60)),
                          const SizedBox(height: 4),
                          CopyCode(
                              code: widget.reference,
                              style: const TextStyle(color: BrandColors.electric, fontSize: 24, fontWeight: FontWeight.w900, letterSpacing: 1)),
                          const SizedBox(height: 6),
                          Text(context.isAr ? 'اضغط على الرقم علشان تنسخه، واستخدمه لو كلمتنا.' : 'Tap the number to copy it — use it when you contact us.',
                              textAlign: TextAlign.center, style: const TextStyle(color: Colors.white54, fontSize: 12.5)),
                          const SizedBox(height: 36),
                          FilledButton(
                            onPressed: () => context.go(widget.isRepair ? '/repairs/${widget.orderId}' : '/orders/${widget.orderId}'),
                            child: Text(context.tr(widget.isRepair ? 'view_repair' : 'view_order')),
                          ),
                          const SizedBox(height: 12),
                          OutlinedButton(
                            style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: Colors.white30)),
                            onPressed: () => context.go('/'),
                            child: Text(context.tr('back_home')),
                          ),
                        ]),
                      ),
                    ),
                  ]);
                },
              ),
            ),
          ),
        ),
      );
}
