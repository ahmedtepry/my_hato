import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/money.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../shared/barcode_scanner.dart';
import '../../shared/brand_logo.dart';
import '../../shared/product_card.dart';
import '../../shared/staff_presence.dart';
import '../../shared/states.dart';
import '../auth/auth_repository.dart';
import '../orders/orders_screens.dart' show fmtDate;
import '../repairs/repairs_repository.dart';
import '../repairs/repairs_screens.dart' show repairLabel, repairStatusColor;
import 'accounts_tab.dart';
import 'loyalty_gifts.dart';
import 'promotions.dart';
import 'team.dart';
import 'admin_repository.dart';
import 'documents.dart';
import 'stock_tools.dart';

String _t(BuildContext c, String ar, String en) => c.isAr ? ar : en;

Color _orderColor(String s) => switch (s) {
      'delivered' => BrandColors.success,
      'cancelled' => BrandColors.error,
      'pending_confirmation' => BrandColors.warning,
      _ => BrandColors.electric,
    };

// =====================================================================================
// Gate: only staff accounts get in. Anyone else sees "private developer area".
// =====================================================================================
class AdminGateScreen extends ConsumerWidget {
  const AdminGateScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    final staff = ref.watch(isStaffProvider);
    if (user != null && staff.valueOrNull == true) return const AdminHomeScreen();
    if (user != null && staff.isLoading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return _AdminLogin(signedInAsCustomer: user != null && staff.valueOrNull == false);
  }
}

class _AdminLogin extends ConsumerStatefulWidget {
  const _AdminLogin({required this.signedInAsCustomer});
  final bool signedInAsCustomer;
  @override
  ConsumerState<_AdminLogin> createState() => _AdminLoginState();
}

class _AdminLoginState extends ConsumerState<_AdminLogin> {
  final _user = TextEditingController();
  final _pass = TextEditingController();
  bool _busy = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (_user.text.trim().isEmpty || _pass.text.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(authRepoProvider).signInWithIdentifier(_user.text, _pass.text);
      ref.invalidate(staffContextProvider);
      final ok = await ref.read(adminRepoProvider).isStaff();
      if (!ok && mounted) setState(() => _error = _t(context, 'الحساب ده مالوش صلاحية دخول المساحة دي.', 'This account has no access to this area.'));
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(context, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: BrandColors.navyDeep,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          foregroundColor: Colors.white,
          leading: CloseButton(onPressed: () => context.canPop() ? context.pop() : context.go('/')),
        ),
        body: SafeArea(
          child: ListView(padding: const EdgeInsets.fromLTRB(28, 8, 28, 28), children: [
            const Center(child: BrandWordmark(size: 26, onDark: true)),
            const SizedBox(height: 28),
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(18), border: Border.all(color: Colors.white12)),
              child: Column(children: [
                const Icon(Icons.lock_rounded, color: BrandColors.electric, size: 40),
                const SizedBox(height: 12),
                Text(_t(context, 'مساحة خاصة بمطوّر My Hatō', 'My Hatō developer area'),
                    textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w800)),
                const SizedBox(height: 6),
                Text(
                  widget.signedInAsCustomer
                      ? _t(context, 'المساحة دي مش متاحة للعملاء.', 'This area is not available to customers.')
                      : _t(context, 'الدخول للمسؤول فقط.', 'Administrator sign-in only.'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70),
                ),
              ]),
            ),
            if (!widget.signedInAsCustomer) ...[
              const SizedBox(height: 24),
              _darkField(_user, _t(context, 'اسم المستخدم', 'Username'), Icons.person_outline, ltr: true),
              const SizedBox(height: 12),
              _darkField(_pass, _t(context, 'كلمة السر', 'Password'), Icons.lock_outline,
                  obscure: _obscure,
                  suffix: IconButton(
                    icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined, color: Colors.white54),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                  onSubmitted: (_) => _login()),
              if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: Color(0xFFFDA29B)))),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _busy ? null : _login,
                child: _busy
                    ? const SizedBox(height: 22, width: 22, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white))
                    : Text(_t(context, 'دخول', 'Sign in')),
              ),
            ],
          ]),
        ),
      );

  Widget _darkField(TextEditingController c, String label, IconData icon,
          {bool ltr = false, bool obscure = false, Widget? suffix, ValueChanged<String>? onSubmitted}) =>
      TextField(
        controller: c,
        obscureText: obscure,
        autocorrect: false,
        textDirection: ltr || obscure ? TextDirection.ltr : null,
        onSubmitted: onSubmitted,
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(color: Colors.white60),
          prefixIcon: Icon(icon, color: Colors.white54),
          suffixIcon: suffix,
          filled: true,
          fillColor: Colors.white.withValues(alpha: 0.06),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: Colors.white24)),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: BrandColors.electric, width: 2)),
        ),
      );
}

// =====================================================================================
// Console home
// =====================================================================================
final _statsProvider = FutureProvider.autoDispose((ref) => ref.watch(adminRepoProvider).stats());
final _cancelCountProvider = FutureProvider.autoDispose((ref) => ref.watch(adminRepoProvider).pendingCancelCount());
final _pendingReviewsProvider = FutureProvider.autoDispose((ref) => ref.watch(adminRepoProvider).pendingReviewsCount());
final _reviewFilterProvider = StateProvider<String>((_) => 'pending');
final _reviewsProvider = FutureProvider.autoDispose((ref) => ref.watch(adminRepoProvider).reviews(ref.watch(_reviewFilterProvider)));

class AdminHomeScreen extends ConsumerWidget {
  const AdminHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tabs = ref.watch(consoleTabsProvider);
    if (StaffPresence.area == 'store') StaffPresence.area = 'overview';
    final perms = ref.watch(staffContextProvider).valueOrNull?.permissions ?? const <String>{};
    return DefaultTabController(
        key: ValueKey(tabs.join(',')),
        length: tabs.length,
        child: Scaffold(
          appBar: AppBar(
            leading: IconButton(
              icon: const Icon(Icons.home_rounded),
              onPressed: () {
                StaffPresence.area = 'store';
                context.go('/');
              },
            ),
            title: Text(_t(context, 'لوحة المسؤول', 'Admin console')),
            actions: [
              if (perms.contains('staff.manage'))
                IconButton(
                  tooltip: _t(context, 'فريق العمل', 'Team'),
                  icon: const Icon(Icons.groups_rounded),
                  onPressed: () {
                    StaffPresence.area = 'team';
                    openTeam(context);
                  },
                ),
              if (perms.contains('orders.manage'))
                IconButton(
                  tooltip: _t(context, 'العروض وأكواد الخصم', 'Offers & codes'),
                  icon: const Icon(Icons.campaign_outlined),
                  onPressed: () {
                    StaffPresence.area = 'offers';
                    openPromotions(context);
                  },
                ),
              if (perms.contains('orders.view') || perms.contains('repairs.view'))
                IconButton(
                  tooltip: _t(context, 'بحث برقم الطلب', 'Search by number'),
                  icon: const Icon(Icons.search_rounded),
                  onPressed: () => _openSearch(context, ref),
                ),
              IconButton(
                tooltip: _t(context, 'خروج', 'Sign out'),
                icon: const Icon(Icons.logout_rounded),
                onPressed: () async {
                  await staffWentOffline(ref);
                  await ref.read(authRepoProvider).signOut();
                  ref.invalidate(staffContextProvider);
                  if (context.mounted) context.go('/');
                },
              ),
            ],
            bottom: TabBar(isScrollable: true, tabAlignment: TabAlignment.start, onTap: (i) => StaffPresence.area = tabs[i], tabs: [
              for (final t in tabs)
                switch (t) {
                  'orders' => Tab(icon: const Icon(Icons.receipt_long_outlined), text: _t(context, 'الطلبات', 'Orders')),
                  'repairs' => Tab(icon: const Icon(Icons.build_outlined), text: _t(context, 'الصيانة', 'Repairs')),
                  'products' => Tab(icon: const Icon(Icons.inventory_2_outlined), text: _t(context, 'المنتجات', 'Products')),
                  'reviews' => Tab(icon: const _ReviewsTabIcon(), text: _t(context, 'التقييمات', 'Reviews')),
                  'accounts' => Tab(icon: const AccountsTabIcon(), text: _t(context, 'الحسابات', 'Accounts')),
                  'gifts' => Tab(icon: const Icon(Icons.card_giftcard_rounded), text: _t(context, 'الهدايا', 'Gifts')),
                  _ => Tab(icon: const Icon(Icons.dashboard_outlined), text: _t(context, 'نظرة عامة', 'Overview')),
                },
            ]),
          ),
          body: TabBarView(children: [
            for (final t in tabs)
              switch (t) {
                'orders' => const _OrdersTab(),
                'repairs' => const _RepairsTab(),
                'products' => const _ProductsTab(),
                'reviews' => const _ReviewsTab(),
                'accounts' => const AccountsTab(),
                'gifts' => const GiftsPanel(),
                _ => const _Overview(),
              },
          ]),
        ),
      );
  }
}

