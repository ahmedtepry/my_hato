// "Server usage" (owner only, staff.manage): how full the free Supabase plan is, so it never fills up by surprise.
// Database (500 MB) and files (1 GB) as gauges, files per folder, the last 60 days, and what the nightly cleanup removed.
// Server: server_usage(); the nightly "maintenance" function records usage and alerts the owner at 70% / 90%.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/supabase_providers.dart';
import '../../shared/states.dart' show showSnack;

String _t(BuildContext c, String ar, String en) => c.isAr ? ar : en;

final serverUsageProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  final r = await ref.watch(supabaseProvider).rpc('server_usage');
  return Map<String, dynamic>.from(r as Map);
});

String _size(num b) {
  if (b >= 1024 * 1024 * 1024) return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  if (b >= 1024 * 1024) return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
  if (b >= 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
  return '$b B';
}

Color _level(double pct) => pct >= 90 ? const Color(0xFFE5484D) : pct >= 70 ? const Color(0xFFF08C00) : const Color(0xFF12B76A);

const _bucketNames = {
  'app-updates': ('ملفات تحديث البرامج (نسخة احتياطية)', 'App installers (backup copy)'),
  'repair-photos': ('صور الصيانة', 'Repair photos'),
  'product-images': ('صور المنتجات', 'Product pictures'),
  'product-360': ('صور ٣٦٠ للمنتجات', '360° product pictures'),
  'banners': ('البانرات والعروض', 'Banners and offers'),
  'avatars': ('صور الحسابات', 'Profile pictures'),
  'transfer-proofs': ('إثباتات التحويل', 'Transfer screenshots'),
  'support-chat': ('مرفقات الدعم', 'Support attachments'),
};

class ServerUsagePanel extends ConsumerWidget {
  const ServerUsagePanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(serverUsageProvider);
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(friendlyError(context, e), textAlign: TextAlign.center),
          const SizedBox(height: 12),
          FilledButton.icon(onPressed: () => ref.invalidate(serverUsageProvider), icon: const Icon(Icons.refresh_rounded), label: Text(_t(context, 'حاول تاني', 'Try again'))),
        ]),
      ),
      data: (d) => _Body(d: d, onRefresh: () => ref.invalidate(serverUsageProvider)),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.d, required this.onRefresh});
  final Map<String, dynamic> d;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final db = (d['db_bytes'] as num?) ?? 0, dbLim = (d['db_limit'] as num?) ?? 1;
    final st = (d['storage_bytes'] as num?) ?? 0, stLim = (d['storage_limit'] as num?) ?? 1;
    final buckets = Map<String, dynamic>.from((d['buckets'] as Map?) ?? const {});
    final hist = [for (final h in (d['history'] as List? ?? const [])) Map<String, dynamic>.from(h as Map)];
    final last = d['last_cleanup'] == null ? null : Map<String, dynamic>.from(d['last_cleanup'] as Map);
    final sorted = buckets.entries.toList()..sort((a, b) => ((b.value as num?) ?? 0).compareTo((a.value as num?) ?? 0));
    final wide = MediaQuery.sizeOf(context).width > 900;
    final gauges = [
      _Gauge(title: _t(context, 'قاعدة البيانات', 'Database'), sub: _t(context, 'المبيعات والعملاء والصيانة والطلبات', 'Sales, customers, repairs, orders'), used: db, limit: dbLim, icon: Icons.storage_rounded),
      _Gauge(title: _t(context, 'الملفات', 'Files'), sub: _t(context, 'الصور وملفات التحديث', 'Pictures and installers'), used: st, limit: stLim, icon: Icons.photo_library_outlined),
    ];
    return ListView(padding: const EdgeInsets.all(20), children: [
      Row(children: [
        Expanded(child: Text(_t(context, 'استهلاك السيرفر', 'Server usage'), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900))),
        IconButton(tooltip: _t(context, 'تحديث', 'Refresh'), onPressed: onRefresh, icon: const Icon(Icons.refresh_rounded)),
      ]),
      const SizedBox(height: 4),
      Text(_t(context, 'الحد المجاني: ٥٠٠ ميجا لقاعدة البيانات و ١ جيجا للملفات. هيوصلك تنبيه لو أي واحد عدّى ٧٠٪.',
              'Free plan: 500 MB database and 1 GB files. You get an alert if either passes 70%.'),
          style: TextStyle(color: Theme.of(context).hintColor)),
      const SizedBox(height: 16),
      wide ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: gauges[0]), const SizedBox(width: 16), Expanded(child: gauges[1])]) : Column(children: [gauges[0], const SizedBox(height: 16), gauges[1]]),
      const SizedBox(height: 16),
      if (hist.length >= 2) _Card(
        title: _t(context, 'آخر ٦٠ يوم', 'Last 60 days'),
        child: SizedBox(height: 140, child: CustomPaint(painter: _HistPainter(hist, dbLim.toDouble(), stLim.toDouble(), Theme.of(context).dividerColor), size: Size.infinite)),
        trailing: Wrap(spacing: 12, children: [_legend(context, const Color(0xFF2E7CF6), _t(context, 'قاعدة البيانات', 'Database')), _legend(context, const Color(0xFF8B5CF6), _t(context, 'الملفات', 'Files'))]),
      ),
      if (hist.length >= 2) const SizedBox(height: 16),
      _Card(
        title: _t(context, 'الملفات حسب النوع', 'Files by kind'),
        child: Column(children: [
          if (sorted.isEmpty) Padding(padding: const EdgeInsets.all(8), child: Text(_t(context, 'مفيش ملفات لسه', 'No files yet'))),
          for (final e in sorted)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(children: [
                Expanded(child: Text(context.isAr ? (_bucketNames[e.key]?.$1 ?? e.key) : (_bucketNames[e.key]?.$2 ?? e.key), style: const TextStyle(fontWeight: FontWeight.w700))),
                SizedBox(width: 160, child: ClipRRect(borderRadius: BorderRadius.circular(4), child: LinearProgressIndicator(minHeight: 8, value: math.min(1, ((e.value as num?) ?? 0) / stLim), color: const Color(0xFF8B5CF6), backgroundColor: Theme.of(context).dividerColor.withValues(alpha: .4)))),
                const SizedBox(width: 12),
                SizedBox(width: 80, child: Text(_size((e.value as num?) ?? 0), textAlign: TextAlign.end, style: const TextStyle(fontWeight: FontWeight.w800))),
              ]),
            ),
        ]),
      ),
      const SizedBox(height: 16),
      _Card(
        title: _t(context, 'الحماية التلقائية', 'Automatic protection'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _rule(context, Icons.compress_rounded, _t(context, 'كل صورة بتتضغط قبل الرفع (من ٤ ميجا لحوالي ٢٠٠ كيلو)', 'Every picture is compressed before upload (about 4 MB down to 200 KB)')),
          _rule(context, Icons.auto_delete_outlined, _t(context, 'كل ليلة: صور الصيانة بعد ٩٠ يوم من التسليم، إثباتات التحويل بعد ٦٠ يوم، ومرفقات الدعم بعد ٦ شهور بتتمسح', 'Every night: repair photos 90 days after delivery, transfer screenshots after 60 days and support attachments after 6 months are removed')),
          _rule(context, Icons.cleaning_services_outlined, _t(context, 'الملفات اللي مالهاش لازمة والسجلات القديمة بتتنضف لوحدها', 'Unused files and old logs are cleaned on their own')),
          _rule(context, Icons.cloud_download_outlined, _t(context, 'تحديثات البرامج بتتحمّل من GitHub، فمش بتاكل من التحميل الشهري', 'App updates download from GitHub, so they do not use the monthly transfer')),
          _rule(context, Icons.backup_outlined, _t(context, 'نسخة احتياطية مشفّرة من قاعدة البيانات كل ليلة', 'An encrypted database backup every night')),
          if (last != null) ...[
            const Divider(height: 24),
            Text(
              _t(context,
                  'آخر تنظيف: ${_when(last['at'])} · ${last['files'] ?? 0} ملف (${_size((last['bytes'] as num?) ?? 0)}) · ${last['rows'] ?? 0} سطر سجل',
                  'Last cleanup: ${_when(last['at'])} · ${last['files'] ?? 0} files (${_size((last['bytes'] as num?) ?? 0)}) · ${last['rows'] ?? 0} log rows'),
              style: TextStyle(color: Theme.of(context).hintColor, fontWeight: FontWeight.w600),
            ),
          ],
        ]),
      ),
      const SizedBox(height: 16),
      _Card(
        title: _t(context, 'التحميل الشهري (Egress)', 'Monthly transfer (egress)'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_t(context, 'الحد ٥ جيجا في الشهر. الرقم ده بيظهر في لوحة Supabase بس (Usage)، مش متاح للبرنامج.',
              'The limit is 5 GB a month. Supabase shows this number only in its dashboard (Usage), not to the app.')),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () async {
              await Clipboard.setData(const ClipboardData(text: 'https://supabase.com/dashboard/org/_/usage'));
              if (context.mounted) showSnack(context, _t(context, 'اتنسخ رابط صفحة الاستهلاك', 'Usage page link copied'));
            },
            icon: const Icon(Icons.link_rounded),
            label: Text(_t(context, 'انسخ رابط صفحة الاستهلاك', 'Copy the usage page link')),
          ),
        ]),
      ),
    ]);
  }

  static String _when(dynamic iso) {
    final d = DateTime.tryParse('$iso')?.toLocal();
    return d == null ? '—' : DateFormat('d/M HH:mm').format(d);
  }

  Widget _legend(BuildContext c, Color col, String s) => Row(mainAxisSize: MainAxisSize.min, children: [Container(width: 10, height: 10, decoration: BoxDecoration(color: col, borderRadius: BorderRadius.circular(3))), const SizedBox(width: 6), Text(s, style: const TextStyle(fontSize: 12))]);

  Widget _rule(BuildContext c, IconData i, String s) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Icon(i, size: 20, color: const Color(0xFF12B76A)), const SizedBox(width: 10), Expanded(child: Text(s))]),
      );
}

