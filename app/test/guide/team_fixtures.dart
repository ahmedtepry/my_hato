// Answers for the owner / manager / accountant pages (shapes taken from the live functions, sample numbers).
part of 'fixtures.dart';

const branch2 = '00000000-0000-4000-8000-0000000000b2';
const branch3 = '00000000-0000-4000-8000-0000000000b3';
const warehouse = '00000000-0000-4000-8000-0000000000b9';

const _u = ['00000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-000000000002', '00000000-0000-4000-8000-000000000003',
  '00000000-0000-4000-8000-000000000004', '00000000-0000-4000-8000-000000000005', '00000000-0000-4000-8000-000000000006'];

String _day(int daysAgo) => DateTime.now().subtract(Duration(days: daysAgo)).toIso8601String().substring(0, 10);

List<Map<String, Object?>> _branches() => [
      {'id': branchId, 'name_ar': 'فرع المعادي', 'name_en': 'Maadi branch', 'is_hq': false},
      {'id': branch2, 'name_ar': 'فرع مدينة نصر', 'name_en': 'Nasr City branch', 'is_hq': false},
      {'id': branch3, 'name_ar': 'فرع التجمع', 'name_en': 'New Cairo branch', 'is_hq': false},
      {'id': warehouse, 'name_ar': 'الوير هاوس', 'name_en': 'Warehouse', 'is_hq': true},
    ];

Map<String, Object?> _daybookRow(String day, String b, String bn, int total, int cash, int card, int wallet, int variance, String status, int collected) => {
      'day': day, 'locked': status == 'locked', 'shifts': 2, 'status': status, 'cashiers': ['أحمد', 'كريم'], 'branch_id': b, 'locked_at': status == 'locked' ? _ago(60 * 24) : null,
      'locked_by': status == 'locked' ? 'أحمد (المالك)' : null, 'card_minor': card, 'cash_minor': cash, 'first_open': _ago(60 * 30), 'last_close': _ago(60 * 18), 'branch_name': bn,
      'float_minor': 20000, 'open_shifts': 0, 'sales_count': total ~/ 9000, 'total_minor': total, 'wallet_minor': wallet, 'counted_minor': cash + variance, 'refunds_minor': 4900,
      'expected_minor': cash, 'expenses_minor': 1500, 'variance_minor': variance, 'collected_minor': collected, 'remaining_minor': cash - collected, 'card_sales_minor': card,
      'cash_sales_minor': cash, 'to_collect_minor': cash, 'corrections_minor': 0, 'wallet_sales_minor': wallet,
    };

