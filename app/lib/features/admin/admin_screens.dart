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
import '../../shared/brand_logo.dart';
import '../../shared/product_card.dart';
import '../../shared/states.dart';
import '../auth/auth_repository.dart';
import '../orders/orders_screens.dart' show fmtDate;
import '../repairs/repairs_repository.dart';
import '../repairs/repairs_screens.dart' show repairLabel, repairStatusColor;
import 'admin_repository.dart';

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
      ref.invalidate(isStaffProvider);
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

class AdminHomeScreen extends ConsumerWidget {
  const AdminHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => DefaultTabController(
        length: 4,
        child: Scaffold(
          appBar: AppBar(
            leading: IconButton(icon: const Icon(Icons.home_rounded), onPressed: () => context.go('/')),
            title: Text(_t(context, 'لوحة المسؤول', 'Admin console')),
            actions: [
              IconButton(
                tooltip: _t(context, 'خروج', 'Sign out'),
                icon: const Icon(Icons.logout_rounded),
                onPressed: () async {
                  await ref.read(authRepoProvider).signOut();
                  ref.invalidate(isStaffProvider);
                  if (context.mounted) context.go('/');
                },
              ),
            ],
            bottom: TabBar(isScrollable: true, tabAlignment: TabAlignment.start, tabs: [
              Tab(icon: const Icon(Icons.dashboard_outlined), text: _t(context, 'نظرة عامة', 'Overview')),
              Tab(icon: const Icon(Icons.receipt_long_outlined), text: _t(context, 'الطلبات', 'Orders')),
              Tab(icon: const Icon(Icons.build_outlined), text: _t(context, 'الصيانة', 'Repairs')),
              Tab(icon: const Icon(Icons.inventory_2_outlined), text: _t(context, 'المنتجات', 'Products')),
            ]),
          ),
          body: const TabBarView(children: [_Overview(), _OrdersTab(), _RepairsTab(), _ProductsTab()]),
        ),
      );
}

class _Overview extends ConsumerWidget {
  const _Overview();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(_statsProvider);
    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(_statsProvider),
      child: stats.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(_statsProvider)),
        data: (s) {
          Widget tile(String label, String value, IconData icon, Color color, VoidCallback onTap) => _StatTile(
                label: label, value: value, icon: icon, color: color, onTap: onTap);
          void go(int tab, void Function() setFilter) {
            setFilter();
            DefaultTabController.of(context).animateTo(tab);
          }

          final n = (String k) => '${s[k] ?? 0}';
          return GridView.count(
            padding: const EdgeInsets.all(16),
            crossAxisCount: 2,
            childAspectRatio: 2.1,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            children: [
              tile(_t(context, 'طلبات جديدة', 'New orders'), n('pending_orders'), Icons.fiber_new_rounded, BrandColors.warning,
                  () => go(1, () => ref.read(_orderFilterProvider.notifier).state = 'pending_confirmation')),
              tile(_t(context, 'طلبات النهارده', 'Orders today'), n('new_orders_today'), Icons.today_rounded, BrandColors.electric,
                  () => go(1, () => ref.read(_orderFilterProvider.notifier).state = null)),
              tile(_t(context, 'صيانة شغالة', 'Active repairs'), n('active_repairs'), Icons.build_rounded, BrandColors.navy,
                  () => go(2, () => ref.read(_repairFilterProvider.notifier).state = null)),
              tile(_t(context, 'مستني موافقة', 'Awaiting approval'), n('repairs_awaiting_approval'), Icons.hourglass_top_rounded, BrandColors.warning,
                  () => go(2, () => ref.read(_repairFilterProvider.notifier).state = 'awaiting_approval')),
              tile(_t(context, 'جاهز للتسليم', 'Ready'), n('repairs_ready'), Icons.check_circle_rounded, BrandColors.success,
                  () => go(2, () => ref.read(_repairFilterProvider.notifier).state = 'ready_for_pickup')),
              tile(_t(context, 'مخزون قليل', 'Low stock'), n('low_stock'), Icons.inventory_rounded, BrandColors.error,
                  () => go(3, () => ref.read(_lowStockOnlyProvider.notifier).state = true)),
              tile(_t(context, 'طلبات اتسلّمت', 'Delivered'), n('completed_orders'), Icons.local_shipping_rounded, BrandColors.success,
                  () => go(1, () => ref.read(_orderFilterProvider.notifier).state = 'delivered')),
              tile(_t(context, 'المبيعات', 'Sales'), formatEgp((s['total_sales_minor'] as num?)?.toInt() ?? 0, context.lang), Icons.payments_rounded, BrandColors.navy,
                  () => go(1, () => ref.read(_orderFilterProvider.notifier).state = 'delivered')),
            ],
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
  static const statuses = ['pending_confirmation', 'confirmed', 'preparing', 'ready_for_pickup', 'out_for_delivery', 'delivered', 'cancelled'];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(_orderFilterProvider);
    final orders = ref.watch(_ordersProvider);
    return Column(children: [
      SizedBox(
        height: 54,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.fromLTRB(12, 10, 12, 4), children: [
          ChoiceChip(label: Text(_t(context, 'الكل', 'All')), selected: filter == null, onSelected: (_) => ref.read(_orderFilterProvider.notifier).state = null),
          for (final s in statuses)
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 8),
              child: ChoiceChip(label: Text(context.tr('os_$s')), selected: filter == s, onSelected: (_) => ref.read(_orderFilterProvider.notifier).state = s),
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
                          subtitle: Text('${o['customer_name']} • ${fmtDate(context, o['created_at'] as String)}'),
                          trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                            Text(formatEgp((o['total_minor'] as num).toInt(), context.lang), style: const TextStyle(fontWeight: FontWeight.w800)),
                            const SizedBox(height: 4),
                            StatusChip(label: context.tr('os_${o['status']}'), color: _orderColor(o['status'] as String)),
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
          StatusChip(label: context.tr('os_${o['status']}'), color: _orderColor(o['status'] as String)),
        ]),
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
        const SizedBox(height: 16),
        _StatusPicker(
          current: o['status'] as String,
          options: next,
          label: (s) => context.tr('os_$s'),
          color: _orderColor,
          isNegative: (s) => s == 'cancelled',
          onConfirm: (s) => _changeOrder(ctx, ref, o['id'] as String, s, askNote: s == 'cancelled'),
        ),
      ]),
    ),
  );
}

