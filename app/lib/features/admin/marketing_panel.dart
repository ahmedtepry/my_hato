import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:supabase_flutter/supabase_flutter.dart' show FileOptions;

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/money.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../shared/motion.dart';
import '../../shared/product_card.dart' show NetImage;
import '../../shared/states.dart';
import 'admin_repository.dart';

String _t(BuildContext c, String ar, String en) => c.isAr ? ar : en;

// ============================================================================================ data
Future<dynamic> _rpc(Ref ref, String fn, [Map<String, dynamic>? params]) => ref.read(supabaseProvider).rpc(fn, params: params);

final _mkOverviewProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async => Map<String, dynamic>.from(await _rpc(ref, 'marketing_overview') as Map));
final _mkSegmentsProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async => [for (final e in (await _rpc(ref, 'marketing_segments')) as List) Map<String, dynamic>.from(e as Map)]);
final _mkCampaignsProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async => [for (final e in (await _rpc(ref, 'marketing_campaigns_list')) as List) Map<String, dynamic>.from(e as Map)]);
final _mkCouponsProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async => [for (final e in (await _rpc(ref, 'marketing_coupon_performance')) as List) Map<String, dynamic>.from(e as Map)]);
final _mkSampleProvider = FutureProvider.autoDispose.family<List<Map<String, dynamic>>, String>((ref, seg) async => [for (final e in (await _rpc(ref, 'marketing_segment_sample', {'p_segment': seg, 'p_limit': 6})) as List) Map<String, dynamic>.from(e as Map)]);

final _mkRequestsProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async => [for (final e in (await _rpc(ref, 'marketing_requests_list')) as List) Map<String, dynamic>.from(e as Map)]);
final _mkProductsProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async => List<Map<String, dynamic>>.from(await ref.read(supabaseProvider).from('products').select('id, name_ar, name_en').order('name_ar').limit(300)));

num _n(Map m, String k) => (m[k] as num?) ?? 0;

class _Seg {
  const _Seg(this.key, this.ar, this.en, this.hintAr, this.hintEn, this.icon, this.color, this.title, this.body);
  final String key, ar, en, hintAr, hintEn, title, body;
  final IconData icon;
  final Color color;
}

const _segs = <_Seg>[
  _Seg('all', 'كل العملاء', 'Everyone', 'كل اللي سجّلوا في التطبيق', 'Everyone signed up', Icons.groups_rounded, Color(0xFF00A3FF), 'عروض الأسبوع في My Hatō', 'اتفرج على أحدث العروض والمنتجات الجديدة قبل ما تخلص.'),
  _Seg('opted_in', 'مفعّلين الإشعارات', 'Opted in', 'وافقوا يوصلهم عروض', 'Agreed to get offers', Icons.notifications_active_rounded, Color(0xFF12B76A), 'عرض ليك إنت بس', 'جهزنا لك خصم خاص. افتح التطبيق وشوفه.'),
  _Seg('new', 'عملاء جداد', 'New', 'اشتركوا آخر 14 يوم', 'Joined in the last 14 days', Icons.waving_hand_rounded, Color(0xFF7A5AF8), 'أهلاً بيك في My Hatō', 'نورتنا! اطلب أول أوردر وخد خصم الترحيب.'),
  _Seg('never', 'سجّلوا ومشتروش', 'Never ordered', 'عندهم حساب وما طلبوش', 'Have an account, no order yet', Icons.shopping_bag_outlined, Color(0xFFF08A12), 'أول طلب ليك عليه خصم', 'لسه ما جرّبتش تطلب؟ معاك كود خصم على أول أوردر.'),
  _Seg('active', 'نشطين', 'Active', 'اشتروا آخر 30 يوم', 'Ordered in the last 30 days', Icons.local_fire_department_rounded, Color(0xFFE5484D), 'وصل جديد ليك', 'منتجات جديدة وصلت. شوفها قبل الباقي.'),
  _Seg('dormant', 'ساكتين', 'Dormant', 'من 60 يوم أو أكتر من غير شراء', '60+ days without an order', Icons.bedtime_outlined, Color(0xFF667085), 'وحشتنا! ارجع واخد خصم', 'بقالك فترة ما طلبتش. جهزنا لك كود خصم يستناك.'),
  _Seg('vip', 'VIP', 'VIP', '5 طلبات أو إنفاق 5000 ج وأكتر', '5+ orders or 5,000+ spent', Icons.workspace_premium_rounded, Color(0xFFD9A400), 'عرض لعملائنا المميزين', 'إنت من أهم عملائنا، وده عرض خاص بيك قبل الكل.'),
  _Seg('points', 'نقاط عالية', 'High points', '500 نقطة وأكتر', '500+ points', Icons.stars_rounded, Color(0xFF1F5FD6), 'نقاطك جاهزة تتحول لهدية', 'عندك نقاط كفاية تستبدلها بهدية. افتح المكافآت.'),
];

// ============================================================================================ panel
class MarketingPanel extends ConsumerStatefulWidget {
  const MarketingPanel({super.key, this.onOffers});

  /// Opens the discount-codes page (kept where it already lives).
  final VoidCallback? onOffers;

  @override
  ConsumerState<MarketingPanel> createState() => _MarketingPanelState();
}

class _MarketingPanelState extends ConsumerState<MarketingPanel> {
  String _seg = 'never';
  String? _coupon;
  bool _viaApp = true, _viaEmail = false;
  bool _busy = false;
  final _name = TextEditingController();
  final _title = TextEditingController();
  final _body = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  void _pick(String key) {
    final s = _segs.firstWhere((e) => e.key == key);
    setState(() => _seg = key);
    if (_title.text.trim().isEmpty && _body.text.trim().isEmpty) _template(s);
  }

  void _template(_Seg s) {
    _title.text = s.title;
    _body.text = s.body;
    if (_name.text.trim().isEmpty) _name.text = '${s.ar} · ${DateFormat('d/M').format(DateTime.now())}';
  }

  void _refresh() {
    ref.invalidate(_mkOverviewProvider);
    ref.invalidate(_mkSegmentsProvider);
    ref.invalidate(_mkCampaignsProvider);
    ref.invalidate(_mkCouponsProvider);
    ref.invalidate(_mkRequestsProvider);
  }