class _Overview extends ConsumerWidget {
  const _Overview();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(_statsProvider);
    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(_statsProvider);
        ref.invalidate(_cancelCountProvider);
        ref.invalidate(_pendingReviewsProvider);
        ref.invalidate(pendingAccountsCountProvider);
      },
      child: stats.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(_statsProvider)),
        data: (s) {
          final tabs = ref.watch(consoleTabsProvider);
          Widget? tile(String tab, String label, String value, IconData icon, Color color, VoidCallback onTap) => tabs.contains(tab)
              ? _StatTile(label: label, value: value, icon: icon, color: color, onTap: onTap)
              : null;
          void go(String tab, void Function() setFilter) {
            setFilter();
            DefaultTabController.of(context).animateTo(tabs.indexOf(tab));
          }

          final n = (String k) => '${s[k] ?? 0}';
          return GridView.count(
            padding: const EdgeInsets.all(16),
            crossAxisCount: 2,
            childAspectRatio: 2.1,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            children: <Widget?>[
              tile('accounts', _t(context, 'حسابات للتوثيق', 'Accounts to verify'), '${ref.watch(pendingAccountsCountProvider).valueOrNull ?? 0}', Icons.how_to_reg_rounded, BrandColors.electric,
                  () => go('accounts', () => ref.read(accountsFilterProvider.notifier).state = 'pending')),
              tile('reviews', _t(context, 'تقييمات للمراجعة', 'Reviews to check'), '${ref.watch(_pendingReviewsProvider).valueOrNull ?? 0}', Icons.reviews_rounded, BrandColors.warning,
                  () => go('reviews', () => ref.read(_reviewFilterProvider.notifier).state = 'pending')),
              tile('orders', _t(context, 'طلبات إلغاء', 'Cancel requests'), '${ref.watch(_cancelCountProvider).valueOrNull ?? 0}', Icons.cancel_outlined, BrandColors.error,
                  () => go('orders', () => ref.read(_orderFilterProvider.notifier).state = 'cancel_requests')),
              tile('orders', _t(context, 'طلبات جديدة', 'New orders'), n('pending_orders'), Icons.fiber_new_rounded, BrandColors.warning,
                  () => go('orders', () => ref.read(_orderFilterProvider.notifier).state = 'pending_confirmation')),
              tile('orders', _t(context, 'طلبات النهارده', 'Orders today'), n('new_orders_today'), Icons.today_rounded, BrandColors.electric,
                  () => go('orders', () => ref.read(_orderFilterProvider.notifier).state = null)),
              tile('repairs', _t(context, 'صيانة شغالة', 'Active repairs'), n('active_repairs'), Icons.build_rounded, BrandColors.navy,
                  () => go('repairs', () => ref.read(_repairFilterProvider.notifier).state = null)),
              tile('repairs', _t(context, 'مستني موافقة', 'Awaiting approval'), n('repairs_awaiting_approval'), Icons.hourglass_top_rounded, BrandColors.warning,
                  () => go('repairs', () => ref.read(_repairFilterProvider.notifier).state = 'awaiting_approval')),
              tile('repairs', _t(context, 'جاهز للتسليم', 'Ready'), n('repairs_ready'), Icons.check_circle_rounded, BrandColors.success,
                  () => go('repairs', () => ref.read(_repairFilterProvider.notifier).state = 'ready_for_pickup')),
              tile('products', _t(context, 'مخزون قليل', 'Low stock'), n('low_stock'), Icons.inventory_rounded, BrandColors.error,
                  () => go('products', () => ref.read(_lowStockOnlyProvider.notifier).state = true)),
              tile('orders', _t(context, 'عمليات مغلقة', 'Closed'), n('closed_operations'), Icons.lock_rounded, BrandColors.gray,
                  () => go('orders', () => ref.read(_orderFilterProvider.notifier).state = 'closed')),
              tile('orders', _t(context, 'طلبات اتسلّمت', 'Delivered'), n('completed_orders'), Icons.local_shipping_rounded, BrandColors.success,
                  () => go('orders', () => ref.read(_orderFilterProvider.notifier).state = 'delivered')),
              tile('orders', _t(context, 'المبيعات', 'Sales'), formatEgp((s['total_sales_minor'] as num?)?.toInt() ?? 0, context.lang), Icons.payments_rounded, BrandColors.navy,
                  () => go('orders', () => ref.read(_orderFilterProvider.notifier).state = 'delivered')),
            ].whereType<Widget>().toList(),
          );
        },
      ),
    );
  }
}

// =====================================================================================
// Orders
// =====================================================================================
final _orderFilterProvider = StateProvider<String?>((_) => 'pending_confirmation');
final _ordersProvider = FutureProvider.autoDispose((ref) => ref.watch(adminRepoProvider).orders(status: ref.watch(_orderFilterProvider)));

class _OrdersTab extends ConsumerWidget {
  const _OrdersTab();
  static const statuses = ['pending_confirmation', 'confirmed', 'preparing', 'shipped', 'ready_for_pickup', 'out_for_delivery', 'delivered', 'cancelled'];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(_orderFilterProvider);
    final orders = ref.watch(_ordersProvider);
    return Column(children: [
      SizedBox(
        height: 54,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.fromLTRB(12, 10, 12, 4), children: [
          ChoiceChip(label: Text(_t(context, 'الكل', 'All')), selected: filter == null, onSelected: (_) => ref.read(_orderFilterProvider.notifier).state = null),
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 8),
            child: ChoiceChip(
              avatar: const Icon(Icons.cancel_outlined, size: 18, color: BrandColors.error),
              label: Text(_t(context, 'طلبات إلغاء', 'Cancel requests')),
              selected: filter == 'cancel_requests',
              onSelected: (_) => ref.read(_orderFilterProvider.notifier).state = 'cancel_requests',
            ),
          ),
          for (final s in statuses)
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 8),
              child: ChoiceChip(label: Text(context.tr('os_$s')), selected: filter == s, onSelected: (_) => ref.read(_orderFilterProvider.notifier).state = s),
            ),
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 8),
            child: ChoiceChip(
              avatar: const Icon(Icons.lock_rounded, size: 16, color: BrandColors.gray),
              label: Text(_t(context, 'مغلقة', 'Closed')),
              selected: filter == 'closed',
              onSelected: (_) => ref.read(_orderFilterProvider.notifier).state = 'closed',
            ),
          ),
        ]),
      ),
      Expanded(
        child: RefreshIndicator(
          onRefresh: () async => ref.invalidate(_ordersProvider),
          child: orders.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(_ordersProvider)),
            data: (list) => list.isEmpty
                ? ListView(children: [const SizedBox(height: 80), Center(child: Text(_t(context, 'مفيش طلبات', 'No orders')))])
                : ListView.separated(
                    padding: const EdgeInsets.all(12),
                    itemCount: list.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, i) {
                      final o = list[i];
                      return Card(
                        child: ListTile(
                          onTap: () => _orderSheet(context, ref, o),
                          title: Text(o['reference'] as String, style: const TextStyle(fontWeight: FontWeight.w800)),
                          subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text('${o['customer_name']} • ${fmtDate(context, o['created_at'] as String)}'),
                            if (_openCancel(o) != null) const _CancelBadge(),
                          ]),
                          trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                            Text(formatEgp((o['total_minor'] as num).toInt(), context.lang), style: const TextStyle(fontWeight: FontWeight.w800)),
                            const SizedBox(height: 4),
                            _orderChip(context, o),
                          ]),
                        ),
                      );
                    },
                  ),
          ),
        ),
      ),
    ]);
  }
}

Future<void> _orderSheet(BuildContext context, WidgetRef ref, Map<String, dynamic> o) async {
  final repo = ref.read(adminRepoProvider);
  final next = await repo.nextOrderStatuses(o['status'] as String, o['fulfillment'] as String);
  if (!context.mounted) return;
  final items = List<Map<String, dynamic>>.from(o['order_items'] as List? ?? const []);
  final addr = o['delivery_address'] as Map<String, dynamic>?;
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (_, sc) => ListView(controller: sc, padding: const EdgeInsets.fromLTRB(20, 0, 20, 24), children: [
        Row(children: [
          Expanded(child: Text(o['reference'] as String, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 20))),
          _orderChip(context, o),
        ]),
        _SeenCard(type: 'order', id: o['id'] as String),
        if (o['closed_at'] != null) _ClosedCard(row: o, kind: 'order'),
        if (o['closed_at'] == null && _openCancel(o) != null)
          _CancelRequestCard(
            request: _openCancel(o)!,
            warning: o['payment_status'] == 'paid' ? _t(context, 'العميل دافع أونلاين — لو وافقت لازم ترجّعله فلوسه.', 'Paid online — approving means a refund.') : null,
            onDone: () {
              ref.invalidate(_ordersProvider);
              ref.invalidate(_statsProvider);
              ref.invalidate(_cancelCountProvider);
            },
          ),
        const SizedBox(height: 8),
        Text('${o['customer_name']}'),
        SelectableText('${o['customer_phone']}', style: const TextStyle(fontWeight: FontWeight.w700)),
        if (addr != null) Text('${addr['governorate']} — ${addr['city']} — ${addr['street']} ${addr['building'] ?? ''}'),
        if ((o['delivery_notes'] as String?)?.isNotEmpty == true) Text('📝 ${o['delivery_notes']}'),
        Text('${_t(context, o['fulfillment'] == 'pickup' ? 'استلام من الفرع' : 'توصيل', o['fulfillment'] == 'pickup' ? 'Branch pickup' : 'Delivery')} • ${o['payment_method']}',
            style: const TextStyle(color: BrandColors.gray)),
        const Divider(height: 24),
        for (final it in items)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: [
              Expanded(child: Text('${it['quantity']} × ${context.isAr ? it['name_ar'] : it['name_en']}')),
              Text(formatEgp((it['line_total_minor'] as num).toInt(), context.lang)),
            ]),
          ),
        const Divider(height: 24),
        Row(children: [
          Text(_t(context, 'الإجمالي', 'Total'), style: const TextStyle(fontWeight: FontWeight.w800)),
          const Spacer(),
          Text(formatEgp((o['total_minor'] as num).toInt(), context.lang), style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18)),
        ]),
        const SizedBox(height: 8),
        if ((o['customer_phone'] as String?)?.isNotEmpty == true)
          ContactButtons(
            phone: o['customer_phone'] as String,
            message: 'أهلاً ${o['customer_name'] ?? ''}، معاك فريق المبيعات في My Hatō بخصوص طلبك رقم ${o['reference']}.',
          ),
        DocumentButtons(fileName: 'MyHato-${o['reference']}', build: () => orderInvoicePdf(o)),
        const SizedBox(height: 16),
        if (o['closed_at'] == null) ...[
        _StatusUpdate(
          current: o['status'] as String,
          options: next,
          flow: _OrdersTab.statuses,
          label: (s) => context.tr('os_$s'),
          color: _orderColor,
          isNegative: (s) => s == 'cancelled',
          presets: o['fulfillment'] == 'pickup' ? _orderPickupPresets : _orderDeliveryPresets,
          onSubmit: (to, msg) => _changeOrder(ctx, ref, o['id'] as String, to, msg),
        ),
        const Divider(height: 36),
        _CloseOperationButton(
          kind: 'order',
          id: o['id'] as String,
          onDone: () {
            ref.invalidate(_ordersProvider);
            ref.invalidate(_statsProvider);
            ref.invalidate(_cancelCountProvider);
          },
        ),
        ],
      ]),
    ),
  );
}

