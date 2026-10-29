// On/off switches for what customers see: the points system and the lucky wheel. Turning one off needs a second "are you sure": it then
// disappears for customers and the server refuses every customer call (no earning, no claiming), so fake accounts cannot farm gifts.
// The team keeps seeing it, and the data is kept so turning it back on restores everything.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/supabase_providers.dart';
import '../../shared/states.dart';

/// {points: bool, wheel: bool} as THIS user should see them (customers get false when switched off; the team always sees true),
/// plus points_enabled / wheel_enabled = the real switch. A failed read keeps points visible (the server enforces anyway) and hides the wheel.
final featureFlagsProvider = FutureProvider<Map<String, bool>>((ref) async {
  ref.watch(currentUserProvider);
  try {
    final m = Map<String, dynamic>.from(await ref.watch(supabaseProvider).rpc('feature_flags') as Map);
    return {for (final e in m.entries) e.key: e.value == true};
  } catch (_) {
    return {'points': true, 'wheel': false, 'points_enabled': true, 'wheel_enabled': false};
  }
});

/// Is [key] ('points' | 'wheel') visible to the current user? While loading, points stay visible and the wheel hidden.
bool featureVisible(WidgetRef ref, String key) =>
    ref.watch(featureFlagsProvider).valueOrNull?[key] ?? (key == 'points');

class FeatureSwitchesPanel extends ConsumerStatefulWidget {
  const FeatureSwitchesPanel({super.key});
  @override
  ConsumerState<FeatureSwitchesPanel> createState() => _FeatureSwitchesPanelState();
}

class _FeatureSwitchesPanelState extends ConsumerState<FeatureSwitchesPanel> {
  String? _busy;

  Future<void> _toggle(String key, bool on, String nameAr, String nameEn) async {
    final ar = context.isAr;
    if (!on) {
      final yes = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(ar ? 'متأكد؟' : 'Are you sure?'),
          content: Text(ar
              ? 'لو قفلت «$nameAr» هتتشال خالص من عند العملا، ومحدّش هيقدر يكسب منها حاجة لحد ما تفتحها تاني. الفريق هيفضل شايفها، وبيانات العملا محفوظة.'
              : 'If you turn off "$nameEn" it disappears for customers and nobody can earn from it until you turn it on again. The team still sees it and all data is kept.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ar ? 'لأ، متشيلهاش' : 'No, keep it')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ar ? 'أيوه، شيلها' : 'Yes, remove it')),
          ],
        ),
      );
      if (yes != true || !mounted) return;
    }
    setState(() => _busy = key);
    try {
      await ref.read(supabaseProvider).rpc('feature_set', params: {'p_key': key, 'p_enabled': on, 'p_confirm': true});
      ref.invalidate(featureFlagsProvider);
      if (mounted) showSnack(context, on ? (ar ? 'اتفتحت للعملا' : 'Turned on') : (ar ? 'اتشالت من عند العملا' : 'Removed for customers'));
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ar = context.isAr;
    final flags = ref.watch(featureFlagsProvider);
    return flags.when(
      loading: () => const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
      error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(featureFlagsProvider)),
      data: (f) => ListView(padding: const EdgeInsets.all(16), children: [
        Text(
          ar
              ? 'اتحكم في اللي بيظهر للعملا. لو قفلت حاجة بتختفي خالص من التطبيق ومحدّش يقدر يكسب منها، ودي حماية من الحسابات المزيفة اللي بتلم هدايا.'
              : 'Control what customers see. Turning something off removes it from the app and nobody can earn from it. This protects you from fake accounts farming gifts.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 12),
        _tile(context, 'points', 'نظام النقاط والمهام والجوايز', 'Points, missions and prizes', 'العميل بيجمع نقاط ويفتح الخزنة ويستلم جوايز.', 'Customers earn points, open the vault and collect prizes.', f['points_enabled'] ?? true, Icons.stars_rounded),
        _tile(context, 'wheel', 'عجلة الحظ اليومية', 'Daily lucky wheel', 'لفّة كل يوم بجوايز تتحكم فيها.', 'One spin a day with prizes you control.', f['wheel_enabled'] ?? false, Icons.casino_rounded),
      ]),
    );
  }

  Widget _tile(BuildContext context, String key, String nameAr, String nameEn, String descAr, String descEn, bool on, IconData icon) {
    final ar = context.isAr;
    return Card(
      child: SwitchListTile(
        secondary: Icon(icon),
        title: Text(ar ? nameAr : nameEn, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text('${ar ? descAr : descEn}\n${on ? (ar ? 'شغّالة عند العملا' : 'Visible to customers') : (ar ? 'مقفولة: مخفية عن العملا' : 'Off: hidden from customers')}'),
        isThreeLine: true,
        value: on,
        onChanged: _busy == null ? (v) => _toggle(key, v, nameAr, nameEn) : null,
      ),
    );
  }
}
