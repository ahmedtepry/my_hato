// The shift robot's chat: it lives in the same strip at the far left of the team console as the live chat ("شات مباشر").
// Open both and they stack (messages on top, robot below); each closes on its own and goes back to just its icon in the left column.
// After "Start the shift" the robot flies to the side, says it is around, and its panel opens. "Close the shift for me" lets the robot run
// the closing on the employee's behalf (he still gives the count and his fingerprint/password: the robot never closes anything alone).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/l10n.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import 'cashier_assistant.dart';
import 'shift_robot.dart';

String _t(BuildContext c, String ar, String en) => c.isAr ? ar : en;

/// Set to true right after the opening ceremony: the dock then plays its "fly to the side" welcome once.
final robotWelcomeProvider = StateProvider<bool>((ref) => false);

/// Whether the robot's panel is showing in the left strip.
final robotPanelOpenProvider = StateProvider<bool>((ref) => false);

/// The panel asks the till to do something ('close' | 'find'); the till clears it when it takes it. Nobody takes it when the till is not open.
final robotCommandProvider = StateProvider<String?>((ref) => null);

/// What the till answers back (shown as a robot message).
final robotReplyProvider = StateProvider<String?>((ref) => null);

class RobotMsg {
  RobotMsg(this.mine, this.text);
  final bool mine;
  final String text;
}

final robotMessagesProvider = StateProvider<List<RobotMsg>>((ref) => []);

/// Lives inside the till. Plays the welcome flight and carries out what the robot panel asks for.
class RobotDock extends ConsumerStatefulWidget {
  const RobotDock({super.key, required this.onCloseShift, required this.onFind, required this.canClose});
  final Future<void> Function() onCloseShift;
  final VoidCallback onFind;
  final bool canClose; // false when the cart is not empty
  @override
  ConsumerState<RobotDock> createState() => _RobotDockState();
}

class _RobotDockState extends ConsumerState<RobotDock> with SingleTickerProviderStateMixin {
  late final AnimationController _fly = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));
  bool _welcome = false, _bubble = false;

  @override
  void initState() {
    super.initState();
    if (ref.read(robotWelcomeProvider)) {
      Future.microtask(() => ref.read(robotWelcomeProvider.notifier).state = false);
      _welcome = true;
      _fly.forward().then((_) async {
        if (!mounted) return;
        setState(() => _bubble = true);
        await Future<void>.delayed(const Duration(milliseconds: 3800));
        if (!mounted) return;
        setState(() {
          _bubble = false;
          _welcome = false;
        });
        ref.read(robotPanelOpenProvider.notifier).state = true; // it settles into the left strip, like the messages
      });
    }
  }

  @override
  void dispose() {
    _fly.dispose();
    super.dispose();
  }

  void _say(String t) {
    final l = ref.read(robotMessagesProvider);
    ref.read(robotMessagesProvider.notifier).state = [...l, RobotMsg(false, t)];
  }

  Future<void> _command(String cmd) async {
    ref.read(robotCommandProvider.notifier).state = null; // taken
    if (cmd == 'find') {
      widget.onFind();
      return;
    }
    if (cmd == 'close') {
      if (!widget.canClose) {
        _say(_t(context, 'السلة فيها حاجة لسه. خلّص البيع أو فضّيها الأول وأنا أقفل بدالك.', 'The cart is not empty. Finish or clear it first and I will close for you.'));
        return;
      }
      _say(_t(context, 'تمام، هقفل بدالك. هطلب منك عدّ الدرج وبصمتك أو الباسورد، وأنا أراجع الباقي.', 'Okay, I will close for you. I will ask for the drawer count and your fingerprint or password, and review the rest.'));
      await Future<void>.delayed(const Duration(milliseconds: 700));
      if (mounted) await widget.onCloseShift();
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<String?>(robotCommandProvider, (p, n) {
      if (n != null) _command(n);
    });
    if (!_welcome) return const SizedBox.shrink();
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth, h = c.maxHeight;
      return Stack(clipBehavior: Clip.none, children: [
        AnimatedBuilder(
          animation: _fly,
          builder: (context, _) {
            final t = Curves.easeInOutCubic.transform(_fly.value);
            final size = 190 - (190 - 72) * t;
            final left = (w / 2 - 95) * (1 - t) + 10 * t;
            final bottom = (h / 2 - 95) * (1 - t) + 90 * t;
            return Positioned(
              left: left,
              bottom: bottom,
              child: Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  color: const Color(0xFF0B1F2A),
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFF2DD4BF), width: 2),
                  boxShadow: const [BoxShadow(color: Color(0x55000000), blurRadius: 14, offset: Offset(0, 4))],
                ),
                clipBehavior: Clip.antiAlias,
                child: FittedBox(fit: BoxFit.cover, child: SizedBox(width: 190, child: RobotView(mood: _bubble ? RobotMood.happy : RobotMood.idle))),
              ),
            );
          },
        ),
        if (_bubble)
          Positioned(
            left: 92,
            bottom: 112,
            child: Material(
              elevation: 4,
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 230),
                  child: Text(_t(context, 'لو احتجت تسألني عن حاجة أنا موجود 👋', 'If you need to ask me anything, I am here 👋'), style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
            ),
          ),
      ]);
    });
  }
}

/// The robot's panel for the left strip of the team console (same look as the live chat panel).
class RobotChatPanel extends ConsumerStatefulWidget {
  const RobotChatPanel({super.key});
  @override
  ConsumerState<RobotChatPanel> createState() => _RobotChatPanelState();
}