Future<void> _changeOrder(BuildContext ctx, WidgetRef ref, String id, String to, {bool askNote = false}) async {
  String? note;
  if (askNote) {
    note = await _askText(ctx, _t(ctx, 'سبب الإلغاء', 'Cancellation reason'));
    if (note == null) return;
  }
  try {
    await ref.read(adminRepoProvider).setOrderStatus(id, to, note: note);
    ref.invalidate(_ordersProvider);
    ref.invalidate(_statsProvider);
    if (ctx.mounted) {
      Navigator.of(ctx).pop();
      showSnack(ctx, _t(ctx, 'اتحدّثت الحالة والعميل وصله إشعار', 'Status updated — the customer was notified'));
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
          chip('awaiting_approval', repairLabel(context, labels, 'awaiting_approval')),
          chip('waiting_for_parts', repairLabel(context, labels, 'waiting_for_parts')),
          chip('ready_for_pickup', repairLabel(context, labels, 'ready_for_pickup')),
          chip('all', _t(context, 'الكل', 'All')),
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
                      subtitle: Text('${r['contact_name']} • ${r['contact_phone']}\n${r['problem_description']}', maxLines: 3, overflow: TextOverflow.ellipsis),
                      isThreeLine: true,
                      trailing: StatusChip(label: repairLabel(context, labels, st), color: repairStatusColor(st)),
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
  final canQuote = ['initial_inspection', 'diagnosis_completed', 'received_at_branch', 'device_collected'].contains(r['status']);
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
        const Divider(height: 28),
        if (canQuote)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: OutlinedButton.icon(
              icon: const Icon(Icons.request_quote_outlined),
              label: Text(_t(context, 'ابعت عرض سعر للعميل', 'Send a quote to the customer')),
              onPressed: () async {
                final amount = await _askText(ctx, _t(ctx, 'التكلفة (ج.م)', 'Cost (EGP)'), keyboard: TextInputType.number);
                final egp = int.tryParse((amount ?? '').replaceAll(RegExp(r'[^0-9]'), ''));
                if (egp == null || egp <= 0 || !ctx.mounted) return;
                final desc = await _askText(ctx, _t(ctx, 'المطلوب إصلاحه', 'Work needed'));
                if (desc == null) return;
                try {
                  await repo.sendQuote(r['id'] as String, egp * 100, desc, desc);
                  ref.invalidate(_repairsProvider);
                  if (ctx.mounted) {
                    Navigator.of(ctx).pop();
                    showSnack(ctx, _t(ctx, 'اتبعت عرض السعر للعميل', 'Quote sent to the customer'));
                  }
                } catch (e) {
                  if (ctx.mounted) showSnack(ctx, friendlyError(ctx, e), error: true);
                }
              },
            ),
          ),
        _StatusPicker(
          current: r['status'] as String,
          options: next,
          label: (s) => repairLabel(context, labels, s),
          color: repairStatusColor,
          isNegative: (s) => s == 'cancelled' || s == 'unrepairable',
          message: (s) => labels?[s] == null ? null : (context.isAr ? labels![s]!['message_ar'] : labels![s]!['message_en']) as String?,
          onConfirm: (s) => _changeRepair(ctx, ref, r['id'] as String, s, askNote: s == 'cancelled' || s == 'unrepairable'),
        ),
        const Divider(height: 32),
        _QuickUpdates(repairId: r['id'] as String),
      ]),
    ),
  );
}

