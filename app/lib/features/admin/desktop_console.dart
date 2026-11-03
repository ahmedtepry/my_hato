import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../../core/appearance.dart';
import '../../core/l10n.dart';
import '../../core/money.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../shared/states.dart';
import '../../shared/avatars.dart';
import '../auth/auth_repository.dart';
import '../profile/profile_repository.dart';
import 'admin_repository.dart';
import 'pos_repository.dart';
import 'team.dart' show roleOf;

String _t(BuildContext c, String ar, String en) => c.isAr ? ar : en;

/// Screens at least this wide get the desktop layout: a navy sidebar on the right (left in English) and a dashboard home.
const desktopBreakpoint = 900.0;
bool isDesktopWidth(BuildContext c) => MediaQuery.sizeOf(c).width >= desktopBreakpoint;

// ============================================================================================ sidebar
class DesktopNavItem {
  const DesktopNavItem({required this.keyName, required this.icon, required this.label, this.badge = 0, this.group = ''});
  final String keyName, label, group;
  final IconData icon;
  final int badge;
}

class DesktopSidebar extends ConsumerWidget {
  const DesktopSidebar({super.key, required this.items, required this.selected, required this.onSelect, required this.onSearch, required this.onSignOut});
  final List<DesktopNavItem> items;
  final String? selected;
  final void Function(String key) onSelect;
  final VoidCallback onSearch;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ctx = ref.watch(staffContextProvider).valueOrNull;
    final role = roleOf(_primaryRole(ctx?.roles ?? const <String>{}));
    final name = _displayName(ref.watch(currentUserProvider));
    final brand = AppName.en.trim();
    final sp = brand.indexOf(' ');
    final first = sp > 0 ? brand.substring(0, sp) : brand;
    final rest = sp > 0 ? brand.substring(sp + 1) : '';
    return Container(
      width: 236,
      color: BrandColors.navyDeep,
      child: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 26, 22, 14),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(text: first, style: const TextStyle(color: Colors.white)),
                  if (rest.isNotEmpty) TextSpan(text: ' $rest', style: const TextStyle(color: BrandColors.electric)),
                ]),
                style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900),
              ),
            ),
          ),
          Container(
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Colors.white.withValues(alpha: 0.12)))),
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(children: [
              Tooltip(
                message: _t(context, 'غيّر الأفاتار', 'Change avatar'),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () async {
                    final cur = ref.read(profileProvider).valueOrNull?['avatar_id'] as String?;
                    final id = await showAvatarPicker(context, current: cur);
                    if (id == null) return;
                    try {
                      await ref.read(profileRepoProvider).update(avatarId: id);
                      ref.invalidate(profileProvider);
                    } catch (_) {}
                  },
                  child: Builder(builder: (_) {
                    final av = ref.watch(profileProvider).valueOrNull?['avatar_id'] as String?;
                    return isAvatarId(av)
                        ? HatoAvatar(key: ValueKey(av), id: av!, size: 40, animate: false)
                        : CircleAvatar(
                            radius: 20,
                            backgroundColor: BrandColors.electric,
                            child: Text(name.isEmpty ? '؟' : String.fromCharCode(name.runes.first).toUpperCase(), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
                          );
                  }),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14)),
                  Text(role.label(context), style: const TextStyle(color: Colors.white54, fontSize: 12)),
                ]),
              ),
              IconButton(
                tooltip: _t(context, 'خروج', 'Sign out'),
                icon: const Icon(Icons.logout_rounded, color: Colors.white70, size: 20),
                onPressed: onSignOut,
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: onSearch,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.07), borderRadius: BorderRadius.circular(12)),
                child: Row(children: [
                  const Icon(Icons.search_rounded, size: 18, color: Colors.white60),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_t(context, 'بحث', 'Search'), style: const TextStyle(color: Colors.white60, fontSize: 13))),
                  Text('Ctrl K', style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 11)),
                ]),
              ),
            ),
          ),
          Expanded(
            child: ListView(padding: const EdgeInsets.fromLTRB(12, 4, 12, 12), children: [
              for (var i = 0; i < items.length; i++) ...[
                if (items[i].group.isNotEmpty && (i == 0 || items[i - 1].group != items[i].group))
                  Padding(
                    padding: EdgeInsets.fromLTRB(8, i == 0 ? 2 : 14, 8, 6),
                    child: Text(items[i].group, style: TextStyle(color: Colors.white.withValues(alpha: 0.42), fontSize: 11.5, fontWeight: FontWeight.w800, letterSpacing: 0.4)),
                  ),
                _NavTile(item: items[i], selected: items[i].keyName == selected, onTap: () => onSelect(items[i].keyName)),
              ],
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Top bar of the Windows console: Home, then one menu per group (sales, money, team, customers, system) listing its sections.
class DesktopTopBar extends ConsumerWidget {
  const DesktopTopBar({super.key, required this.items, required this.selected, required this.onSelect, required this.onSearch, required this.onSignOut});
  final List<DesktopNavItem> items;
  final String? selected;
  final void Function(String key) onSelect;
  final VoidCallback onSearch;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ctx = ref.watch(staffContextProvider).valueOrNull;
    final role = roleOf(_primaryRole(ctx?.roles ?? const <String>{}));
    final name = _displayName(ref.watch(currentUserProvider));
    final groups = <String, List<DesktopNavItem>>{};
    for (final it in items) {
      groups.putIfAbsent(it.group, () => []).add(it);
    }
    Widget groupButton(String g, List<DesktopNavItem> list) {
      final on = list.any((e) => e.keyName == selected);
      final badge = list.fold<int>(0, (a, e) => a + e.badge);
      final single = g.isEmpty || list.length == 1;
      final label = single ? list.first.label : g;
      final chip = Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(color: on ? BrandColors.electric : Colors.transparent, borderRadius: BorderRadius.circular(10)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(label, style: TextStyle(color: on ? Colors.white : Colors.white70, fontWeight: on ? FontWeight.w800 : FontWeight.w600, fontSize: 14.5)),
          if (!single) Icon(Icons.expand_more_rounded, size: 18, color: on ? Colors.white : Colors.white54),
          if (badge > 0) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(color: const Color(0xFFF04466), borderRadius: BorderRadius.circular(9)),
              child: Text('$badge', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800)),
            ),
          ],
        ]),
      );
      if (single) return InkWell(borderRadius: BorderRadius.circular(10), onTap: () => onSelect(list.first.keyName), child: chip);
      return PopupMenuButton<String>(
        tooltip: '',
        position: PopupMenuPosition.under,
        onSelected: onSelect,
        itemBuilder: (_) => [
          for (final e in list)
            PopupMenuItem<String>(
              value: e.keyName,
              child: Row(children: [
                Icon(e.icon, size: 20, color: e.keyName == selected ? BrandColors.electric : BrandColors.gray),
                const SizedBox(width: 10),
                Expanded(child: Text(e.label, style: TextStyle(fontWeight: e.keyName == selected ? FontWeight.w800 : FontWeight.w500))),
                if (e.badge > 0) Text('${e.badge}', style: const TextStyle(color: Color(0xFFF04466), fontWeight: FontWeight.w800)),
              ]),
            ),
        ],
        child: chip,
      );
    }

    return Container(
      height: 64,
      color: BrandColors.navyDeep,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(children: [
        Directionality(
          textDirection: TextDirection.ltr,
          child: Text.rich(
            TextSpan(children: [
              const TextSpan(text: 'My ', style: TextStyle(color: Colors.white)),
              TextSpan(text: 'Hatō', style: TextStyle(color: BrandColors.electric)),
            ]),
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
          ),
        ),
        const SizedBox(width: 22),
        for (final e in groups.entries) ...[groupButton(e.key, e.value), const SizedBox(width: 4)],
        const Spacer(),
        InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onSearch,
          child: Container(
            width: 260,
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(10)),
            child: Row(children: [
              const Icon(Icons.search_rounded, size: 18, color: Colors.white60),
              const SizedBox(width: 8),
              Expanded(child: Text(_t(context, 'بحث', 'Search'), style: const TextStyle(color: Colors.white60, fontSize: 13))),
              Text('Ctrl K', style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 11)),
            ]),
          ),
        ),
        const SizedBox(width: 14),
        Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(name.isEmpty ? role.label(context) : name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13.5)),
          if (name.isNotEmpty) Text(role.label(context), style: const TextStyle(color: Colors.white54, fontSize: 11.5)),
        ]),
        IconButton(tooltip: _t(context, 'خروج', 'Sign out'), icon: const Icon(Icons.logout_rounded, color: Colors.white70, size: 20), onPressed: onSignOut),
      ]),
    );
  }
}

