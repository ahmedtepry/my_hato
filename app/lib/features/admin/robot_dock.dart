// The shift robot's chat: it lives in the same strip at the far left of the team console as the live chat ("شات مباشر").
// Open both and they stack (messages on top, robot below); each closes on its own and goes back to just its icon in the left column.
// After "Start the shift" the robot flies to the side, says it is around, and its panel opens. "Close the shift for me" lets the robot run
// the closing on the employee's behalf (he still gives the count and his fingerprint/password: the robot never closes anything alone).
import 'dart:async';
import 'dart:convert';
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

/// When this console session started (read once when the console opens): the shift clock counts from here.
final DateTime onlineSessionStart = DateTime.now();

/// How big the robot's panel is: -1 (smaller) .. 4 (largest). The owner / employee grows or shrinks it with the buttons in its header; it is remembered.
final robotPanelStepProvider = StateProvider<int>((ref) {
  try {
    return (ref.read(sharedPrefsProvider).getInt('robot_panel_step') ?? 0).clamp(-1, 4);
  } catch (_) {
    return 0;
  }
});

/// Width of the left strip when the robot panel is open at [step].
double robotStripWidth(int step) => 374.0 + step * 70;

/// Height cap of the robot panel at [step].
double robotPanelMaxHeight(int step) => 640.0 + step * 90;

/// Whether the robot's panel is showing in the left strip.
final robotPanelOpenProvider = StateProvider<bool>((ref) => false);

/// The panel asks the till to do something ('close' | 'find'); the till clears it when it takes it. Nobody takes it when the till is not open.
final robotCommandProvider = StateProvider<String?>((ref) => null);

/// What the till answers back (shown as a robot message).
final robotReplyProvider = StateProvider<String?>((ref) => null);

class RobotMsg {
  RobotMsg(this.mine, this.text, [DateTime? at]) : at = at ?? DateTime.now();
  final bool mine;
  final String text;
  final DateTime at;

  Map<String, dynamic> toJson() => {'m': mine, 't': text, 'a': at.millisecondsSinceEpoch};
  static RobotMsg? fromJson(Object? j) {
    if (j is! Map || j['t'] is! String) return null;
    return RobotMsg(j['m'] == true, j['t'] as String, DateTime.fromMillisecondsSinceEpoch((j['a'] as num?)?.toInt() ?? 0));
  }
}

/// Each employee has his own robot conversation: it is kept on this computer under his own account id, survives closing and reopening the
/// program (the last [robotKeepDays] days, at most [robotKeepMax] messages), and is never shown to another employee who signs in afterwards.
const robotKeepDays = 7;
const robotKeepMax = 200;

class RobotMessages extends StateNotifier<List<RobotMsg>> {
  RobotMessages(this._prefs, this._uid) : super(const []) {
    final key = _key;
    if (key == null || _prefs == null) return;
    try {
      final raw = _prefs.getString(key);
      if (raw == null) return;
      final cutoff = DateTime.now().subtract(const Duration(days: robotKeepDays));
      final list = <RobotMsg>[
        for (final e in jsonDecode(raw) as List)
          if (RobotMsg.fromJson(e) case final m? when m.at.isAfter(cutoff)) m,
      ];
      super.state = list;
    } catch (_) {}
  }

  final dynamic _prefs; // SharedPreferences (null when it is not ready)
  final String? _uid;
  String? get _key => _uid == null || _uid.isEmpty ? null : 'robot_chat_$_uid';

  @override
  set state(List<RobotMsg> v) {
    final kept = v.length > robotKeepMax ? v.sublist(v.length - robotKeepMax) : v;
    super.state = kept;
    final key = _key;
    if (key == null || _prefs == null) return;
    try {
      _prefs.setString(key, jsonEncode([for (final m in kept) m.toJson()]));
    } catch (_) {}
  }

  /// True when the robot has not said anything yet today (so it greets once per day, not on every start).
  bool get noneToday {
    final n = DateTime.now();
    return !state.any((m) => m.at.year == n.year && m.at.month == n.month && m.at.day == n.day);
  }
}

