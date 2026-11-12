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


List<Map<String, Object?>> orders() => [
      for (final (i, (ref, name, status, pay, fl, total, mins, items)) in const [
        ('MH-24117', 'منى خالد', 'pending_confirmation', 'cash_on_delivery', 'delivery', 37800, 12, [('شاحن سريع 25 واط', 'Fast charger 25W', 1, 24900), ('كابل Type-C مضفّر 1م', 'Braided Type-C cable 1m', 1, 11900)]),
        ('MH-24116', 'عمر سامي', 'pending_confirmation', 'wallet', 'pickup', 89900, 35, [('سماعة لاسلكية Pro', 'Wireless earbuds Pro', 1, 89900)]),
        ('MH-24115', 'سارة أحمد', 'confirmed', 'online', 'delivery', 19900, 80, [('باكدج حماية متكامل', 'Full protection bundle', 1, 19900)]),
        ('MH-24114', 'يوسف علي', 'preparing', 'cash_on_delivery', 'delivery', 14900, 140, [('حامل موبايل للعربية', 'Car phone holder', 1, 14900)]),
      ].indexed)
        {
          'id': '00000000-0000-4000-8000-00000000d${i}0e',
          'reference': ref,
          'customer_name': name,
          'customer_phone': '0101234567$i',
          'customer_email': null,
          'total_minor': total,
          'delivery_fee_minor': fl == 'delivery' ? 3000 : 0,
          'status': status,
          'fulfillment': fl,
          'payment_method': pay,
          'payment_status': pay == 'online' ? 'paid' : 'unpaid',
          'delivery_notes': i == 0 ? 'الدور التالت، رن الجرس' : null,
          'created_at': _ago(mins),
          'closed_at': null,
          'close_reason': null,
          'coupon_code': null,
          'coupon_discount_minor': 0,
          'branch_id': branchId,
          'branch_confirmed': i > 1,
          'branches': {'name_ar': 'فرع المعادي', 'name_en': 'Maadi branch'},
          'order_items': [
            for (final (ar, en, q, p) in items) {'name_ar': ar, 'name_en': en, 'quantity': q, 'unit_price_minor': p, 'line_total_minor': p * q},
          ],
          'cancel_requests': <Object>[],
        },
    ];

List<Map<String, Object?>> repairs() => [
      for (final (i, (ref, name, brand, model, problem, status, est, mins)) in const [
        ('RP-1042', 'محمود حسن', 'Apple', 'iPhone 13', 'الشاشة مكسورة واللمس مش شغال', 'initial_inspection', 0, 40),
        ('RP-1041', 'نورا عادل', 'Samsung', 'Galaxy A54', 'البطارية بتفضى بسرعة', 'awaiting_approval', 85000, 190),
        ('RP-1040', 'كريم سلامة', 'Xiaomi', 'Redmi Note 12', 'مدخل الشحن مش بيشحن', 'repair_in_progress', 35000, 600),
        ('RP-1039', 'هالة مصطفى', 'Apple', 'iPhone 11', 'تغيير ضهر', 'ready_for_pickup', 120000, 1500),
      ].indexed)
        {
          'id': '00000000-0000-4000-8000-00000000e${i}0e',
          'reference': ref,
          'contact_name': name,
          'contact_phone': '0122345678$i',
          'device_brand': brand,
          'device_model': model,
          'problem_description': problem,
          'status': status,
          'estimated_cost_minor': est == 0 ? null : est,
          'approved_cost_minor': status == 'repair_in_progress' || status == 'ready_for_pickup' ? est : null,
          'created_at': _ago(mins),
          'closed_at': null,
          'close_reason': null,
          'cancel_requests': <Object>[],
        },
    ];

const repairLabels = [
  ['pickup_requested', 'تم طلب الاستلام', 'Pickup requested'],
  ['received_at_branch', 'استلمنا جهازك', 'Device received'],
  ['initial_inspection', 'بيتفحص دلوقتي', 'Being checked'],
  ['diagnosis_completed', 'حددنا العطل', 'Fault found'],
  ['awaiting_approval', 'في انتظار موافقتك على التكلفة', 'Awaiting your approval'],
  ['repair_approved', 'تمت الموافقة على الصيانة', 'Repair approved'],
  ['repair_in_progress', 'بيتصلح دلوقتي', 'Being repaired'],
  ['waiting_for_parts', 'مستنيين قطعة الغيار', 'Waiting for parts'],
  ['quality_testing', 'بنختبره بعد الإصلاح', 'Final testing'],
  ['ready_for_pickup', 'اتصلح وجاهز تستلمه', 'Ready for pickup'],
  ['delivered', 'اتسلّم', 'Delivered'],
  ['cancelled', 'ملغي', 'Cancelled'],
  ['unrepairable', 'غير قابل للإصلاح', 'Unrepairable'],
];

List<Map<String, Object?>> productRows() => [
      for (final p in products)
        {
          ...p,
          'model': null,
          'warranty_ar': null,
          'warranty_en': null,
          'brand_id': null,
          'compare_at_price_minor': null,
          'status': 'published',
          'is_featured': false,
          'category_id': null,
          'brands': null,
          'product_images': <Object>[],
        },
    ];