/// to == null: message only. Cancelling needs a reason (the message counts as one).
Future<void> _changeOrder(BuildContext ctx, WidgetRef ref, String id, String? to, String? message) async {
  String? note;
  if (to == 'cancelled') {
    note = message ?? await _askText(ctx, _t(ctx, 'سبب الإلغاء', 'Cancellation reason'));
    if (note == null) return;
  }
  try {
    final repo = ref.read(adminRepoProvider);
    if (to == null) {
      await repo.postOrderUpdate(id, message!);
    } else {
      await repo.setOrderStatus(id, to, note: note, message: message);
    }
    ref.invalidate(_ordersProvider);
    ref.invalidate(_statsProvider);
    if (ctx.mounted) {
      Navigator.of(ctx).pop();
      showSnack(ctx, to == null ? _t(ctx, 'الرسالة وصلت للعميل', 'Message sent to the customer')
          : _t(ctx, 'اتحدّثت الحالة والعميل وصله إشعار', 'Status updated — the customer was notified'));
    }
  } catch (e) {
    if (ctx.mounted) showSnack(ctx, friendlyError(ctx, e), error: true);
  }
}

Future<String?> _askText(BuildContext context, String title, {String? hint, TextInputType? keyboard}) {
  final c = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(title),
      content: TextField(controller: c, autofocus: true, keyboardType: keyboard, decoration: InputDecoration(hintText: hint), maxLines: keyboard == null ? 3 : 1),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: Text(context.tr('cancel'))),
        FilledButton(onPressed: () => Navigator.pop(d, c.text.trim().isEmpty ? null : c.text.trim()), child: Text(_t(context, 'تأكيد', 'Confirm'))),
      ],
    ),
  );
}

// =====================================================================================
// Repairs
// =====================================================================================
final _repairFilterProvider = StateProvider<String?>((_) => null);
final _repairsProvider = FutureProvider.autoDispose((ref) => ref.watch(adminRepoProvider).repairs(status: ref.watch(_repairFilterProvider)));

class _RepairsTab extends ConsumerWidget {
  const _RepairsTab();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repairs = ref.watch(_repairsProvider);
    final labels = ref.watch(repairLabelsProvider).valueOrNull;
    final filter = ref.watch(_repairFilterProvider);
    Widget chip(String? value, String label) => Padding(
          padding: const EdgeInsetsDirectional.only(end: 8),
          child: ChoiceChip(label: Text(label), selected: filter == value, onSelected: (_) => ref.read(_repairFilterProvider.notifier).state = value),
        );
    return Column(children: [
      SizedBox(
        height: 54,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.fromLTRB(12, 10, 12, 4), children: [
          chip(null, _t(context, 'الشغالة', 'Active')),
          chip('cancel_requests', _t(context, 'طلبات إلغاء', 'Cancel requests')),
          chip('awaiting_approval', repairLabel(context, labels, 'awaiting_approval')),
          chip('waiting_for_parts', repairLabel(context, labels, 'waiting_for_parts')),
          chip('ready_for_pickup', repairLabel(context, labels, 'ready_for_pickup')),
          chip('all', _t(context, 'الكل', 'All')),
          chip('closed', _t(context, 'مغلقة', 'Closed')),
        ]),
      ),
      Expanded(child: RefreshIndicator(
      onRefresh: () async => ref.invalidate(_repairsProvider),
      child: repairs.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(_repairsProvider)),
        data: (list) => list.isEmpty
            ? ListView(children: [const SizedBox(height: 80), Center(child: Text(_t(context, 'مفيش طلبات صيانة شغالة', 'No active repairs')))])
            : ListView.separated(
                padding: const EdgeInsets.all(12),
                itemCount: list.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (_, i) {
                  final r = list[i];
                  final st = r['status'] as String;
                  return Card(
                    child: ListTile(
                      onTap: () => _repairSheet(context, ref, r),
                      title: Text('${r['reference']} • ${r['device_brand']} ${r['device_model']}', style: const TextStyle(fontWeight: FontWeight.w800)),
                      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('${r['contact_name']} • ${r['contact_phone']}\n${r['problem_description']}', maxLines: 3, overflow: TextOverflow.ellipsis),
                        if (_openCancel(r) != null) const _CancelBadge(),
                      ]),
                      isThreeLine: true,
                      trailing: _repairChip(context, labels, r),
                    ),
                  );
                },
              ),
      ),
    ))]);
  }
}

Future<void> _repairSheet(BuildContext context, WidgetRef ref, Map<String, dynamic> r) async {
  final repo = ref.read(adminRepoProvider);
  final next = await repo.nextRepairStatuses(r['status'] as String);
  final labels = ref.read(repairLabelsProvider).valueOrNull;
  if (!context.mounted) return;
  final closed = r['closed_at'] != null;
  final canQuote = !closed && ['initial_inspection', 'diagnosis_completed', 'received_at_branch', 'device_collected', 'awaiting_approval'].contains(r['status']);
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (_, sc) => ListView(controller: sc, padding: const EdgeInsets.fromLTRB(20, 0, 20, 24), children: [
        Row(children: [
          Expanded(child: Text(r['reference'] as String, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 20))),
          StatusChip(label: repairLabel(context, labels, r['status'] as String), color: repairStatusColor(r['status'] as String)),
        ]),
        _SeenCard(type: 'repair', id: r['id'] as String),
        if (r['closed_at'] != null) _ClosedCard(row: r, kind: 'repair'),
        if (r['closed_at'] == null && _openCancel(r) != null)
          _CancelRequestCard(
            request: _openCancel(r)!,
            onDone: () {
              ref.invalidate(_repairsProvider);
              ref.invalidate(_statsProvider);
              ref.invalidate(_cancelCountProvider);
            },
          ),
        const SizedBox(height: 8),
        Text('${r['device_brand']} ${r['device_model']}', style: const TextStyle(fontWeight: FontWeight.w700)),
        Text('${r['contact_name']}'),
        SelectableText('${r['contact_phone']}', style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Text('${r['problem_description']}', style: const TextStyle(color: BrandColors.gray)),
        if (r['estimated_cost_minor'] != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('${_t(context, 'عرض السعر', 'Quote')}: ${formatEgp((r['estimated_cost_minor'] as num).toInt(), context.lang)}'),
          ),
        if ((r['contact_phone'] as String?)?.isNotEmpty == true)
          ContactButtons(
            phone: r['contact_phone'] as String,
            message: 'أهلاً ${r['contact_name'] ?? ''}، معاك فريق الصيانة في My Hatō بخصوص طلب الصيانة رقم ${r['reference']} (${r['device_brand']} ${r['device_model']}).',
          ),
        DocumentButtons(
          fileName: 'MyHato-${r['reference']}',
          build: () => repairReceiptPdf(r, repairLabel(context, labels, r['status'] as String)),
        ),
        const Divider(height: 28),
        if (!closed) ...[
        _StatusUpdate(
          current: r['status'] as String,
          options: next,
          flow: _repairFlow,
          label: (s) => repairLabel(context, labels, s),
          color: repairStatusColor,
          isNegative: (s) => s == 'cancelled' || s == 'unrepairable',
          message: (s) => labels?[s] == null ? null : (context.isAr ? labels![s]!['message_ar'] : labels![s]!['message_en']) as String?,
          presets: _repairPresets,
          onSubmit: (to, msg) => _changeRepair(ctx, ref, r['id'] as String, to, msg),
          onQuote: canQuote
              ? (egp, msg) async {
                  final desc = msg ?? _t(ctx, 'تكلفة الإصلاح', 'Repair cost');
                  try {
                    await repo.sendQuote(r['id'] as String, egp * 100, desc, msg);
                    ref.invalidate(_repairsProvider);
                    if (ctx.mounted) {
                      Navigator.of(ctx).pop();
                      showSnack(ctx, _t(ctx, 'اتبعت التكلفة للعميل، مستنيين رده', 'Price sent to the customer, waiting for the answer'));
                    }
                  } catch (e) {
                    if (ctx.mounted) showSnack(ctx, friendlyError(ctx, e), error: true);
                  }
                }
              : null,
        ),
        const Divider(height: 36),
        _CloseOperationButton(
          kind: 'repair',
          id: r['id'] as String,
          onDone: () {
            ref.invalidate(_repairsProvider);
            ref.invalidate(_statsProvider);
            ref.invalidate(_cancelCountProvider);
          },
        ),
        ],
      ]),
    ),
  );
}

const _repairFlow = [
  'pickup_requested', 'pickup_scheduled', 'device_collected', 'received_at_branch', 'initial_inspection', 'diagnosis_completed',
  'awaiting_approval', 'repair_approved', 'repair_in_progress', 'waiting_for_parts', 'quality_testing', 'repair_completed',
  'ready_for_pickup', 'out_for_delivery', 'delivered', 'cancelled', 'unrepairable',
];

/// to == null: message only. The message rides on the status notification; cancel / unrepairable need one.
Future<void> _changeRepair(BuildContext ctx, WidgetRef ref, String id, String? to, String? message) async {
  var note = message;
  if ((to == 'cancelled' || to == 'unrepairable') && note == null) {
    note = await _askText(ctx, _t(ctx, 'السبب (هيوصل للعميل)', 'Reason (sent to the customer)'));
    if (note == null) return;
  }
  try {
    final repo = ref.read(adminRepoProvider);
    if (to == null) {
      await repo.postRepairUpdate(id, message!);
    } else {
      await repo.setRepairStatus(id, to, note: note);
    }
    ref.invalidate(_repairsProvider);
    ref.invalidate(_statsProvider);
    if (ctx.mounted) {
      Navigator.of(ctx).pop();
      showSnack(ctx, to == null ? _t(ctx, 'الرسالة وصلت للعميل', 'Message sent to the customer')
          : _t(ctx, 'اتحدّثت الحالة والعميل وصله إشعار', 'Status updated — the customer was notified'));
    }
  } catch (e) {
    if (ctx.mounted) showSnack(ctx, friendlyError(ctx, e), error: true);
  }
}

// =====================================================================================
// Products
// =====================================================================================
final _productSearchProvider = StateProvider.autoDispose<String>((_) => '');
final _lowStockOnlyProvider = StateProvider<bool>((_) => false);
final _productsProvider = FutureProvider.autoDispose(
    (ref) => ref.watch(adminRepoProvider).products(search: ref.watch(_productSearchProvider), lowStockOnly: ref.watch(_lowStockOnlyProvider)));
final _categoriesProvider = FutureProvider.autoDispose((ref) => ref.watch(adminRepoProvider).categories());
final _brandsProvider = FutureProvider.autoDispose((ref) => ref.watch(adminRepoProvider).brands());