/// Rebuilt for every account that signs in, so one employee's conversation can never leak into the next one's.
final robotMessagesProvider = StateNotifierProvider<RobotMessages, List<RobotMsg>>((ref) {
  final uid = ref.watch(currentUserProvider)?.id;
  dynamic prefs;
  try {
    prefs = ref.read(sharedPrefsProvider);
  } catch (_) {}
  return RobotMessages(prefs, uid);
});

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
                  child: Text(_t(context, 'لو احتجت تسألني عن حاجة أنا موجود', 'If you need to ask me anything, I am here'), style: const TextStyle(fontWeight: FontWeight.w700)),
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
  Timer? _watch;
  int _lastPending = -1;
  int _lastDone = -1;
  final Set<String> _nudged = {}; // orders already reminded about, so the robot nags once per order
  int _lastTransfer = -1;
  bool? _shiftOpen;

  @override
  void initState() {
    super.initState();
    // online employees: the robot keeps an eye on the orders and tells them when a new one arrives or one has waited too long
    _watch = Timer.periodic(const Duration(seconds: 60), (_) => _poll());
    Future.microtask(() {
      if (ref.read(robotMessagesProvider.notifier).noneToday && _isAcct()) {
        final g = timeOfDayGreeting(context).greet;
        final w = accountantWelcome[DateTime.now().day % accountantWelcome.length];
        ref.read(robotMessagesProvider.notifier).state = [
          ...ref.read(robotMessagesProvider),
          RobotMsg(false, '$g\n${_t(context, 'أنا مساعد المحاسب. هراجع معاك الأرقام والورديات والفروق، والقرار المالي دايمًا ليك.', 'I am the accountant assistant. I will go over the figures, shifts and differences with you; the financial decision is always yours.')}'),
          RobotMsg(false, _t(context, w.$1, w.$2)),
        ];
      } else if (ref.read(robotMessagesProvider.notifier).noneToday && _group() != null) {
        final g = timeOfDayGreeting(context).greet;
        final k = _group()!;
        final w = staffWelcome[k]!;
        ref.read(robotMessagesProvider.notifier).state = [
          ...ref.read(robotMessagesProvider),
          RobotMsg(false, '$g\n${_t(context, w.$1, w.$2)}'),
          RobotMsg(false, _t(context, staffValues[DateTime.now().day % staffValues.length].$1, staffValues[DateTime.now().day % staffValues.length].$2)),
        ];
      } else if (ref.read(robotMessagesProvider.notifier).noneToday) {
        ref.read(robotMessagesProvider.notifier).state = [
          ...ref.read(robotMessagesProvider),
          RobotMsg(false, _t(context, 'أنا روبوت الوردية. لو عايز تسألني، اختار من الحاجات الشائعة تحت. أنا بشرح وبساعد بس، والقرار دايمًا ليك.',
              'I am the shift robot. Pick one of the common questions below. I only explain and help, the decision is always yours.')),
        ];
      }
    });
  }

  @override
  void dispose() {
    _watch?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  /// repairs / stock / sales group for staff who are neither online nor accountant (they already have their own welcome).
  bool get _isOwner => ref.read(staffContextProvider).valueOrNull?.roles.contains('owner') ?? false;

  String? _group() {
    final p = ref.read(staffContextProvider).valueOrNull?.permissions;
    if (p == null) return null;
    if (_isOwner) return 'owner'; // the owner is not an employee: no shift, no target, no commission
    if (p.contains('repairs.view') || p.contains('repairs.manage') || p.contains('repairs.update_assigned')) return 'repairs';
    if (p.contains('products.manage') || p.contains('inventory.manage')) return 'stock';
    return null;
  }

  bool _isAcct() {
    final perms = ref.read(staffContextProvider).valueOrNull?.permissions;
    return perms != null && (perms.contains('sales.view') || perms.contains('shifts.review') || perms.contains('assistant.accountant')) && !perms.contains('orders.view');
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

  /// Counts the things an online employee has to act on. Null when it cannot be read.
  Future<({int pending, int oldestMin, int walletWait, int branchWait, int accounts})?> _counts() async {
    try {
      final rows = await ref.read(supabaseProvider).from('orders')
          .select('created_at, status, fulfillment, payment_method, payment_status, branch_confirmed')
          .isFilter('closed_at', null)
          .not('status', 'in', '(delivered,cancelled)')
          .limit(500) as List;
      var pending = 0, wallet = 0, branch = 0;
      DateTime? oldest;
      for (final r in rows) {
        final m = r as Map;
        if (m['status'] == 'pending_confirmation') {
          pending++;
          final at = DateTime.tryParse('${m['created_at']}');
          if (at != null && (oldest == null || at.isBefore(oldest))) oldest = at;
        }
        if (m['payment_method'] == 'wallet' && m['payment_status'] == 'unpaid') wallet++;
        if (m['fulfillment'] == 'pickup' && m['branch_confirmed'] != true) branch++;
      }
      ref.invalidate(pendingAccountsCountProvider);
      final acc = await ref.read(pendingAccountsCountProvider.future).catchError((_) => 0);
      return (pending: pending, oldestMin: oldest == null ? 0 : DateTime.now().difference(oldest).inMinutes, walletWait: wallet, branchWait: branch, accounts: acc);
    } catch (_) {
      return null;
    }
  }

  Future<void> _poll() async {
    if (!mounted) return;
    final online = ref.read(staffContextProvider).valueOrNull?.permissions.contains('orders.view') ?? false;
    if (!online) return;
    if (!_isOwner && (ref.read(staffContextProvider).valueOrNull?.permissions.contains('online.mine') ?? false)) {
      try {
        final st = Map<String, dynamic>.from(await ref.read(supabaseProvider).rpc('my_online_status') as Map); // also sends the 50 / 75 / 100 percent target notifications
        final done = (st['orders_done'] as num?)?.toInt() ?? 0;
        final com = (st['commission_today_minor'] as num?)?.toInt() ?? 0;
        if (_lastDone >= 0 && done > _lastDone && mounted) {
          final c = _cheers[done % _cheers.length];
          final line = '${_t(context, c.$1, c.$2)}${com > 0 ? '\n${_t(context, 'عمولتك النهارده: ${_egp(com)}', 'Your commission today: ${_egp(com)}')}' : ''}';
          _add(RobotMsg(false, line));
          playRobotCheer(context, _t(context, c.$1, c.$2));
        }
        _lastDone = done;
      } catch (_) {}
      try {
        // A customer waiting more than 15 minutes for confirmation: remind the online employee once per order.
        final rows = await ref.read(supabaseProvider).from('orders').select('id, created_at').eq('status', 'pending_confirmation').isFilter('closed_at', null).limit(50) as List;
        final late = <String>[];
        for (final r in rows) {
          final m = r as Map;
          final at = DateTime.tryParse('${m['created_at']}');
          if (at != null && DateTime.now().difference(at).inMinutes >= 15 && _nudged.add('${m['id']}')) late.add('${m['id']}');
        }
        if (late.isNotEmpty && mounted) {
          final msg = _t(context, 'فيه ${late.length} عميل مستني التأكيد من أكتر من ربع ساعة. افتح «طلبات المبيعات» وكلّمهم دلوقتي.', '${late.length} customer(s) have been waiting for confirmation for over 15 minutes. Open Sales orders and call them now.');
          _add(RobotMsg(false, msg));
          playRobotCheer(context, _t(context, 'فيه عميل مستني', 'A customer is waiting'));
        }
      } catch (_) {}
    }
    if (ref.read(staffContextProvider).valueOrNull?.permissions.contains('wallet.view') ?? false) {
      try {
        final r = Map<String, dynamic>.from(await ref.read(supabaseProvider).rpc('wallet_inbox_list', params: {'p_limit': 5}) as Map);
        final list = (r['transfers'] as List? ?? const []);
        final top = list.isEmpty ? 0 : ((list.first as Map)['id'] as num).toInt();
        if (_lastTransfer >= 0 && top > _lastTransfer && mounted) {
          for (final e in list.reversed) {
            final m = e as Map;
            if ((m['id'] as num) > _lastTransfer && m['status'] == 'new') {
              final amt = (m['amount_minor'] as num?) == null ? '' : _egp(m['amount_minor'] as num);
              _add(RobotMsg(false, _t(context, 'وصل تحويل $amt${m['sender'] == null ? '' : ' من ${m['sender']}'}. افتح «استقبال المحافظ» واربطه بالأوردر.', 'A transfer arrived $amt${m['sender'] == null ? '' : ' from ${m['sender']}'}. Open the wallet inbox and link it to the order.')));
              playRobotCheer(context, _t(context, 'وصل تحويل $amt', 'Transfer received $amt'));
            }
          }
        }
        _lastTransfer = top;
      } catch (_) {}
    }
    final c = await _counts();
    if (c == null || !mounted) return;
    if (_lastPending >= 0 && c.pending > _lastPending) {
      _add(RobotMsg(false, _t(context, 'وصل طلب جديد! عندك دلوقتي ${c.pending} طلب مستني التأكيد.', 'A new order arrived! You now have ${c.pending} waiting for confirmation.')));
    } else if (c.pending > 0 && c.oldestMin >= 30 && (_lastPending < 0 || c.oldestMin % 30 < 1)) {
      _add(RobotMsg(false, _t(context, 'في طلب مستني من ${_ago(c.oldestMin)}. الأحسن تتصل بالعميل وتأكده.', 'An order has waited for ${_ago(c.oldestMin)}. Better call the customer and confirm it.')));
    }
    _lastPending = c.pending;
  }

  String _ago(int min) => min < 60 ? _t(context, '$min دقيقة', '$min min') : _t(context, '${min ~/ 60} ساعة', '${min ~/ 60} h');

  /// "What should I do now?": everything that is waiting, in the order to do it.
  Future<void> _summary() async {
    _add(RobotMsg(true, _t(context, 'إيه المطلوب مني دلوقتي؟', 'What should I do now?')));
    final c = await _counts();
    if (!mounted) return;
    if (c == null) {
      _add(RobotMsg(false, _t(context, 'معرفتش أقرا الطلبات دلوقتي. جرّب تاني بعد شوية.', 'I could not read the orders now. Try again in a moment.')));
      return;
    }
    final todo = <String>[
      if (c.pending > 0) _t(context, '${c.pending} طلب جديد مستني التأكيد (أقدمهم من ${_ago(c.oldestMin)})', '${c.pending} new order(s) to confirm (oldest ${_ago(c.oldestMin)})'),
      if (c.branchWait > 0) _t(context, '${c.branchWait} طلب استلام محتاج تحدد له الفرع بعد ما تكلّم العميل', '${c.branchWait} pickup order(s) need a branch after you call the customer'),
      if (c.walletWait > 0) _t(context, '${c.walletWait} طلب بمحفظة محتاج تتأكد إن التحويل وصل', '${c.walletWait} wallet order(s): check the transfer arrived'),
      if (c.accounts > 0) _t(context, '${c.accounts} حساب مستني التوثيق', '${c.accounts} account(s) waiting for verification'),
    ];
    _add(RobotMsg(false, todo.isEmpty
        ? _t(context, 'كله تمام، مفيش حاجة مستنياك دلوقتي.', 'All clear, nothing is waiting for you right now.')
        : [for (var i = 0; i < todo.length; i++) '${i + 1}. ${todo[i]}'].join('\n')));
    _lastPending = c.pending;
  }

  /// "My target and hours": shift time against the hours the owner set, and the orders / value targets.
  Future<void> _myPlan() async {
    _add(RobotMsg(true, _t(context, 'تارجتي وساعاتي', 'My target and hours')));
    try {
      final r = Map<String, dynamic>.from(await ref.read(supabaseProvider).rpc('my_online_status') as Map);
      if (!mounted) return;
      final lines = <String>[];
      final mins = DateTime.now().difference(onlineSessionStart).inMinutes;
      final hrs = r['daily_hours'] as num?;
      if (hrs != null) {
        final left = (hrs * 60).round() - mins;
        lines.add(_t(context, 'الشيفت: عدّى ${_dur(mins)} من ${hrs.toStringAsFixed(hrs % 1 == 0 ? 0 : 1)} ساعة${left > 0 ? '، فاضل ${_dur(left)}' : '، خلصت ساعاتك'}',
            'Shift: ${_dur(mins)} of ${hrs.toStringAsFixed(hrs % 1 == 0 ? 0 : 1)} h${left > 0 ? ', ${_dur(left)} left' : ', your hours are done'}'));
      } else {
        lines.add(_t(context, 'الشيفت: عدّى ${_dur(mins)} (مفيش ساعات محددة ليك)', 'Shift: ${_dur(mins)} so far (no hours set for you)'));
      }
      final ot = r['orders_target'] as num?, vt = r['value_target_minor'] as num?;
      if (ot != null && ot > 0) lines.add(_t(context, 'الأوردرات: ${r['orders_done']} من $ot (${r['orders_pct']}%)', 'Orders: ${r['orders_done']} of $ot (${r['orders_pct']}%)'));
      if (vt != null && vt > 0) lines.add(_t(context, 'القيمة: ${((r['value_done_minor'] as num) / 100).round()} من ${(vt / 100).round()} ج.م (${r['value_pct']}%)', 'Value: ${((r['value_done_minor'] as num) / 100).round()} of ${(vt / 100).round()} EGP (${r['value_pct']}%)'));
      if ((ot == null || ot == 0) && (vt == null || vt == 0)) lines.add(_t(context, 'لسه مفيش تارجت محدد ليك.', 'No target has been set for you yet.'));
      lines.add(_t(context, 'النهارده جهّزت ${r['orders_today']} أوردر.', 'Today you handled ${r['orders_today']} order(s).'));
      final cm = (r['commission_minor'] as num?) ?? 0, cd = (r['commission_today_minor'] as num?) ?? 0;
      lines.add(_t(context, 'عمولتك: النهارده ${_egp(cd)}، والشهر ${_egp(cm)} (من عمولة المنتجات)', 'Your commission: today ${_egp(cd)}, month ${_egp(cm)} (from product commissions)'));
      _add(RobotMsg(false, lines.join('\n')));
    } catch (_) {
      _add(RobotMsg(false, _t(context, 'معرفتش أجيب تارجتك دلوقتي.', 'I could not load your target now.')));
    }
  }


  // ------------------------------------------------------------ the accountant side of the assistant
  Future<Map<String, dynamic>?> _brief() async {
    try {
      return Map<String, dynamic>.from(await ref.read(supabaseProvider).rpc('accountant_brief') as Map);
    } catch (_) {
      if (mounted) _add(RobotMsg(false, _t(context, 'معرفتش أقرا الأرقام دلوقتي. جرّب تاني بعد شوية.', 'I could not read the figures now. Try again in a moment.')));
      return null;
    }
  }

  String _egp(num minor) {
    final v = (minor / 100).round().toString();
    final b = StringBuffer();
    for (var i = 0; i < v.length; i++) {
      if (i > 0 && (v.length - i) % 3 == 0 && v[i - 1] != '-') b.write(',');
      b.write(v[i]);
    }
    return _t(context, '$b ج.م', '$b EGP');
  }

  num _n(Object? v) => v is num ? v : 0;

  Future<void> _accToday() async {
    _add(RobotMsg(true, _t(context, 'ملخص النهارده', 'Today summary')));
    final r = await _brief();
    if (r == null || !mounted) return;
    final t = Map<String, dynamic>.from(r['today'] as Map), y = Map<String, dynamic>.from(r['yesterday'] as Map);
    final on = Map<String, dynamic>.from(r['online_today'] as Map);
    final net = _n(t['gross_minor']) - _n(t['refunds_minor']), yNet = _n(y['gross_minor']) - _n(y['refunds_minor']);
    final lines = <String>[
      _t(context, 'مبيعات الفروع النهارده: ${_egp(net)} في ${t['count']} فاتورة', 'Branch sales today: ${_egp(net)} in ${t['count']} invoice(s)'),
      if (_n(t['refunds_minor']) > 0) _t(context, 'مرتجعات: ${_egp(_n(t['refunds_minor']))}', 'Refunds: ${_egp(_n(t['refunds_minor']))}'),
      if (_n(t['discount_minor']) > 0) _t(context, 'خصومات: ${_egp(_n(t['discount_minor']))}', 'Discounts: ${_egp(_n(t['discount_minor']))}'),
      if (yNet > 0)
        _t(context, 'مقارنة بإمبارح (${_egp(yNet)}): ${net >= yNet ? 'أعلى' : 'أقل'} بنسبة ${((net - yNet).abs() * 100 / yNet).round()}%',
            'Versus yesterday (${_egp(yNet)}): ${net >= yNet ? 'up' : 'down'} ${((net - yNet).abs() * 100 / yNet).round()}%')
      else
        _t(context, 'مفيش مبيعات إمبارح للمقارنة.', 'No sales yesterday to compare with.'),
      _t(context, 'الأونلاين النهارده: ${on['count']} طلب بقيمة ${_egp(_n(on['total_minor']))}', 'Online today: ${on['count']} order(s) worth ${_egp(_n(on['total_minor']))}'),
    ];
    final top = (r['top_today'] as List? ?? const []);
    if (top.isNotEmpty) {
      lines.add(_t(context, 'الأكتر مبيعًا:', 'Best sellers:'));
      for (final e in top) {
        final m = e as Map;
        lines.add('• ${m['name']} (${m['qty']}) ${_egp(_n(m['total_minor']))}');
      }
    }
    _add(RobotMsg(false, lines.join('\n')));
  }

  Future<void> _accShifts() async {
    _add(RobotMsg(true, _t(context, 'الورديات والفروق', 'Shifts and differences')));
    final r = await _brief();
    if (r == null || !mounted) return;
    final open = (r['open_shifts'] as List? ?? const []), vars = (r['variances'] as List? ?? const []);
    final lines = <String>[];
    if (open.isEmpty) {
      lines.add(_t(context, 'مفيش ورديات مفتوحة دلوقتي.', 'No shifts are open right now.'));
    } else {
      lines.add(_t(context, 'ورديات مفتوحة (${open.length}):', 'Open shifts (${open.length}):'));
      for (final e in open) {
        final m = e as Map;
        final long = _n(m['hours']) >= 12;
        lines.add('• ${m['branch']} - ${m['cashier']} - ${_t(context, 'من ${m['hours']} ساعة', '${m['hours']} h')}${long ? _t(context, ' (طويلة، اتأكد إنها تتقفل)', ' (long, make sure it gets closed)') : ''}');
      }
    }
    if (vars.isEmpty) {
      lines.add(_t(context, 'مفيش فروق في العهدة آخر 7 أيام. كويس.', 'No cash differences in the last 7 days. Good.'));
    } else {
      lines.add(_t(context, 'فروق عهدة آخر 7 أيام:', 'Cash differences in the last 7 days:'));
      for (final e in vars) {
        final m = e as Map;
        final v = _n(m['variance_minor']);
        lines.add('• ${m['branch']} - ${m['cashier']}: ${v < 0 ? _t(context, 'عجز', 'short') : _t(context, 'زيادة', 'over')} ${_egp(v.abs())}');
      }
      lines.add(_t(context, 'راجع الوردية من قسم «الورديات» واسأل الكاشير قبل ما تسجل أي حاجة.', 'Review the shift under Shifts and ask the cashier before recording anything.'));
    }
    _add(RobotMsg(false, lines.join('\n')));
  }

  Future<void> _accBranches() async {
    _add(RobotMsg(true, _t(context, 'الفروع النهارده', 'Branches today')));
    final r = await _brief();
    if (r == null || !mounted) return;
    final bs = (r['branches_today'] as List? ?? const []);
    _add(RobotMsg(false, bs.isEmpty
        ? _t(context, 'مفيش فروع متاحة ليك.', 'No branches available to you.')
        : [for (final e in bs) '• ${(e as Map)['name']}: ${_egp(_n(e['gross_minor']))} (${e['count']} ${_t(context, 'فاتورة', 'inv.')})'].join('\n')));
  }

  Future<void> _accMonth() async {
    _add(RobotMsg(true, _t(context, 'الشهر لحد دلوقتي', 'Month so far')));
    final r = await _brief();
    if (r == null || !mounted) return;
    final m = Map<String, dynamic>.from(r['month'] as Map);
    final net = _n(m['gross_minor']) - _n(m['refunds_minor']);
    final day = DateTime.now().day;
    _add(RobotMsg(false, [
      _t(context, 'صافي مبيعات الفروع: ${_egp(net)} في ${m['count']} فاتورة', 'Net branch sales: ${_egp(net)} in ${m['count']} invoice(s)'),
      _t(context, 'مرتجعات: ${_egp(_n(m['refunds_minor']))} - خصومات: ${_egp(_n(m['discount_minor']))}', 'Refunds: ${_egp(_n(m['refunds_minor']))} - Discounts: ${_egp(_n(m['discount_minor']))}'),
      _t(context, 'متوسط اليوم: ${_egp(net / day)}', 'Daily average: ${_egp(net / day)}'),
      _t(context, 'لو عايز ملفات الإكسيل للشهر: قسم «المساعد الآلي» > المحاسب الآلي.', 'For the month Excel files: Assistant section > Automatic accountant.'),
    ].join('\n')));
  }

  /// "What do I need to do?" for the accountant: the things that are waiting for him, in order.
  Future<void> _accTodo() async {
    _add(RobotMsg(true, _t(context, 'إيه المطلوب مني؟', 'What do I need to do?')));
    final r = await _brief();
    if (r == null || !mounted) return;
    final open = (r['open_shifts'] as List? ?? const []), vars = (r['variances'] as List? ?? const []);
    final w = Map<String, dynamic>.from(r['wallet_waiting'] as Map);
    final todo = <String>[
      if (vars.isNotEmpty) _t(context, '${vars.length} فرق عهدة آخر 7 أيام محتاج مراجعة', '${vars.length} cash difference(s) in the last 7 days to review'),
      if (_n(w['count']) > 0) _t(context, '${w['count']} طلب بمحفظة لسه التحويل ما اتأكدش (${_egp(_n(w['total_minor']))})', '${w['count']} wallet order(s) with an unconfirmed transfer (${_egp(_n(w['total_minor']))})'),
      for (final e in open)
        if (_n((e as Map)['hours']) >= 12) _t(context, 'وردية ${e['branch']} (${e['cashier']}) مفتوحة من ${e['hours']} ساعة', 'Shift ${e['branch']} (${e['cashier']}) open for ${e['hours']} h'),
    ];
    _add(RobotMsg(false, todo.isEmpty
        ? _t(context, 'كله تمام، مفيش حاجة مالية مستنياك دلوقتي.', 'All clear, nothing financial is waiting for you.')
        : [for (var i = 0; i < todo.length; i++) '${i + 1}. ${todo[i]}'].join('\n')));
  }


  Future<void> _repairsToday() async {
    _add(RobotMsg(true, _t(context, 'إيه في الصيانة؟', 'What is in repairs?')));
    try {
      final rows = await ref.read(supabaseProvider).from('repair_requests').select('status, created_at').isFilter('closed_at', null).not('status', 'in', '(delivered,cancelled)').limit(500) as List;
      var pick = 0, diag = 0, work = 0, ready = 0;
      DateTime? oldest;
      for (final r in rows) {
        final m = r as Map;
        switch (m['status']) {
          case 'pickup_requested': pick++; break;
          case 'diagnosis_completed': diag++; break;
          case 'repair_in_progress': work++; break;
          case 'ready_for_pickup': ready++; break;
        }
        final at = DateTime.tryParse('${m['created_at']}');
        if (m['status'] == 'pickup_requested' && at != null && (oldest == null || at.isBefore(oldest))) oldest = at;
      }
      final todo = <String>[
        if (pick > 0) _t(context, '$pick طلب صيانة جديد محتاج استلام الجهاز${oldest == null ? '' : ' (أقدمهم من ${_ago(DateTime.now().difference(oldest).inMinutes)})'}', '$pick new repair request(s) waiting for the device${oldest == null ? '' : ' (oldest ${_ago(DateTime.now().difference(oldest).inMinutes)})'}'),
        if (diag > 0) _t(context, '$diag جهاز تم تشخيصه ومستني موافقة العميل أو بدء الإصلاح', '$diag diagnosed device(s) waiting for the customer or to start repairing'),
        if (work > 0) _t(context, '$work جهاز قيد الإصلاح', '$work device(s) being repaired'),
        if (ready > 0) _t(context, '$ready جهاز جاهز والعميل لسه ما استلمش، كلّمه', '$ready device(s) ready; the customer has not collected, call him'),
      ];
      _add(RobotMsg(false, todo.isEmpty ? _t(context, 'مفيش صيانة مفتوحة دلوقتي.', 'No open repairs right now.') : [for (var i = 0; i < todo.length; i++) '${i + 1}. ${todo[i]}'].join('\n')));
    } catch (_) {
      _add(RobotMsg(false, _t(context, 'معرفتش أقرا الصيانة دلوقتي.', 'I could not read the repairs now.')));
    }
  }

  Future<void> _stockLow() async {
    _add(RobotMsg(true, _t(context, 'نواقص المخزون', 'Low stock')));
    try {
      final rows = await ref.read(supabaseProvider).from('products').select('name_ar, stock_quantity').neq('status', 'archived').lte('stock_quantity', 3).order('stock_quantity').limit(12) as List;
      _add(RobotMsg(false, rows.isEmpty
          ? _t(context, 'مفيش منتجات قربت تخلص.', 'Nothing is running low.')
          : '${_t(context, 'منتجات قربت تخلص:', 'Running low:')}\n${[for (final r in rows) '• ${(r as Map)['name_ar']}: ${r['stock_quantity'] == 0 ? _t(context, 'خلص', 'out') : r['stock_quantity']}'].join('\n')}'));
    } catch (_) {
      _add(RobotMsg(false, _t(context, 'معرفتش أقرا المخزون دلوقتي.', 'I could not read the stock now.')));
    }
  }


  /// The online shift: no cash at all, it only counts the orders this person confirmed that end delivered.
  Future<void> _shiftToggle() async {
    try {
      final st = Map<String, dynamic>.from(await ref.read(supabaseProvider).rpc('online_shift_state') as Map);
      final open = st['open'] == true;
      if (!open) {
        _add(RobotMsg(true, _t(context, 'افتح شيفت الأونلاين', 'Open the online shift')));
        await ref.read(supabaseProvider).rpc('online_shift_open');
        _shiftOpen = true;
        if (!mounted) return;
        final g = timeOfDayGreeting(context).greet;
        _add(RobotMsg(false, '$g\n${_t(context, 'الشيفت اتفتح. مفيش فلوس في إيدك: اللي بيتحسب ليك الأوردرات اللي بتأكدها وتتسلم. بالتوفيق!', 'The shift is open. No cash for you: what counts is the orders you confirm that get delivered. Good luck!')}'));
        playRobotCheer(context, _t(context, 'الشيفت اتفتح، يلا بينا!', 'Shift is open, let us go!'));
      } else {
        _add(RobotMsg(true, _t(context, 'اقفل شيفت الأونلاين', 'Close the online shift')));
        final r = Map<String, dynamic>.from(await ref.read(supabaseProvider).rpc('online_shift_close') as Map);
        _shiftOpen = false;
        if (!mounted) return;
        final bye = staffOutro[DateTime.now().day % staffOutro.length];
        _add(RobotMsg(false, '${_t(context, 'الشيفت اتقفل. في الشيفت ده اتسلم لك ${r['orders']} أوردر بقيمة ${_egp((r['value_minor'] as num?) ?? 0)}.', 'Shift closed. In this shift ${r['orders']} order(s) of yours were delivered, worth ${_egp((r['value_minor'] as num?) ?? 0)}.')}\n${_t(context, bye.$1, bye.$2)}'));
      }
    } catch (e) {
      if (mounted) _add(RobotMsg(false, '$e'.contains('NO_OPEN_SHIFT') ? _t(context, 'مفيش شيفت مفتوح.', 'No open shift.') : _t(context, 'معرفتش أغيّر الشيفت دلوقتي. جرّب تاني.', 'I could not change the shift now. Try again.')));
    }
  }

  String _dur(int min) => min < 60 ? _t(context, '$min دقيقة', '$min min') : _t(context, '${min ~/ 60} ساعة و${min % 60} دقيقة', '${min ~/ 60} h ${min % 60} min');

  Future<void> _newOrders() async {
    _add(RobotMsg(true, _t(context, 'طلبات جديدة', 'New orders')));
    try {
      final rows = await ref.read(supabaseProvider).from('orders').select('id').eq('status', 'pending_confirmation').isFilter('closed_at', null);
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

  void _resize(int step) {
    ref.read(robotPanelStepProvider.notifier).state = step;
    try {
      ref.read(sharedPrefsProvider).setInt('robot_panel_step', step);
    } catch (_) {}
  }

  Future<void> _off() async {
    // goodbye message first (trust and honesty for the accountant), then switch off
    final perms = ref.read(staffContextProvider).valueOrNull?.permissions;
    final acct = perms != null && (perms.contains('sales.view') || perms.contains('shifts.review') || perms.contains('assistant.accountant'));
    final bye = accountantOutro[DateTime.now().day % accountantOutro.length];
    _add(RobotMsg(false, acct
        ? '${_t(context, bye.$1, bye.$2)}\n${_t(context, 'مع السلامة، ونشوفك على خير.', 'Goodbye, see you soon.')}'
        : '${_t(context, staffOutro[DateTime.now().day % staffOutro.length].$1, staffOutro[DateTime.now().day % staffOutro.length].$2)}\n${_t(context, 'مع السلامة، ونشوفك على خير.', 'Goodbye, see you soon.')}'));
    await Future<void>.delayed(const Duration(milliseconds: 2800));
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
    final step = ref.watch(robotPanelStepProvider);
    final canClose = f['robot_close'] == true, canFind = f['find'] == true;
    final online = ref.watch(staffContextProvider).valueOrNull?.permissions.contains('orders.view') ?? false;
    final perms = ref.watch(staffContextProvider).valueOrNull?.permissions;
    final acct = perms != null && (perms.contains('sales.view') || perms.contains('shifts.review') || perms.contains('assistant.accountant'));
    return Material(
      elevation: 10,
      color: panelColor(context),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: panelLine(context))),
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
              tooltip: _t(context, 'تصغير', 'Smaller'),
              onPressed: step <= -1 ? null : () => _resize(step - 1),
              icon: Icon(Icons.zoom_out_map_rounded, color: step <= -1 ? Colors.white24 : Colors.white70, size: 19),
            ),
            IconButton(
              tooltip: _t(context, 'تكبير', 'Larger'),
              onPressed: step >= 4 ? null : () => _resize(step + 1),
              icon: Icon(Icons.open_in_full_rounded, color: step >= 4 ? Colors.white24 : Colors.white70, size: 17),
            ),
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
          // the buttons area grows with the panel size so no button is cut off (it also scrolls)
          height: 150.0 + (step + 1) * 30,
          child: Scrollbar(child: ListView(padding: const EdgeInsets.all(8), children: [
            Wrap(spacing: 6, runSpacing: 6, children: [
              if (canClose) ActionChip(avatar: const Icon(Icons.lock_clock_outlined, size: 16), label: Text(_t(context, 'قفّل الوردية عني', 'Close the shift for me')), onPressed: () => _ask('close', _t(context, 'قفّل الوردية عني', 'Close the shift for me'))),
              if (canFind) ActionChip(avatar: const Icon(Icons.search_rounded, size: 16), label: Text(_t(context, 'دوّر على منتج', 'Find a product')), onPressed: () => _ask('find', _t(context, 'دوّر على منتج', 'Find a product'))),
              if (_group() == 'repairs') ActionChip(avatar: const Icon(Icons.build_circle_outlined, size: 16), label: Text(_t(context, 'إيه في الصيانة؟', 'What is in repairs?')), onPressed: _repairsToday),
              if (_group() == 'stock' || (ref.watch(staffContextProvider).valueOrNull?.permissions.contains('inventory.manage') ?? false))
                ActionChip(avatar: const Icon(Icons.inventory_2_outlined, size: 16), label: Text(_t(context, 'نواقص المخزون', 'Low stock')), onPressed: _stockLow),
              if (acct) ...[
                ActionChip(avatar: const Icon(Icons.checklist_rounded, size: 16), label: Text(_t(context, 'إيه المطلوب مني؟', 'What do I need to do?')), onPressed: _accTodo),
                ActionChip(avatar: const Icon(Icons.today_rounded, size: 16), label: Text(_t(context, 'ملخص النهارده', 'Today summary')), onPressed: _accToday),
                ActionChip(avatar: const Icon(Icons.lock_clock_outlined, size: 16), label: Text(_t(context, 'الورديات والفروق', 'Shifts and differences')), onPressed: _accShifts),
                ActionChip(avatar: const Icon(Icons.store_mall_directory_outlined, size: 16), label: Text(_t(context, 'الفروع النهارده', 'Branches today')), onPressed: _accBranches),
                ActionChip(avatar: const Icon(Icons.calendar_month_rounded, size: 16), label: Text(_t(context, 'الشهر لحد دلوقتي', 'Month so far')), onPressed: _accMonth),
                for (final g in accountantGuides)
                  ActionChip(
                    label: Text(_t(context, g.$1, g.$2)),
                    onPressed: () {
                      _add(RobotMsg(true, _t(context, g.$1, g.$2)));
                      final steps = context.isAr ? g.$3 : g.$4;
                      _add(RobotMsg(false, [for (var i = 0; i < steps.length; i++) '${i + 1}. ${steps[i]}'].join('\n')));
                    },
                  ),
              ],
              if (online) ...[
                if (!_isOwner && (ref.watch(staffContextProvider).valueOrNull?.permissions.contains('online.shift') ?? false))
                  ActionChip(avatar: const Icon(Icons.timer_outlined, size: 16), label: Text(_t(context, 'شيفت الأونلاين (فتح/قفل)', 'Online shift (open/close)')), onPressed: _shiftToggle),
                if (!_isOwner && (ref.watch(staffContextProvider).valueOrNull?.permissions.contains('online.mine') ?? false))
                  ActionChip(avatar: const Icon(Icons.flag_outlined, size: 16), label: Text(_t(context, 'تارجتي وساعاتي', 'My target and hours')), onPressed: _myPlan),
                ActionChip(avatar: const Icon(Icons.checklist_rounded, size: 16), label: Text(_t(context, 'إيه المطلوب دلوقتي؟', 'What now?')), onPressed: _summary),
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
                for (final q in onlineScripts)
                  ActionChip(
                    avatar: const Icon(Icons.call_outlined, size: 15),
                    label: Text(_t(context, q.$1, q.$2)),
                    onPressed: () {
                      _add(RobotMsg(true, _t(context, q.$1, q.$2)));
                      final a = _t(context, q.$3, q.$4);
                      Clipboard.setData(ClipboardData(text: a));
                      _add(RobotMsg(false, '$a\n\n${_t(context, '(اتنسخ، غيّر الأقواس بالبيانات)', '(Copied: replace the brackets with the details)')}'));
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
          ])),
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

const onlineScripts = <(String, String, String, String)>[
  ('كلام مكالمة تأكيد الطلب', 'Order confirmation call', 'السلام عليكم، معاك {اسمك} من My Hatō. بخصوص طلبك رقم {رقم الطلب}: عايز أتأكد من العنوان وميعاد التوصيل المناسب ليك.', 'Hello, this is {your name} from My Hatō. About your order {number}: I would like to confirm the address and a delivery time that suits you.'),
  ('كلام تحديد فرع الاستلام', 'Choosing the pickup branch', 'السلام عليكم، معاك {اسمك} من My Hatō. بخصوص طلبك {رقم الطلب}: إنت ساكن في أنهي منطقة؟ هنقولك أقرب فرع ليك وميعاد الاستلام.', 'Hello, this is {your name} from My Hatō. About your order {number}: which area do you live in? We will tell you the nearest branch and the pickup time.'),
  ('كلام تأكيد تحويل المحفظة', 'Wallet transfer follow-up', 'السلام عليكم، بخصوص طلبك {رقم الطلب}: لسه ماوصلناش تحويل المبلغ. لو حوّلت قولي من أنهي رقم عشان أطابقه، وشكرًا لك.', 'Hello, about your order {number}: we have not received the transfer yet. If you sent it, tell me from which number so I can match it. Thank you.'),
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

/// Step-by-step help for the accountant.
const accountantGuides = <(String, String, List<String>, List<String>)>[
  ('إزاي أراجع وردية؟', 'How do I review a shift?', [
    'افتح قسم «الورديات» واختار الوردية المقفولة.',
    'قارن المتوقع بالمعدود، والفرق هيظهر لك.',
    'لو في فرق: اسأل الكاشير الأول وشوف الفواتير والمرتجعات في الوردية.',
    'اكتب ملاحظتك واعتمد المراجعة.',
  ], [
    'Open Shifts and pick the closed shift.',
    'Compare expected with counted; the difference is shown.',
    'If there is a difference: ask the cashier first and check the sales and refunds in that shift.',
    'Write your note and approve the review.',
  ]),
  ('قفل اليوم', 'Closing the day', [
    'اتأكد إن كل الورديات اتقفلت (اسألني «الورديات والفروق»).',
    'راجع فروق العهدة وسجّل سببها.',
    'اتأكد من طلبات المحافظ اللي لسه التحويل ما وصلش.',
    'خد ملخص النهارده وقارنه بالنقدية.',
  ], [
    'Make sure every shift is closed (ask me "Shifts and differences").',
    'Review cash differences and record the reason.',
    'Check the wallet orders whose transfer has not arrived.',
    'Take today summary and compare it with the cash.',
  ]),
  ('قفل الشهر', 'Month-end checklist', [
    'قفّل كل الورديات وراجع الفروق.',
    'راجع المرتجعات والخصومات الكبيرة.',
    'نزّل ملفات الشهر من «المساعد الآلي > المحاسب الآلي».',
    'راجع العمولات والتارجت قبل الصرف.',
  ], [
    'Close all shifts and review the differences.',
    'Review large refunds and discounts.',
    'Download the month files from Assistant > Automatic accountant.',
    'Review commissions and targets before paying.',
  ]),
];

/// Welcome and goodbye lines for the accountant: honesty (amana), trust and work.
const accountantWelcome = <(String, String)>[
  ('الأمانة أساس شغلك: كل رقم بتسجله هو أمانة، والدقة فيه هي اللي بتبني ثقة الناس فيك.', 'Honesty is the base of your work: every figure you record is a trust, and accuracy is what builds people\'s confidence in you.'),
  ('الثقة بتتبني بالشفافية: اكتب سبب أي فرق أو تعديل، وماتسيبش حاجة من غير توثيق.', 'Trust is built on transparency: write the reason for any difference or change, and leave nothing undocumented.'),
  ('شغلك مش أرقام وبس، ده حق الشركة وحق الموظفين. راجع بهدوء وركّز في التفاصيل.', 'Your work is more than numbers, it is the company\'s and the staff\'s right. Review calmly and watch the details.'),
  ('يوم جديد وشغل جديد: ابدأ بالورديات المفتوحة والفروق، وبعدها كمّل باقي يومك براحة.', 'A new day: start with the open shifts and differences, then carry on at ease.'),
];

const accountantOutro = <(String, String)>[
  ('قبل ما تمشي: اتأكد إن كل الورديات اتقفلت وكل فرق اتكتب سببه. الأمانة في التفاصيل الصغيرة.', 'Before you leave: make sure every shift is closed and every difference has its reason written. Honesty lives in the small details.'),
  ('شكرًا على أمانتك ودقتك النهارده. ثقة الفريق فيك هي أغلى حاجة عندك.', 'Thank you for your honesty and accuracy today. The team\'s trust in you is your most valuable asset.'),
  ('خلصت يوم شغل كويس. أرقامك النهارده واضحة وموثقة، ودي أمانة اتأدّت.', 'A good day\'s work done. Your figures are clear and documented today, a trust well kept.'),
  ('تعبك مقدّر. ارتاح، وبكرة نكمل بنفس الدقة والثقة.', 'Your effort is appreciated. Rest, and tomorrow we continue with the same accuracy and trust.'),
];

/// Welcome lines per group, and trust / honesty / work values for every employee.
const staffWelcome = <String, (String, String)>{
  'owner': ('أنا مساعدك يا صاحب المكان. بتابع الأرقام والتنبيهات وبلخّصلك الورديات والفروق والأونلاين، والقرار كله ليك.', 'I am your assistant, owner. I follow the figures and alerts and summarise shifts, differences and Online; every decision is yours.'),
  'repairs': ('أنا مساعد الصيانة. هفكّرك بالأجهزة المستنية وبالعملاء اللي لازم تكلمهم، والقرار الفني دايمًا ليك.', 'I am the repairs assistant. I will remind you of waiting devices and customers to call; the technical decision is always yours.'),
  'stock': ('أنا مساعد المخزون. هنبّهك للمنتجات اللي قربت تخلص، والتعديل دايمًا بإيدك.', 'I am the stock assistant. I will warn you about products running low; the change is always yours.'),
};
const staffValues = <(String, String)>[
  ('الأمانة في الشغل: اللي بتسلمه وتستلمه اكتبه بدقة، وده اللي بيحفظ حقك وحق الشركة.', 'Honesty at work: write exactly what you hand over and receive; it protects you and the company.'),
  ('الثقة بتتبني بالصدق: لو غلطت قول فورًا، الغلطة المكشوفة بتتصلح بسرعة.', 'Trust is built on truth: if you make a mistake, say so right away; an open mistake is fixed fast.'),
  ('شغلك بيفرق مع كل عميل. خدمة محترمة وهادية بتكسب عميل لسنين.', 'Your work matters to every customer. Calm, respectful service wins a customer for years.'),
];
const staffOutro = <(String, String)>[
  ('شكرًا على أمانتك وتعبك النهارده. ثقة الفريق فيك بتكبر بشغلك.', 'Thank you for your honesty and effort today. The team\'s trust in you grows with your work.'),
  ('خلصت يوم شغل كويس. اتأكد إن كل حاجة اتسلمت واتسجلت قبل ما تمشي.', 'A good day done. Make sure everything is handed over and recorded before you leave.'),
  ('تعبك مقدّر. ارتاح، وبكرة نبدأ بنشاط جديد.', 'Your effort is appreciated. Rest, and tomorrow we start fresh.'),
];

const _cheers = <(String, String)>[
  ('برافو! أوردر جديد اتسلم. شغل ممتاز!', 'Bravo! Another order delivered. Great work!'),
  ('تمام كده! عميل جديد راضي بفضلك.', 'Nice! Another happy customer thanks to you.'),
  ('بطل! كمّل على نفس النَّفَس.', 'Champion! Keep the same pace.'),
  ('جامد! الأوردر ده زوّد تارجتك.', 'Awesome! That order moved your target up.'),
];

/// A short cheer: the robot hops in with a message (same cheap transform-only animation as the welcome).
void playRobotCheer(BuildContext context, String text) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  late OverlayEntry entry;
  entry = OverlayEntry(builder: (_) => IgnorePointer(child: _WalkingRobot(greet: text, icon: Icons.emoji_events_rounded, color: const Color(0xFFF59E0B), onDone: () => entry.remove())));
  overlay.insert(entry);
}
