// Sample data for the guide screenshots (same shapes the real server returns).
const fakeUserId = '00000000-0000-4000-8000-000000000001';
const fakeSellerId = '00000000-0000-4000-8000-000000000002';
const branchId = '00000000-0000-4000-8000-0000000000b1';
const shiftId = '00000000-0000-4000-8000-0000000000a1';

const cashierPerms = {
  'assistant.cashier', 'assistant.guard', 'assistant.use_challenge', 'assistant.use_find', 'assistant.use_fingerprint', 'assistant.use_overview',
  'assistant.use_reel', 'assistant.use_robot_close', 'assistant.use_robot_open', 'chat.use', 'commission.today', 'invoices.view', 'pos.discount',
  'pos.refund', 'pos.remember_login', 'pos.sell', 'pos.shift', 'targets.mine',
};
const salesPerms = {
  'banners.manage', 'cancel_requests.decide', 'chat.use', 'commission.today', 'coupons.manage', 'customers.view', 'inventory.manage', 'marketing.view',
  'notifications.broadcast', 'online.mine', 'online.shift', 'orders.address', 'orders.confirm_wallet', 'orders.manage', 'orders.set_branch', 'orders.view',
  'payments.manage', 'pos.remember_login', 'pos.sell', 'pos.shift', 'products.manage', 'reviews.moderate', 'stock.receive', 'stock.transfer', 'stock.view',
  'targets.mine', 'wallet.view',
};
const technicianPerms = {'chat.use', 'repairs.manage', 'repairs.update_assigned', 'repairs.view'};
const supportPerms = {
  'assistant.accountant', 'assistant.support', 'assistant.use_fingerprint', 'banners.manage', 'branches.manage', 'cancel_requests.decide', 'chat.use',
  'coupons.manage', 'customers.review', 'customers.view', 'marketing.view', 'notifications.broadcast', 'occasions.manage', 'orders.address', 'orders.view',
  'pos.remember_login', 'repairs.view', 'reviews.moderate', 'support.manage',
};
const marketingPerms = {
  'banners.manage', 'chat.use', 'contest.manage', 'coupons.manage', 'customers.view', 'marketing.analytics', 'marketing.campaigns', 'marketing.request',
  'marketing.segments', 'marketing.view', 'notifications.broadcast', 'occasions.manage', 'pos.remember_login', 'reviews.moderate',
};

String _ago(int minutes) => DateTime.now().toUtc().subtract(Duration(minutes: minutes)).toIso8601String();

final products = <Map<String, Object?>>[
  for (final (i, (ar, en, sku, bc, price, stock)) in const [
    ('إسكرينة خصوصية Privacy', 'Privacy screen protector', 'MH-PROT-002', '50332359', 4900, 93),
    ('إسكرينة زجاج كاملة 9D / 11D / 21D', 'Full-cover tempered glass 9D', 'MH-PROT-001', '13127867', 4900, 194),
    ('إسكرينة مات ضد البصمات', 'Matte anti-fingerprint screen', 'MH-PROT-003', '74775304', 4900, 96),
    ('إسكرينة هيدروجيل مرنة', 'Flexible hydrogel screen', 'MH-PROT-004', '71274928', 4900, 283),
    ('باكدج حماية متكامل', 'Full protection bundle', 'MH-BNDL-001', '36501260', 19900, 11),
    ('جراب بجيب للكروت', 'Card-pocket case', 'MH-CASE-005', '21241262', 8900, 90),
    ('جراب حماية من المية بتعليقة', 'Waterproof pouch with lanyard', 'MH-CASE-006', '15212061', 4900, 66),
    ('جراب سيليكون ببطانة مخملية', 'Silicone case, velvet lining', 'MH-CASE-001', '27219894', 7900, 0),
    ('شاحن سريع 25 واط', 'Fast charger 25W', 'MH-CHRG-001', '64019372', 24900, 40),
    ('كابل Type-C مضفّر 1م', 'Braided Type-C cable 1m', 'MH-CABL-001', '80237715', 11900, 152),
    ('سماعة لاسلكية Pro', 'Wireless earbuds Pro', 'MH-AUD-001', '55120948', 89900, 14),
    ('حامل موبايل للعربية', 'Car phone holder', 'MH-HOLD-001', '39981046', 14900, 37),
  ].indexed)
    {
      'id': '00000000-0000-4000-8000-${(1000 + i).toString().padLeft(12, '0')}',
      'name_ar': ar,
      'name_en': en,
      'sku': sku,
      'barcode': bc,
      'price_minor': price,
      'stock_quantity': stock,
    },
];