Future<void> _changeRepair(BuildContext ctx, WidgetRef ref, String id, String to, {bool askNote = false}) async {
  String? note;
  if (askNote) {
    note = await _askText(ctx, _t(ctx, 'السبب (هيوصل للعميل)', 'Reason (sent to the customer)'));
    if (note == null) return;
  }
  try {
    await ref.read(adminRepoProvider).setRepairStatus(id, to, note: note);
    ref.invalidate(_repairsProvider);
    ref.invalidate(_statsProvider);
    if (ctx.mounted) {
      Navigator.of(ctx).pop();
      showSnack(ctx, _t(ctx, 'اتحدّثت الحالة والعميل وصله إشعار', 'Status updated — the customer was notified'));
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
          child: TextField(
            decoration: InputDecoration(hintText: _t(context, 'ابحث باسم المنتج أو الكود', 'Search name or SKU'), prefixIcon: const Icon(Icons.search)),
            onSubmitted: (v) => ref.read(_productSearchProvider.notifier).state = v,
          ),
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
  const _ProductEditor({this.product});
  final Map<String, dynamic>? product;
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
  late String? _categoryId = p?['category_id'] as String?;
  late bool _published = (p?['status'] ?? 'published') == 'published';
  late bool _featured = p?['is_featured'] == true;
  Uint8List? _image;
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [_nameAr, _nameEn, _price, _compare, _stock, _desc]) {
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
        );
      } else {
        await repo.updateProduct(p!['id'] as String, {
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
            DropdownButtonFormField<String>(
              value: cats.any((c) => c['id'] == _categoryId) ? _categoryId : null,
              isExpanded: true,
              decoration: InputDecoration(labelText: _t(context, 'القسم', 'Category')),
              items: [for (final c in cats) DropdownMenuItem(value: c['id'] as String, child: Text(context.isAr ? c['name_ar'] as String : c['name_en'] as String))],
              onChanged: (v) => setState(() => _categoryId = v),
              validator: (v) => v == null ? context.tr('required') : null,
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

/// Status change as a choice list: the current status on top, the allowed next statuses as
/// radio options, and one confirm button.
class _StatusPicker extends StatefulWidget {
  const _StatusPicker({
    required this.current,
    required this.options,
    required this.label,
    required this.color,
    required this.isNegative,
    required this.onConfirm,
    this.message,
  });
  final String? Function(String)? message;
  final String current;
  final List<String> options;
  final String Function(String) label;
  final Color Function(String) color;
  final bool Function(String) isNegative;
  final Future<void> Function(String) onConfirm;

  @override
  State<_StatusPicker> createState() => _StatusPickerState();
}

class _StatusPickerState extends State<_StatusPicker> {
  String? _selected;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    if (widget.options.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(_t(context, 'الحالة دي نهائية — مفيش خطوات بعدها.', 'This is a final status — no further steps.'),
            style: const TextStyle(color: BrandColors.gray)),
      );
    }
    final ordered = [...widget.options.where((s) => !widget.isNegative(s)), ...widget.options.where(widget.isNegative)];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(_t(context, 'اختار الحالة الجديدة', 'Choose the new status'), style: const TextStyle(fontWeight: FontWeight.w800)),
      const SizedBox(height: 8),
      Container(
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: BrandColors.border)),
        clipBehavior: Clip.antiAlias,
        child: Column(children: [
          ListTile(
            dense: true,
            enabled: false,
            leading: Icon(Icons.radio_button_checked, color: widget.color(widget.current).withValues(alpha: 0.5)),
            title: Text(widget.label(widget.current)),
            trailing: Text(_t(context, 'الحالية', 'Current'), style: const TextStyle(color: BrandColors.gray, fontSize: 12)),
          ),
          for (final s in ordered) ...[
            const Divider(height: 1),
            ListTile(
              onTap: _busy ? null : () => setState(() => _selected = s),
              leading: AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                child: Icon(
                  _selected == s ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                  key: ValueKey(_selected == s),
                  color: _selected == s ? (widget.isNegative(s) ? BrandColors.error : BrandColors.electric) : BrandColors.gray,
                ),
              ),
              title: Text(
                widget.label(s),
                style: TextStyle(
                  fontWeight: _selected == s ? FontWeight.w800 : FontWeight.w500,
                  color: widget.isNegative(s) ? BrandColors.error : null,
                ),
              ),
              subtitle: widget.message?.call(s) == null ? null : Text('💬 ${widget.message!(s)}', style: const TextStyle(fontSize: 12)),
              selected: _selected == s,
              selectedTileColor: (widget.isNegative(s) ? BrandColors.error : BrandColors.electric).withValues(alpha: 0.06),
            ),
          ],
        ]),
      ),
      const SizedBox(height: 14),
      FilledButton.icon(
        style: _selected != null && widget.isNegative(_selected!) ? FilledButton.styleFrom(backgroundColor: BrandColors.error) : null,
        icon: _busy
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white))
            : const Icon(Icons.check_rounded),
        label: Text(_t(context, 'تأكيد التغيير', 'Confirm change')),
        onPressed: (_selected == null || _busy)
            ? null
            : () async {
                setState(() => _busy = true);
                await widget.onConfirm(_selected!);
                if (mounted) setState(() => _busy = false);
              },
      ),
    ]);
  }
}