class _ProductsTab extends ConsumerWidget {
  const _ProductsTab();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final products = ref.watch(_productsProvider);
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const _ProductEditor())),
        icon: const Icon(Icons.add),
        label: Text(_t(context, 'منتج جديد', 'New product')),
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: _ProductSearchField(onSearch: (v) => ref.read(_productSearchProvider.notifier).state = v),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
          child: Row(children: [
            Expanded(
              child: FilledButton.tonalIcon(
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(42)),
                icon: const Icon(Icons.qr_code_scanner_rounded, size: 18),
                label: Text(_t(context, 'استلام بضاعة', 'Receive stock')),
                onPressed: () => receiveStockByBarcode(
                  context,
                  ref,
                  onChanged: () => ref.invalidate(_productsProvider),
                  onNewProduct: (sku) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => _ProductEditor(initialSku: sku))),
                ),
              ),
            ),
            const SizedBox(width: 8),
            PopupMenuButton<String>(
              tooltip: 'Excel',
              onSelected: (v) {
                if (v == 'export') {
                  exportProductsExcel(context, ref);
                } else {
                  importProductsExcel(context, ref, onDone: () => ref.invalidate(_productsProvider));
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(value: 'export', child: ListTile(leading: const Icon(Icons.download_rounded), title: Text(_t(context, 'تصدير Excel', 'Export to Excel')), contentPadding: EdgeInsets.zero)),
                PopupMenuItem(value: 'import', child: ListTile(leading: const Icon(Icons.upload_file_rounded), title: Text(_t(context, 'استيراد أسعار وكميات من Excel', 'Import prices & stock')), contentPadding: EdgeInsets.zero)),
              ],
              child: Container(
                height: 42,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(color: const Color(0xFF1D6F42).withValues(alpha: 0.1), borderRadius: BorderRadius.circular(14)),
                child: const Row(children: [
                  Icon(Icons.table_chart_rounded, color: Color(0xFF1D6F42), size: 20),
                  SizedBox(width: 6),
                  Text('Excel', style: TextStyle(color: Color(0xFF1D6F42), fontWeight: FontWeight.w800)),
                ]),
              ),
            ),
          ]),
        ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: FilterChip(
              avatar: const Icon(Icons.inventory_rounded, size: 18, color: BrandColors.error),
              label: Text(_t(context, 'مخزون قليل بس', 'Low stock only')),
              selected: ref.watch(_lowStockOnlyProvider),
              onSelected: (v) => ref.read(_lowStockOnlyProvider.notifier).state = v,
            ),
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () async => ref.invalidate(_productsProvider),
            child: products.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(_productsProvider)),
              data: (list) => ListView.separated(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
                itemCount: list.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (_, i) {
                  final p = list[i];
                  final imgs = List<Map<String, dynamic>>.from(p['product_images'] as List? ?? const [])
                    ..sort((a, b) => (a['sort_order'] as int).compareTo(b['sort_order'] as int));
                  final stock = (p['stock_quantity'] as num).toInt();
                  return Card(
                    child: ListTile(
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => _ProductEditor(product: p))),
                      leading: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: SizedBox(width: 52, height: 52, child: NetImage(path: imgs.isEmpty ? null : imgs.first['storage_path'] as String)),
                      ),
                      title: Text(context.isAr ? p['name_ar'] as String : p['name_en'] as String, maxLines: 2, overflow: TextOverflow.ellipsis),
                      subtitle: Text('${formatEgp((p['price_minor'] as num).toInt(), context.lang)} • ${_t(context, 'المخزون', 'Stock')}: $stock'
                          '${p['status'] != 'published' ? ' • ${_t(context, 'مخفي', 'Hidden')}' : ''}'),
                      trailing: Icon(Icons.circle, size: 12, color: stock <= 0 ? BrandColors.error : stock <= 5 ? BrandColors.warning : BrandColors.success),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

class _ProductEditor extends ConsumerStatefulWidget {
  const _ProductEditor({this.product, this.initialSku});
  final Map<String, dynamic>? product;

  /// New product from an unknown scanned barcode.
  final String? initialSku;
  @override
  ConsumerState<_ProductEditor> createState() => _ProductEditorState();
}

class _ProductEditorState extends ConsumerState<_ProductEditor> {
  final _form = GlobalKey<FormState>();
  late final p = widget.product;
  late final _nameAr = TextEditingController(text: p?['name_ar'] as String? ?? '');
  late final _nameEn = TextEditingController(text: p?['name_en'] as String? ?? '');
  late final _price = TextEditingController(text: p == null ? '' : '${(p!['price_minor'] as num) ~/ 100}');
  late final _compare = TextEditingController(text: p?['compare_at_price_minor'] == null ? '' : '${(p!['compare_at_price_minor'] as num) ~/ 100}');
  late final _stock = TextEditingController(text: p == null ? '' : '${p!['stock_quantity']}');
  late final _desc = TextEditingController();
  late final _sku = TextEditingController(text: p?['sku'] as String? ?? widget.initialSku ?? '');
  late final _model = TextEditingController(text: p?['model'] as String? ?? '');
  late String? _brandId = p?['brand_id'] as String?;
  late String? _categoryId = p?['category_id'] as String?;
  late bool _published = (p?['status'] ?? 'published') == 'published';
  late bool _featured = p?['is_featured'] == true;
  Uint8List? _image;
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [_nameAr, _nameEn, _price, _compare, _stock, _desc, _sku, _model]) {
      c.dispose();
    }
    super.dispose();
  }

  int? _egp(String s) => int.tryParse(s.replaceAll(RegExp(r'[^0-9]'), ''));

  Future<void> _save() async {
    if (!_form.currentState!.validate() || _categoryId == null) return;
    setState(() => _busy = true);
    final repo = ref.read(adminRepoProvider);
    try {
      final price = _egp(_price.text)! * 100;
      final compare = _egp(_compare.text);
      final stock = _egp(_stock.text) ?? 0;
      if (p == null) {
        await repo.createProduct(
          categoryId: _categoryId!,
          nameAr: _nameAr.text,
          nameEn: _nameEn.text,
          descriptionAr: _desc.text.trim().isEmpty ? null : _desc.text.trim(),
          priceMinor: price,
          stock: stock,
          imageBytes: _image,
          sku: _sku.text,
          brandId: _brandId,
          model: _model.text,
        );
      } else {
        final sku = _sku.text.trim();
        if (sku.isNotEmpty && sku != p!['sku'] && await repo.skuTaken(sku, exceptId: p!['id'] as String)) throw Exception('SKU_TAKEN');
        await repo.updateProduct(p!['id'] as String, {
          if (sku.isNotEmpty && sku != p!['sku']) 'sku': sku,
          'brand_id': _brandId,
          'model': _model.text.trim().isEmpty ? null : _model.text.trim(),
          'name_ar': _nameAr.text.trim(),
          'name_en': _nameEn.text.trim().isEmpty ? _nameAr.text.trim() : _nameEn.text.trim(),
          'price_minor': price,
          'compare_at_price_minor': (compare != null && compare * 100 > price) ? compare * 100 : null,
          'category_id': _categoryId,
          'status': _published ? 'published' : 'draft',
          'is_featured': _featured,
        });
        await repo.setStock(p!['id'] as String, (p!['stock_quantity'] as num).toInt(), stock);
        if (_image != null) await repo.addImage(p!['id'] as String, _image!, 9);
      }
      ref.invalidate(_productsProvider);
      if (mounted) {
        showSnack(context, _t(context, 'اتحفظ والتغيير ظهر في المتجر', 'Saved — the store is updated'));
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _newBrand() async {
    final ar = TextEditingController();
    final en = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(_t(context, 'ماركة جديدة', 'New brand')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: ar, autofocus: true, decoration: InputDecoration(labelText: _t(context, 'الاسم بالعربي', 'Arabic name'))),
          const SizedBox(height: 10),
          TextField(controller: en, textDirection: TextDirection.ltr, decoration: InputDecoration(labelText: _t(context, 'الاسم بالإنجليزي', 'English name'))),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(context.tr('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(d, ar.text.trim().isNotEmpty), child: Text(_t(context, 'إضافة', 'Add'))),
        ],
      ),
    );
    if (ok != true) return null;
    try {
      final id = await ref.read(adminRepoProvider).createBrand(ar.text, en.text);
      ref.invalidate(_brandsProvider);
      await ref.read(_brandsProvider.future);
      return id;
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(context, e), error: true);
      return null;
    }
  }

  Future<void> _archive() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(_t(context, 'حذف المنتج؟', 'Delete product?')),
        content: Text(_t(context, 'المنتج هيختفي من المتجر فورًا. الطلبات القديمة بتفضل محفوظة زي ما هي.',
            'The product disappears from the store right away. Past orders keep their history.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(context.tr('cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: BrandColors.error),
            onPressed: () => Navigator.pop(d, true),
            child: Text(_t(context, 'حذف', 'Delete')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(adminRepoProvider).archiveProduct(p!['id'] as String);
      ref.invalidate(_productsProvider);
      if (mounted) {
        showSnack(context, _t(context, 'المنتج اتشال من المتجر', 'Product removed from the store'));
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(context, e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cats = ref.watch(_categoriesProvider).valueOrNull ?? const [];
    final brands = ref.watch(_brandsProvider).valueOrNull ?? const [];
    String? need(String? v) => (v == null || v.trim().isEmpty) ? context.tr('required') : null;
    return Scaffold(
      appBar: AppBar(
        title: Text(p == null ? _t(context, 'منتج جديد', 'New product') : _t(context, 'تعديل المنتج', 'Edit product')),
        actions: [if (p != null) IconButton(tooltip: _t(context, 'حذف', 'Delete'), icon: const Icon(Icons.delete_outline, color: BrandColors.error), onPressed: _archive)],
      ),
      body: AbsorbPointer(
        absorbing: _busy,
        child: Form(
          key: _form,
          child: ListView(padding: const EdgeInsets.all(16), children: [
            TextFormField(controller: _nameAr, decoration: InputDecoration(labelText: _t(context, 'الاسم بالعربي', 'Arabic name')), validator: need),
            const SizedBox(height: 12),
            TextFormField(controller: _nameEn, textDirection: TextDirection.ltr, decoration: InputDecoration(labelText: _t(context, 'الاسم بالإنجليزي (اختياري)', 'English name (optional)'))),
            const SizedBox(height: 12),
            TextFormField(
              controller: _sku,
              textDirection: TextDirection.ltr,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                labelText: _t(context, 'كود المنتج SKU / باركود', 'SKU / barcode'),
                hintText: p == null ? _t(context, 'اكتبه أو امسحه — لو سبته فاضي هيتعمل تلقائي', 'Type or scan — left empty, one is generated') : null,
                prefixIcon: const Icon(Icons.qr_code_2_rounded),
                suffixIcon: IconButton(
                  tooltip: _t(context, 'امسح بالكاميرا', 'Scan with camera'),
                  icon: const Icon(Icons.qr_code_scanner_rounded, color: BrandColors.electric),
                  onPressed: () async {
                    final code = await scanBarcode(context);
                    if (code != null && mounted) setState(() => _sku.text = code);
                  },
                ),
              ),
              validator: (v) {
                final t = (v ?? '').trim();
                if (t.isEmpty) return p == null ? null : context.tr('required');
                return RegExp(r'^[A-Za-z0-9._\-]{3,64}$').hasMatch(t)
                    ? null
                    : _t(context, 'من 3 لـ 64 حرف إنجليزي أو رقم (مسموح . _ -)', '3–64 letters/digits (. _ - allowed)');
              },
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: cats.any((c) => c['id'] == _categoryId) ? _categoryId : null,
              isExpanded: true,
              decoration: InputDecoration(labelText: _t(context, 'القسم', 'Category')),
              items: [for (final c in cats) DropdownMenuItem(value: c['id'] as String, child: Text(context.isAr ? c['name_ar'] as String : c['name_en'] as String))],
              onChanged: (v) => setState(() => _categoryId = v),
              validator: (v) => v == null ? context.tr('required') : null,
            ),
            const SizedBox(height: 12),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                flex: 5,
                child: DropdownButtonFormField<String>(
                  value: brands.any((b) => b['id'] == _brandId) ? _brandId : null,
                  isExpanded: true,
                  decoration: InputDecoration(labelText: _t(context, 'الماركة', 'Brand'), prefixIcon: const Icon(Icons.sell_outlined)),
                  items: [
                    DropdownMenuItem(value: '', child: Text(_t(context, 'بدون ماركة', 'No brand'), style: const TextStyle(color: BrandColors.gray))),
                    for (final b in brands)
                      DropdownMenuItem(value: b['id'] as String, child: Text(context.isAr ? b['name_ar'] as String : b['name_en'] as String, overflow: TextOverflow.ellipsis)),
                    DropdownMenuItem(
                      value: '__new__',
                      child: Row(children: [
                        const Icon(Icons.add_circle_outline, size: 18, color: BrandColors.electric),
                        const SizedBox(width: 6),
                        Text(_t(context, 'ماركة جديدة…', 'New brand…'), style: const TextStyle(color: BrandColors.electric, fontWeight: FontWeight.w700)),
                      ]),
                    ),
                  ],
                  onChanged: (v) async {
                    if (v == '__new__') {
                      final id = await _newBrand();
                      setState(() => _brandId = id ?? _brandId);
                    } else {
                      setState(() => _brandId = (v == null || v.isEmpty) ? null : v);
                    }
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 4,
                child: TextFormField(
                  controller: _model,
                  textDirection: TextDirection.ltr,
                  decoration: InputDecoration(
                    labelText: _t(context, 'الموديل', 'Model'),
                    hintText: _t(context, 'مثلاً A73', 'e.g. A73'),
                  ),
                ),
              ),
            ]),
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 4, top: 4),
              child: Text(
                _t(context, 'للإكسسوارات: الماركة والموديل اللي المنتج بيركب عليه (جراب أوبو A73 مثلاً).',
                    'For accessories: the phone brand and model it fits (e.g. an Oppo A73 case).'),
                style: const TextStyle(color: BrandColors.gray, fontSize: 12),
              ),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: TextFormField(
                  controller: _price,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: _t(context, 'السعر (ج.م)', 'Price (EGP)')),
                  validator: (v) => (_egp(v ?? '') ?? 0) <= 0 ? context.tr('required') : null,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextFormField(
                  controller: _compare,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: _t(context, 'السعر قبل الخصم', 'Was price'), hintText: _t(context, 'اختياري', 'optional')),
                ),
              ),
            ]),
            const SizedBox(height: 12),
            TextFormField(
              controller: _stock,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: _t(context, 'الكمية في المخزن', 'Stock quantity')),
              validator: (v) => _egp(v ?? '') == null ? context.tr('required') : null,
            ),
            if (p == null) ...[
              const SizedBox(height: 12),
              TextFormField(controller: _desc, maxLines: 3, decoration: InputDecoration(labelText: _t(context, 'وصف (اختياري)', 'Description (optional)'))),
            ],
            if (p != null) ...[
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(_t(context, 'ظاهر في المتجر', 'Visible in the store')),
                value: _published,
                onChanged: (v) => setState(() => _published = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(_t(context, 'منتج مميّز في الرئيسية', 'Featured on home')),
                value: _featured,
                onChanged: (v) => setState(() => _featured = v),
              ),
            ],
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: Icon(_image == null ? Icons.add_photo_alternate_outlined : Icons.check_circle, color: _image == null ? null : BrandColors.success),
              label: Text(_image == null ? _t(context, 'إضافة صورة من الموبايل', 'Add a photo') : _t(context, 'الصورة جاهزة', 'Photo ready')),
              onPressed: () async {
                final x = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 80, maxWidth: 1400);
                if (x != null) {
                  final bytes = await x.readAsBytes();
                  setState(() => _image = bytes);
                }
              },
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _save,
              child: _busy
                  ? const SizedBox(height: 22, width: 22, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white))
                  : Text(context.tr('save')),
            ),
          ]),
        ),
      ),
    );
  }
}

