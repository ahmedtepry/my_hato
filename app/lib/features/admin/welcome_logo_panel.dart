import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/appearance.dart';
import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/theme.dart';
import '../../shared/launch_animation.dart';
import '../../shared/states.dart';
import 'admin_repository.dart';

String _t(BuildContext c, String ar, String en) => c.isAr ? ar : en;

/// "apk welcome logo": the owner (appearance.welcome) previews the two robot welcomes and turns one on for every customer.
/// The customers' app plays it as its opening animation once they have the app version that contains it.
class WelcomeLogoPanel extends ConsumerStatefulWidget {
  const WelcomeLogoPanel({super.key});
  @override
  ConsumerState<WelcomeLogoPanel> createState() => _WelcomeLogoPanelState();
}

class _WelcomeLogoPanelState extends ConsumerState<WelcomeLogoPanel> {
  final _replay = {'peek': 0, 'call': 0};
  String? _busy;

  Future<void> _set(String style) async {
    setState(() => _busy = style);
    try {
      await ref.read(adminRepoProvider).setWelcomeLogo(style);
      await ref.read(appearanceProvider.notifier).refresh();
      if (mounted) {
        showSnack(context, style == 'off'
            ? _t(context, 'اتقفلت. العملاء هيرجعوا للحركة العادية.', 'Turned off. Customers go back to the normal opening animation.')
            : _t(context, 'اتفعّلت لكل العملاء. بتظهر عند اللي نزّل آخر نسخة من التطبيق أول ما يفتحه.', 'Turned on for every customer. It shows for anyone who has the latest app version, the next time they open it.'));
      }
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Widget _card(BuildContext context, String id, String titleAr, String titleEn, String descAr, String descEn, String current) {
    final on = current == id;
    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: on ? BrandColors.success : BrandColors.border, width: on ? 2 : 1)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(_t(context, titleAr, titleEn), style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16))),
            if (on) Chip(label: Text(_t(context, 'شغّال عند العملاء', 'On for customers')), backgroundColor: BrandColors.success.withValues(alpha: 0.14), side: BorderSide.none),
          ]),
          const SizedBox(height: 4),
          Text(_t(context, descAr, descEn), style: const TextStyle(color: BrandColors.gray, fontSize: 12.5)),
          const SizedBox(height: 10),
          Container(
            height: 360,
            width: double.infinity,
            decoration: BoxDecoration(color: BrandColors.navy, borderRadius: BorderRadius.circular(16)),
            child: Stack(children: [
              Center(child: LaunchAnimation(key: ValueKey('$id${_replay[id]}'), variant: id, scale: 0.9)),
              PositionedDirectional(
                top: 6,
                end: 6,
                child: IconButton(onPressed: () => setState(() => _replay[id] = _replay[id]! + 1), icon: const Icon(Icons.replay_rounded, color: Colors.white), tooltip: _t(context, 'شغّل تاني', 'Replay')),
              ),
            ]),
          ),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _busy != null || on ? null : () => _set(id),
                icon: _busy == id ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.rocket_launch_rounded),
                label: Text(on ? _t(context, 'شغّال دلوقتي', 'Running now') : _t(context, 'فعّلها لكل العملاء', 'Turn on for every customer')),
              ),
            ),
          ]),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final current = ref.watch(appearanceProvider).animation;
    final on = welcomeAnimations.contains(current);
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text('apk welcome logo', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 20), textDirection: TextDirection.ltr),
      const SizedBox(height: 4),
      Text(
        _t(context, 'شاشة ترحيب بالروبوت بتظهر في تطبيق العملاء أول ما يفتحوه. لما تفعّلها بتوصل لكل اللي نزّلوا آخر تحديث للتطبيق، وبتفضل الحركة العادية عند اللي لسه ما حدّثش. تقدر تقفلها في أي وقت.',
            'A robot welcome that plays when customers open the app. When you turn it on it reaches everyone who has installed the latest app update; people who have not updated yet keep the normal animation. You can turn it off any time.'),
        style: const TextStyle(color: BrandColors.gray, fontSize: 13),
      ),
      const SizedBox(height: 14),
      _card(context, 'peek', 'الروبوت بيلوّح', 'The robot waves', 'بيطلع من طرف الحرف بزاوية، يلوّح بإيده ويبتسم.', 'Slides out from the edge of the letter at an angle, waves and smiles.', current),
      _card(context, 'call', 'الروبوت بيتصل', 'The robot makes a call', 'بيطلع ماسك تليفون ويحطه على ودنه، ينط على حرف الـM، يقعد رجل على رجل ويتكلم.', 'Comes out holding a phone, puts it to its ear, jumps onto the M, sits with its legs crossed and talks.', current),
      if (on)
        OutlinedButton.icon(
          onPressed: _busy != null ? null : () => _set('off'),
          icon: _busy == 'off' ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.power_settings_new_rounded),
          label: Text(_t(context, 'قفلها ورجّع الحركة العادية', 'Turn off and go back to the normal animation')),
        ),
      const SizedBox(height: 24),
    ]);
  }
}