class _NavTile extends StatelessWidget {
  const _NavTile({required this.item, required this.selected, required this.onTap});
  final DesktopNavItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            hoverColor: Colors.white.withValues(alpha: 0.06),
            onTap: onTap,
            child: Ink(
              height: 46,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                gradient: selected ? LinearGradient(colors: [BrandColors.electric, BrandColors.electric.withValues(alpha: 0.78)]) : null,
              ),
              child: Row(children: [
                Icon(item.icon, size: 21, color: selected ? Colors.white : Colors.white70),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(item.label, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: selected ? Colors.white : Colors.white70, fontWeight: selected ? FontWeight.w800 : FontWeight.w500, fontSize: 14.5)),
                ),
                if (item.badge > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(color: const Color(0xFFF04466), borderRadius: BorderRadius.circular(10)),
                    child: Text('${item.badge}', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800)),
                  ),
              ]),
            ),
          ),
        ),
      );
}

class DesktopStatusBar extends StatelessWidget {
  const DesktopStatusBar({super.key, required this.shortcuts});
  final String shortcuts;
  @override
  Widget build(BuildContext context) => Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: BrandColors.border))),
        child: Row(children: [
          const Icon(Icons.circle, size: 9, color: BrandColors.success),
          const SizedBox(width: 6),
          Text(_t(context, 'متصل', 'Connected'), style: const TextStyle(fontSize: 12, color: BrandColors.gray)),
          const Spacer(),
          Text(shortcuts, style: const TextStyle(fontSize: 12, color: BrandColors.gray)),
        ]),
      );
}