/// One step for status + customer message: pick the new status (or keep the current one), pick a
/// ready-made message (or write one), then one button applies both — the customer gets a single
/// notification with the status and the message.
class _StatusUpdate extends StatefulWidget {
  const _StatusUpdate({
    required this.current,
    required this.options,
    required this.flow,
    required this.label,
    required this.color,
    required this.isNegative,
    required this.presets,
    required this.onSubmit,
    this.message,
    this.onQuote,
  });
  final String current;
  final List<String> options;

  /// All statuses in their natural order (options are shown in this order).
  final List<String> flow;
  final String Function(String) label;
  final Color Function(String) color;
  final bool Function(String) isNegative;
  final String? Function(String)? message;
  final List<String> presets;

  /// to == null: keep the status, only send the message.
  final Future<void> Function(String? to, String? message) onSubmit;

  /// When set, the list offers "will cost" with a price field: the customer gets the price and
  /// can accept or reject it (amount in EGP, optional message).
  final Future<void> Function(int egp, String? message)? onQuote;

  @override
  State<_StatusUpdate> createState() => _StatusUpdateState();
}

class _StatusUpdateState extends State<_StatusUpdate> {
  String? _to;
  String? _preset;
  bool _quote = false;
  final _custom = TextEditingController();
  final _price = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _custom.dispose();
    _price.dispose();
    super.dispose();
  }

  int? get _priceEgp {
    final n = int.tryParse(_price.text.replaceAll(RegExp(r'[^0-9]'), ''));
    return (n == null || n <= 0 || n > 1000000) ? null : n;
  }

  String? get _message => _custom.text.trim().isNotEmpty ? _custom.text.trim() : _preset;

  Widget _radio(bool sel, {bool negative = false}) => AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        child: Icon(sel ? Icons.radio_button_checked : Icons.radio_button_unchecked,
            key: ValueKey(sel), color: sel ? (negative ? BrandColors.error : BrandColors.electric) : BrandColors.gray),
      );

  @override
  Widget build(BuildContext context) {
    final finalStatus = widget.options.isEmpty;
    final idx = {for (var i = 0; i < widget.flow.length; i++) widget.flow[i]: i};
    final ordered = [...widget.options.where((s) => !widget.isNegative(s)), ...widget.options.where(widget.isNegative)]
      ..sort((x, y) {
        final nx = widget.isNegative(x), ny = widget.isNegative(y);
        if (nx != ny) return nx ? 1 : -1;
        return (idx[x] ?? 99).compareTo(idx[y] ?? 99);
      });
    final msg = _message;
    final ready = !_busy && (_quote ? _priceEgp != null : (_to != null || msg != null));
    final negative = _to != null && widget.isNegative(_to!);
    final buttonLabel = _quote
        ? _t(context, 'ابعت التكلفة للعميل', 'Send the price to the customer')
        : _to == null
        ? _t(context, 'ابعت الرسالة للعميل', 'Send message')
        : (msg == null ? _t(context, 'تأكيد تغيير الحالة', 'Confirm status change') : _t(context, 'غيّر الحالة وابعت الرسالة', 'Change status & send message'));

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(_t(context, 'الحالة', 'Status'), style: const TextStyle(fontWeight: FontWeight.w800)),
      const SizedBox(height: 8),
      Material(
            color: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: BrandColors.border)),
            clipBehavior: Clip.antiAlias,
            child: Column(children: [
          ListTile(
            onTap: _busy ? null : () => setState(() {
              _to = null;
              _quote = false;
            }),
            selected: _to == null && !_quote,
            selectedTileColor: BrandColors.electric.withValues(alpha: 0.04),
            leading: _radio(_to == null && !_quote),
            title: Text(widget.label(widget.current), style: TextStyle(fontWeight: _to == null && !_quote ? FontWeight.w700 : FontWeight.w500)),
            trailing: Text(finalStatus ? _t(context, 'نهائية', 'Final') : _t(context, 'الحالية — من غير تغيير', 'Current — keep'),
                style: const TextStyle(color: BrandColors.gray, fontSize: 12)),
          ),
          for (final s in ordered) ...[
            const Divider(height: 1),
            ListTile(
              onTap: _busy ? null : () => setState(() {
                _to = s;
                _quote = false;
              }),
              selected: _to == s,
              selectedTileColor: (widget.isNegative(s) ? BrandColors.error : BrandColors.electric).withValues(alpha: 0.06),
              leading: _radio(_to == s, negative: widget.isNegative(s)),
              title: Text(widget.label(s),
                  style: TextStyle(fontWeight: _to == s ? FontWeight.w800 : FontWeight.w500, color: widget.isNegative(s) ? BrandColors.error : null)),
              subtitle: widget.message?.call(s) == null ? null : Text('💬 ${widget.message!(s)}', style: const TextStyle(fontSize: 12)),
            ),
          ],
          if (widget.onQuote != null) ...[
            const Divider(height: 1),
            ListTile(
              onTap: _busy
                  ? null
                  : () => setState(() {
                        _quote = true;
                        _to = null;
                      }),
              selected: _quote,
              selectedTileColor: BrandColors.success.withValues(alpha: 0.08),
              leading: _radio(_quote),
              title: Text(_t(context, 'هيكلّف 💰', 'Will cost 💰'), style: TextStyle(fontWeight: _quote ? FontWeight.w800 : FontWeight.w500)),
              subtitle: Text(_t(context, 'العميل يوصله السعر ويختار يوافق أو يرفض', 'The customer gets the price and accepts or rejects'),
                  style: const TextStyle(fontSize: 12)),
              trailing: SizedBox(
                width: 112,
                child: TextField(
                  controller: _price,
                  enabled: !_busy,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  textDirection: TextDirection.ltr,
                  onTap: () => setState(() {
                    _quote = true;
                    _to = null;
                  }),
                  onChanged: (_) => setState(() {
                    _quote = true;
                    _to = null;
                  }),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: _t(context, 'السعر', 'Price'),
                    suffixText: _t(context, 'ج.م', 'EGP'),
                  ),
                ),
              ),
            ),
          ],
        ]),
      ),
      if (!finalStatus) ...[
        const SizedBox(height: 18),
        Text(_t(context, 'رسالة للعميل (اختياري)', 'Message to the customer (optional)'), style: const TextStyle(fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        Material(
            color: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: BrandColors.border)),
            clipBehavior: Clip.antiAlias,
            child: Column(children: [
            for (var i = 0; i < widget.presets.length; i++) ...[
              if (i > 0) const Divider(height: 1),
              ListTile(
                onTap: _busy
                    ? null
                    : () => setState(() {
                          _preset = _preset == widget.presets[i] ? null : widget.presets[i];
                          if (_preset != null) _custom.clear();
                        }),
                selected: _preset == widget.presets[i],
                selectedTileColor: BrandColors.electric.withValues(alpha: 0.06),
                leading: _radio(_preset == widget.presets[i]),
                title: Text(widget.presets[i],
                    style: TextStyle(fontWeight: _preset == widget.presets[i] ? FontWeight.w700 : FontWeight.w500, height: 1.4)),
              ),
            ],
          ]),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _custom,
          maxLines: 2,
          maxLength: 500,
          onChanged: (_) => setState(() => _preset = null),
          decoration: InputDecoration(hintText: _t(context, 'أو اكتب رسالة من عندك…', 'Or write your own message…'), counterText: ''),
        ),
      ],
      const SizedBox(height: 14),
      if (!finalStatus || msg != null)
        FilledButton.icon(
          style: negative ? FilledButton.styleFrom(backgroundColor: BrandColors.error) : null,
          icon: _busy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white))
              : Icon(_to == null ? Icons.send_rounded : Icons.check_rounded),
          label: Text(buttonLabel),
          onPressed: !ready
              ? null
              : () async {
                  setState(() => _busy = true);
                  try {
                    if (_quote) {
                      await widget.onQuote!(_priceEgp!, msg);
                    } else {
                      await widget.onSubmit(_to, msg);
                    }
                  } finally {
                    if (mounted) setState(() => _busy = false);
                  }
                },
        ),
    ]);
  }
}