Map<String, Object> shiftRow() => {
      'id': shiftId,
      'status': 'open',
      'branch_id': branchId,
      'branch_name_ar': 'فرع المعادي',
      'cashier_id': fakeUserId,
      'opened_at': _ago(190),
      'opening_minor': 20000,
      'opening_cash_minor': 20000,
      'sales_count': 14,
      'sales_minor': 486500,
      'cash_sales_minor': 241000,
      'card_sales_minor': 168500,
      'wallet_sales_minor': 77000,
      'card_sales_count': 5,
      'refunds_minor': 4900,
      'cash_refunds_minor': 4900,
      'card_refunds_minor': 0,
      'wallet_refunds_minor': 0,
      'expenses_minor': 3500,
      'tips_minor': 0,
      'tips_kept_minor': 0,
      'expected_minor': 252600,
    };

Map<String, Object> cashierRpc() => {
      ...commonRpc(),
      'pos_invoices_list': invoices(),
      'pos_invoice_detail': {...saleJson(), 'can_edit_payment': true, 'seller_code': 'ahmed'},
      'pos_find_sale': saleJson(),
      'pos_shift_summary': shiftRow(),
      'pos_sales': [for (final x in invoices()) {'id': x['id'], 'number': x['number'], 'total_minor': x['total_minor'], 'refunded_minor': x['refunded_minor'], 'created_at': x['created_at']}],
      'my_target_status': {'at': _ago(0), 'pct': 73.6, 'net_minor': 1840000, 'bonus_days': 6, 'month_from': _ago(60 * 24 * 11), 'online_minor': 0, 'target_minor': 2500000,
        'bonus_120_minor': 2500, 'bonus_150_minor': 5000, 'bonus_month_minor': 9500, 'bonus_today_minor': 1000, 'daily_bonus_minor': 1000, 'sales_today_minor': 96000,
        'commission_month_minor': 64000, 'commission_today_minor': 4500, 'online_commission_minor': 0},
      'pos_current_shift': shiftRow(),
      'pos_get_limits': {'is_owner': false, 'can_discount': true, 'discount_free_minor': 1000, 'allow_negative_stock': false, 'discount_approval_pct': 10, 'refund_approval_minor': 50000},
      'assistant_flags': {'find': true, 'mine': true, 'reel': false, 'guard': true, 'cashier': true, 'available': true, 'challenge': true, 'robot_open': true, 'fingerprint': true, 'robot_close': true},
      'my_challenge_today': {
        'products': [
          {'sku': 'MH-BNDL-001', 'name_ar': 'باكدج حماية متكامل', 'name_en': 'Full protection bundle', 'product_id': products[4]['id'], 'sold_today': 1, 'amount_minor': 1500},
        ],
        'bonus_days': 6,
        'days_in_month': 30,
        'daily_bonus_minor': 1000,
        'bonus_120_minor': 2500,
        'bonus_150_minor': 5000,
        'month_net_minor': 1840000,
        'bonus_today_minor': 1000,
        'sales_today_minor': 96000,
        'daily_target_minor': 83334,
        'monthly_target_minor': 2500000,
        'commission_month_minor': 64000,
        'commission_today_minor': 4500,
      },
      'pos_current_seller': {'id': fakeUserId, 'name': 'أحمد'},
      'pos_seller_candidates': [
        {'id': fakeUserId, 'name': 'أحمد', 'code': 'ahmed', 'has_pin': true, 'active': true},
        {'id': fakeSellerId, 'name': 'محمد', 'code': 'mohamed', 'has_pin': true, 'active': false},
        {'id': '00000000-0000-4000-8000-000000000003', 'name': 'كريم', 'code': 'karim', 'has_pin': false, 'active': false},
      ],
      'staff_my_branches': [
        {'id': branchId, 'is_hq': false, 'name_ar': 'فرع المعادي', 'name_en': 'Maadi branch'},
      ],
      'pos_search_products': products,
      'pos_catalog_snapshot': products,
      'commission_today_products': [
        {'product_id': products[4]['id'], 'name_ar': 'باكدج حماية متكامل', 'name_en': 'Full protection bundle', 'sku': 'MH-BNDL-001', 'amount_minor': 1500},
      ],
    };