/// Send the customer an update without changing the status: ready-made messages or a custom one.
class _QuickUpdates extends ConsumerStatefulWidget {
  const _QuickUpdates({required this.repairId});
  final String repairId;
  @override
  ConsumerState<_QuickUpdates> createState() => _QuickUpdatesState();
}

class _QuickUpdatesState extends ConsumerState<_QuickUpdates> {
  static const presets = [
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
  String? _selected;
  final _custom = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final msg = _custom.text.trim().isNotEmpty ? _custom.text.trim() : _selected;
    if (msg == null) return;
    setState(() => _busy = true);
    try {
      await ref.read(adminRepoProvider).postRepairUpdate(widget.repairId, msg);
      if (mounted) {
        Navigator.of(context).pop();
        showSnack(context, _t(context, 'الرسالة وصلت للعميل', 'Update sent to the customer'));
      }
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(_t(context, 'ابعت تحديث للعميل (من غير ما تغيّر الحالة)', 'Send the customer an update (status unchanged)'),
            style: const TextStyle(fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final m in presets)
            ChoiceChip(
              label: Text(m, style: const TextStyle(fontSize: 12.5)),
              selected: _selected == m,
              onSelected: (v) => setState(() {
                _selected = v ? m : null;
                if (v) _custom.clear();
              }),
            ),
        ]),
        const SizedBox(height: 10),
        TextField(
          controller: _custom,
          maxLines: 2,
          maxLength: 500,
          onChanged: (_) => setState(() => _selected = null),
          decoration: InputDecoration(hintText: _t(context, 'أو اكتب رسالة من عندك…', 'Or write your own message…'), counterText: ''),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.2)) : const Icon(Icons.send_rounded),
          label: Text(_t(context, 'ابعت التحديث', 'Send update')),
          onPressed: (_busy || (_selected == null && _custom.text.trim().isEmpty)) ? null : _send,
        ),
      ]);
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