class _Gauge extends StatelessWidget {
  const _Gauge({required this.title, required this.sub, required this.used, required this.limit, required this.icon});
  final String title, sub;
  final num used, limit;
  final IconData icon;
  @override
  Widget build(BuildContext context) {
    final pct = 100 * used / limit;
    final col = _level(pct.toDouble());
    return _Card(
      title: title,
      trailing: Icon(icon, color: col),
      child: Row(children: [
        SizedBox(
          width: 110,
          height: 110,
          child: Stack(alignment: Alignment.center, children: [
            SizedBox.expand(child: CircularProgressIndicator(value: math.min(1, pct / 100), strokeWidth: 12, color: col, backgroundColor: Theme.of(context).dividerColor.withValues(alpha: .35))),
            Text('${pct.toStringAsFixed(pct < 10 ? 1 : 0)}%', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: col)),
          ]),
        ),
        const SizedBox(width: 18),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${_size(used)} / ${_size(limit)}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text(sub, style: TextStyle(color: Theme.of(context).hintColor)),
            const SizedBox(height: 8),
            Text(
              pct >= 90
                  ? _t(context, 'قرّب يخلص: كلّمني فورًا', 'Almost full: act now')
                  : pct >= 70
                      ? _t(context, 'محتاج متابعة', 'Needs attention')
                      : _t(context, 'تمام، فيه مساحة كبيرة', 'Fine, plenty of room'),
              style: TextStyle(color: col, fontWeight: FontWeight.w800),
            ),
          ]),
        ),
      ]),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.child, this.trailing});
  final String title;
  final Widget child;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [Expanded(child: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900))), if (trailing != null) trailing!]),
            const SizedBox(height: 12),
            child,
          ]),
        ),
      );
}