Map<String, Object> salesRpc() => {
      ...cashierRpc(),
      'orders': orders(),
      'products': productRows(),
      'stock_overview': [
        for (final p in products)
          {'sku': p['sku'], 'total': p['stock_quantity'], 'name_ar': p['name_ar'], 'name_en': p['name_en'], 'product_id': p['id'],
            'branches': [{'qty': p['stock_quantity'], 'branch_id': branchId}], 'unallocated': 0},
      ],
      'stock_transfers_list': <Object>[],
    };

Map<String, Object> repairsRpc() => {
      ...commonRpc(),
      'assistant_flags': {'available': false},
      'repair_requests': repairs(),
      'repair_status_labels': [
        for (final (i, l) in repairLabels.indexed) {'status': l[0], 'label_ar': l[1], 'label_en': l[2], 'message_ar': '', 'message_en': '', 'sort_order': i + 1},
      ],
    };

Map<String, Object> onlineRpc() => {
      ...repairsRpc(),
      'orders': orders(),
      'staff_accounts': <Object>[],
      'assistant_flags': {'available': true, 'find': true},
      'assistant_state': {
        'guard': {'enabled': true},
        'cashier': {'enabled': true},
        'support': {
          'enabled': true,
          'log': [
            {'at': _ago(20), 'kind': 'order_pending', 'text': 'نبّهت الفريق إن الطلب MH-24117 لسه مستني التأكيد'},
            {'at': _ago(95), 'kind': 'order_pending', 'text': 'نبّهت الفريق إن الطلب MH-24116 لسه مستني التأكيد'},
          ],
        },
      },
    };

Map<String, Object> marketingRpc() => {
      ...commonRpc(),
      'assistant_flags': {'available': false},
      'product_reviews': <Object>[],
      'marketing_overview': {'new_30d': 48, 'reviews': 31, 'opted_in': 112, 'customers': 640, 'buyers_30d': 96, 'orders_30d': 154, 'rating_avg': 4.7, 'repeat_rate': 38,
        'revenue_30d': 18450000, 'new_prev_30d': 41, 'points_total': 51708, 'campaigns_30d': 3, 'promo_read_30d': 220, 'promo_sent_30d': 470, 'coupon_uses_30d': 27,
        'reviews_pending': 2, 'wheel_spins_30d': 85, 'revenue_prev_30d': 16100000, 'coupon_discount_30d': 152000},
      'marketing_segments': [
        {'key': 'all', 'count': 640, 'reachable': 112}, {'key': 'opted_in', 'count': 112, 'reachable': 112}, {'key': 'new', 'count': 48, 'reachable': 20},
        {'key': 'never', 'count': 210, 'reachable': 14}, {'key': 'active', 'count': 160, 'reachable': 70}, {'key': 'dormant', 'count': 95, 'reachable': 22},
        {'key': 'vip', 'count': 34, 'reachable': 18}, {'key': 'points', 'count': 120, 'reachable': 40},
      ],
      'marketing_segment_sample': <Object>[],
      'marketing_requests_list': [
        {'id': '00000000-0000-4000-8000-0000000000f1', 'kind': 'coupon', 'mine': true, 'note': null, 'sort': '1', 'title': 'كود EID20', 'result': {'code': 'EID20'}, 'status': 'approved',
          'details': {'code': 'EID20', 'ends_at': null, 'max_uses': 50, 'title_ar': 'خصم العيد', 'percent_off': 20, 'min_order_minor': 50000}, 'requester': 'أحمد',
          'decided_at': _ago(300), 'requested_at': _ago(330)},
      ],
      'marketing_coupon_performance': [
        {'code': 'EID20', 'title': 'خصم العيد', 'ends_at': null, 'max_uses': 50, 'is_active': true, 'uses_count': 18, 'percent_off': 20, 'revenue_minor': 4120000, 'discount_minor': 82400, 'amount_off_minor': null},
        {'code': 'WELCOME10', 'title': 'أول طلب', 'ends_at': null, 'max_uses': null, 'is_active': true, 'uses_count': 9, 'percent_off': 10, 'revenue_minor': 1350000, 'discount_minor': 13500, 'amount_off_minor': null},
      ],
      'marketing_campaigns_list': <Object>[],
      'contest_admin_list': <Object>[],
      'banners': [
        {'id': '00000000-0000-4000-8000-0000000000b9', 'badge': 'عرض خاص', 'color': 'blue', 'emoji': '🛡️', 'style': 'product', 'cta_ar': null, 'cta_en': null, 'ends_at': _ago(-60 * 24 * 3),
          'title_ar': 'عروض الإسكرينات', 'title_en': 'Screen protector deals', 'is_active': true, 'link_type': null, 'starts_at': _ago(60 * 24), 'created_at': _ago(60 * 24), 'image_path': null,
          'link_value': null, 'price_text': null, 'sort_order': 0, 'product_ids': [products[0]['id'], products[1]['id']], 'subtitle_ar': 'لحد آخر الأسبوع', 'subtitle_en': 'Until the end of the week', 'old_price_text': null},
      ],
    };