Map<String, Object> saleJson({String number = '49988498', String pm = 'cash', int minutesAgo = 25}) => {
      'id': '00000000-0000-4000-8000-00000000ca1e',
      'number': number,
      'shift_id': shiftId,
      'branch_id': branchId,
      'branch_name_ar': 'فرع المعادي',
      'cashier_id': fakeUserId,
      'cashier_name': 'أحمد',
      'created_at': _ago(minutesAgo),
      'payment_method': pm,
      'paid_cash_minor': pm == 'cash' ? 33300 : 0,
      'paid_card_minor': pm == 'card' ? 33300 : 0,
      'paid_wallet_minor': 0,
      'subtotal_minor': 33300,
      'discount_minor': 0,
      'total_minor': 33300,
      'cash_received_minor': 35000,
      'change_minor': 1700,
      'tip_minor': 0,
      'refunded_minor': 0,
      'cancelled': false,
      'refunds': <Object>[],
      'items': [
        {'id': '00000000-0000-4000-8000-0000000017e1', 'sku': 'MH-PROT-001', 'name_ar': 'إسكرينة زجاج كاملة 9D / 11D / 21D', 'name_en': 'Full-cover tempered glass 9D', 'quantity': 2, 'product_id': products[1]['id'],
          'refunded_qty': 0, 'net_line_minor': 9800, 'line_total_minor': 9800, 'unit_price_minor': 4900, 'commission_unit_minor': 0, 'refunded_amount_minor': 0},
        {'id': '00000000-0000-4000-8000-0000000017e2', 'sku': 'MH-CHRG-001', 'name_ar': 'شاحن سريع 25 واط', 'name_en': 'Fast charger 25W', 'quantity': 1, 'product_id': products[8]['id'],
          'refunded_qty': 0, 'net_line_minor': 23500, 'line_total_minor': 23500, 'unit_price_minor': 23500, 'commission_unit_minor': 0, 'refunded_amount_minor': 0},
      ],
    };

List<Map<String, Object>> invoices() => [
      for (final (i, (n, total, pm, mins, ref)) in const [
        ('49988498', 33300, 'cash', 25, 0),
        ('23643893', 19600, 'split', 48, 0),
        ('35283034', 89900, 'card', 70, 0),
        ('43944824', 70400, 'cash', 96, 19700),
        ('88790266', 4900, 'wallet', 130, 0),
        ('73218044', 9800, 'card', 160, 0),
      ].indexed)
        {
          'id': '00000000-0000-4000-8000-00000000c${i}0e',
          'number': n,
          'status': 'paid',
          'created_at': _ago(mins),
          'seller_code': 'ahmed',
          'seller_name': i == 2 ? 'محمد' : 'أحمد',
          'total_minor': total,
          'branch_name_ar': 'فرع المعادي',
          'payment_method': pm,
          'refunded_minor': ref,
        },
    ];

/// Answers every team page needs, whatever the job.
Map<String, Object> commonRpc() => {
      'chat_unread': {'total': 2, 'threads': <Object>[]},
      'staff_pending_accounts_count': 0,
      'staff_dashboard_stats': <String, Object>{},
      'profiles': [
        {'id': fakeUserId, 'full_name': 'أحمد', 'phone': '01000000000', 'email': 'ahmed@myhato.app'},
      ],
      'cancel_requests': <Object>[],
      'application_settings': [
        {'value': {'look': 'midnight', 'locked': false}},
      ],
      'staff_my_branches': [
        {'id': branchId, 'is_hq': false, 'name_ar': 'فرع المعادي', 'name_en': 'Maadi branch'},
      ],
    };


Map<String, Object> salesRpc() => {...cashierRpc()};
Map<String, Object> repairsRpc() => {...commonRpc()};
Map<String, Object> onlineRpc() => {...commonRpc()};
Map<String, Object> marketingRpc() => {...commonRpc()};