String _primaryRole(Set<String> roles) {
  for (final r in const ['owner', 'manager', 'accountant', 'cashier', 'sales', 'technician', 'support']) {
    if (roles.contains(r)) return r;
  }
  return 'sales';
}

String _displayName(dynamic user) {
  try {
    final meta = user?.userMetadata as Map?;
    final n = '${meta?['full_name'] ?? ''}'.trim();
    if (n.isNotEmpty) return n;
    final e = '${user?.email ?? ''}';
    if (e.isNotEmpty && !e.endsWith('@team.myhato.app')) return e.split('@').first;
  } catch (_) {}
  return '';
}

// ============================================================================================ dashboard home
final _dStatsProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) => ref.watch(adminRepoProvider).stats());

final _dTodayProvider = FutureProvider.autoDispose<({int orders, int pos})>((ref) async {
  final perms = ref.watch(staffContextProvider).valueOrNull?.permissions ?? const <String>{};
  var o = 0, p = 0;
  if (perms.contains('sales.view')) {
    try {
      o = ((await ref.watch(adminRepoProvider).salesReport('day'))['total_minor'] as num).toInt();
    } catch (_) {}
  }
  if (perms.contains('sales.view') || perms.contains('shifts.review')) {
    try {
      final now = DateTime.now();
      for (final b in await ref.watch(posRepoProvider).branchReportSince(DateTime(now.year, now.month, now.day))) {
        p += (b['net_minor'] as num).toInt();
      }
    } catch (_) {}
  }
  return (orders: o, pos: p);
});