  Future<void> _send(int reachable) async {
    final seg = _segs.firstWhere((e) => e.key == _seg);
    if (_name.text.trim().isEmpty || _title.text.trim().isEmpty || _body.text.trim().isEmpty) {
      showSnack(context, _t(context, 'اكتب اسم الحملة والعنوان والنص', 'Write the campaign name, title and text'), error: true);
      return;
    }
    if (!_viaApp && !_viaEmail) {
      showSnack(context, _t(context, 'اختار طريقة الإرسال: إشعار أو إيميل', 'Pick how to send: notification or email'), error: true);
      return;
    }
    final canSend = ref.read(staffContextProvider).valueOrNull?.permissions.contains('marketing.campaigns') ?? false;
    if (!canSend) {
      setState(() => _busy = true);
      try {
        await ref.read(supabaseProvider).rpc('marketing_request_create', params: {
          'p_kind': 'campaign',
          'p_title': _name.text.trim(),
          'p_details': {'name': _name.text.trim(), 'segment': _seg, 'title': _title.text.trim(), 'body': _body.text.trim(), 'coupon_code': _coupon},
        });
        if (!mounted) return;
        showSnack(context, _t(context, 'اتبعتت للمالك للموافقة. مش هتتبعت للعملاء غير بعد موافقته ✅', 'Sent to the owner for approval. It reaches customers only after he approves ✅'));
        _name.clear();
        _title.clear();
        _body.clear();
        setState(() => _coupon = null);
        _refresh();
      } catch (e) {
        if (mounted) showSnack(context, friendlyError(context, e), error: true);
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      return;
    }
    final ok = await showSmoothDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_t(ctx, 'تبعت الحملة؟', 'Send this campaign?')),
        content: Text(_t(ctx, 'هتوصل لـ $reachable عميل من شريحة «${seg.ar}». مش هينفع تتسحب بعد الإرسال.', 'It will reach $reachable customers in "${seg.en}". It cannot be recalled once sent.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(_t(ctx, 'إلغاء', 'Cancel'))),
          FilledButton(style: FilledButton.styleFrom(minimumSize: const Size(110, 44)), onPressed: () => Navigator.pop(ctx, true), child: Text(_t(ctx, 'ابعت', 'Send'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final params = {'p_name': _name.text.trim(), 'p_segment': _seg, 'p_title': _title.text.trim(), 'p_body': _body.text.trim(), 'p_coupon_code': _coupon};
      Map<String, dynamic>? r;
      Map<String, dynamic>? em;
      if (_viaApp) r = Map<String, dynamic>.from(await ref.read(supabaseProvider).rpc('marketing_send_campaign', params: params) as Map);
      if (_viaEmail) em = Map<String, dynamic>.from(await ref.read(supabaseProvider).rpc('marketing_send_campaign_email', params: params) as Map);
      if (!mounted) return;
      showSnack(
          context,
          [
            if (r != null) _t(context, 'إشعار اتبعت لـ ${r['sent']} عميل', 'Notification sent to ${r['sent']} customers'),
            if (em != null) _t(context, 'إيميل اتحط في الطابور لـ ${em['queued']} عميل', 'Email queued for ${em['queued']} customers'),
          ].join(' · ') + ' ✅');
      _name.clear();
      _title.clear();
      _body.clear();
      setState(() => _coupon = null);
      _refresh();
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final perms = ref.watch(staffContextProvider).valueOrNull?.permissions ?? const <String>{};
    final canSend = perms.contains('marketing.campaigns');
    final canRequest = perms.contains('marketing.request');
    final canApprove = perms.contains('marketing.approve');
    final canAnalytics = perms.contains('marketing.analytics');
    final canNames = perms.contains('marketing.segments');
    final ov = ref.watch(_mkOverviewProvider);
    final segs = ref.watch(_mkSegmentsProvider).valueOrNull ?? const <Map<String, dynamic>>[];
    final coupons = ref.watch(_mkCouponsProvider).valueOrNull ?? const <Map<String, dynamic>>[];
    int countOf(String k, String f) {
      for (final s in segs) {
        if (s['key'] == k) return ((s[f] as num?) ?? 0).toInt();
      }
      return 0;
    }

    return RefreshIndicator(
      onRefresh: () async => _refresh(),
      child: ListView(padding: const EdgeInsets.fromLTRB(28, 22, 28, 40), children: [
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_t(context, 'لوحة التسويق', 'Marketing'), style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: inkColor(context))),
              Text(_t(context, 'مين عملاؤنا، مين محتاج رسالة، وإيه اللي نفع. آخر 30 يوم.', 'Who our customers are, who needs a message, and what worked. Last 30 days.'), style: const TextStyle(color: BrandColors.gray)),
            ]),
          ),
          if (canRequest)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 10),
              child: FilledButton.icon(
                style: FilledButton.styleFrom(minimumSize: const Size(0, 44), padding: const EdgeInsets.symmetric(horizontal: 18)),
                onPressed: () async {
                  final done = await showSmoothDialog<bool>(context: context, builder: (_) => const _IdeaDialog());
                  if (done == true) _refresh();
                },
                icon: const Icon(Icons.lightbulb_outline_rounded),
                label: Text(_t(context, 'فكرة جديدة', 'New idea')),
              ),
            ),
          if (widget.onOffers != null)
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44), padding: const EdgeInsets.symmetric(horizontal: 18)),
              onPressed: widget.onOffers,
              icon: const Icon(Icons.local_offer_outlined),
              label: Text(_t(context, 'أكواد الخصم', 'Discount codes')),
            ),
          IconButton(tooltip: _t(context, 'تحديث', 'Refresh'), onPressed: _refresh, icon: const Icon(Icons.refresh_rounded)),
        ]),
        const SizedBox(height: 18),
        if (canRequest || canApprove) ...[
          _RequestsSection(canApprove: canApprove, onChanged: _refresh),
          const SizedBox(height: 18),
        ],
        ov.when(
          loading: () => const SizedBox(height: 160, child: Center(child: CircularProgressIndicator())),
          error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(_mkOverviewProvider)),
          data: (o) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _kpis(context, o),
            const SizedBox(height: 16),
            _insights(context, o, coupons, countOf('never', 'count'), countOf('dormant', 'count')),
          ]),
        ),
        const SizedBox(height: 22),
        _heading(context, _t(context, 'شرايح العملاء', 'Customer segments'), _t(context, 'اختار شريحة وابعتلها رسالة مناسبة لحالتها', 'Pick a segment and send a message that fits it')),
        const SizedBox(height: 10),
        Wrap(spacing: 12, runSpacing: 12, children: [
          for (final s in _segs)
            _SegCard(
              seg: s,
              count: countOf(s.key, 'count'),
              reachable: countOf(s.key, 'reachable'),
              selected: _seg == s.key,
              onTap: () => _pick(s.key),
            ),
        ]),
        if (canNames) _Sample(seg: _seg),
        const SizedBox(height: 22),
        if (canSend || canRequest) _composer(context, coupons, countOf(_seg, 'reachable'), countOf(_seg, 'count'), canSend),
        if (canAnalytics) ...[
          const SizedBox(height: 22),
          _heading(context, _t(context, 'نتايج الحملات', 'Campaign results'), _t(context, 'القراءة والاستخدام والإيراد لكل حملة', 'Reads, uses and revenue per campaign')),
          const SizedBox(height: 10),
          _campaigns(context),
          const SizedBox(height: 22),
          _heading(context, _t(context, 'أداء أكواد الخصم', 'Discount code performance'), _t(context, 'كل كود كسّب قد إيه وكلّف قد إيه', 'What each code earned and cost')),
          const SizedBox(height: 10),
          _couponTable(context, coupons),
        ],
      ]),
    );
  }

  Widget _heading(BuildContext c, String t, String s) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(t, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: inkColor(context))),
        Text(s, style: const TextStyle(color: BrandColors.gray, fontSize: 13)),
      ]);

  Widget _card(Widget child, {EdgeInsets padding = const EdgeInsets.all(18)}) => Container(
        padding: padding,
        decoration: BoxDecoration(color: panelColor(context), borderRadius: BorderRadius.circular(18), border: Border.all(color: panelLine(context))),
        child: child,
      );

  // -------------------------------------------------------------------------------- KPIs
  Widget _kpis(BuildContext c, Map<String, dynamic> o) {
    String pct(num cur, num prev) => prev == 0 ? '' : '${cur >= prev ? '+' : ''}${((cur - prev) / prev * 100).round()}%';
    final sent = _n(o, 'promo_sent_30d'), read = _n(o, 'promo_read_30d');
    final customers = _n(o, 'customers');
    final tiles = <(String, String, String?, bool)>[
      (_t(c, 'عملاء', 'Customers'), '${_n(o, 'customers')}', null, true),
      (_t(c, 'جداد آخر 30 يوم', 'New in 30 days'), '${_n(o, 'new_30d')}', pct(_n(o, 'new_30d'), _n(o, 'new_prev_30d')), _n(o, 'new_30d') >= _n(o, 'new_prev_30d')),
      (_t(c, 'مفعّلين الإشعارات', 'Opted in'), customers == 0 ? '0%' : '${(_n(o, 'opted_in') / customers * 100).round()}%', '${_n(o, 'opted_in')} ${_t(c, 'من', 'of')} ${_n(o, 'customers')}', _n(o, 'opted_in') / (customers == 0 ? 1 : customers) >= 0.5),
      (_t(c, 'إيراد 30 يوم', 'Revenue 30d'), formatEgp(_n(o, 'revenue_30d').toInt(), c.lang), pct(_n(o, 'revenue_30d'), _n(o, 'revenue_prev_30d')), _n(o, 'revenue_30d') >= _n(o, 'revenue_prev_30d')),
      (_t(c, 'عملاء اشتروا', 'Buyers'), '${_n(o, 'buyers_30d')}', '${_n(o, 'orders_30d')} ${_t(c, 'طلب', 'orders')}', true),
      (_t(c, 'بيرجعوا يشتروا تاني', 'Repeat rate'), '${_n(o, 'repeat_rate')}%', null, _n(o, 'repeat_rate') >= 30),
      (_t(c, 'قراءة العروض', 'Offer read rate'), sent == 0 ? '—' : '${(read / sent * 100).round()}%', '${read.toInt()} ${_t(c, 'من', 'of')} ${sent.toInt()}', sent == 0 || read / sent >= 0.3),
      (_t(c, 'استخدام الأكواد', 'Code uses'), '${_n(o, 'coupon_uses_30d')}', formatEgp(_n(o, 'coupon_discount_30d').toInt(), c.lang), true),
    ];
    return Wrap(spacing: 12, runSpacing: 12, children: [
      for (final t in tiles)
        SizedBox(
          width: 230,
          child: _card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.$1, style: const TextStyle(color: BrandColors.gray, fontSize: 13)),
            const SizedBox(height: 4),
            FittedBox(fit: BoxFit.scaleDown, alignment: AlignmentDirectional.centerStart, child: CountUpText(t.$2, style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: inkColor(context)))),
            const SizedBox(height: 4),
            Text((t.$3 ?? ' ').isEmpty ? ' ' : (t.$3 ?? ' '), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: t.$4 ? BrandColors.success : BrandColors.error)),
          ])),
        ),
    ]);
  }

  // -------------------------------------------------------------------------------- insights
  Widget _insights(BuildContext c, Map<String, dynamic> o, List<Map<String, dynamic>> coupons, int never, int dormant) {
    final customers = _n(o, 'customers');
    final tips = <(IconData, Color, String)>[];
    if (customers > 0 && _n(o, 'opted_in') / customers < 0.5) {
      tips.add((Icons.notifications_off_outlined, const Color(0xFFF08A12), _t(c, 'أقل من نص العملاء مفعّلين الإشعارات (${_n(o, 'opted_in')} من $customers). اطلب منهم يفعّلوها بعرض صغير جوه التطبيق، لأن الحملات بتوصل لهم بس.', 'Fewer than half of customers allow promotions (${_n(o, 'opted_in')} of $customers). Campaigns only reach them.')));
    }
    if (never > 0 && customers > 0 && never / customers >= 0.3) {
      tips.add((Icons.shopping_bag_outlined, const Color(0xFF7A5AF8), _t(c, '$never عميل سجّلوا ومشتروش. جرّب كود ترحيب على أول طلب لشريحة «سجّلوا ومشتروش».', '$never customers signed up without ordering. Try a welcome code for them.')));
    }
    if (coupons.isNotEmpty && coupons.every((e) => e['is_active'] != true)) {
      tips.add((Icons.local_offer_outlined, const Color(0xFFE5484D), _t(c, 'كل أكواد الخصم منتهية أو موقوفة. اعمل كود جديد قبل أي حملة.', 'Every discount code is expired or off. Create a new one before a campaign.')));
    }
    if (dormant > 0) {
      tips.add((Icons.bedtime_outlined, const Color(0xFF667085), _t(c, '$dormant عميل ساكتين من 60 يوم. رسالة «وحشتنا» مع كود هي أرخص طريقة ترجّعهم.', '$dormant customers have been quiet for 60 days. A win-back message with a code is the cheapest way back.')));
    }
    if (_n(o, 'reviews') == 0) {
      tips.add((Icons.star_border_rounded, const Color(0xFFD9A400), _t(c, 'مفيش تقييمات لسه. اطلب من أول عملاء يقيّموا، التقييمات بتزوّد ثقة العملاء الجداد.', 'No reviews yet. Ask early customers to rate; reviews build trust.')));
    }
    if (_n(o, 'campaigns_30d') == 0) {
      tips.add((Icons.campaign_outlined, const Color(0xFF00A3FF), _t(c, 'ما بعتّش حملة آخر 30 يوم. ابعت حملة أسبوعية لشريحة «نشطين» عشان تفضل في بالهم.', 'No campaign in the last 30 days. A weekly one to "Active" keeps you in mind.')));
    }
    if (tips.isEmpty) return const SizedBox.shrink();
    return _card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Icon(Icons.tips_and_updates_outlined, color: BrandColors.electric),
        const SizedBox(width: 8),
        Text(_t(c, 'توصيات من الأرقام', 'Recommendations from the numbers'), style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: inkColor(context))),
      ]),
      const SizedBox(height: 8),
      for (final t in tips)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(width: 34, height: 34, decoration: BoxDecoration(color: t.$2.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(10)), child: Icon(t.$1, size: 19, color: t.$2)),
            const SizedBox(width: 12),
            Expanded(child: Padding(padding: const EdgeInsets.only(top: 6), child: Text(t.$3, style: const TextStyle(height: 1.5)))),
          ]),
        ),
    ]));
  }

  // -------------------------------------------------------------------------------- composer
  Widget _composer(BuildContext c, List<Map<String, dynamic>> coupons, int reachable, int total, bool canSend) {
    final seg = _segs.firstWhere((e) => e.key == _seg);
    final active = [for (final e in coupons) if (e['is_active'] == true && (e['ends_at'] == null || DateTime.parse('${e['ends_at']}').isAfter(DateTime.now()))) e];
    return _card(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Icon(seg.icon, color: seg.color),
        const SizedBox(width: 8),
        Expanded(child: Text(canSend ? _t(c, 'حملة جديدة لشريحة «${seg.ar}»', 'New campaign to "${seg.en}"') : _t(c, 'اقتراح حملة لشريحة «${seg.ar}» (بعد موافقة المالك)', 'Propose a campaign to "${seg.en}" (after owner approval)'), style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: inkColor(context)))),
        TextButton.icon(onPressed: () => setState(() => _template(seg)), icon: const Icon(Icons.auto_fix_high_rounded, size: 18), label: Text(_t(c, 'اقتراح نص', 'Suggest text'))),
      ]),
      const SizedBox(height: 10),
      TextField(controller: _name, decoration: InputDecoration(labelText: _t(c, 'اسم الحملة (ليك إنت)', 'Campaign name (for you)'))),
      const SizedBox(height: 10),
      TextField(controller: _title, maxLength: 120, decoration: InputDecoration(labelText: _t(c, 'عنوان الإشعار', 'Notification title'))),
      TextField(controller: _body, maxLength: 500, minLines: 2, maxLines: 4, decoration: InputDecoration(labelText: _t(c, 'النص', 'Message'))),
      const SizedBox(height: 6),
      Text(_t(c, 'تتبعت عن طريق', 'Send through'), style: const TextStyle(fontWeight: FontWeight.w700)),
      const SizedBox(height: 6),
      Wrap(spacing: 8, children: [
        FilterChip(avatar: const Icon(Icons.notifications_active_outlined, size: 18), label: Text(_t(c, 'إشعار في التطبيق', 'App notification')), selected: _viaApp, onSelected: (v) => setState(() => _viaApp = v)),
        FilterChip(avatar: const Icon(Icons.email_outlined, size: 18), label: Text(_t(c, 'إيميل', 'Email')), selected: _viaEmail, onSelected: (v) => setState(() => _viaEmail = v)),
      ]),
      if (_viaEmail)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(_t(c, 'الإيميل بيروح بس للعملاء اللي وافقوا على العروض وإيميلهم متأكد (بحد أقصى 500 عميل، وحملتين إيميل في اليوم). بيتبعت أول ما يتفعّل مفتاح الإرسال.', 'Email only goes to customers who accepted offers and have a verified email (max 500, two email campaigns a day). It is sent once the sending key is active.'),
              style: const TextStyle(fontSize: 12, color: Color(0xFF667085), height: 1.5)),
        ),
      const SizedBox(height: 6),
      DropdownButtonFormField<String?>(
        value: _coupon != null && active.any((e) => e['code'] == _coupon) ? _coupon : null,
        decoration: InputDecoration(labelText: _t(c, 'كود خصم مع الرسالة (اختياري)', 'Discount code with the message (optional)')),
        items: [
          DropdownMenuItem<String?>(value: null, child: Text(_t(c, 'من غير كود', 'No code'))),
          for (final e in active) DropdownMenuItem<String?>(value: '${e['code']}', child: Text('${e['code']} · ${e['percent_off'] != null ? '${e['percent_off']}%' : formatEgp(((e['amount_off_minor'] as num?) ?? 0).toInt(), c.lang)}')),
        ],
        onChanged: (v) => setState(() => _coupon = v),
      ),
      const SizedBox(height: 14),
      Row(children: [
        Expanded(
          child: Text(
            reachable == 0
                ? _t(c, 'مفيش حد في الشريحة دي مفعّل الإشعارات، فمش هتوصل لحد.', 'Nobody in this segment allows promotions, so nobody would receive it.')
                : _t(c, 'هتوصل لـ $reachable من $total (اللي مفعّلين الإشعارات). الحد 5 حملات في اليوم.', 'Reaches $reachable of $total (those who allow promotions). Limit: 5 campaigns a day.'),
            style: TextStyle(color: reachable == 0 ? BrandColors.error : BrandColors.gray, fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(width: 12),
        FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size(0, 48), padding: const EdgeInsets.symmetric(horizontal: 26)),
          onPressed: _busy || reachable == 0 ? null : () => _send(reachable),
          icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.send_rounded),
          label: Text(canSend ? _t(c, 'ابعت الحملة', 'Send campaign') : _t(c, 'ابعتها للمالك للموافقة', 'Send to the owner for approval')),
        ),
      ]),
    ]));
  }

  // -------------------------------------------------------------------------------- results
  Widget _campaigns(BuildContext c) {
    final list = ref.watch(_mkCampaignsProvider);
    return list.when(
      loading: () => const SizedBox(height: 80, child: Center(child: CircularProgressIndicator())),
      error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(_mkCampaignsProvider)),
      data: (rows) {
        if (rows.isEmpty) return _card(Text(_t(c, 'لسه ما بعتّش حملات. أول حملة هتظهر هنا بنتايجها.', 'No campaigns yet. The first one will show here with its results.'), style: const TextStyle(color: BrandColors.gray)));
        const head = TextStyle(color: BrandColors.gray, fontSize: 12.5);
        return _card(
          Column(children: [
            Row(children: [
              Expanded(flex: 4, child: Text(_t(c, 'الحملة', 'Campaign'), style: head)),
              Expanded(flex: 2, child: Text(_t(c, 'اتبعت لـ', 'Sent'), style: head)),
              Expanded(flex: 2, child: Text(_t(c, 'اتقرت', 'Read'), style: head)),
              Expanded(flex: 2, child: Text(_t(c, 'استخدام الكود', 'Code uses'), style: head)),
              Expanded(flex: 2, child: Text(_t(c, 'إيراد', 'Revenue'), style: head)),
            ]),
            for (final r in rows)
              Container(
                padding: const EdgeInsets.symmetric(vertical: 11),
                decoration: const BoxDecoration(border: Border(top: BorderSide(color: Color(0xFFEFF1F5)))),
                child: Row(children: [
                  Expanded(
                    flex: 4,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${r['name']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w800, color: inkColor(context))),
                      Text('${_segs.firstWhere((s) => s.key == r['segment'], orElse: () => _segs.first).label(c)} · ${DateFormat('d/M HH:mm').format(DateTime.parse('${r['created_at']}').toLocal())}', style: const TextStyle(fontSize: 12, color: BrandColors.gray)),
                    ]),
                  ),
                  Expanded(flex: 2, child: Text('${r['sent']}', style: const TextStyle(fontWeight: FontWeight.w700))),
                  Expanded(flex: 2, child: Text((r['sent'] as num) == 0 ? '—' : '${r['reads']} (${((r['reads'] as num) / (r['sent'] as num) * 100).round()}%)', style: const TextStyle(fontWeight: FontWeight.w700))),
                  Expanded(flex: 2, child: Text(r['coupon'] == null ? '—' : '${r['uses']} · ${r['coupon']}', style: const TextStyle(fontWeight: FontWeight.w700))),
                  Expanded(flex: 2, child: Text(r['coupon'] == null ? '—' : formatEgp(((r['revenue_minor'] as num?) ?? 0).toInt(), c.lang), style: const TextStyle(fontWeight: FontWeight.w700))),
                ]),
              ),
          ]),
        );
      },
    );
  }

  Widget _couponTable(BuildContext c, List<Map<String, dynamic>> rows) {
    if (rows.isEmpty) return _card(Text(_t(c, 'مفيش أكواد خصم لسه.', 'No discount codes yet.'), style: const TextStyle(color: BrandColors.gray)));
    return _card(Column(children: [
      for (var i = 0; i < rows.length; i++)
        Container(
          padding: const EdgeInsets.symmetric(vertical: 11),
          decoration: BoxDecoration(border: i == 0 ? null : const Border(top: BorderSide(color: Color(0xFFEFF1F5)))),
          child: Row(children: [
            Expanded(
              flex: 3,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${rows[i]['code']}', textDirection: TextDirection.ltr, textAlign: TextAlign.start, style: TextStyle(fontWeight: FontWeight.w900, color: inkColor(context))),
                Text('${rows[i]['title'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: BrandColors.gray)),
              ]),
            ),
            Expanded(flex: 2, child: Text(rows[i]['percent_off'] != null ? '${rows[i]['percent_off']}%' : formatEgp(((rows[i]['amount_off_minor'] as num?) ?? 0).toInt(), c.lang))),
            Expanded(flex: 2, child: Text('${rows[i]['uses_count']}${rows[i]['max_uses'] != null ? ' / ${rows[i]['max_uses']}' : ''} ${_t(c, 'استخدام', 'uses')}')),
            Expanded(flex: 2, child: Text('${_t(c, 'خصم', 'Cost')} ${formatEgp(((rows[i]['discount_minor'] as num?) ?? 0).toInt(), c.lang)}', style: const TextStyle(color: BrandColors.gray))),
            Expanded(flex: 2, child: Text('${_t(c, 'إيراد', 'Revenue')} ${formatEgp(((rows[i]['revenue_minor'] as num?) ?? 0).toInt(), c.lang)}', style: const TextStyle(fontWeight: FontWeight.w700))),
            StatusChip(
              label: rows[i]['is_active'] == true ? _t(c, 'شغال', 'Active') : _t(c, 'منتهي', 'Off'),
              color: rows[i]['is_active'] == true ? BrandColors.success : BrandColors.gray,
            ),
          ]),
        ),
    ]));
  }
}

