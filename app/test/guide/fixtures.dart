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
