import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/money.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../shared/motion.dart';
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
  }

  Future<void> _send(int reachable) async {
    final seg = _segs.firstWhere((e) => e.key == _seg);
    if (_name.text.trim().isEmpty || _title.text.trim().isEmpty || _body.text.trim().isEmpty) {
      showSnack(context, _t(context, 'اكتب اسم الحملة والعنوان والنص', 'Write the campaign name, title and text'), error: true);
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
      final r = Map<String, dynamic>.from(await ref.read(supabaseProvider).rpc('marketing_send_campaign', params: {
        'p_name': _name.text.trim(),
        'p_segment': _seg,
        'p_title': _title.text.trim(),
        'p_body': _body.text.trim(),
        'p_coupon_code': _coupon,
      }) as Map);
      if (!mounted) return;
      showSnack(context, _t(context, 'اتبعتت لـ ${r['sent']} عميل ✅', 'Sent to ${r['sent']} customers ✅'));
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
              Text(_t(context, 'لوحة التسويق', 'Marketing'), style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: BrandColors.navy)),
              Text(_t(context, 'مين عملاؤنا، مين محتاج رسالة، وإيه اللي نفع. آخر 30 يوم.', 'Who our customers are, who needs a message, and what worked. Last 30 days.'), style: const TextStyle(color: BrandColors.gray)),
            ]),
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
        if (canSend) _composer(context, coupons, countOf(_seg, 'reachable'), countOf(_seg, 'count')),
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
        Text(t, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: BrandColors.navy)),
        Text(s, style: const TextStyle(color: BrandColors.gray, fontSize: 13)),
      ]);

  Widget _card(Widget child, {EdgeInsets padding = const EdgeInsets.all(18)}) => Container(
        padding: padding,
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), border: Border.all(color: BrandColors.border)),
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
            FittedBox(fit: BoxFit.scaleDown, alignment: AlignmentDirectional.centerStart, child: CountUpText(t.$2, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: BrandColors.navy))),
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
        Text(_t(c, 'توصيات من الأرقام', 'Recommendations from the numbers'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: BrandColors.navy)),
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
  Widget _composer(BuildContext c, List<Map<String, dynamic>> coupons, int reachable, int total) {
    final seg = _segs.firstWhere((e) => e.key == _seg);
    final active = [for (final e in coupons) if (e['is_active'] == true && (e['ends_at'] == null || DateTime.parse('${e['ends_at']}').isAfter(DateTime.now()))) e];
    return _card(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Icon(seg.icon, color: seg.color),
        const SizedBox(width: 8),
        Expanded(child: Text(_t(c, 'حملة جديدة لشريحة «${seg.ar}»', 'New campaign to "${seg.en}"'), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: BrandColors.navy))),
        TextButton.icon(onPressed: () => setState(() => _template(seg)), icon: const Icon(Icons.auto_fix_high_rounded, size: 18), label: Text(_t(c, 'اقتراح نص', 'Suggest text'))),
      ]),
      const SizedBox(height: 10),
      TextField(controller: _name, decoration: InputDecoration(labelText: _t(c, 'اسم الحملة (ليك إنت)', 'Campaign name (for you)'))),
      const SizedBox(height: 10),
      TextField(controller: _title, maxLength: 120, decoration: InputDecoration(labelText: _t(c, 'عنوان الإشعار', 'Notification title'))),
      TextField(controller: _body, maxLength: 500, minLines: 2, maxLines: 4, decoration: InputDecoration(labelText: _t(c, 'النص', 'Message'))),
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
          label: Text(_t(c, 'ابعت الحملة', 'Send campaign')),
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
                      Text('${r['name']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, color: BrandColors.navy)),
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
                Text('${rows[i]['code']}', textDirection: TextDirection.ltr, textAlign: TextAlign.start, style: const TextStyle(fontWeight: FontWeight.w900, color: BrandColors.navy)),
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
              Expanded(child: Text(seg.label(context), style: const TextStyle(fontWeight: FontWeight.w800, color: BrandColors.navy))),
            ]),
            const SizedBox(height: 10),
            CountUpText('$count', style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: BrandColors.navy)),
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
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: BrandColors.border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_t(context, 'عينة من الشريحة (الأكتر إنفاقًا الأول)', 'Sample of this segment (top spenders first)'), style: const TextStyle(fontWeight: FontWeight.w800, color: BrandColors.navy)),
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