extension on _Seg {
  String label(BuildContext c) => c.isAr ? ar : en;
}

class _SegCard extends StatelessWidget {
  const _SegCard({required this.seg, required this.count, required this.reachable, required this.selected, required this.onTap});
  final _Seg seg;
  final int count, reachable;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          width: 230,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: selected ? seg.color.withValues(alpha: 0.09) : Colors.white,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: selected ? seg.color : BrandColors.border, width: selected ? 2 : 1),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(width: 34, height: 34, decoration: BoxDecoration(color: seg.color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(10)), child: Icon(seg.icon, size: 19, color: seg.color)),
              const SizedBox(width: 10),
              Expanded(child: Text(seg.label(context), style: TextStyle(fontWeight: FontWeight.w800, color: inkColor(context)))),
            ]),
            const SizedBox(height: 10),
            CountUpText('$count', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: inkColor(context))),
            Text(_t(context, seg.hintAr, seg.hintEn), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: BrandColors.gray)),
            const SizedBox(height: 4),
            Text(_t(context, 'يوصل لـ $reachable', 'Reaches $reachable'), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: reachable == 0 ? BrandColors.error : BrandColors.success)),
          ]),
        ),
      );
}

class _Sample extends ConsumerWidget {
  const _Sample({required this.seg});
  final String seg;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(_mkSampleProvider(seg)).valueOrNull ?? const <Map<String, dynamic>>[];
    if (rows.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: panelColor(context), borderRadius: BorderRadius.circular(16), border: Border.all(color: panelLine(context))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_t(context, 'عينة من الشريحة (الأكتر إنفاقًا الأول)', 'Sample of this segment (top spenders first)'), style: TextStyle(fontWeight: FontWeight.w800, color: inkColor(context))),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final r in rows)
              Chip(
                avatar: const Icon(Icons.person_outline_rounded, size: 18),
                label: Text('${(r['name'] as String?)?.trim().isNotEmpty == true ? r['name'] : _t(context, 'بدون اسم', 'No name')} · ${r['orders']} ${_t(context, 'طلب', 'orders')} · ${formatEgp(((r['spent_minor'] as num?) ?? 0).toInt(), context.lang)}'),
              ),
          ]),
        ]),
      ),
    );
  }
}

