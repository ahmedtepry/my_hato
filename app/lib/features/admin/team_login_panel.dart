import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../shared/states.dart';

String _t(BuildContext c, String ar, String en) => c.isAr ? ar : en;

const teamLoginStyles = ['split', 'hello', 'classic'];

/// How the Windows team login looks: 'split' (navy panel with the waving robot), 'hello' (light panel, the robot greets the typed name),
/// 'classic' (the old dark single column). Readable before sign-in; changed by whoever has appearance.login.
final teamLoginStyleProvider = FutureProvider<String>((ref) async {
  try {
    final rows = await ref.read(supabaseProvider).from('application_settings').select('value').eq('key', 'team_login_style').limit(1);
    final v = rows.isEmpty ? null : rows.first['value'];
    return v is String && teamLoginStyles.contains(v) ? v : 'split';
  } catch (_) {
    return 'split';
  }
});

class TeamLoginPanel extends ConsumerStatefulWidget {
  const TeamLoginPanel({super.key});
  @override
  ConsumerState<TeamLoginPanel> createState() => _TeamLoginPanelState();
}

class _TeamLoginPanelState extends ConsumerState<TeamLoginPanel> {
  String? _busy;

  Future<void> _set(String style) async {
    setState(() => _busy = style);
    try {
      await ref.read(supabaseProvider).rpc('team_login_set', params: {'p_style': style});
      ref.invalidate(teamLoginStyleProvider);
      if (mounted) showSnack(context, _t(context, 'اتغيّرت شاشة دخول الفريق. هتظهر في المرة الجاية اللي حد يفتح برنامج الويندوز.', 'Team login changed. It shows the next time the Windows app is opened.'));
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Widget _mini(String id) {
    final robot = Container(width: 26, height: 26, decoration: const BoxDecoration(color: Color(0xFFEAF3FF), shape: BoxShape.circle));
    final form = Container(width: 70, padding: const EdgeInsets.all(6), child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      for (var i = 0; i < 2; i++) Container(height: 12, margin: const EdgeInsets.only(bottom: 5), decoration: BoxDecoration(color: panelColor(context), borderRadius: BorderRadius.circular(4), border: Border.all(color: const Color(0xFFC9D4E8)))),
      Container(height: 12, decoration: BoxDecoration(color: const Color(0xFF1F5FD6), borderRadius: BorderRadius.circular(4))),
    ]));
    return Container(
      width: 170,
      height: 100,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: BrandColors.border), color: const Color(0xFFF4F7FC)),
      child: switch (id) {
        'classic' => Container(color: BrandColors.navyDeep, child: Center(child: Container(width: 80, padding: const EdgeInsets.all(6), decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(8)), child: Column(mainAxisSize: MainAxisSize.min, children: [for (var i = 0; i < 3; i++) Container(height: 10, margin: const EdgeInsets.only(bottom: 4), color: Colors.white24)])))),
        'hello' => Row(children: [Expanded(child: Center(child: form)), Expanded(child: Container(color: const Color(0xFFEAF3FF), child: Center(child: Container(width: 52, height: 52, decoration: const BoxDecoration(color: Color(0xFF152C58), shape: BoxShape.circle), child: Center(child: robot)))))]),
        _ => Row(children: [Expanded(child: Center(child: form)), Expanded(child: Container(color: const Color(0xFF152C58), child: Center(child: robot)))]),
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final current = ref.watch(teamLoginStyleProvider).valueOrNull ?? 'split';
    final items = <(String, String, String, String, String)>[
      ('split', 'منقسمة (الافتراضي)', 'Split (default)', 'الفورم على جنب فاتح، وعلى الجنب التاني لوحة كحلي فيها الروبوت بيلوّح ويقول أهلاً بيك في ماي هاتو.', 'Light form on one side, a navy panel with the waving robot on the other.'),
      ('hello', 'الروبوت يرحّب بالاسم', 'Robot greets by name', 'نفس التقسيمة بس لوحة فاتحة والروبوت جوه دايرة كحلي، وبيقول أهلاً يا (الاسم اللي اتكتب).', 'Same split, light panel, the robot sits in a navy circle and greets the typed name.'),
      ('classic', 'القديمة', 'Classic', 'عمود واحد غامق زي الأول، من غير روبوت.', 'The old single dark column, no robot.'),
    ];
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text(_t(context, 'شاشة دخول الفريق (ويندوز)', 'Team login screen (Windows)'), style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 20)),
      const SizedBox(height: 4),
      Text(_t(context, 'اختار شكل شاشة الدخول اللي بتظهر لكل الفريق في برنامج الويندوز. بتتغيّر عند الكل.', 'Pick the sign-in screen your whole team sees in the Windows app.'), style: const TextStyle(color: BrandColors.gray, fontSize: 13)),
      const SizedBox(height: 14),
      for (final it in items)
        Card(
          margin: const EdgeInsets.only(bottom: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: current == it.$1 ? BrandColors.success : BrandColors.border, width: current == it.$1 ? 2 : 1)),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _mini(it.$1),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_t(context, it.$2, it.$3), style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
                  const SizedBox(height: 4),
                  Text(_t(context, it.$4, it.$5), style: const TextStyle(color: BrandColors.gray, fontSize: 12.5)),
                  const SizedBox(height: 10),
                  FilledButton(
                    onPressed: _busy != null || current == it.$1 ? null : () => _set(it.$1),
                    child: _busy == it.$1 ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : Text(current == it.$1 ? _t(context, 'شغّالة دلوقتي', 'Active') : _t(context, 'فعّلها', 'Use this')),
                  ),
                ]),
              ),
            ]),
          ),
        ),
    ]);
  }
}