final _dWeekProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final r = await ref.watch(adminRepoProvider).salesReport('week');
  return [for (final e in (r['series'] as List? ?? const [])) Map<String, dynamic>.from(e as Map)];
});

final _dOrdersProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async => (await ref.watch(adminRepoProvider).orders()).take(6).toList());

void refreshDesktopHome(WidgetRef ref) {
  ref.invalidate(_dStatsProvider);
  ref.invalidate(_dTodayProvider);
  ref.invalidate(_dWeekProvider);
  ref.invalidate(_dOrdersProvider);
}

/// One thing that needs the member's attention right now (shown in the "needs action" strip of the home page).
class DesktopAttention {
  const DesktopAttention(this.tab, this.label, this.count, this.color, this.bg);
  final String tab, label;
  final int count;
  final Color color, bg;
}

class DesktopHome extends ConsumerWidget {
  const DesktopHome({super.key, required this.onOpen, required this.onSearch, required this.available, required this.pendingAccounts, this.attention = const []});
  final List<DesktopAttention> attention;
  final void Function(String key) onOpen;
  final VoidCallback onSearch;
  final List<String> available;
  final int pendingAccounts;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final perms = ref.watch(staffContextProvider).valueOrNull?.permissions ?? const <String>{};
    final name = _displayName(ref.watch(currentUserProvider));
    final stats = ref.watch(_dStatsProvider).valueOrNull ?? const <String, dynamic>{};
    final today = ref.watch(_dTodayProvider).valueOrNull;
    final hour = DateTime.now().hour;
    final hello = hour < 12 ? _t(context, 'صباح الخير', 'Good morning') : _t(context, 'مساء الخير', 'Good evening');
    String n(String k) => '${stats[k] ?? 0}';

    final cards = <Widget>[
      if (perms.contains('sales.view') || perms.contains('shifts.review'))
        _Kpi(
          label: _t(context, 'مبيعات اليوم', 'Sales today'),
          value: today == null ? '…' : formatEgp(today.orders + today.pos, context.lang),
          sub: today == null || today.pos == 0 ? null : '${_t(context, 'منها كاشير', 'POS')} ${formatEgp(today.pos, context.lang)}',
          subColor: BrandColors.success,
          onTap: () => onOpen(available.contains('sales') ? 'sales' : 'books'),
        ),
      if (perms.contains('orders.view'))
        _Kpi(
          label: _t(context, 'طلبات جديدة', 'New orders'),
          value: n('new_orders_today'),
          sub: '${n('pending_orders')} ${_t(context, 'محتاجة تأكيد', 'need confirming')}',
          subColor: BrandColors.warning,
          onTap: () => onOpen('orders'),
        ),
      if (perms.contains('support.manage'))
        _Kpi(
          label: _t(context, 'حسابات للتوثيق', 'Accounts to verify'),
          value: '$pendingAccounts',
          sub: pendingAccounts > 0 ? _t(context, 'مستنية مراجعة', 'waiting for review') : null,
          subColor: BrandColors.electric,
          onTap: () => onOpen('accounts'),
        ),
      if (perms.contains('repairs.view'))
        _Kpi(
          label: _t(context, 'صيانة قيد التنفيذ', 'Repairs in progress'),
          value: n('active_repairs'),
          sub: '${n('repairs_awaiting_approval')} ${_t(context, 'مستنية موافقة', 'awaiting approval')}',
          subColor: BrandColors.warning,
          onTap: () => onOpen('repairs'),
        ),
    ];

    final showChart = perms.contains('sales.view');
    final showOrders = perms.contains('orders.view');

