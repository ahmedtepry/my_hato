// The shift robot's chat: it lives in the same strip at the far left of the team console as the live chat ("شات مباشر").
// Open both and they stack (messages on top, robot below); each closes on its own and goes back to just its icon in the left column.
// After "Start the shift" the robot flies to the side, says it is around, and its panel opens. "Close the shift for me" lets the robot run
// the closing on the employee's behalf (he still gives the count and his fingerprint/password: the robot never closes anything alone).
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/l10n.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import 'accounts_tab.dart' show pendingAccountsCountProvider;
import 'admin_repository.dart' show staffContextProvider;
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

  Future<void> _newOrders() async {
    _add(RobotMsg(true, _t(context, 'طلبات جديدة', 'New orders')));
    try {
      final rows = await ref.read(supabaseProvider).from('orders').select('id').eq('status', 'pending').isFilter('closed_at', null);
      final n = (rows as List).length;
      _add(RobotMsg(false, n == 0
          ? _t(context, 'مفيش طلبات جديدة مستنية دلوقتي.', 'No new orders are waiting right now.')
          : _t(context, 'في $n طلب جديد مستني التأكيد. افتح «طلبات المبيعات» وابدأ بأقدمهم، وكلّم العميل لو محتاج تأكيد.', '$n new order(s) waiting for confirmation. Open Sales orders and start with the oldest; call the customer if you need to confirm.')));
    } catch (_) {
      _add(RobotMsg(false, _t(context, 'معرفتش أجيب الطلبات دلوقتي. افتح «طلبات المبيعات» بنفسك.', 'I could not load the orders. Open Sales orders yourself.')));
    }
  }

  Future<void> _pendingAccounts() async {
    _add(RobotMsg(true, _t(context, 'حسابات مستنية', 'Accounts waiting')));
    ref.invalidate(pendingAccountsCountProvider);
    final n = await ref.read(pendingAccountsCountProvider.future).catchError((_) => 0);
    if (!mounted) return;
    _add(RobotMsg(false, n == 0
        ? _t(context, 'مفيش حسابات مستنية التوثيق.', 'No accounts are waiting for verification.')
        : _t(context, 'في $n حساب مستني التوثيق. افتح قسم «الحسابات» وراجعهم واحد واحد.', '$n account(s) waiting. Open Accounts and review them one by one.')));
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
    final online = ref.watch(staffContextProvider).valueOrNull?.permissions.contains('orders.view') ?? false;
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
              if (online) ...[
                ActionChip(avatar: const Icon(Icons.shopping_bag_outlined, size: 16), label: Text(_t(context, 'طلبات جديدة', 'New orders')), onPressed: _newOrders),
                ActionChip(avatar: const Icon(Icons.verified_user_outlined, size: 16), label: Text(_t(context, 'حسابات مستنية', 'Accounts waiting')), onPressed: _pendingAccounts),
                for (final q in onlineFaq)
                  ActionChip(
                    avatar: const Icon(Icons.copy_rounded, size: 15),
                    label: Text(_t(context, q.$1, q.$2)),
                    onPressed: () {
                      _add(RobotMsg(true, _t(context, q.$1, q.$2)));
                      final a = _t(context, q.$3, q.$4);
                      Clipboard.setData(ClipboardData(text: a));
                      _add(RobotMsg(false, '$a\n\n${_t(context, '(اتنسخ الرد، ابعته للعميل في الشات)', '(Copied: paste it to the customer in the chat)')}'));
                    },
                  ),
                for (final g in onlineGuides)
                  ActionChip(
                    label: Text(_t(context, g.$1, g.$2)),
                    onPressed: () {
                      _add(RobotMsg(true, _t(context, g.$1, g.$2)));
                      final steps = context.isAr ? g.$3 : g.$4;
                      _add(RobotMsg(false, [for (var i = 0; i < steps.length; i++) '${i + 1}. ${steps[i]}'].join('\n')));
                    },
                  ),
              ],
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


// ============================================================ online staff: the robot's welcome walk and its help
/// Good morning / afternoon / evening / night, from the computer's clock.
({String greet, IconData icon, Color color}) timeOfDayGreeting(BuildContext c) {
  final h = DateTime.now().hour;
  if (h >= 5 && h < 12) return (greet: _t(c, 'صباح الخير! يوم جديد وشغل حلو', 'Good morning! A fresh day ahead'), icon: Icons.wb_sunny_rounded, color: const Color(0xFFF59E0B));
  if (h >= 12 && h < 17) return (greet: _t(c, 'نهارك سعيد! يلا نشتغل', 'Good afternoon! Let us get to work'), icon: Icons.wb_sunny_outlined, color: const Color(0xFFF97316));
  if (h >= 17 && h < 21) return (greet: _t(c, 'مساء الخير! أنا معاك', 'Good evening! I am with you'), icon: Icons.wb_twilight_rounded, color: const Color(0xFF8B5CF6));
  return (greet: _t(c, 'مساء النور! سهرانين النهارده؟ أنا معاك', 'Good night! Working late? I am with you'), icon: Icons.nightlight_round, color: const Color(0xFF6366F1));
}

/// A small, cheap animation (only transforms, no heavy painting): the robot comes in from the side of the screen, hops along while
/// saying hello according to the time of day, then settles at the left strip. Calls [onSettled] when it arrives.
void playOnlineWelcome(BuildContext context, {required VoidCallback onSettled}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) {
    onSettled();
    return;
  }
  final g = timeOfDayGreeting(context);
  late OverlayEntry entry;
  entry = OverlayEntry(builder: (_) => IgnorePointer(child: _WalkingRobot(greet: g.greet, icon: g.icon, color: g.color, onDone: () {
        entry.remove();
        onSettled();
      })));
  overlay.insert(entry);
}

