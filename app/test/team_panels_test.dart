import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:myhato/core/l10n.dart';
import 'package:myhato/core/supabase_providers.dart';
import 'package:myhato/core/theme.dart';
import 'package:myhato/features/admin/admin_repository.dart';
import 'package:myhato/features/admin/online_review_panel.dart';
import 'package:myhato/features/admin/wallet_inbox_panel.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Staff extends StaffContextController {
  _Staff(this.perms);
  final Set<String> perms;
  @override
  Future<StaffContext> build() async => StaffContext(const {'accountant'}, perms);
}

/// Opens the new team screens against a fake server, so a build error or a wrong reading of the data shows up here and not on the accountant's screen.
Future<void> _pump(WidgetTester t, Widget panel, Set<String> perms, Map<String, Object> rpc) async {
  t.view.physicalSize = const Size(1600, 1400);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final client = MockClient((req) async {
    final name = req.url.pathSegments.last;
    final body = rpc[name];
    if (body == null) return http.Response(jsonEncode({'message': 'no such fake: $name'}), 404, headers: {'content-type': 'application/json'});
    return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
  });
  await t.pumpWidget(ProviderScope(
    overrides: [
      supabaseProvider.overrideWithValue(SupabaseClient('https://example.supabase.co', 'anon', httpClient: client, authOptions: const AuthClientOptions(autoRefreshToken: false))),
      staffContextProvider.overrideWith(() => _Staff(perms)),
    ],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      supportedLocales: supportedLocales,
      localizationsDelegates: const [GlobalMaterialLocalizations.delegate, GlobalWidgetsLocalizations.delegate, GlobalCupertinoLocalizations.delegate],
      theme: AppTheme.light(const Locale('ar')),
      home: Scaffold(body: panel),
    ),
  ));
  await t.pump(const Duration(milliseconds: 300));
  await t.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('wallet inbox: accountant sees transfers, suggestion, balances', (t) async {
    await _pump(t, const WalletInboxPanel(), {'wallet.view', 'wallet.refund', 'orders.confirm_wallet'}, {
      'wallet_inbox_list': {
        'enabled': true,
        'transfers': [
          {'id': 2, 'wallet': 'vodafone', 'amount_minor': 199150, 'sender': '01012345678', 'reference': '123456789', 'at': DateTime.now().toIso8601String(), 'status': 'new', 'order': null, 'raw': null,
            'suggest': [{'order_id': 'o1', 'reference': 'MH-1', 'total_minor': 199150, 'exact': true}]},
          {'id': 1, 'wallet': 'etisalat', 'amount_minor': null, 'sender': null, 'reference': null, 'at': DateTime.now().toIso8601String(), 'status': 'new', 'order': null, 'raw': 'رسالة غريبة', 'suggest': []},
        ],
      },
      'wallet_balance': [
        {'wallet': 'vodafone', 'received_minor': 199150, 'unlinked_minor': 199150, 'refunds_minor': 0, 'withdrawn_minor': 0},
        {'wallet': 'etisalat', 'received_minor': 0, 'unlinked_minor': 0, 'refunds_minor': 0, 'withdrawn_minor': 0},
      ],
    });
    expect(t.takeException(), isNull);
    expect(find.textContaining('1,991.50'), findsWidgets);
    expect(find.textContaining('MH-1'), findsWidgets);
    expect(find.text('رسالة غريبة'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('wallet inbox: a view-only employee has no refund or balance', (t) async {
    await _pump(t, const WalletInboxPanel(), {'wallet.view'}, {
      'wallet_inbox_list': {'enabled': false, 'transfers': []},
    });
    expect(t.takeException(), isNull);
    expect(find.textContaining('مرتجع محفظة'), findsNothing);
    expect(find.textContaining('الرصيد المتوقع'), findsNothing);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('online page: employees, money buckets and the double-counting alert', (t) async {
    await _pump(t, const OnlineReviewPanel(), {'online.review'}, {
      'online_report': {
        'year': 2026,
        'month': 10,
        'employees': [
          {'user_id': 'u1', 'name': 'منى', 'confirmed_n': 3, 'delivered_n': 2, 'delivered_minor': 130000, 'commission_minor': 1500, 'payable_minor': 1000, 'shifts_count': 2, 'shift_hours': 8.5},
        ],
        'money': [
          {'bucket': 'branch_till', 'n': 1, 'total_minor': 100000, 'counted_again_minor': 100000},
          {'bucket': 'online_money', 'n': 1, 'total_minor': 30000, 'counted_again_minor': 0},
        ],
        'orders': [
          {'reference': 'MH-1', 'at': '2026-10-20T10:00:00Z', 'delivered_at': '2026-10-21T10:00:00Z', 'status': 'delivered', 'fulfillment': 'pickup', 'branch': 'فرع ١', 'branch_confirmed': true,
            'payment_method': 'pay_at_branch', 'payment_status': 'unpaid', 'bucket': 'branch_till', 'total_minor': 100000, 'employee': 'منى', 'commission_minor': 1000, 'commission_state': 'waiting_branch_sale', 'till_sale': null, 'settled': false},
          {'reference': 'MH-2', 'at': '2026-10-20T11:00:00Z', 'delivered_at': null, 'status': 'delivered', 'fulfillment': 'delivery', 'branch': null, 'branch_confirmed': false,
            'payment_method': 'wallet', 'payment_status': 'paid', 'bucket': 'online_money', 'total_minor': 30000, 'employee': null, 'commission_minor': 0, 'commission_state': 'payable', 'till_sale': 'S-9', 'settled': false},
        ],
      },
    });
    expect(t.takeException(), isNull);
    expect(find.text('منى'), findsOneWidget);
    expect(find.textContaining('تنبيه تكرار الفلوس'), findsOneWidget);
    expect(find.textContaining('MH-1'), findsWidgets);
  });
}