// ============================================================================================ requests (nothing goes live without the owner)
String _kindAr(String k) => switch (k) { 'banner' => 'بانر', 'coupon' => 'كود خصم', 'campaign' => 'حملة', _ => 'فكرة' };
String _kindEn(String k) => switch (k) { 'banner' => 'Banner', 'coupon' => 'Discount code', 'campaign' => 'Campaign', _ => 'Idea' };
IconData _kindIcon(String k) => switch (k) { 'banner' => Icons.image_outlined, 'coupon' => Icons.local_offer_outlined, 'campaign' => Icons.campaign_outlined, _ => Icons.lightbulb_outline_rounded };

class _RequestsSection extends ConsumerWidget {
  const _RequestsSection({required this.canApprove, required this.onChanged});
  final bool canApprove;
  final VoidCallback onChanged;

  Future<void> _decide(BuildContext context, WidgetRef ref, Map<String, dynamic> r, bool approve) async {
    final note = TextEditingController();
    final ok = await showSmoothDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(approve ? _t(ctx, 'توافق وتفعّل؟', 'Approve and activate?') : _t(ctx, 'ترفض الطلب؟', 'Reject this request?')),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${_t(ctx, _kindAr('${r['kind']}'), _kindEn('${r['kind']}'))}: ${r['title']}', style: const TextStyle(fontWeight: FontWeight.w800)),
            if (approve && r['kind'] != 'idea') Padding(padding: const EdgeInsets.only(top: 8), child: Text(_t(ctx, 'هيتفعّل فورًا ويظهر للعملاء.', 'It goes live immediately.'), style: const TextStyle(color: BrandColors.warning, fontWeight: FontWeight.w700))),
            const SizedBox(height: 10),
            TextField(controller: note, decoration: InputDecoration(labelText: _t(ctx, 'ملاحظة لصاحب الطلب (اختياري)', 'Note to the requester (optional)'))),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(_t(ctx, 'رجوع', 'Back'))),
          FilledButton(style: FilledButton.styleFrom(minimumSize: const Size(110, 44), backgroundColor: approve ? BrandColors.success : BrandColors.error), onPressed: () => Navigator.pop(ctx, true), child: Text(approve ? _t(ctx, 'وافق', 'Approve') : _t(ctx, 'ارفض', 'Reject'))),
        ],
      ),
    );
    final text = note.text;
    disposeLater(note);
    if (ok != true || !context.mounted) return;
    try {
      await ref.read(supabaseProvider).rpc('marketing_request_decide', params: {'p_id': r['id'], 'p_approve': approve, 'p_note': text});
      if (context.mounted) showSnack(context, approve ? _t(context, 'اتفعّل ✅', 'Activated ✅') : _t(context, 'اترفض', 'Rejected'));
      onChanged();
    } catch (e) {
      if (context.mounted) showSnack(context, friendlyError(context, e), error: true);
    }
  }

  List<Widget> _details(BuildContext c, Map<String, dynamic> r) {
    final d = Map<String, dynamic>.from(r['details'] as Map? ?? const {});
    Widget line(String a, String? b) => (b == null || b.isEmpty) ? const SizedBox.shrink() : Padding(padding: const EdgeInsets.only(top: 3), child: Text('$a: $b', style: const TextStyle(fontSize: 13, color: BrandColors.gray)));
    switch ('${r['kind']}') {
      case 'banner':
        return [
          if (d['image_path'] != null) Padding(padding: const EdgeInsets.only(top: 8), child: ClipRRect(borderRadius: BorderRadius.circular(12), child: SizedBox(height: 120, width: 320, child: NetImage(path: '${d['image_path']}', bucket: 'banners')))),
          line(_t(c, 'العنوان', 'Title'), '${d['title_ar'] ?? ''}'),
          line(_t(c, 'يفتح', 'Opens'), d['link_type'] == null || '${d['link_type']}'.isEmpty ? null : '${d['link_type']}'),
          line(_t(c, 'من', 'From'), d['starts_at'] == null ? null : '${d['starts_at']}'.split('T').first),
          line(_t(c, 'إلى', 'To'), d['ends_at'] == null ? null : '${d['ends_at']}'.split('T').first),
          line(_t(c, 'ملاحظة', 'Note'), '${d['note'] ?? ''}'),
        ];
      case 'coupon':
        return [
          line(_t(c, 'الكود', 'Code'), '${d['code'] ?? ''}'),
          line(_t(c, 'الخصم', 'Discount'), d['percent_off'] != null ? '${d['percent_off']}%' : formatEgp(((d['amount_off_minor'] as num?) ?? 0).toInt(), c.lang)),
          line(_t(c, 'أقل طلب', 'Min order'), d['min_order_minor'] == null ? null : formatEgp(((d['min_order_minor'] as num?) ?? 0).toInt(), c.lang)),
          line(_t(c, 'أقصى استخدام', 'Max uses'), d['max_uses'] == null ? null : '${d['max_uses']}'),
          line(_t(c, 'ينتهي', 'Ends'), d['ends_at'] == null ? null : '${d['ends_at']}'.split('T').first),
        ];
      case 'campaign':
        final sg = _segs.firstWhere((s) => s.key == d['segment'], orElse: () => _segs.first);
        return [line(_t(c, 'الشريحة', 'Segment'), sg.label(c)), line(_t(c, 'العنوان', 'Title'), '${d['title'] ?? ''}'), line(_t(c, 'النص', 'Message'), '${d['body'] ?? ''}'), line(_t(c, 'الكود', 'Code'), '${d['coupon_code'] ?? ''}')];
      default:
        return [Padding(padding: const EdgeInsets.only(top: 6), child: Text('${d['text'] ?? ''}', style: const TextStyle(height: 1.5)))];
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(_mkRequestsProvider).valueOrNull ?? const <Map<String, dynamic>>[];
    if (rows.isEmpty) return const SizedBox.shrink();
    final pending = [for (final r in rows) if (r['status'] == 'pending') r];
    final done = [for (final r in rows) if (r['status'] != 'pending') r].take(6).toList();
    Color col(String s) => switch (s) { 'approved' => BrandColors.success, 'rejected' => BrandColors.error, 'cancelled' => BrandColors.gray, _ => BrandColors.warning };
    String lab(String s) => switch (s) { 'approved' => _t(context, 'اتفعّل', 'Approved'), 'rejected' => _t(context, 'اترفض', 'Rejected'), 'cancelled' => _t(context, 'اتلغى', 'Cancelled'), _ => _t(context, 'مستني الموافقة', 'Waiting for approval') };
    Widget tile(Map<String, dynamic> r) {
      final isPending = r['status'] == 'pending';
      return Container(
        margin: const EdgeInsets.only(top: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: isPending ? const Color(0xFFFFFAF0) : const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(14), border: Border.all(color: isPending ? const Color(0xFFFFD99A) : BrandColors.border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(_kindIcon('${r['kind']}'), size: 20, color: inkColor(context)),
            const SizedBox(width: 8),
            Expanded(child: Text('${_t(context, _kindAr('${r['kind']}'), _kindEn('${r['kind']}'))} · ${r['title']}', style: TextStyle(fontWeight: FontWeight.w800, color: inkColor(context)))),
            StatusChip(label: lab('${r['status']}'), color: col('${r['status']}')),
          ]),
          Text('${r['requester']} · ${DateFormat('d/M HH:mm').format(DateTime.parse('${r['requested_at']}').toLocal())}', style: const TextStyle(fontSize: 12, color: BrandColors.gray)),
          ..._details(context, r),
          if ((r['note'] as String?)?.isNotEmpty == true) Padding(padding: const EdgeInsets.only(top: 6), child: Text('${_t(context, 'ملاحظة المالك', 'Owner note')}: ${r['note']}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700))),
          if (isPending && canApprove)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Row(children: [
                FilledButton.icon(style: FilledButton.styleFrom(minimumSize: const Size(0, 42), backgroundColor: BrandColors.success), onPressed: () => _decide(context, ref, r, true), icon: const Icon(Icons.check_rounded), label: Text(_t(context, 'وافق وفعّل', 'Approve'))),
                const SizedBox(width: 10),
                OutlinedButton.icon(style: OutlinedButton.styleFrom(minimumSize: const Size(0, 42), foregroundColor: BrandColors.error), onPressed: () => _decide(context, ref, r, false), icon: const Icon(Icons.close_rounded), label: Text(_t(context, 'ارفض', 'Reject'))),
              ]),
            ),
          if (isPending && !canApprove && r['mine'] == true)
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton(
                onPressed: () async {
                  try {
                    await ref.read(supabaseProvider).rpc('marketing_request_cancel', params: {'p_id': r['id']});
                    onChanged();
                  } catch (e) {
                    if (context.mounted) showSnack(context, friendlyError(context, e), error: true);
                  }
                },
                child: Text(_t(context, 'إلغاء الطلب', 'Cancel request')),
              ),
            ),
        ]),
      );
    }

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(color: panelColor(context), borderRadius: BorderRadius.circular(18), border: Border.all(color: pending.isNotEmpty && canApprove ? const Color(0xFFFFB84D) : BrandColors.border, width: pending.isNotEmpty && canApprove ? 1.6 : 1)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(canApprove ? Icons.fact_check_outlined : Icons.pending_actions_rounded, color: BrandColors.electric),
          const SizedBox(width: 8),
          Text(canApprove ? _t(context, 'طلبات التسويق (محتاجة موافقتك)', 'Marketing requests (need your approval)') : _t(context, 'طلباتي للمالك', 'My requests to the owner'), style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: inkColor(context))),
          const SizedBox(width: 8),
          if (pending.isNotEmpty) StatusChip(label: '${pending.length}', color: BrandColors.warning),
        ]),
        for (final r in pending) tile(r),
        if (done.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text(_t(context, 'آخر القرارات', 'Recent decisions'), style: const TextStyle(color: BrandColors.gray, fontWeight: FontWeight.w700, fontSize: 13)),
          for (final r in done) tile(r),
        ],
      ]),
    );
  }
}