    return RefreshIndicator(
      onRefresh: () async => refreshDesktopHome(ref),
      child: ListView(padding: const EdgeInsets.fromLTRB(28, 22, 28, 28), children: [
        Row(children: [
          Text('$hello${name.isEmpty ? '' : _t(context, ' يا $name', ', $name')} 👋', style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: BrandColors.navy)),
          const SizedBox(width: 20),
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: onSearch,
              child: Container(
                height: 44,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: BrandColors.border)),
                child: Row(children: [
                  Expanded(child: Text(_t(context, 'ابحث برقم الطلب أو الصيانة…', 'Search by order or repair number…'), style: const TextStyle(color: BrandColors.gray, fontSize: 13.5))),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(color: const Color(0xFFF2F4F7), borderRadius: BorderRadius.circular(6)),
                    child: const Text('Ctrl K', style: TextStyle(fontSize: 11, color: BrandColors.gray)),
                  ),
                ]),
              ),
            ),
          ),
          if (available.contains('pos')) ...[
            const SizedBox(width: 14),
            FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 44), padding: const EdgeInsets.symmetric(horizontal: 20)),
              icon: const Icon(Icons.add_rounded),
              label: Text(_t(context, 'بيع جديد', 'New sale')),
              onPressed: () => onOpen('pos'),
            ),
          ],
        ]),
        const SizedBox(height: 22),
        if (attention.isNotEmpty) ...[
          Container(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), border: Border.all(color: BrandColors.border)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_t(context, 'محتاج تصرف دلوقتي', 'Needs action now'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: BrandColors.navy)),
              const SizedBox(height: 12),
              Row(children: [
                for (var i = 0; i < attention.length; i++) ...[
                  if (i > 0) const SizedBox(width: 12),
                  Expanded(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () => onOpen(attention[i].tab),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                        decoration: BoxDecoration(color: attention[i].bg, borderRadius: BorderRadius.circular(14)),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('${attention[i].count}', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: attention[i].color)),
                          Text(attention[i].label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: attention[i].color)),
                        ]),
                      ),
                    ),
                  ),
                ],
              ]),
            ]),
          ),
          const SizedBox(height: 16),
        ],
        if (cards.isNotEmpty)
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (var i = 0; i < cards.length; i++) ...[if (i > 0) const SizedBox(width: 16), Expanded(child: cards[i])],
          ]),
        const SizedBox(height: 20),
        if (showChart || showOrders)
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (showChart) Expanded(flex: 2, child: const _WeekChart()),
            if (showChart && showOrders) const SizedBox(width: 16),
            if (showOrders) Expanded(flex: 3, child: _LatestOrders(onOpen: () => onOpen('orders'))),
          ]),
      ]),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.title, required this.child, this.minHeight = 340});
  final String title;
  final Widget child;
  final double minHeight;
  @override
  Widget build(BuildContext context) => Container(
        constraints: BoxConstraints(minHeight: minHeight),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), border: Border.all(color: BrandColors.border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: BrandColors.navy)),
          const SizedBox(height: 14),
          child,
        ]),
      );
}

class _Kpi extends StatelessWidget {
  const _Kpi({required this.label, required this.value, this.sub, this.subColor, required this.onTap});
  final String label, value;
  final String? sub;
  final Color? subColor;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Container(
          height: 128,
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), border: Border.all(color: BrandColors.border)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(label, style: const TextStyle(color: BrandColors.gray, fontSize: 13.5)),
            FittedBox(fit: BoxFit.scaleDown, alignment: AlignmentDirectional.centerStart, child: Text(value, style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w900, color: BrandColors.navy))),
            Text(sub ?? ' ', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: subColor ?? BrandColors.gray, fontWeight: FontWeight.w600)),
          ]),
        ),
      );
}

