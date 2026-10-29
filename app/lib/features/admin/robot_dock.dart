// The robot after "Start the shift": it flies to the left corner like a chat bubble, says it is around,
// and opens a small chat with the common questions. "Close the shift for me" lets the robot run the closing on the employee's behalf
// (he still gives the count and his fingerprint/password: the robot never closes anything alone).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/l10n.dart';
import '../../core/theme.dart';
import 'cashier_assistant.dart';
import 'shift_robot.dart';

String _t(BuildContext c, String ar, String en) => c.isAr ? ar : en;

/// Set to true right after the opening ceremony: the dock then plays its "fly to the side" welcome once.
final robotWelcomeProvider = StateProvider<bool>((ref) => false);

class _Msg {
  _Msg(this.mine, this.text);
  final bool mine;
  final String text;
}

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
  bool _welcome = false, _bubble = false, _open = false;
  final _msgs = <_Msg>[];
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    if (ref.read(robotWelcomeProvider)) {
      ref.read(robotWelcomeProvider.notifier).state = false;
      _welcome = true;
      _fly.forward().then((_) async {
        if (!mounted) return;
        setState(() => _bubble = true);
        await Future<void>.delayed(const Duration(seconds: 6));
        if (mounted) setState(() {
          _bubble = false;
          _welcome = false;
        });
      });
    } else {
      _fly.value = 1;
    }
  }

  @override
  void dispose() {
    _fly.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _say(bool mine, String t) {
    setState(() => _msgs.add(_Msg(mine, t)));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.animateTo(_scroll.position.maxScrollExtent + 200, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    });
  }

  void _openChat() {
    if (_msgs.isEmpty) {
      _msgs.add(_Msg(false, _t(context, 'أنا روبوت الوردية. لو عايز تسألني، اختار من الحاجات الشائعة تحت. أنا بشرح وبساعد بس، والقرار دايمًا ليك.',
          'I am the shift robot. Pick one of the common questions below. I only explain and help, the decision is always yours.')));
    }
    setState(() {
      _open = true;
      _bubble = false;
    });
  }

  Future<void> _closeForHim() async {
    _say(true, _t(context, 'قفّل الوردية عني', 'Close the shift for me'));
    if (!widget.canClose) {
      _say(false, _t(context, 'السلة فيها حاجة لسه. خلّص البيع أو فضّيها الأول وأنا أقفل بدالك.', 'The cart is not empty. Finish or clear it first and I will close for you.'));
      return;
    }
    _say(false, _t(context, 'تمام، هقفل بدالك. هطلب منك عدّ الدرج وبصمتك أو الباسورد، وأنا أراجع الباقي.', 'Okay, I will close for you. I will ask for the drawer count and your fingerprint or password, and review the rest.'));
    await Future<void>.delayed(const Duration(milliseconds: 900));
    if (!mounted) return;
    setState(() => _open = false);
    await widget.onCloseShift();
  }

  @override
  Widget build(BuildContext context) {
    final f = ref.watch(assistantFlagsProvider).valueOrNull ?? const {};
    final canClose = f['robot_close'] == true, canFind = f['find'] == true;
    if (!canClose && !canFind) return const SizedBox.shrink();
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth, h = c.maxHeight;
      final chatH = (h - 40).clamp(260.0, 480.0).toDouble();
      return Stack(clipBehavior: Clip.none, children: [
        AnimatedBuilder(
          animation: _fly,
          builder: (context, _) {
            final t = Curves.easeInOutCubic.transform(_fly.value);
            final size = _welcome ? 190 - (190 - 64) * t : 64.0;
            final left = _welcome ? (w / 2 - 95) * (1 - t) + 10 * t : 10.0;
            final bottom = _welcome ? (h / 2 - 95) * (1 - t) + 90 * t : 90.0;
            return Positioned(
              left: left,
              bottom: bottom,
              child: GestureDetector(
                onTap: _open ? () => setState(() => _open = false) : _openChat,
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
                  child: FittedBox(fit: BoxFit.cover, child: SizedBox(width: 190, child: RobotView(mood: _open ? RobotMood.happy : RobotMood.idle))),
                ),
              ),
            );
          },
        ),
        if (_bubble)
          Positioned(
            left: 84,
            bottom: 108,
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 350),
              builder: (context, v, child) => Opacity(opacity: v, child: Transform.translate(offset: Offset(-12 * (1 - v), 0), child: child)),
              child: Material(
                elevation: 4,
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 220),
                    child: Text(_t(context, 'لو احتجت تسألني عن حاجة أنا موجود 👋', 'If you need to ask me anything, I am here 👋'), style: const TextStyle(fontWeight: FontWeight.w700)),
                  ),
                ),
              ),
            ),
          ),
        if (_open)
          Positioned(
            left: 10,
            bottom: 160,
            child: Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(18),
              color: Colors.white,
              child: SizedBox(
                width: 330.0.clamp(0, w - 20).toDouble(),
                height: (chatH - 70).clamp(240.0, 480.0).toDouble(),
                child: Column(children: [
                  Container(
                    padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
                    decoration: const BoxDecoration(color: Color(0xFF0B1F2A), borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
                    child: Row(children: [
                      Expanded(child: Text(_t(context, 'روبوت الوردية', 'Shift robot'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800))),
                      IconButton(onPressed: () => setState(() => _open = false), icon: const Icon(Icons.close_rounded, color: Colors.white)),
                    ]),
                  ),
                  Expanded(
                    child: ListView(controller: _scroll, padding: const EdgeInsets.all(10), children: [
                      for (final m in _msgs)
                        Align(
                          alignment: m.mine ? AlignmentDirectional.centerEnd : AlignmentDirectional.centerStart,
                          child: Container(
                            margin: const EdgeInsets.symmetric(vertical: 3),
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            constraints: const BoxConstraints(maxWidth: 270),
                            decoration: BoxDecoration(color: m.mine ? const Color(0xFF0E9384) : const Color(0xFFF1F5F4), borderRadius: BorderRadius.circular(12)),
                            child: Text(m.text, style: TextStyle(color: m.mine ? Colors.white : null, height: 1.5)),
                          ),
                        ),
                    ]),
                  ),
                  const Divider(height: 1),
                  SizedBox(
                    height: 96,
                    child: ListView(padding: const EdgeInsets.all(8), children: [
                      Wrap(spacing: 6, runSpacing: 6, children: [
                        if (canClose) ActionChip(avatar: const Icon(Icons.lock_clock_outlined, size: 16), label: Text(_t(context, 'قفّل الوردية عني', 'Close the shift for me')), onPressed: _closeForHim),
                        if (canFind)
                          ActionChip(
                            avatar: const Icon(Icons.search_rounded, size: 16),
                            label: Text(_t(context, 'دوّر على منتج', 'Find a product')),
                            onPressed: () {
                              setState(() => _open = false);
                              widget.onFind();
                            },
                          ),
                        for (final g in assistantGuides)
                          ActionChip(
                            label: Text(_t(context, g.$1, g.$2)),
                            onPressed: () {
                              _say(true, _t(context, g.$1, g.$2));
                              final steps = context.isAr ? g.$3 : g.$4;
                              _say(false, [for (var i = 0; i < steps.length; i++) '${i + 1}. ${steps[i]}'].join('\n'));
                            },
                          ),
                      ]),
                    ]),
                  ),
                ]),
              ),
            ),
          ),
      ]);
    });
  }
}