class _HistPainter extends CustomPainter {
  _HistPainter(this.h, this.dbLim, this.stLim, this.grid);
  final List<Map<String, dynamic>> h;
  final double dbLim, stLim;
  final Color grid;
  @override
  void paint(Canvas canvas, Size size) {
    final g = Paint()..color = grid.withValues(alpha: .5)..strokeWidth = 1;
    for (final f in [0.0, .5, 1.0]) {
      canvas.drawLine(Offset(0, size.height * (1 - f)), Offset(size.width, size.height * (1 - f)), g);
    }
    void line(String k, double lim, Color c) {
      final p = Path();
      for (var i = 0; i < h.length; i++) {
        final x = h.length == 1 ? 0.0 : size.width * i / (h.length - 1);
        final v = (((h[i][k] as num?) ?? 0) / lim).clamp(0, 1).toDouble();
        final y = size.height * (1 - v);
        i == 0 ? p.moveTo(x, y) : p.lineTo(x, y);
      }
      canvas.drawPath(p, Paint()..color = c..style = PaintingStyle.stroke..strokeWidth = 2.5..strokeCap = StrokeCap.round);
    }
    line('db', dbLim, const Color(0xFF2E7CF6));
    line('storage', stLim, const Color(0xFF8B5CF6));
  }

  @override
  bool shouldRepaint(_HistPainter o) => o.h != h;
}