class _WeekChart extends ConsumerWidget {
  const _WeekChart();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final week = ref.watch(_dWeekProvider);
    return _Panel(
      title: _t(context, 'مبيعات آخر ٧ أيام', 'Sales, last 7 days'),
      child: week.when(
        loading: () => const SizedBox(height: 240, child: Center(child: CircularProgressIndicator())),
        error: (_, __) => SizedBox(height: 240, child: Center(child: Text(_t(context, 'مقدرتش أحمّل المبيعات', 'Could not load sales'), style: const TextStyle(color: BrandColors.gray)))),
        data: (rows) {
          if (rows.isEmpty) return SizedBox(height: 240, child: Center(child: Text(_t(context, 'مفيش مبيعات لسه', 'No sales yet'), style: const TextStyle(color: BrandColors.gray))));
          final maxV = rows.fold<int>(1, (m, r) => (r['total_minor'] as num).toInt() > m ? (r['total_minor'] as num).toInt() : m);
          return SizedBox(
            height: 250,
            child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              for (final r in rows)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                    child: Tooltip(
                      message: formatEgp((r['total_minor'] as num).toInt(), context.lang),
                      child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                        Flexible(
                          child: FractionallySizedBox(
                            heightFactor: ((r['total_minor'] as num).toInt() / maxV).clamp(0.02, 1.0),
                            alignment: Alignment.bottomCenter,
                            child: Container(
                              decoration: BoxDecoration(
                                borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
                                gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [BrandColors.electric, BrandColors.electric.withValues(alpha: 0.7)]),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(_dayLabel(context, '${r['label']}'), style: const TextStyle(fontSize: 11, color: BrandColors.gray)),
                      ]),
                    ),
                  ),
                ),
            ]),
          );
        },
      ),
    );
  }

  String _dayLabel(BuildContext c, String raw) {
    final d = DateTime.tryParse(raw);
    return d == null ? raw : DateFormat.E(c.lang).format(d);
  }
}

class _LatestOrders extends ConsumerWidget {
  const _LatestOrders({required this.onOpen});
  final VoidCallback onOpen;

  Color _color(String s) => switch (s) {
        'pending_confirmation' => BrandColors.warning,
        'delivered' => BrandColors.success,
        'cancelled' => BrandColors.error,
        _ => BrandColors.electric,
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final orders = ref.watch(_dOrdersProvider);
    const head = TextStyle(color: BrandColors.gray, fontSize: 12.5);
    return _Panel(
      title: _t(context, 'آخر الطلبات', 'Latest orders'),
      child: orders.when(
        loading: () => const SizedBox(height: 240, child: Center(child: CircularProgressIndicator())),
        error: (_, __) => SizedBox(height: 240, child: Center(child: Text(_t(context, 'مقدرتش أحمّل الطلبات', 'Could not load orders'), style: const TextStyle(color: BrandColors.gray)))),
        data: (list) => list.isEmpty
            ? SizedBox(height: 240, child: Center(child: Text(_t(context, 'مفيش طلبات مفتوحة 🎉', 'No open orders 🎉'), style: const TextStyle(color: BrandColors.gray))))
            : Column(children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(children: [
                    Expanded(flex: 2, child: Text(_t(context, 'الطلب', 'Order'), style: head)),
                    Expanded(flex: 3, child: Text(_t(context, 'العميل', 'Customer'), style: head)),
                    Expanded(flex: 2, child: Text(_t(context, 'المبلغ', 'Amount'), style: head)),
                    Expanded(flex: 3, child: Text(_t(context, 'الحالة', 'Status'), style: head)),
                  ]),
                ),
                for (final o in list)
                  InkWell(
                    onTap: onOpen,
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 11),
                      decoration: const BoxDecoration(border: Border(top: BorderSide(color: Color(0xFFEFF1F5)))),
                      child: Row(children: [
                        Expanded(flex: 2, child: Text('${o['reference']}', textDirection: TextDirection.ltr, textAlign: TextAlign.start, style: const TextStyle(fontWeight: FontWeight.w800, color: BrandColors.navy))),
                        Expanded(flex: 3, child: Text('${o['customer_name'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis)),
                        Expanded(flex: 2, child: Text(formatEgp((o['total_minor'] as num).toInt(), context.lang), style: const TextStyle(fontWeight: FontWeight.w700))),
                        Expanded(
                          flex: 3,
                          child: Align(
                            alignment: AlignmentDirectional.centerStart,
                            child: StatusChip(label: context.tr('os_${o['status']}'), color: _color('${o['status']}')),
                          ),
                        ),
                      ]),
                    ),
                  ),
              ]),
      ),
      minHeight: 340,
    );
  }
}