Map<String, Object> teamRpc() => {
      'staff_view_branches': _branches(),
      'staff_my_branches': _branches(),
      'daybook_list': {
        'to': _day(0), 'from': _day(6), 'enabled': true, 'can_lock': true, 'can_collect': true, 'older_due': <Object>[],
        'rows': [
          _daybookRow(_day(0), branchId, 'فرع المعادي', 1248500, 702000, 386500, 160000, 0, 'open', 0),
          _daybookRow(_day(0), branch2, 'فرع مدينة نصر', 986000, 541000, 312000, 133000, -2500, 'open', 0),
          _daybookRow(_day(1), branchId, 'فرع المعادي', 1412000, 803000, 421000, 188000, 0, 'collected', 803000),
          _daybookRow(_day(1), branch2, 'فرع مدينة نصر', 1105500, 612500, 351000, 142000, 1000, 'pending', 0),
          _daybookRow(_day(1), branch3, 'فرع التجمع', 1630000, 905000, 508000, 217000, 0, 'collected', 905000),
          _daybookRow(_day(2), branchId, 'فرع المعادي', 1199000, 655000, 389000, 155000, 0, 'locked', 655000),
          _daybookRow(_day(2), branch3, 'فرع التجمع', 1544500, 861500, 473000, 210000, -1500, 'locked', 860000),
        ],
      },
      'my_sales_report': (Map<String, dynamic> a) => {
            'to': _day(0), 'from': _day(29), 'code': a['p_user'] == null ? null : '101', 'name': a['p_user'] == null ? null : 'محمد', 'user': a['p_user'],
            'total': 4865000, 'invoices': 214, 'monthly': false, 'can_others': true, 'can_edit_groups': true,
            'groups': {'acc': {'qty': 386, 'amount': 2145000}, 'brand': {'qty': 21, 'amount': 2290000}, 'repair': {'qty': 17, 'amount': 430000}},
            'series': [for (var i = 13; i >= 0; i--) {'b': _day(i), 'acc': 60000 + (i * 7919) % 90000, 'brand': (i % 3 == 0) ? 249900 : 0, 'repair': (i % 4 == 1) ? 35000 : 0}],
            'top': [
              {'qty': 41, 'group': 'acc', 'amount': 815900, 'name_ar': 'باكدج حماية متكامل', 'name_en': 'Full protection bundle'},
              {'qty': 6, 'group': 'brand', 'amount': 1499400, 'name_ar': 'موبايل جديد ١٢٨ جيجا', 'name_en': 'New phone 128GB'},
              {'qty': 96, 'group': 'acc', 'amount': 470400, 'name_ar': 'إسكرينة هيدروجيل مرنة', 'name_en': 'Flexible hydrogel screen'},
              {'qty': 9, 'group': 'repair', 'amount': 270000, 'name_ar': 'تغيير شاشة', 'name_en': 'Screen replacement'},
              {'qty': 38, 'group': 'acc', 'amount': 452200, 'name_ar': 'كابل Type-C مضفّر 1م', 'name_en': 'Braided Type-C cable 1m'},
            ],
          },
      'staff_codes': [
        {'user_id': _u[0], 'code': '001', 'name': 'أحمد', 'role': 'owner'},
        {'user_id': _u[1], 'code': '101', 'name': 'محمد', 'role': 'cashier'},
        {'user_id': _u[2], 'code': '102', 'name': 'كريم', 'role': 'cashier'},
        {'user_id': _u[3], 'code': '103', 'name': 'سارة', 'role': 'accountant'},
        {'user_id': _u[4], 'code': '104', 'name': 'منى', 'role': 'sales'},
        {'user_id': _u[5], 'code': '105', 'name': 'يوسف', 'role': 'technician'},
      ],
      'kpi_employees': {
        'to': _ago(0), 'from': _ago(60 * 24 * 30),
        'employees': [
          for (final (i, (n, r, net, cnt, tips, com, tgt)) in const [
            ('محمد', 'cashier', 2185000, 241, 18500, 64000, 2500000), ('كريم', 'cashier', 1730000, 198, 9500, 41000, 2500000),
            ('منى', 'sales', 1210000, 63, 0, 36000, 1500000), ('أحمد', 'owner', 436000, 31, 0, 0, null),
          ].indexed)
            {'name': n, 'role': r, 'user_id': _u[i + 1 < 6 ? i + 1 : 0], 'net_minor': net, 'tips_minor': tips, 'gross_minor': net + 25000, 'sales_count': cnt, 'shifts_count': 22 - i * 3,
              'target_minor': tgt, 'online_orders': r == 'sales' ? 63 : 0, 'refunds_minor': 25000, 'discount_minor': 12000, 'avg_ticket_minor': net ~/ cnt, 'commission_minor': com,
              'online_sales_minor': r == 'sales' ? net : 0, 'online_commission_minor': r == 'sales' ? com : 0},
        ],
      },
      'ops_live': {
        'now': _ago(0),
        'team': [
          for (final (i, (n, r, area, pres)) in const [
            ('أحمد', 'owner', 'ops', 'online'), ('محمد', 'cashier', 'pos', 'online'), ('كريم', 'cashier', 'pos', 'online'),
            ('سارة', 'accountant', 'daybook', 'online'), ('منى', 'sales', 'orders', 'away'), ('يوسف', 'technician', 'repairs', 'online'),
          ].indexed)
            {'area': area, 'name': n, 'rank': i == 0 ? 0 : 2, 'role': r, 'user_id': _u[i], 'platform': 'windows', 'presence': pres, 'last_seen_at': _ago(i)},
        ],
        'profit': {'by_branch': <String, Object>{}, 'profit_minor': 612000, 'sales_counted': 86, 'sales_uncosted': 2, 'pos_profit_minor': 548000, 'online_profit_minor': 64000},
        'branches': [
          for (final (b, ar, en, net, open, cnt) in [
            (branchId, 'فرع المعادي', 'Maadi branch', 1248500, 1, 41), (branch2, 'فرع مدينة نصر', 'Nasr City branch', 986000, 1, 33), (branch3, 'فرع التجمع', 'New Cairo branch', 1402000, 1, 38),
          ])
            {'id': b, 'is_hq': false, 'name_ar': ar, 'name_en': en, 'net_minor': net, 'open_shifts': open, 'sales_count': cnt, 'last_sale_at': _ago(3), 'refunds_minor': 4900},
        ],
        'open_shifts': [
          for (final (i, (b, bn, c)) in const [(branchId, 'فرع المعادي', 'محمد'), (branch2, 'فرع مدينة نصر', 'كريم'), (branch3, 'فرع التجمع', 'أحمد')].indexed)
            {'shift_id': '00000000-0000-4000-8000-0000000005${i}0', 'branch_id': b, 'opened_at': _ago(300 - i * 40), 'cashier_id': _u[i + 1], 'sales_count': 41 - i * 4, 'sales_minor': 1248500 - i * 150000,
              'cashier_name': c, 'last_sale_at': _ago(3 + i), 'opening_minor': 20000, 'branch_name_ar': bn},
        ],
        'recent_sales': [
          for (final (i, x) in invoices().indexed)
            {'id': x['id'], 'number': x['number'], 'branch_id': branchId, 'created_at': x['created_at'], 'total_minor': x['total_minor'], 'cashier_name': i.isEven ? 'محمد' : 'كريم',
              'branch_name_ar': i < 3 ? 'فرع المعادي' : 'فرع التجمع', 'discount_minor': 0, 'refunded_minor': x['refunded_minor']},
        ],
        'recent_actions': [
          {'id': 1, 'action': 'pos.sale', 'details': <String, Object>{}, 'actor_id': _u[1], 'entity_id': '49988498', 'actor_name': 'محمد', 'created_at': _ago(2), 'entity_type': 'sale'},
          {'id': 2, 'action': 'daybook.collect', 'details': <String, Object>{}, 'actor_id': _u[3], 'entity_id': 'x', 'actor_name': 'سارة', 'created_at': _ago(9), 'entity_type': 'daybook'},
          {'id': 3, 'action': 'order.status', 'details': <String, Object>{}, 'actor_id': _u[4], 'entity_id': 'MH-24117', 'actor_name': 'منى', 'created_at': _ago(14), 'entity_type': 'order'},
        ],
      },
      'pos_branch_report': [
        {'branch_id': branchId, 'branch_name_ar': 'فرع المعادي', 'sales_count': 742, 'sales_minor': 38450000, 'refunds_minor': 312000, 'net_minor': 38138000, 'shifts_closed': 58, 'variance_minor': -4500, 'cashiers': 3},
        {'branch_id': branch2, 'branch_name_ar': 'فرع مدينة نصر', 'sales_count': 598, 'sales_minor': 30210000, 'refunds_minor': 201000, 'net_minor': 30009000, 'shifts_closed': 54, 'variance_minor': 1000, 'cashiers': 2},
        {'branch_id': branch3, 'branch_name_ar': 'فرع التجمع', 'sales_count': 811, 'sales_minor': 44120000, 'refunds_minor': 280000, 'net_minor': 43840000, 'shifts_closed': 60, 'variance_minor': 0, 'cashiers': 3},
      ],
      'pos_branch_payment_split2': [
        {'branch_id': branchId, 'cash_minor': 21400000, 'card_minor': 11800000, 'card_count': 231, 'wallet_minor': 4938000},
        {'branch_id': branch2, 'cash_minor': 17100000, 'card_minor': 8900000, 'card_count': 188, 'wallet_minor': 4009000},
        {'branch_id': branch3, 'cash_minor': 23300000, 'card_minor': 14200000, 'card_count': 266, 'wallet_minor': 6340000},
      ],
      'pos_expense_report': [
        {'id': '00000000-0000-4000-8000-0000000e0001', 'created_at': _ago(200), 'branch_id': branchId, 'branch_name_ar': 'فرع المعادي', 'cashier_name': 'محمد', 'amount_minor': 3500, 'reason': 'مية وشاي'},
        {'id': '00000000-0000-4000-8000-0000000e0002', 'created_at': _ago(1500), 'branch_id': branch3, 'branch_name_ar': 'فرع التجمع', 'cashier_name': 'كريم', 'amount_minor': 15000, 'reason': 'مواصلات توصيل'},
      ],
      'pos_pending_approvals': [
        {'id': '00000000-0000-4000-8000-0000000a0001', 'kind': 'discount', 'branch_id': branchId, 'requester_id': _u[1], 'requester_name': 'محمد', 'amount_minor': 15000, 'reason': 'عميل دايم، طلب خصم ١٥٪',
          'payload': {'percent': 15, 'total_minor': 100000}, 'created_at': _ago(3)},
        {'id': '00000000-0000-4000-8000-0000000a0002', 'kind': 'refund', 'branch_id': branch2, 'requester_id': _u[2], 'requester_name': 'كريم', 'amount_minor': 89900, 'reason': 'السماعة فيها عيب صناعة',
          'payload': {'number': '35283034'}, 'created_at': _ago(11)},
      ],
      'pos_shift_list': [
        for (final (i, (b, bn, c, st, sales, cnt, exp, cnt2, v, note)) in const [
          (branchId, 'فرع المعادي', 'محمد', 'open', 1248500, 41, 722000, 0, 0, ''), (branch2, 'فرع مدينة نصر', 'كريم', 'closed', 1105500, 37, 632500, 630000, -2500, 'ناقص ٢٥ جنيه'),
          (branch3, 'فرع التجمع', 'أحمد', 'closed', 1630000, 52, 925000, 925000, 0, ''), (branchId, 'فرع المعادي', 'محمد', 'closed', 1412000, 46, 823000, 824000, 1000, 'زيادة ١٠ جنيه'),
        ].indexed)
          {'id': '00000000-0000-4000-8000-0000000051${i}0', 'branch_id': b, 'branch_name_ar': bn, 'cashier_id': _u[1], 'cashier_name': c, 'status': st, 'opened_at': _ago(400 + i * 1440),
            'closed_at': st == 'open' ? null : _ago(i * 1440 - 0), 'opening_minor': 20000, 'sales_count': cnt, 'sales_minor': sales, 'refunds_minor': 4900, 'expected_minor': exp,
            'counted_minor': st == 'open' ? null : cnt2, 'variance_minor': st == 'open' ? null : v, 'note': note},
      ],
      'pos_shift_report_list': [
        for (final (i, (bn, c, sales, exp, counted, v)) in const [
          ('فرع مدينة نصر', 'كريم', 1105500, 632500, 630000, -2500), ('فرع التجمع', 'أحمد', 1630000, 925000, 925000, 0), ('فرع المعادي', 'محمد', 1412000, 823000, 824000, 1000),
        ].indexed)
          {'report_no': 'SR-00014${7 - i}', 'shift_id': '00000000-0000-4000-8000-0000000051${i + 1}0', 'branch_id': branchId, 'branch_name_ar': bn, 'cashier_name': c, 'closed_by_name': c,
            'closed_device': 'windows · CASHIER-PC', 'opened_at': _ago(1700 + i * 1440), 'closed_at': _ago(1000 + i * 1440), 'sales_minor': sales, 'refunds_minor': 4900, 'expected_minor': exp,
            'counted_minor': counted, 'variance_minor': v, 'corrections_minor': 0, 'note': v == 0 ? '' : (v < 0 ? 'ناقص ٢٥ جنيه' : 'زيادة ١٠ جنيه')},
      ],
      'sales_report': {
        'to': _ago(0), 'from': _ago(60 * 24 * 17), 'orders': 214, 'total_minor': 48650000, 'prev_total_minor': 42100000, 'pending_minor': 870000, 'pending_orders': 6,
        'pickup_orders': 71, 'delivery_orders': 143,
        'series': [for (var i = 17; i >= 0; i--) {'label': _day(i), 'total_minor': 2100000 + (i * 389017) % 1400000}],
        'top': [
          {'name_ar': 'باكدج حماية متكامل', 'name_en': 'Full protection bundle', 'qty': 112, 'total_minor': 2228800},
          {'name_ar': 'سماعة لاسلكية Pro', 'name_en': 'Wireless earbuds Pro', 'qty': 23, 'total_minor': 2067700},
          {'name_ar': 'شاحن سريع 25 واط', 'name_en': 'Fast charger 25W', 'qty': 61, 'total_minor': 1518900},
        ],
      },
      'profit_report': {
        'to': _ago(0), 'from': _ago(60 * 24 * 30), 'products_without_cost': 2,
        'totals': {'cost_minor': 6210000, 'losing_sales': 1, 'profit_minor': 5940000, 'revenue_minor': 12150000, 'sales_counted': 512, 'sales_uncosted': 4, 'pos_profit_minor': 5120000,
          'online_profit_minor': 820000, 'revenue_uncosted_minor': 96000},
        'series': [for (var i = 13; i >= 0; i--) {'day': _day(i), 'profit_minor': 330000 + (i * 77003) % 210000}],
        'top': [
          {'qty': 112, 'name': 'باكدج حماية متكامل', 'cost_minor': 1008000, 'profit_minor': 1220800, 'revenue_minor': 2228800},
          {'qty': 96, 'name': 'إسكرينة هيدروجيل مرنة', 'cost_minor': 76800, 'profit_minor': 393600, 'revenue_minor': 470400},
          {'qty': 61, 'name': 'شاحن سريع 25 واط', 'cost_minor': 793000, 'profit_minor': 725900, 'revenue_minor': 1518900},
        ],
        'worst': [{'qty': 1, 'name': 'حامل موبايل للعربية', 'cost_minor': 16000, 'profit_minor': -1100, 'revenue_minor': 14900}],
        'sales': [
          for (final (i, x) in invoices().indexed)
            {'at': x['created_at'], 'ref': x['number'], 'who': i.isEven ? 'محمد' : 'كريم', 'kind': 'pos', 'cost_minor': (x['total_minor']! as int) * 45 ~/ 100,
              'profit_minor': (x['total_minor']! as int) * 55 ~/ 100, 'missing_lines': 0, 'revenue_minor': x['total_minor']},
        ],
      },
      'online_overview': {
        'employees': [
          {'user_id': _u[4], 'name': 'منى', 'daily_hours': 8, 'orders_done': 63, 'orders_target': 80, 'value_done_minor': 1210000, 'value_target_minor': 1500000},
          {'user_id': _u[1], 'name': 'محمد', 'daily_hours': 4, 'orders_done': 21, 'orders_target': 30, 'value_done_minor': 402000, 'value_target_minor': 600000},
        ],
      },
      'online_report': {
        'year': DateTime.now().year, 'month': DateTime.now().month, 'money': <Object>[],
        'employees': [{'name': 'منى', 'orders': 63, 'delivered': 58, 'total_minor': 1210000, 'commission_minor': 36000}],
        'orders': [
          for (final (i, o) in orders().indexed)
            {'at': o['created_at'], 'branch': 'فرع المعادي', 'bucket': i.isEven ? 'online_money' : 'branch_money', 'status': o['status'], 'settled': i > 1, 'employee': 'منى', 'reference': o['reference'],
              'till_sale': null, 'fulfillment': o['fulfillment'], 'total_minor': o['total_minor'], 'delivered_at': null, 'payment_method': o['payment_method'], 'payment_status': o['payment_status'],
              'branch_confirmed': o['branch_confirmed'], 'commission_minor': 600, 'commission_state': i > 1 ? 'earned' : 'not_delivered'},
        ],
      },
      'wallet_balance': [
        {'wallet': 'vodafone', 'refunds_minor': 0, 'received_minor': 3418000, 'unlinked_minor': 49000, 'withdrawn_minor': 2900000},
        {'wallet': 'etisalat', 'refunds_minor': 19900, 'received_minor': 1204000, 'unlinked_minor': 0, 'withdrawn_minor': 1000000},
        {'wallet': 'instapay', 'refunds_minor': 0, 'received_minor': 2611500, 'unlinked_minor': 0, 'withdrawn_minor': 2000000},
      ],
      'wallet_inbox_state': {'enabled': true, 'has_token': true, 'auto_confirm': true, 'last_received': _ago(6)},
      'wallet_inbox_list': {
        'enabled': true,
        'transfers': [
          for (final (i, (w, from, amt, ref, mins)) in const [
            ('vodafone', '01012345670', 89900, 'MH-24116', 6), ('instapay', '01122334455', 37800, 'MH-24117', 25), ('vodafone', '01555667788', 49000, null, 70), ('etisalat', '01133557799', 19900, 'MH-24109', 180),
          ].indexed)
            {'id': '00000000-0000-4000-8000-0000000c0${i}0e', 'wallet': w, 'from_phone': from, 'amount_minor': amt, 'received_at': _ago(mins), 'order_reference': ref, 'matched': ref != null,
              'text': 'تم استلام مبلغ ${amt ~/ 100} جنيه من $from', 'status': ref != null ? 'linked' : 'unlinked'},
        ],
      },
      'wallet_numbers_get': {'vodafone': '01000000000', 'etisalat': '01100000000', 'instapay': 'myhato@instapay'},
      'purchases_list': [
        for (final (i, (n, sup, st, tot, paid, d)) in const [
          ('PO-0031', 'الشركة المصرية للإكسسوارات', 'ordered', 4850000, 2000000, 2), ('PO-0030', 'مؤسسة النور للموبايلات', 'partial', 12600000, 12600000, 6),
          ('PO-0029', 'الشركة المصرية للإكسسوارات', 'received', 3120000, 3120000, 11),
        ].indexed)
          {'id': '00000000-0000-4000-8000-0000000f00${i}e', 'number': n, 'supplier': sup, 'supplier_id': '00000000-0000-4000-8000-0000000f10${i % 2}e', 'status': st, 'total_minor': tot, 'paid_minor': paid,
            'created_at': _ago(60 * 24 * d), 'expected_date': _day(-2 + d), 'note': i == 0 ? 'إسكرينات وجرابات للعيد' : null, 'branch_id': warehouse,
            'items': [{'sku': 'MH-PROT-001', 'name_ar': 'إسكرينة زجاج كاملة 9D', 'name_en': 'Full-cover tempered glass 9D', 'qty': 200, 'received_qty': st == 'ordered' ? 0 : 200, 'unit_cost_minor': 1200}]},
      ],
      'suppliers_list': [
        {'id': '00000000-0000-4000-8000-0000000f100e', 'name': 'الشركة المصرية للإكسسوارات', 'phone': '0225550001', 'is_active': true, 'orders': 14, 'owed_minor': 2850000, 'note': null},
        {'id': '00000000-0000-4000-8000-0000000f101e', 'name': 'مؤسسة النور للموبايلات', 'phone': '0225550002', 'is_active': true, 'orders': 6, 'owed_minor': 0, 'note': 'موبايلات براند'},
      ],
      'goods_receipts_list': <Object>[],
      'wheel_gifts_list': <Object>[],
      'stocktakes_list': <Object>[],
      'price_changes_list': <Object>[],
      'wheel_admin_get': {
        'ease': 50, 'enabled': true, 'spins_today': 23, 'gifts_pending': 4, 'require_order': true, 'spins_per_day': 1,
        'segments': [
          for (final (i, (kind, ar, en, w, pts, pct)) in const [
            ('points', '50 نقطة', '50 points', 30, 50, null), ('discount', 'خصم 10%', '10% off', 15, null, 10), ('points', '100 نقطة', '100 points', 15, 100, null),
            ('lose', 'حظ أوفر', 'Better luck', 25, null, null), ('gift', 'جراب هدية', 'Free case', 5, null, null), ('discount', 'خصم 5%', '5% off', 10, null, 5),
          ].indexed)
            {'id': '00000000-0000-4000-8000-00000000510$i', 'kind': kind, 'active': true, 'points': pts, 'weight': w, 'label_ar': ar, 'label_en': en, 'daily_limit': kind == 'gift' ? 3 : null,
              'given_today': i == 0 ? 9 : i, 'valid_hours': 72, 'discount_percent': pct},
        ],
      },
      'feature_flags': {'wheel': true, 'points': true, 'wheel_enabled': true, 'points_enabled': true},
      'owner_loyalty_overview': {
        'awards': <Object>[],
        'levels': [
          {'sort': 1, 'name_ar': 'مستكشف', 'name_en': 'Explorer', 'plan_ar': null, 'plan_en': null, 'min_points': 0},
          {'sort': 2, 'name_ar': 'فضي', 'name_en': 'Silver', 'plan_ar': 'خصم ٥٪', 'plan_en': '5% off', 'min_points': 500},
          {'sort': 3, 'name_ar': 'ذهبي', 'name_en': 'Gold', 'plan_ar': 'توصيل مجاني', 'plan_en': 'Free delivery', 'min_points': 1500},
        ],
        'statuses': <Object>[],
        'customers': [
          {'email': 'mona@example.com', 'points': 1840, 'customer': 'منى خالد', 'level_ar': 'ذهبي'},
          {'email': 'omar@example.com', 'points': 960, 'customer': 'عمر سامي', 'level_ar': 'فضي'},
        ],
      },
      'assistant_state': {
        'guard': {'enabled': true}, 'cashier': {'enabled': true}, 'accountant': {'enabled': true},
        'support': {'enabled': true, 'log': [{'at': _ago(20), 'kind': 'order_pending', 'text': 'نبّهت الفريق إن الطلب MH-24117 لسه مستني التأكيد'}]},
      },
      'staff_blocked_accounts': [
        {'code': 'MHC-100231', 'kind': 'customer', 'name': 'حسام عادل', 'email': 'hossam@example.com', 'phone': '+201012345678', 'status': 'locked', 'user_id': _u[5], 'username': 'hossam',
          'blocked_at': _ago(40), 'failed_count': 6, 'locked_until': _ago(-20), 'suspended_at': null, 'last_failed_at': _ago(40)},
      ],
      'storefront_layout_get': 'toggle',
      'server_usage': {
        'db_bytes': 25548467, 'db_limit': 524288000, 'storage_bytes': 115757621, 'storage_limit': 1073741824,
        'buckets': {'app-updates': 98000000, 'product-images': 12400000, 'repair-photos': 3900000, 'banners': 1450000},
        'history': [for (var i = 20; i >= 0; i--) {'day': _day(i), 'db': 23000000 + (20 - i) * 120000, 'storage': 101000000 + (20 - i) * 700000}],
        'last_cleanup': {'at': _ago(600), 'files': 12, 'bytes': 4100000, 'rows': 230},
      },
    };