const _orderDeliveryPresets = [
  'بنجهّز طلبك وهيخرج النهارده.',
  'طلبك هيوصلك مع المندوب بكرة إن شاء الله.',
  'طلبك هيوصلك مع المندوب خلال يومين.',
  'طلبك اتشحن، والمندوب هيكلمك قبل ما يوصل.',
  'المندوب في الطريق وهيكلمك خلال ساعة.',
  'حاولنا نوصلك ومحدش ردّ، ياريت تكلمنا علشان نحدد ميعاد تاني.',
  'محتاجين نأكد العنوان معاك، ياريت ترد على تليفوننا.',
  'في منتج من طلبك خلص مؤقتًا، هنكلمك نتفق على بديل.',
];

const _orderPickupPresets = [
  'بنجهّز طلبك وهيبقى جاهز في الفرع النهارده.',
  'طلبك هيبقى جاهز في الفرع بكرة إن شاء الله.',
  'طلبك جاهز في الفرع، تقدر تستلمه في أي وقت في مواعيد العمل.',
  'لسه مستنيينك تستلم طلبك من الفرع.',
  'في منتج من طلبك خلص مؤقتًا، هنكلمك نتفق على بديل.',
];

const _repairPresets = [
  'استلمنا جهازك في الفرع وبيتفحص دلوقتي.',
  'بنحدد تكلفة الإصلاح وهنبلغك بالسعر قريب.',
  'بنفحص الجهاز كويس علشان نحدد كل العيوب، وهنبلغك بالتفاصيل.',
  'لقينا عيب إضافي في الجهاز، هنكلمك نوضحلك قبل ما نكمّل.',
  'محتاجين نكلمك بخصوص جهازك، ياريت ترد على تليفوننا.',
  'قطعة الغيار اتطلبت وهتوصل خلال يوم أو اتنين.',
  'الإصلاح ماشي كويس، وهنبلغك أول ما يخلص.',
  'الجهاز تحت اختبار الجودة للتأكد إن كل حاجة شغالة.',
  'اتصلح وجاهز تستلمه من الفرع.',
  'الجهاز خارج للتوصيل وهيوصلك النهارده.',
];

Map<String, dynamic>? _openCancel(Map<String, dynamic> row) => List<Map<String, dynamic>>.from(row['cancel_requests'] as List? ?? const [])
    .where((c) => c['status'] == 'pending')
    .firstOrNull;

class _CancelBadge extends StatelessWidget {
  const _CancelBadge();
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(color: BrandColors.error.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.cancel_outlined, size: 14, color: BrandColors.error),
            const SizedBox(width: 4),
            Text(_t(context, 'العميل طالب إلغاء', 'Customer wants to cancel'),
                style: const TextStyle(color: BrandColors.error, fontSize: 12, fontWeight: FontWeight.w700)),
          ]),
        ),
      );
}

/// Open cancellation request: reason + approve / reject (staff may call the customer first).
class _CancelRequestCard extends ConsumerStatefulWidget {
  const _CancelRequestCard({required this.request, required this.onDone, this.warning});
  final Map<String, dynamic> request;
  final VoidCallback onDone;
  final String? warning;
  @override
  ConsumerState<_CancelRequestCard> createState() => _CancelRequestCardState();
}

class _CancelRequestCardState extends ConsumerState<_CancelRequestCard> {
  bool _busy = false;

  Future<void> _decide(bool approve) async {
    String? note;
    if (approve) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          title: Text(_t(context, 'توافق على الإلغاء؟', 'Approve cancellation?')),
          content: Text(widget.warning ?? _t(context, 'هيتلغي الطلب والعميل هيوصله إشعار.', 'It will be cancelled and the customer notified.')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: Text(context.tr('cancel'))),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: BrandColors.error),
              onPressed: () => Navigator.pop(d, true),
              child: Text(_t(context, 'موافق، إلغاء', 'Approve')),
            ),
          ],
        ),
      );
      if (ok != true) return;
    } else {
      note = await _askText(context, _t(context, 'سبب الرفض (هيوصل للعميل)', 'Reason for rejecting (sent to the customer)'),
          hint: _t(context, 'مثلاً: كلمناك واتفقنا نكمّل الطلب', 'e.g. we called and agreed to continue'));
      if (note == null) return;
    }
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(adminRepoProvider).decideCancel(widget.request['id'] as String, approve, note: note);
      widget.onDone();
      if (mounted) {
        Navigator.of(context).pop();
        showSnack(context, approve ? _t(context, 'اتلغى، والعميل وصله إشعار', 'Cancelled — the customer was notified')
            : _t(context, 'اترفض طلب الإلغاء، والعميل وصله الرد', 'Request rejected — the customer was notified'));
      }
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: BrandColors.error.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: BrandColors.error.withValues(alpha: 0.3)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const Icon(Icons.cancel_outlined, color: BrandColors.error),
            const SizedBox(width: 8),
            Expanded(child: Text(_t(context, 'العميل طالب إلغاء', 'Cancellation requested'), style: const TextStyle(fontWeight: FontWeight.w800, color: BrandColors.error))),
            Text(fmtDate(context, widget.request['created_at'] as String), style: const TextStyle(color: BrandColors.gray, fontSize: 12)),
          ]),
          const SizedBox(height: 8),
          Text('${_t(context, 'السبب', 'Reason')}: ${widget.request['reason']}', style: const TextStyle(fontWeight: FontWeight.w600, height: 1.5)),
          if (widget.warning != null) ...[
            const SizedBox(height: 6),
            Text(widget.warning!, style: const TextStyle(color: BrandColors.warning, fontSize: 13, fontWeight: FontWeight.w600)),
          ],
          const SizedBox(height: 4),
          Text(_t(context, 'تقدر تكلّم العميل الأول وبعدين تقرر.', 'You can call the customer first, then decide.'),
              style: const TextStyle(color: BrandColors.gray, fontSize: 12.5)),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _busy ? null : () => _decide(false),
                child: Text(_t(context, 'رفض', 'Reject')),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: BrandColors.error),
                onPressed: _busy ? null : () => _decide(true),
                child: _busy
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white))
                    : Text(_t(context, 'موافقة وإلغاء', 'Approve & cancel')),
              ),
            ),
          ]),
        ]),
      );
}

// =====================================================================================
// Search by order / repair number
// =====================================================================================
Future<void> _openSearch(BuildContext context, WidgetRef ref) async {
  final picked = await showModalBottomSheet<(String, Map<String, dynamic>)>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const _SearchSheet(),
  );
  if (picked == null || !context.mounted) return;
  if (picked.$1 == 'order') {
    await _orderSheet(context, ref, picked.$2);
  } else {
    await _repairSheet(context, ref, picked.$2);
  }
}

class _SearchSheet extends ConsumerStatefulWidget {
  const _SearchSheet();
  @override
  ConsumerState<_SearchSheet> createState() => _SearchSheetState();
}