class _WalkingRobot extends StatefulWidget {
  const _WalkingRobot({required this.greet, required this.icon, required this.color, required this.onDone});
  final String greet;
  final IconData icon;
  final Color color;
  final VoidCallback onDone;
  @override
  State<_WalkingRobot> createState() => _WalkingRobotState();
}

class _WalkingRobotState extends State<_WalkingRobot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 4600))
    ..forward().whenComplete(() {
      if (mounted) widget.onDone();
    });

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = _c.value;
        // 0..0.18 slides in from the right edge, 0.18..0.82 walks (hops) to the left, 0.82..1 settles and fades
        final walk = Curves.easeInOut.transform(((t - 0.12) / 0.78).clamp(0.0, 1.0));
        final x = size.width + 30 - (size.width - 40 + 30) * walk; // right edge -> left strip
        final hop = t > 0.12 && t < 0.9 ? (math.sin(t * 2 * math.pi * 9)).abs() * 16 : 0.0;
        final tilt = t > 0.12 && t < 0.9 ? math.sin(t * 2 * math.pi * 9) * 0.1 : 0.0;
        final fade = t > 0.88 ? (1 - (t - 0.88) / 0.12).clamp(0.0, 1.0) : 1.0;
        final bubble = t > 0.08 && t < 0.86;
        return Opacity(
          opacity: fade,
          child: Stack(children: [
            Positioned(
              left: x - 28,
              bottom: 90 + hop,
              child: Transform.rotate(
                angle: tilt,
                child: Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(color: const Color(0xFF0B1F2A), shape: BoxShape.circle, border: Border.all(color: const Color(0xFF2DD4BF), width: 2)),
                  child: const Icon(Icons.smart_toy_rounded, color: Color(0xFF2DD4BF), size: 32),
                ),
              ),
            ),
            if (bubble)
              Positioned(
                left: (x + 34).clamp(8.0, size.width - 270),
                bottom: 160 + hop,
                child: Material(
                  elevation: 4,
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 240),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(widget.icon, color: widget.color, size: 22),
                        const SizedBox(width: 8),
                        Flexible(child: Text(widget.greet, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5, decoration: TextDecoration.none, color: Color(0xFF0B1F2A)))),
                      ]),
                    ),
                  ),
                ),
              ),
          ]),
        );
      },
    );
  }
}

/// Ready answers the online employee can send to customers (he copies one and sends it in the chat).
const onlineFaq = <(String, String, String, String)>[
  ('مدة التوصيل', 'Delivery time', 'التوصيل بياخد من يوم لتلات أيام عمل حسب المحافظة. هنكلمك لتأكيد العنوان قبل ما نشحن.', 'Delivery takes one to three working days depending on the governorate. We will call to confirm the address before shipping.'),
  ('طرق الدفع', 'Payment methods', 'تقدر تدفع كاش عند الاستلام، أو تحوّل على فودافون كاش أو اتصالات كاش أو إنستا باي من نفس رقمك أو من رقم تاني وتكتبه لنا في الطلب.', 'You can pay cash on delivery, or transfer by Vodafone Cash, Etisalat Cash or InstaPay from your own number or another one that you write in the order.'),
  ('الاستلام من الفرع', 'Pickup from a branch', 'هنكلمك نحدد أقرب فرع ليك وميعاد الاستلام، وبتستلم طلبك من هناك.', 'We will call you to set the nearest branch and the pickup time, then you collect your order there.'),
  ('الضمان والاستبدال', 'Warranty and exchange', 'المنتجات عليها ضمان حسب النوع. لو في مشكلة ابعتلنا رقم الطلب وهنساعدك في الاستبدال أو الصيانة.', 'Products come with a warranty depending on the type. If there is a problem, send us the order number and we will help with exchange or repair.'),
  ('تتبّع الطلب', 'Track my order', 'تقدر تتابع حالة طلبك من التطبيق في «طلباتي»، وهيوصلك إشعار مع كل تغيير.', 'You can follow your order in the app under My Orders, and you get a notification with every change.'),
];

const onlineGuides = <(String, String, List<String>, List<String>)>[
  ('إزاي أجهّز أوردر؟', 'How do I prepare an order?', [
    'افتح طلبات المبيعات واختار الطلب الجديد.',
    'كلّم العميل لو محتاج تأكيد (العنوان أو الفرع أو التحويل).',
    'جهّز المنتجات وغيّر الحالة لـ «قيد التجهيز» ثم «جاهز» أو «تم الشحن».',
    'لو الدفع بمحفظة: اتأكد إن التحويل وصل واضغط «استلمت التحويل».',
  ], [
    'Open Sales orders and pick the new order.',
    'Call the customer if you need to confirm (address, branch or transfer).',
    'Prepare the items and change the status to Preparing, then Ready or Shipped.',
    'For wallet payments: check the transfer arrived and press Transfer received.',
  ]),
  ('إزاي أوثّق حساب عميل؟', 'How do I verify a customer account?', [
    'افتح قسم الحسابات (الرقم عليه بيبيّن عدد اللي مستنيين).',
    'راجع بيانات العميل ورقمه.',
    'اضغط قبول أو رفض، ولو رفضت اكتب السبب.',
  ], [
    'Open Accounts (the number shows how many are waiting).',
    'Check the customer details and phone.',
    'Press Approve or Reject, and write a reason if you reject.',
  ]),
];