// ============================================================================================ the "new idea" form
class _IdeaDialog extends ConsumerStatefulWidget {
  const _IdeaDialog();
  @override
  ConsumerState<_IdeaDialog> createState() => _IdeaDialogState();
}

class _IdeaDialogState extends ConsumerState<_IdeaDialog> {
  String _kind = 'banner';
  bool _busy = false;
  Uint8List? _img;
  final _title = TextEditingController();
  final _titleEn = TextEditingController();
  final _text = TextEditingController();
  final _code = TextEditingController();
  final _value = TextEditingController();
  final _min = TextEditingController();
  final _maxUses = TextEditingController();
  final _cTitle = TextEditingController();
  final _cBody = TextEditingController();
  final _cCode = TextEditingController();
  String _link = '';
  String? _product;
  bool _percent = true;
  String _segment = 'all';
  DateTime? _from, _to;

  @override
  void dispose() {
    for (final c in [_title, _titleEn, _text, _code, _value, _min, _maxUses, _cTitle, _cBody, _cCode]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickImage() async {
    try {
      final x = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 82, maxWidth: 1600);
      if (x == null) return;
      final b = await x.readAsBytes();
      if (mounted) setState(() => _img = b);
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(context, e), error: true);
    }
  }

  Future<DateTime?> _date(DateTime? cur) => showDatePicker(context: context, initialDate: cur ?? DateTime.now().add(const Duration(days: 7)), firstDate: DateTime.now().subtract(const Duration(days: 1)), lastDate: DateTime.now().add(const Duration(days: 730)));