class _SearchSheetState extends ConsumerState<_SearchSheet> {
  final _q = TextEditingController();
  Timer? _debounce;
  bool _loading = false;
  String? _error;
  ({List<Map<String, dynamic>> orders, List<Map<String, dynamic>> repairs})? _res;
  int _seq = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  void _changed(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () => _run(v));
  }

  Future<void> _run(String v) async {
    final seq = ++_seq;
    if (v.trim().length < 3) {
      setState(() {
        _res = null;
        _loading = false;
        _error = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await ref.read(adminRepoProvider).searchByReference(v);
      if (mounted && seq == _seq) setState(() => _res = r);
    } catch (e) {
      if (mounted && seq == _seq) setState(() => _error = friendlyError(context, e));
    } finally {
      if (mounted && seq == _seq) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final labels = ref.watch(repairLabelsProvider).valueOrNull;
    final r = _res;
    final empty = r != null && r.orders.isEmpty && r.repairs.isEmpty;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.8,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              controller: _q,
              autofocus: true,
              textDirection: TextDirection.ltr,
              textCapitalization: TextCapitalization.characters,
              onChanged: _changed,
              onSubmitted: _run,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search_rounded),
                hintText: _t(context, 'رقم الطلب أو الصيانة — مثلاً 1003 أو MY-HATO75', 'Order or repair number — e.g. 1003 or MY-HATO75'),
                suffixIcon: _loading
                    ? const Padding(padding: EdgeInsets.all(14), child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.2)))
                    : (_q.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close_rounded),
                            onPressed: () {
                              _q.clear();
                              _run('');
                            })),
              ),
            ),
          ),
          Expanded(
            child: _error != null
                ? Center(child: Text(_error!, style: const TextStyle(color: BrandColors.error)))
                : r == null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(_t(context, 'اكتب 3 حروف أو أرقام على الأقل من رقم الطلب', 'Type at least 3 characters of the number'),
                              textAlign: TextAlign.center, style: const TextStyle(color: BrandColors.gray)),
                        ),
                      )
                    : empty
                        ? Center(child: Text(_t(context, 'مفيش طلب بالرقم ده', 'No order or repair with this number'), style: const TextStyle(color: BrandColors.gray)))
                        : ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
                            if (r.orders.isNotEmpty) ...[
                              _header(_t(context, 'طلبات المبيعات', 'Sales orders'), Icons.receipt_long_rounded, r.orders.length),
                              for (final o in r.orders)
                                _result(
                                  title: o['reference'] as String,
                                  subtitle: '${o['customer_name']} • ${o['customer_phone']}\n${fmtDate(context, o['created_at'] as String)} • ${formatEgp((o['total_minor'] as num).toInt(), context.lang)}',
                                  chip: _orderChip(context, o),
                                  cancel: _openCancel(o) != null,
                                  onTap: () => Navigator.pop(context, ('order', o)),
                                ),
                            ],
                            if (r.repairs.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              _header(_t(context, 'طلبات الصيانة', 'Repairs'), Icons.build_rounded, r.repairs.length),
                              for (final x in r.repairs)
                                _result(
                                  title: x['reference'] as String,
                                  subtitle: '${x['device_brand']} ${x['device_model']} • ${x['contact_name']}\n${fmtDate(context, x['created_at'] as String)}',
                                  chip: _repairChip(context, labels, x),
                                  cancel: _openCancel(x) != null,
                                  onTap: () => Navigator.pop(context, ('repair', x)),
                                ),
                            ],
                          ]),
          ),
        ]),
      ),
    );
  }

  Widget _header(String text, IconData icon, int n) => Padding(
        padding: const EdgeInsets.only(bottom: 6, top: 4),
        child: Row(children: [
          Icon(icon, size: 18, color: BrandColors.navy),
          const SizedBox(width: 6),
          Text('$text ($n)', style: const TextStyle(fontWeight: FontWeight.w800)),
        ]),
      );

  Widget _result({required String title, required String subtitle, required Widget chip, required bool cancel, required VoidCallback onTap}) => Card(
        margin: const EdgeInsets.only(bottom: 8),
        child: ListTile(
          onTap: onTap,
          title: Directionality(textDirection: TextDirection.ltr, child: Text(title, textAlign: TextAlign.start, style: const TextStyle(fontWeight: FontWeight.w800))),
          subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(subtitle),
            if (cancel) const _CancelBadge(),
          ]),
          isThreeLine: true,
          trailing: chip,
        ),
      );
}

// =====================================================================================
// Close the operation (final): hidden from the customer, kept here with the reason
// =====================================================================================
const _closeReasons = {
  'order': ['cancelled_by_customer', 'purchased'],
  'repair': ['cancelled_by_customer', 'repaired', 'unrepairable'],
};

String _closeReasonLabel(BuildContext c, String? r) => switch (r) {
      'cancelled_by_customer' => _t(c, 'ملغي من العميل', 'Cancelled by customer'),
      'purchased' => _t(c, 'تم الشراء', 'Purchased'),
      'repaired' => _t(c, 'تم الإصلاح', 'Repaired'),
      'unrepairable' => _t(c, 'مش هينفع يتصلح', 'Cannot be repaired'),
      _ => _t(c, 'مغلق', 'Closed'),
    };

IconData _closeReasonIcon(String r) => switch (r) {
      'cancelled_by_customer' => Icons.cancel_rounded,
      'purchased' => Icons.shopping_bag_rounded,
      'repaired' => Icons.build_circle_rounded,
      _ => Icons.report_rounded,
    };

Color _closeReasonColor(String? r) => switch (r) {
      'purchased' || 'repaired' => BrandColors.success,
      'cancelled_by_customer' => BrandColors.error,
      'unrepairable' => BrandColors.warning,
      _ => BrandColors.gray,
    };

Widget _orderChip(BuildContext context, Map<String, dynamic> o) => o['closed_at'] != null
    ? StatusChip(label: '🔒 ${_closeReasonLabel(context, o['close_reason'] as String?)}', color: _closeReasonColor(o['close_reason'] as String?))
    : StatusChip(label: context.tr('os_${o['status']}'), color: _orderColor(o['status'] as String));

Widget _repairChip(BuildContext context, Map<String, Map<String, dynamic>>? labels, Map<String, dynamic> r) => r['closed_at'] != null
    ? StatusChip(label: '🔒 ${_closeReasonLabel(context, r['close_reason'] as String?)}', color: _closeReasonColor(r['close_reason'] as String?))
    : StatusChip(label: repairLabel(context, labels, r['status'] as String), color: repairStatusColor(r['status'] as String));

class _ClosedCard extends StatelessWidget {
  const _ClosedCard({required this.row, required this.kind});
  final Map<String, dynamic> row;
  final String kind;
  @override
  Widget build(BuildContext context) {
    final reason = row['close_reason'] as String?;
    final color = _closeReasonColor(reason);
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(children: [
        Icon(Icons.lock_rounded, color: color),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${_t(context, 'تم إغلاق العملية', 'Operation closed')} — ${_closeReasonLabel(context, reason)}',
                style: TextStyle(fontWeight: FontWeight.w800, color: color)),
            const SizedBox(height: 2),
            Text(fmtDate(context, row['closed_at'] as String), style: const TextStyle(color: BrandColors.gray, fontSize: 12)),
            const SizedBox(height: 2),
            Text(_t(context, 'مش ظاهرة للعميل في التطبيق.', 'No longer visible to the customer.'), style: const TextStyle(color: BrandColors.gray, fontSize: 12)),
          ]),
        ),
      ]),
    );
  }
}

class _CloseOperationButton extends ConsumerWidget {
  const _CloseOperationButton({required this.kind, required this.id, required this.onDone});
  final String kind;
  final String id;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context, WidgetRef ref) => OutlinedButton.icon(
        style: OutlinedButton.styleFrom(foregroundColor: BrandColors.navy, side: const BorderSide(color: BrandColors.navy)),
        icon: const Icon(Icons.lock_outline_rounded),
        label: Text(_t(context, 'إغلاق العملية', 'Close operation')),
        onPressed: () async {
          final reason = await showModalBottomSheet<String>(
            context: context,
            showDragHandle: true,
            builder: (_) => _CloseReasonSheet(kind: kind),
          );
          if (reason == null || !context.mounted) return;
          try {
            await ref.read(adminRepoProvider).closeOperation(kind, id, reason);
            onDone();
            if (context.mounted) {
              Navigator.of(context).pop();
              showSnack(context, _t(context, 'اتقفلت العملية واختفت من عند العميل', 'Closed — hidden from the customer'));
            }
          } catch (e) {
            if (context.mounted) showSnack(context, friendlyError(context, e), error: true);
          }
        },
      );
}

class _CloseReasonSheet extends StatefulWidget {
  const _CloseReasonSheet({required this.kind});
  final String kind;
  @override
  State<_CloseReasonSheet> createState() => _CloseReasonSheetState();
}

class _CloseReasonSheetState extends State<_CloseReasonSheet> {
  String? _sel;
  @override
  Widget build(BuildContext context) {
    final reasons = _closeReasons[widget.kind]!;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(_t(context, 'إغلاق العملية', 'Close operation'), style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text(
            _t(context, 'خطوة نهائية: الطلب هيختفي من عند العميل نهائيًا، ويفضل عندك هنا مقفول بالسبب.',
                'Final step: it disappears from the customer\'s app for good and stays here as closed with the reason.'),
            style: const TextStyle(color: BrandColors.gray, height: 1.5),
          ),
          const SizedBox(height: 14),
          Material(
            color: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: BrandColors.border)),
            clipBehavior: Clip.antiAlias,
            child: Column(children: [
              for (var i = 0; i < reasons.length; i++) ...[
                if (i > 0) const Divider(height: 1),
                ListTile(
                  onTap: () => setState(() => _sel = reasons[i]),
                  selected: _sel == reasons[i],
                  selectedTileColor: _closeReasonColor(reasons[i]).withValues(alpha: 0.07),
                  leading: Icon(_sel == reasons[i] ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                      color: _sel == reasons[i] ? _closeReasonColor(reasons[i]) : BrandColors.gray),
                  title: Text(_closeReasonLabel(context, reasons[i]), style: TextStyle(fontWeight: _sel == reasons[i] ? FontWeight.w800 : FontWeight.w500)),
                  trailing: Icon(_closeReasonIcon(reasons[i]), color: _closeReasonColor(reasons[i])),
                ),
              ],
            ]),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: BrandColors.navy),
            icon: const Icon(Icons.lock_rounded),
            label: Text(_t(context, 'إغلاق نهائي', 'Close for good')),
            onPressed: _sel == null ? null : () => Navigator.pop(context, _sel),
          ),
        ]),
      ),
    );
  }
}

