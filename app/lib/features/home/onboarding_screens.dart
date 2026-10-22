import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/l10n.dart';
import '../../core/theme.dart';
import '../../shared/brand_logo.dart';

const onboardingDoneKey = 'onboarding_done_v1';

class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});
  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..forward();

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (!mounted) return;
      // no intro slides: straight to the store (language can be changed from My account)
      context.go('/');
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: BrandColors.navy,
        body: Center(
          child: AnimatedBuilder(
            animation: _c,
            builder: (_, __) => Column(mainAxisSize: MainAxisSize.min, children: [
              BrandMark(size: 96, onDark: true, progress: Curves.easeOut.transform(_c.value)),
              const SizedBox(height: 24),
              Opacity(opacity: _c.value, child: const BrandWordmark(size: 30, onDark: true, showSlogan: true)),
            ]),
          ),
        ),
      );
}

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});
  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _pc = PageController();
  int _i = 0;

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    await ref.read(sharedPrefsProvider).setBool(onboardingDoneKey, true);
    if (mounted) context.go('/');
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      (Icons.smartphone_rounded, 'onb1_t', 'onb1_b'),
      (Icons.build_circle_outlined, 'onb2_t', 'onb2_b'),
      (Icons.headphones_rounded, 'onb3_t', 'onb3_b'),
    ];
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 16),
              child: SegmentedButton<String>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(value: 'ar', label: Text(context.tr('arabic'))),
                  ButtonSegment(value: 'en', label: Text(context.tr('english'))),
                ],
                selected: {context.lang},
                onSelectionChanged: (s) => ref.read(localeProvider.notifier).set(Locale(s.first)),
              ),
            ),
            TextButton(onPressed: _finish, child: Text(context.tr('skip'))),
          ]),
          Expanded(
            child: PageView.builder(
              controller: _pc,
              itemCount: pages.length,
              onPageChanged: (i) => setState(() => _i = i),
              itemBuilder: (_, i) => Padding(
                padding: const EdgeInsets.all(32),
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Container(
                    padding: const EdgeInsets.all(40),
                    decoration: const BoxDecoration(color: BrandColors.navy, shape: BoxShape.circle),
                    child: Icon(pages[i].$1, size: 88, color: BrandColors.electric),
                  ),
                  const SizedBox(height: 36),
                  Text(context.tr(pages[i].$2), textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 12),
                  Text(context.tr(pages[i].$3), textAlign: TextAlign.center, style: const TextStyle(color: BrandColors.gray, fontSize: 16)),
                ]),
              ),
            ),
          ),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            for (var i = 0; i < pages.length; i++)
              AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                margin: const EdgeInsets.all(4),
                width: i == _i ? 22 : 8,
                height: 8,
                decoration: BoxDecoration(color: i == _i ? BrandColors.electric : BrandColors.border, borderRadius: BorderRadius.circular(8)),
              ),
          ]),
          Padding(
            padding: const EdgeInsets.all(24),
            child: FilledButton(
              onPressed: _i == pages.length - 1
                  ? _finish
                  : () => _pc.nextPage(duration: const Duration(milliseconds: 300), curve: Curves.easeOut),
              child: Text(_i == pages.length - 1 ? context.tr('start') : context.tr('next')),
            ),
          ),
        ]),
      ),
    );
  }
}