class _RobotChatPanelState extends ConsumerState<RobotChatPanel> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (ref.read(robotMessagesProvider).isEmpty) {
        ref.read(robotMessagesProvider.notifier).state = [
          RobotMsg(false, _t(context, 'أنا روبوت الوردية. لو عايز تسألني، اختار من الحاجات الشائعة تحت. أنا بشرح وبساعد بس، والقرار دايمًا ليك.',
              'I am the shift robot. Pick one of the common questions below. I only explain and help, the decision is always yours.')),
        ];
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _add(RobotMsg m) {
    ref.read(robotMessagesProvider.notifier).state = [...ref.read(robotMessagesProvider), m];
  }

  void _toBottom() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.animateTo(_scroll.position.maxScrollExtent + 200, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      });

  Future<void> _ask(String cmd, String label) async {
    _add(RobotMsg(true, label));
    ref.read(robotCommandProvider.notifier).state = cmd;
    await Future<void>.delayed(const Duration(milliseconds: 700));
    if (!mounted) return;
    if (ref.read(robotCommandProvider) == cmd) {
      // nobody took it: the till is not open
      ref.read(robotCommandProvider.notifier).state = null;
      _add(RobotMsg(false, _t(context, 'افتح شاشة الكاشير الأول وأنا أكمّل معاك.', 'Open the cashier screen first and I will continue.')));
    }
  }

  Future<void> _off() async {
    try {
      await ref.read(supabaseProvider).rpc('assistant_my_mode_set', params: {'p_enabled': false});
    } catch (_) {}
    ref.read(robotPanelOpenProvider.notifier).state = false;
    ref.invalidate(assistantFlagsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final f = ref.watch(assistantFlagsProvider).valueOrNull ?? const {};
    final msgs = ref.watch(robotMessagesProvider);
    ref.listen<String?>(robotReplyProvider, (p, n) {
      if (n != null) {
        _add(RobotMsg(false, n));
        ref.read(robotReplyProvider.notifier).state = null;
      }
    });
    ref.listen<List<RobotMsg>>(robotMessagesProvider, (p, n) => _toBottom());
    final canClose = f['robot_close'] == true, canFind = f['find'] == true;
    return Material(
      elevation: 10,
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: const BorderSide(color: BrandColors.border)),
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        Container(
          color: const Color(0xFF0B1F2A),
          padding: const EdgeInsetsDirectional.fromSTEB(14, 6, 4, 6),
          child: Row(children: [
            const SizedBox(width: 34, height: 34, child: ClipOval(child: ColoredBox(color: Color(0xFF12303E), child: FittedBox(fit: BoxFit.cover, child: SizedBox(width: 120, child: RobotView(mood: RobotMood.happy)))))),
            const SizedBox(width: 10),
            Expanded(child: Text(_t(context, 'المساعد الآلي', 'Automatic assistant'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800))),
            IconButton(
              tooltip: _t(context, 'إيقاف المساعد الآلي', 'Turn the assistant off'),
              onPressed: _off,
              icon: const Icon(Icons.power_settings_new_rounded, color: Colors.white70, size: 20),
            ),
            IconButton(
              tooltip: _t(context, 'إغلاق', 'Close'),
              onPressed: () => ref.read(robotPanelOpenProvider.notifier).state = false,
              icon: const Icon(Icons.close_rounded, color: Colors.white),
            ),
          ]),
        ),
        Expanded(
          child: ListView(controller: _scroll, padding: const EdgeInsets.all(10), children: [
            for (final m in msgs)
              Align(
                alignment: m.mine ? AlignmentDirectional.centerEnd : AlignmentDirectional.centerStart,
                child: Container(
                  margin: const EdgeInsets.symmetric(vertical: 3),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  constraints: const BoxConstraints(maxWidth: 280),
                  decoration: BoxDecoration(color: m.mine ? const Color(0xFF0E9384) : const Color(0xFFF1F5F4), borderRadius: BorderRadius.circular(12)),
                  child: Text(m.text, style: TextStyle(color: m.mine ? Colors.white : null, height: 1.5)),
                ),
              ),
          ]),
        ),
        const Divider(height: 1),
        SizedBox(
          height: 108,
          child: ListView(padding: const EdgeInsets.all(8), children: [
            Wrap(spacing: 6, runSpacing: 6, children: [
              if (canClose) ActionChip(avatar: const Icon(Icons.lock_clock_outlined, size: 16), label: Text(_t(context, 'قفّل الوردية عني', 'Close the shift for me')), onPressed: () => _ask('close', _t(context, 'قفّل الوردية عني', 'Close the shift for me'))),
              if (canFind) ActionChip(avatar: const Icon(Icons.search_rounded, size: 16), label: Text(_t(context, 'دوّر على منتج', 'Find a product')), onPressed: () => _ask('find', _t(context, 'دوّر على منتج', 'Find a product'))),
              for (final g in assistantGuides)
                ActionChip(
                  label: Text(_t(context, g.$1, g.$2)),
                  onPressed: () {
                    _add(RobotMsg(true, _t(context, g.$1, g.$2)));
                    final steps = context.isAr ? g.$3 : g.$4;
                    _add(RobotMsg(false, [for (var i = 0; i < steps.length; i++) '${i + 1}. ${steps[i]}'].join('\n')));
                  },
                ),
            ]),
          ]),
        ),
      ]),
    );
  }
}