/// Product search: type a name / SKU, or scan a barcode to find the product.
class _ProductSearchField extends StatefulWidget {
  const _ProductSearchField({required this.onSearch});
  final ValueChanged<String> onSearch;
  @override
  State<_ProductSearchField> createState() => _ProductSearchFieldState();
}

class _ProductSearchFieldState extends State<_ProductSearchField> {
  final _c = TextEditingController();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
        controller: _c,
        decoration: InputDecoration(
          hintText: _t(context, 'ابحث باسم المنتج أو الكود', 'Search name or SKU'),
          prefixIcon: const Icon(Icons.search),
          suffixIcon: IconButton(
            tooltip: _t(context, 'امسح باركود', 'Scan barcode'),
            icon: const Icon(Icons.qr_code_scanner_rounded, color: BrandColors.electric),
            onPressed: () async {
              final code = await scanBarcode(context);
              if (code == null) return;
              _c.text = code;
              widget.onSearch(code);
            },
          ),
        ),
        onSubmitted: widget.onSearch,
      );
}

// =====================================================================================
// Reviews moderation
// =====================================================================================
class _ReviewsTabIcon extends ConsumerWidget {
  const _ReviewsTabIcon();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final n = ref.watch(_pendingReviewsProvider).valueOrNull ?? 0;
    return Badge(isLabelVisible: n > 0, label: Text('$n'), child: const Icon(Icons.reviews_outlined));
  }
}

class _ReviewsTab extends ConsumerWidget {
  const _ReviewsTab();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(_reviewFilterProvider);
    final data = ref.watch(_reviewsProvider);
    Widget chip(String value, String label, IconData icon) => Padding(
          padding: const EdgeInsetsDirectional.only(end: 8),
          child: ChoiceChip(
            avatar: Icon(icon, size: 16),
            label: Text(label),
            selected: filter == value,
            onSelected: (_) => ref.read(_reviewFilterProvider.notifier).state = value,
          ),
        );
    return Column(children: [
      SizedBox(
        height: 54,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.fromLTRB(12, 10, 12, 4), children: [
          chip('pending', _t(context, 'قيد المراجعة', 'To review'), Icons.hourglass_top_rounded),
          chip('published', _t(context, 'منشورة', 'Published'), Icons.check_circle_outline),
          chip('removed', _t(context, 'محذوفة', 'Removed'), Icons.delete_outline),
        ]),
      ),
      Expanded(
        child: RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(_reviewsProvider);
            ref.invalidate(_pendingReviewsProvider);
          },
          child: data.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(_reviewsProvider)),
            data: (list) => list.isEmpty
                ? ListView(children: [
                    const SizedBox(height: 80),
                    Center(child: Text(filter == 'pending' ? _t(context, 'مفيش تقييمات محتاجة مراجعة 👌', 'Nothing to review 👌') : _t(context, 'مفيش تقييمات', 'No reviews'))),
                  ])
                : ListView.separated(
                    padding: const EdgeInsets.all(12),
                    itemCount: list.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (_, i) => _ReviewModerationCard(review: list[i]),
                  ),
          ),
        ),
      ),
    ]);
  }
}

class _ReviewModerationCard extends ConsumerStatefulWidget {
  const _ReviewModerationCard({required this.review});
  final Map<String, dynamic> review;
  @override
  ConsumerState<_ReviewModerationCard> createState() => _ReviewModerationCardState();
}

class _ReviewModerationCardState extends ConsumerState<_ReviewModerationCard> {
  bool _busy = false;

  Future<void> _act(String action) async {
    if (action == 'remove') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          title: Text(_t(context, 'مسح التقييم؟', 'Remove review?')),
          content: Text(_t(context, 'التقييم هيختفي من صفحة المنتج ومش هيتحسب في متوسط النجوم.', 'It disappears from the product page and the star average.')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: Text(context.tr('cancel'))),
            FilledButton(style: FilledButton.styleFrom(backgroundColor: BrandColors.error), onPressed: () => Navigator.pop(d, true), child: Text(_t(context, 'مسح', 'Remove'))),
          ],
        ),
      );
      if (ok != true) return;
    }
    setState(() => _busy = true);
    try {
      await ref.read(adminRepoProvider).moderateReview(widget.review['id'] as String, action);
      ref.invalidate(_reviewsProvider);
      ref.invalidate(_pendingReviewsProvider);
      if (mounted) showSnack(context, action == 'approve' ? _t(context, 'اتنشر التقييم', 'Review published') : _t(context, 'اتمسح التقييم', 'Review removed'));
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.review;
    final product = r['products'] as Map<String, dynamic>?;
    final flags = List<String>.from(r['flagged_words'] as List? ?? const []);
    final status = r['status'] as String;
    final rating = (r['rating'] as num).toInt();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
              child: Text(product == null ? '—' : (context.isAr ? product['name_ar'] : product['name_en']) as String,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800)),
            ),
            Directionality(
              textDirection: TextDirection.ltr,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                for (var i = 1; i <= 5; i++) Icon(i <= rating ? Icons.star_rounded : Icons.star_outline_rounded, size: 16, color: i <= rating ? const Color(0xFFFFB400) : BrandColors.border),
              ]),
            ),
          ]),
          const SizedBox(height: 4),
          Text('${r['author_name']} • ${fmtDate(context, (r['updated_at'] ?? r['created_at']) as String)}${r['verified_purchase'] == true ? ' • ✔ ${_t(context, 'مشتري مؤكد', 'verified buyer')}' : ''}',
              style: const TextStyle(color: BrandColors.gray, fontSize: 12)),
          if ((r['comment'] as String?)?.isNotEmpty == true) ...[
            const SizedBox(height: 8),
            Text(r['comment'] as String, style: const TextStyle(height: 1.5)),
          ],
          if (flags.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(spacing: 6, runSpacing: 6, children: [
              const Icon(Icons.flag_rounded, size: 16, color: BrandColors.error),
              for (final f in flags)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(color: BrandColors.error.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
                  child: Text(f == 'link/phone' ? _t(context, 'رابط / رقم تليفون', 'link / phone') : f,
                      style: const TextStyle(color: BrandColors.error, fontSize: 12, fontWeight: FontWeight.w700)),
                ),
            ]),
          ],
          const SizedBox(height: 10),
          Row(children: [
            if (status != 'removed')
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(foregroundColor: BrandColors.error, minimumSize: const Size.fromHeight(42)),
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: Text(_t(context, 'مسح', 'Remove')),
                  onPressed: _busy ? null : () => _act('remove'),
                ),
              ),
            if (status != 'removed' && status != 'published') const SizedBox(width: 10),
            if (status != 'published')
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: BrandColors.success, minimumSize: const Size.fromHeight(42)),
                  icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.check_rounded, size: 18),
                  label: Text(status == 'removed' ? _t(context, 'رجّعه ونشره', 'Restore') : _t(context, 'قبول ونشر', 'Approve')),
                  onPressed: _busy ? null : () => _act('approve'),
                ),
              ),
          ]),
        ]),
      ),
    );
  }
}

/// Overview tile: tap feedback (ripple + slight press-in) and a chevron so it reads as a button.
class _StatTile extends StatefulWidget {
  const _StatTile({required this.label, required this.value, required this.icon, required this.color, required this.onTap});
  final String label, value;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  @override
  State<_StatTile> createState() => _StatTileState();
}

class _StatTileState extends State<_StatTile> {
  bool _down = false;
  @override
  Widget build(BuildContext context) => AnimatedScale(
        scale: _down ? 0.96 : 1,
        duration: const Duration(milliseconds: 120),
        child: Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: widget.onTap,
            onHighlightChanged: (v) => setState(() => _down = v),
            child: Ink(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), border: Border.all(color: BrandColors.border)),
              child: Row(children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(color: widget.color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
                  child: Icon(widget.icon, color: widget.color),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: AlignmentDirectional.centerStart,
                      child: Text(widget.value, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 20)),
                    ),
                    Text(widget.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: BrandColors.gray, fontSize: 12)),
                  ]),
                ),
                const Icon(Icons.chevron_right_rounded, color: BrandColors.gray, size: 20),
              ]),
            ),
          ),
        ),
      );
}


final _seenProvider = FutureProvider.autoDispose.family<List<Map<String, dynamic>>, (String, String)>(
    (ref, k) => ref.watch(adminRepoProvider).entitySeen(k.$1, k.$2));

/// Read receipts: what the customer was told about this order/repair and whether they have opened it
/// (single grey tick = delivered to their notifications, blue double tick = they saw it, with the time).
class _SeenCard extends ConsumerWidget {
  const _SeenCard({required this.type, required this.id});
  final String type;
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(_seenProvider((type, id)));
    return data.maybeWhen(
      data: (list) {
        if (list.isEmpty) return const SizedBox.shrink();
        return Container(
          margin: const EdgeInsets.only(top: 12),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: BrandColors.electric.withValues(alpha: 0.07), borderRadius: BorderRadius.circular(14)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.visibility_outlined, size: 18, color: BrandColors.electric),
              const SizedBox(width: 6),
              Text(_t(context, 'العميل شاف الرسائل؟', 'Did the customer see the messages?'), style: const TextStyle(fontWeight: FontWeight.w800)),
              const Spacer(),
              InkWell(onTap: () => ref.invalidate(_seenProvider((type, id))), child: const Icon(Icons.refresh_rounded, size: 18, color: BrandColors.gray)),
            ]),
            const SizedBox(height: 6),
            for (final n in list)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(children: [
                  Icon(n['read_at'] != null ? Icons.done_all_rounded : Icons.done_rounded, size: 18, color: n['read_at'] != null ? const Color(0xFF1E88E5) : BrandColors.gray),
                  const SizedBox(width: 8),
                  Expanded(child: Text(context.isAr ? n['title_ar'] as String : n['title_en'] as String, maxLines: 1, overflow: TextOverflow.ellipsis)),
                  const SizedBox(width: 8),
                  Text(
                    n['read_at'] != null
                        ? _t(context, 'شافها ${fmtDate(context, n['read_at'] as String)}', 'Seen ${fmtDate(context, n['read_at'] as String)}')
                        : _t(context, 'لسه ما شافهاش', 'Not seen yet'),
                    style: TextStyle(fontSize: 12, color: n['read_at'] != null ? const Color(0xFF1E88E5) : BrandColors.gray),
                  ),
                ]),
              ),
          ]),
        );
      },
      orElse: () => const SizedBox.shrink(),
    );
  }
}