  Future<void> _submit() async {
    final sb = ref.read(supabaseProvider);
    String title;
    Map<String, dynamic> d;
    switch (_kind) {
      case 'banner':
        if (_img == null || _title.text.trim().isEmpty) {
          showSnack(context, _t(context, 'اختار الصورة واكتب عنوان البانر', 'Pick the picture and write the banner title'), error: true);
          return;
        }
        if (_link == 'product' && _product == null) {
          showSnack(context, _t(context, 'اختار المنتج اللي البانر يفتحه', 'Pick the product the banner opens'), error: true);
          return;
        }
        title = _title.text.trim();
        d = {'title_ar': title, 'title_en': _titleEn.text.trim(), 'link_type': _link, 'link_value': _link == 'product' ? _product : null, 'starts_at': _from?.toUtc().toIso8601String(), 'ends_at': _to == null ? null : DateTime(_to!.year, _to!.month, _to!.day, 23, 59).toUtc().toIso8601String(), 'note': _text.text.trim()};
      case 'coupon':
        final v = int.tryParse(_value.text.trim());
        if (v == null || v <= 0 || !RegExp(r'^[A-Za-z0-9_-]{3,24}$').hasMatch(_code.text.trim())) {
          showSnack(context, _t(context, 'اكتب كود (حروف وأرقام 3 لـ 24) وقيمة خصم صحيحة', 'Write a code (3 to 24 letters or digits) and a valid discount'), error: true);
          return;
        }
        if (_percent && v > 90) {
          showSnack(context, _t(context, 'أقصى خصم 90%', 'Max discount is 90%'), error: true);
          return;
        }
        title = '${_t(context, 'كود', 'Code')} ${_code.text.trim().toUpperCase()}';
        d = {'code': _code.text.trim().toUpperCase(), 'title_ar': _cTitle.text.trim(), if (_percent) 'percent_off': v else 'amount_off_minor': v * 100, if (int.tryParse(_min.text.trim()) != null) 'min_order_minor': int.parse(_min.text.trim()) * 100, if (int.tryParse(_maxUses.text.trim()) != null) 'max_uses': int.parse(_maxUses.text.trim()), 'ends_at': _to == null ? null : DateTime(_to!.year, _to!.month, _to!.day, 23, 59).toUtc().toIso8601String()};
      case 'campaign':
        if (_title.text.trim().isEmpty || _cTitle.text.trim().isEmpty || _cBody.text.trim().isEmpty) {
          showSnack(context, _t(context, 'اكتب اسم الحملة وعنوان الإشعار والنص', 'Write the campaign name, notification title and text'), error: true);
          return;
        }
        title = _title.text.trim();
        d = {'name': title, 'segment': _segment, 'title': _cTitle.text.trim(), 'body': _cBody.text.trim(), 'coupon_code': _cCode.text.trim().isEmpty ? null : _cCode.text.trim().toUpperCase()};
      default:
        if (_title.text.trim().isEmpty || _text.text.trim().isEmpty) {
          showSnack(context, _t(context, 'اكتب اسم الفكرة وشرحها', 'Write the idea name and explain it'), error: true);
          return;
        }
        title = _title.text.trim();
        d = {'text': _text.text.trim()};
    }
    setState(() => _busy = true);
    try {
      if (_kind == 'banner') {
        final path = 'proposals/${DateTime.now().microsecondsSinceEpoch}.jpg';
        await sb.storage.from('banners').uploadBinary(path, _img!, fileOptions: const FileOptions(contentType: 'image/jpeg'));
        d['image_path'] = path;
      }
      await sb.rpc('marketing_request_create', params: {'p_kind': _kind, 'p_title': title, 'p_details': d});
      if (!mounted) return;
      showSnack(context, _t(context, 'اتبعت للمالك. مش هيتفعّل غير بعد موافقته ✅', 'Sent to the owner. It stays off until he approves ✅'));
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final products = ref.watch(_mkProductsProvider).valueOrNull ?? const <Map<String, dynamic>>[];
    Widget dateRow(String label, DateTime? v, void Function(DateTime?) set) => Row(children: [
          Expanded(child: Text(v == null ? label : '$label: ${DateFormat('d/M/yyyy').format(v)}')),
          TextButton(onPressed: () async {
            final x = await _date(v);
            if (x != null) set(x);
          }, child: Text(_t(context, 'اختار', 'Pick'))),
          if (v != null) IconButton(onPressed: () => set(null), icon: const Icon(Icons.close_rounded, size: 18)),
        ]);
    final body = switch (_kind) {
      'banner' => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: _busy ? null : _pickImage,
            child: Container(
              height: 150,
              decoration: BoxDecoration(color: const Color(0xFFF2F4F7), borderRadius: BorderRadius.circular(14), border: Border.all(color: BrandColors.border)),
              child: _img == null
                  ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.add_photo_alternate_outlined, size: 36, color: BrandColors.electric), Text(_t(context, 'اختار صورة البانر (هتظهر في الرئيسية بعد الموافقة)', 'Pick the banner picture (shown on the home screen after approval)'))]))
                  : ClipRRect(borderRadius: BorderRadius.circular(14), child: Image.memory(_img!, fit: BoxFit.cover, width: double.infinity)),
            ),
          ),
          const SizedBox(height: 10),
          TextField(controller: _title, decoration: InputDecoration(labelText: _t(context, 'عنوان البانر', 'Banner title'))),
          const SizedBox(height: 8),
          TextField(controller: _titleEn, decoration: InputDecoration(labelText: _t(context, 'العنوان بالإنجليزي (اختياري)', 'English title (optional)'))),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            value: _link,
            decoration: InputDecoration(labelText: _t(context, 'البانر يفتح إيه؟', 'What does it open?')),
            items: [
              DropdownMenuItem(value: '', child: Text(_t(context, 'مش بيفتح حاجة', 'Nothing'))),
              DropdownMenuItem(value: 'product', child: Text(_t(context, 'منتج معين', 'A product'))),
              DropdownMenuItem(value: 'repair', child: Text(_t(context, 'طلب صيانة', 'Repair request'))),
            ],
            onChanged: (v) => setState(() => _link = v ?? ''),
          ),
          if (_link == 'product') ...[
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: _product,
              isExpanded: true,
              decoration: InputDecoration(labelText: _t(context, 'المنتج', 'Product')),
              items: [for (final p in products) DropdownMenuItem(value: '${p['id']}', child: Text('${p['name_ar'] ?? p['name_en']}', overflow: TextOverflow.ellipsis))],
              onChanged: (v) => setState(() => _product = v),
            ),
          ],
          const SizedBox(height: 6),
          dateRow(_t(context, 'يبدأ', 'Starts'), _from, (v) => setState(() => _from = v)),
          dateRow(_t(context, 'ينتهي', 'Ends'), _to, (v) => setState(() => _to = v)),
          TextField(controller: _text, minLines: 1, maxLines: 3, decoration: InputDecoration(labelText: _t(context, 'ملاحظة للمالك: المناسبة أو المنتج أو الهدف', 'Note to the owner: occasion, product or goal'))),
        ]),
      'coupon' => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(controller: _code, textDirection: TextDirection.ltr, decoration: InputDecoration(labelText: _t(context, 'الكود (مثلًا EID25)', 'Code (e.g. EID25)'))),
          const SizedBox(height: 8),
          TextField(controller: _cTitle, decoration: InputDecoration(labelText: _t(context, 'وصف قصير', 'Short title'))),
          const SizedBox(height: 8),
          SegmentedButton<bool>(segments: [ButtonSegment(value: true, label: Text(_t(context, 'نسبة %', 'Percent'))), ButtonSegment(value: false, label: Text(_t(context, 'مبلغ ثابت', 'Fixed amount')))], selected: {_percent}, onSelectionChanged: (s) => setState(() => _percent = s.first)),
          const SizedBox(height: 8),
          TextField(controller: _value, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: _percent ? _t(context, 'نسبة الخصم (1 - 90)', 'Discount percent (1-90)') : _t(context, 'قيمة الخصم بالجنيه', 'Discount in EGP'))),
          const SizedBox(height: 8),
          TextField(controller: _min, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: _t(context, 'أقل قيمة للطلب بالجنيه (اختياري)', 'Minimum order in EGP (optional)'))),
          const SizedBox(height: 8),
          TextField(controller: _maxUses, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: _t(context, 'أقصى عدد استخدامات (اختياري)', 'Max uses (optional)'))),
          dateRow(_t(context, 'ينتهي', 'Ends'), _to, (v) => setState(() => _to = v)),
        ]),
      'campaign' => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(controller: _title, decoration: InputDecoration(labelText: _t(context, 'اسم الحملة', 'Campaign name'))),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            value: _segment,
            decoration: InputDecoration(labelText: _t(context, 'الشريحة', 'Segment')),
            items: [for (final s in _segs) DropdownMenuItem(value: s.key, child: Text(s.label(context)))],
            onChanged: (v) => setState(() => _segment = v ?? 'all'),
          ),
          const SizedBox(height: 8),
          TextField(controller: _cTitle, decoration: InputDecoration(labelText: _t(context, 'عنوان الإشعار', 'Notification title'))),
          const SizedBox(height: 8),
          TextField(controller: _cBody, minLines: 2, maxLines: 4, decoration: InputDecoration(labelText: _t(context, 'النص', 'Message'))),
          const SizedBox(height: 8),
          TextField(controller: _cCode, textDirection: TextDirection.ltr, decoration: InputDecoration(labelText: _t(context, 'كود خصم موجود (اختياري)', 'Existing discount code (optional)'))),
        ]),
      _ => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(controller: _title, decoration: InputDecoration(labelText: _t(context, 'اسم الفكرة', 'Idea name'))),
          const SizedBox(height: 8),
          TextField(controller: _text, minLines: 5, maxLines: 9, decoration: InputDecoration(labelText: _t(context, 'اشرح الفكرة: إيه المطلوب، لمين، وإمتى؟ حتى لو مش موجودة في البرنامج', 'Explain: what, for whom, when? Even if the app cannot do it yet'), alignLabelWithHint: true)),
          Padding(padding: const EdgeInsets.only(top: 8), child: Text(_t(context, 'لو المالك وافق، الفكرة بتتبني وتتفعّل عنده.', 'If the owner approves, it gets built and switched on.'), style: const TextStyle(color: BrandColors.gray, fontSize: 12.5))),
        ]),
    };
    return AlertDialog(
      title: Text(_t(context, 'فكرة جديدة للمالك', 'New idea for the owner')),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Wrap(spacing: 8, children: [
              for (final k in const ['banner', 'coupon', 'campaign', 'idea'])
                ChoiceChip(avatar: Icon(_kindIcon(k), size: 18), label: Text(_t(context, _kindAr(k), _kindEn(k))), selected: _kind == k, onSelected: (_) => setState(() => _kind = k)),
            ]),
            const SizedBox(height: 14),
            body,
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: const Color(0xFFFFF7E6), borderRadius: BorderRadius.circular(10)),
              child: Row(children: [const Icon(Icons.verified_user_outlined, size: 18, color: BrandColors.warning), const SizedBox(width: 8), Expanded(child: Text(_t(context, 'مفيش حاجة هتتفعّل غير لما المالك يوافق، وهيجيله إشعار.', 'Nothing goes live until the owner approves. He gets a notification.'), style: const TextStyle(fontSize: 12.5)))]),
            ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(false), child: Text(_t(context, 'إلغاء', 'Cancel'))),
        FilledButton.icon(style: FilledButton.styleFrom(minimumSize: const Size(0, 46)), onPressed: _busy ? null : _submit, icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.send_rounded), label: Text(_t(context, 'ابعت للمالك', 'Send to the owner'))),
      ],
    );
  }
}
