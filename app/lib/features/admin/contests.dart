// Contests ("وريّنا شطارتك"). The owner writes 1-3 questions, a motivating text and a prize, chooses who sees it (team, customers or everyone),
// how long it runs and how long each person has to answer, publishes it (a notification goes out) and announces the winners.
// Team members and customers see a card, press Start, answer against a countdown and get their result. Everything is checked and graded
// by the database (migration 0088); the right answers never reach the phone before the contest ends.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../shared/states.dart';

String _t(BuildContext c, String ar, String en) => c.isAr ? ar : en;

String _contestError(BuildContext c, Object e) {
  final m = e.toString();
  if (m.contains('HAS_ENTRIES')) return _t(c, 'فيه ناس شاركت، الأسئلة اتقفلت. انسخها كمسابقة جديدة.', 'People already entered, so the questions are locked. Copy it as a new contest.');
  if (m.contains('CONTEST_CLOSED')) return _t(c, 'المسابقة خلصت.', 'This contest has ended.');
  if (m.contains('TIME_UP')) return _t(c, 'الوقت خلص.', 'Time is up.');
  if (m.contains('ALREADY_SUBMITTED')) return _t(c, 'إنت جاوبت قبل كده.', 'You already answered.');
  return friendlyError(c, e);
}

String _mmss(Duration d) {
  final s = d.inSeconds < 0 ? 0 : d.inSeconds;
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, x = s % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(x)}' : '${two(m)}:${two(x)}';
}

List<Map<String, dynamic>> _maps(Object? v) => (v as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();

// ------------------------------------------------------------------ data
final contestActiveProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final db = ref.watch(supabaseProvider);
  if (db.auth.currentUser == null) return const [];
  final timer = Timer(const Duration(minutes: 2), ref.invalidateSelf); // new contests show up without a restart
  ref.onDispose(timer.cancel);
  try {
    return _maps(await db.rpc('contest_active'));
  } catch (_) {
    return const [];
  }
});

final contestsAdminProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  return _maps(await ref.watch(supabaseProvider).rpc('contest_admin_list'));
});

// ------------------------------------------------------------------ participant: the card and the play dialog
/// The contest card for the home page / console: only shows when a contest is running for this member.
class ContestBanner extends ConsumerWidget {
  const ContestBanner({super.key, this.margin = const EdgeInsets.fromLTRB(16, 10, 16, 0)});
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(contestActiveProvider).valueOrNull ?? const [];
    final open = list.where((c) => c['state'] == 'new' || c['state'] == 'running').toList();
    if (open.isEmpty) return const SizedBox.shrink();
    return Column(children: [
      for (final c in open)
        Padding(
          padding: margin,
          child: _ContestCard(
            contest: c,
            onTap: () async {
              await showDialog<void>(context: context, barrierDismissible: false, builder: (_) => ContestPlayDialog(contest: c));
              ref.invalidate(contestActiveProvider);
            },
          ),
        ),
    ]);
  }
}

class _ContestCard extends StatelessWidget {
  const _ContestCard({required this.contest, required this.onTap});
  final Map<String, dynamic> contest;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ends = DateTime.tryParse('${contest['ends_at']}')?.toLocal();
    final prize = contest['prize'] as String?;
    final secs = contest['answer_seconds'] as num?;
    return Material(
      borderRadius: BorderRadius.circular(18),
      elevation: 3,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Ink(
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(18), gradient: const LinearGradient(colors: [Color(0xFF1B2B5E), Color(0xFF3A5BD9)])),
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            const Text('🏆', style: TextStyle(fontSize: 38)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${contest['title']}', style: const TextStyle(color: Colors.white, fontSize: 16.5, fontWeight: FontWeight.w900)),
                const SizedBox(height: 3),
                Text(
                  [
                    _t(context, 'وريّنا شطارتك', 'Show us what you got'),
                    if (secs != null) _t(context, 'عندك ${secs.toInt()} ثانية', '${secs.toInt()} seconds to answer'),
                    if (prize != null && prize.isNotEmpty) '🎁 $prize',
                  ].join(' · '),
                  style: const TextStyle(color: Colors.white70, fontSize: 12.5),
                ),
                if (ends != null) _Remaining(until: ends, prefix: _t(context, 'باقي على نهايتها: ', 'Ends in: '), style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w700)),
              ]),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)),
              child: Text(_t(context, 'شارك', 'Join'), style: const TextStyle(color: BrandColors.navy, fontWeight: FontWeight.w900)),
            ),
          ]),
        ),
      ),
    );
  }
}

/// A live "mm:ss" until a moment (re-draws once a second).
class _Remaining extends StatefulWidget {
  const _Remaining({required this.until, this.prefix = '', this.style, this.onDone});
  final DateTime until;
  final String prefix;
  final TextStyle? style;
  final VoidCallback? onDone;
  @override
  State<_Remaining> createState() => _RemainingState();
}

class _RemainingState extends State<_Remaining> {
  Timer? _timer;
  bool _fired = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (!_fired && !widget.until.isAfter(DateTime.now())) {
        _fired = true;
        widget.onDone?.call();
      }
      setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text('${widget.prefix}${_mmss(widget.until.difference(DateTime.now()))}', style: widget.style);
}

class ContestPlayDialog extends ConsumerStatefulWidget {
  const ContestPlayDialog({super.key, required this.contest});
  final Map<String, dynamic> contest;
  @override
  ConsumerState<ContestPlayDialog> createState() => _ContestPlayDialogState();
}

class _ContestPlayDialogState extends ConsumerState<ContestPlayDialog> {
  Map<String, dynamic>? _data; // contest_open() result once started
  Map<String, dynamic>? _result; // contest_submit() result
  DateTime? _deadline;
  bool _busy = false;
  bool _submitted = false;
  String? _error;
  final Map<String, TextEditingController> _text = {};
  final Map<String, String> _choice = {};

  @override
  void initState() {
    super.initState();
    if (widget.contest['state'] == 'running') _start(); // came back to a contest he already started: his clock is running
  }

  @override
  void dispose() {
    for (final c in _text.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _start() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final d = Map<String, dynamic>.from(await ref.read(supabaseProvider).rpc('contest_open', params: {'p_id': widget.contest['id']}) as Map);
      final now = DateTime.tryParse('${d['now']}') ?? DateTime.now();
      final dl = DateTime.tryParse('${d['deadline']}');
      _deadline = dl == null ? null : DateTime.now().add(dl.difference(now)); // the server clock decides; we only count down
      if (!mounted) return;
      setState(() {
        _data = d;
        _busy = false;
        for (final q in _maps(d['questions'])) {
          _text.putIfAbsent('${q['id']}', () => TextEditingController());
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = _contestError(context, e);
        });
      }
    }
  }

  Future<void> _submit() async {
    if (_submitted || _data == null) return;
    _submitted = true;
    setState(() {
      _busy = true;
      _error = null;
    });
    final answers = <String, String>{};
    for (final q in _maps(_data!['questions'])) {
      final id = '${q['id']}';
      answers[id] = q['kind'] == 'choice' ? (_choice[id] ?? '') : (_text[id]?.text ?? '');
    }
    try {
      final r = Map<String, dynamic>.from(await ref.read(supabaseProvider).rpc('contest_submit', params: {'p_id': widget.contest['id'], 'p_answers': answers}) as Map);
      if (mounted) {
        setState(() {
          _result = r;
          _busy = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = _contestError(context, e);
          _result = {'failed': true};
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.contest;
    final state = _data?['state'] as String?;
    Widget body;
    List<Widget> actions;
    if (_result != null) {
      final failed = _result!['failed'] == true;
      final ok = (_result!['correct_count'] as num?)?.toInt() ?? 0;
      final tot = (_result!['graded_total'] as num?)?.toInt() ?? 0;
      body = Column(mainAxisSize: MainAxisSize.min, children: [
        Text(failed ? '⏰' : '🎉', style: const TextStyle(fontSize: 54)),
        const SizedBox(height: 8),
        Text(
          failed
              ? (_error ?? _t(context, 'الوقت خلص قبل ما تسلّم.', 'Time ran out before you sent your answers.'))
              : tot > 0
                  ? _t(context, 'جاوبت $ok من $tot صح في ${_result!['seconds']} ثانية. هنعلن الفايزين قريب.', 'You got $ok of $tot right in ${_result!['seconds']} seconds. Winners are announced soon.')
                  : _t(context, 'وصلت إجابتك! هنراجعها ونعلن الفايزين قريب.', 'Your answers are in! We will review them and announce the winners soon.'),
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 15, height: 1.6),
        ),
      ]);
      actions = [FilledButton(onPressed: () => Navigator.pop(context), child: Text(_t(context, 'تمام', 'OK')))];
    } else if (_data == null) {
      // before he presses Start
      final secs = (c['answer_seconds'] as num?)?.toInt();
      body = Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('🏆', style: TextStyle(fontSize: 54)),
        const SizedBox(height: 6),
        Text('${c['title']}', textAlign: TextAlign.center, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900)),
        if ((c['intro'] as String?)?.isNotEmpty ?? false) ...[
          const SizedBox(height: 8),
          Text('${c['intro']}', textAlign: TextAlign.center, style: const TextStyle(fontSize: 14, height: 1.6, color: BrandColors.gray)),
        ],
        if ((c['prize'] as String?)?.isNotEmpty ?? false) ...[
          const SizedBox(height: 8),
          Text('🎁 ${c['prize']}', textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w800)),
        ],
        const SizedBox(height: 10),
        Text(
          secs == null ? _t(context, 'جاهز؟ دوس ابدأ وجاوب.', 'Ready? Tap Start and answer.') : _t(context, 'جاهز؟ أول ما تدوس ابدأ هيشتغل عدّاد $secs ثانية.', 'Ready? A $secs second countdown starts when you tap Start.'),
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
        ),
        if (_error != null) ...[const SizedBox(height: 8), Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: BrandColors.error, fontSize: 13))],
      ]);
      actions = [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: Text(_t(context, 'بعدين', 'Later'))),
        FilledButton.icon(onPressed: _busy ? null : _start, icon: const Icon(Icons.play_arrow_rounded), label: Text(_t(context, 'ابدأ', 'Start'))),
      ];
    } else if (state == 'running') {
      final qs = _maps(_data!['questions']);
      body = SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (_deadline != null)
              Center(
                child: _Remaining(until: _deadline!, prefix: '⏱ ', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: BrandColors.warning), onDone: _submit),
              ),
            const SizedBox(height: 10),
            for (final q in qs) ...[
              Text('${q['position']}. ${q['body']}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, height: 1.5)),
              const SizedBox(height: 6),
              if (q['kind'] == 'choice')
                for (final o in (q['options'] as List? ?? const []).map((e) => '$e'))
                  RadioListTile<String>(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: o,
                    groupValue: _choice['${q['id']}'],
                    onChanged: _busy ? null : (v) => setState(() => _choice['${q['id']}'] = v ?? ''),
                    title: Text(o),
                  )
              else
                TextField(
                  controller: _text['${q['id']}'],
                  enabled: !_busy,
                  decoration: InputDecoration(hintText: _t(context, 'اكتب إجابتك', 'Type your answer'), border: const OutlineInputBorder()),
                ),
              const SizedBox(height: 14),
            ],
            if (_error != null) Text(_error!, style: const TextStyle(color: BrandColors.error, fontSize: 13)),
          ]),
        ),
      );
      actions = [FilledButton.icon(onPressed: _busy ? null : _submit, icon: const Icon(Icons.send_rounded), label: Text(_t(context, 'سلّم الإجابة', 'Submit')))];
    } else {
      // done or missed (he opened it again)
      final done = state == 'done';
      final ok = (_data!['correct_count'] as num?)?.toInt() ?? 0;
      final tot = (_data!['graded_total'] as num?)?.toInt() ?? 0;
      final reveal = _data!['answers_reveal'];
      body = Column(mainAxisSize: MainAxisSize.min, children: [
        Text(done ? ((_data!['is_winner'] == true) ? '🏆' : '✅') : '⏰', style: const TextStyle(fontSize: 54)),
        const SizedBox(height: 8),
        Text(
          done
              ? (_data!['is_winner'] == true
                  ? _t(context, 'مبروك، إنت من الفايزين!', 'Congratulations, you are a winner!')
                  : tot > 0
                      ? _t(context, 'جاوبت $ok من $tot صح.', 'You got $ok of $tot right.')
                      : _t(context, 'إجابتك وصلت.', 'Your answers are in.'))
              : _t(context, 'الوقت خلص قبل ما تسلّم.', 'Time ran out before you sent your answers.'),
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
        if (reveal is Map && reveal.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(_t(context, 'الإجابات الصح: ${reveal.values.map((v) => '$v'.split('|').first).join(' / ')}', 'Right answers: ${reveal.values.map((v) => '$v'.split('|').first).join(' / ')}'),
              textAlign: TextAlign.center, style: const TextStyle(color: BrandColors.gray)),
        ],
      ]);
      actions = [FilledButton(onPressed: () => Navigator.pop(context), child: Text(_t(context, 'تمام', 'OK')))];
    }
    return PopScope(
      canPop: state != 'running' || _result != null,
      child: AlertDialog(
        content: SingleChildScrollView(child: body),
        actionsAlignment: MainAxisAlignment.center,
        actions: actions,
      ),
    );
  }
}

// ------------------------------------------------------------------ owner: the contests page
class ContestsPanel extends ConsumerWidget {
  const ContestsPanel({super.key});

  Future<void> _edit(BuildContext context, WidgetRef ref, {String? id, Map<String, dynamic>? copyOf}) async {
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => _ContestEditor(id: id, copyOf: copyOf)));
    if (saved == true) ref.invalidate(contestsAdminProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(contestsAdminProvider);
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context, ref),
        icon: const Icon(Icons.add_rounded),
        label: Text(_t(context, 'مسابقة جديدة', 'New contest')),
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(contestsAdminProvider),
        child: data.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(contestsAdminProvider)),
          data: (list) => ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 96), children: [
            Text(
              _t(context, 'اكتب سؤال لـ 3 أسئلة ونص تحفيزي، حدّد المدة والجمهور (الفريق أو العملاء)، وانشرها. كله بيوصله إشعار «وريّنا شطارتك». بعدها تتابع النتايج وتعلن الفايزين.',
                  'Write up to 3 questions and a motivating text, set the time and audience (team or customers) and publish. Everyone in the audience gets a notification. Then follow the results and announce the winners.'),
              style: const TextStyle(color: BrandColors.gray, fontSize: 13),
            ),
            const SizedBox(height: 12),
            if (list.isEmpty)
              Padding(padding: const EdgeInsets.only(top: 40), child: Center(child: Text(_t(context, 'لسه مفيش مسابقات. دوس «مسابقة جديدة».', 'No contests yet. Tap New contest.'))))
            else
              for (final c in list) _ContestTile(contest: c, onEdit: (id, {copyOf}) => _edit(context, ref, id: id, copyOf: copyOf)),
          ]),
        ),
      ),
    );
  }
}

class _ContestTile extends ConsumerWidget {
  const _ContestTile({required this.contest, required this.onEdit});
  final Map<String, dynamic> contest;
  final Future<void> Function(String? id, {Map<String, dynamic>? copyOf}) onEdit;

  Future<void> _run(BuildContext context, WidgetRef ref, Future<Object?> Function() job, {String? ok}) async {
    try {
      await job();
      ref.invalidate(contestsAdminProvider);
      ref.invalidate(contestActiveProvider);
      if (context.mounted && ok != null) showSnack(context, ok);
    } catch (e) {
      if (context.mounted) showSnack(context, _contestError(context, e), error: true);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.read(supabaseProvider);
    final id = '${contest['id']}';
    final state = '${contest['state']}';
    final entries = (contest['entries'] as num?)?.toInt() ?? 0;
    final submitted = (contest['submitted'] as num?)?.toInt() ?? 0;
    final audience = switch ('${contest['audience']}') {
      'team' => _t(context, 'الفريق', 'Team'),
      'customers' => _t(context, 'العملاء', 'Customers'),
      _ => _t(context, 'الفريق والعملاء', 'Team and customers'),
    };
    final (label, color) = switch (state) {
      'running' => (_t(context, 'شغّالة دلوقتي', 'Running'), BrandColors.success),
      'ended' => (_t(context, 'الوقت خلص', 'Time is up'), BrandColors.warning),
      'closed' => (_t(context, 'اتقفلت', 'Closed'), BrandColors.gray),
      _ => (_t(context, 'مسودة', 'Draft'), BrandColors.electric),
    };
    final ends = DateTime.tryParse('${contest['ends_at']}')?.toLocal();
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: state == 'running' ? BrandColors.success : BrandColors.border, width: state == 'running' ? 2 : 1)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Text('🏆 ', style: TextStyle(fontSize: 20)),
            Expanded(child: Text('${contest['title']}', style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w900))),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
              child: Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 12)),
            ),
          ]),
          const SizedBox(height: 4),
          Text(
            _t(context, '$audience · ${contest['questions']} أسئلة · ${contest['duration_minutes']} دقيقة${contest['answer_seconds'] != null ? ' · ${contest['answer_seconds']} ث للحل' : ''} · ${contest['winners_count']} فايز',
                '$audience · ${contest['questions']} questions · ${contest['duration_minutes']} min${contest['answer_seconds'] != null ? ' · ${contest['answer_seconds']}s to answer' : ''} · ${contest['winners_count']} winner(s)'),
            style: const TextStyle(color: BrandColors.gray, fontSize: 12.5),
          ),
          if (state != 'draft')
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(children: [
                Text(_t(context, '$entries دخلوا · $submitted سلّموا', '$entries entered · $submitted submitted'), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                if (state == 'running' && ends != null) ...[
                  const SizedBox(width: 10),
                  _Remaining(until: ends, prefix: _t(context, '⏱ باقي ', '⏱ left '), style: const TextStyle(color: BrandColors.success, fontWeight: FontWeight.w800, fontSize: 13)),
                ],
              ]),
            ),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (state == 'draft' || state == 'ended')
              FilledButton.icon(
                onPressed: () async {
                  final yes = await _confirm(context, _t(context, 'نشر المسابقة؟', 'Publish the contest?'),
                      _t(context, 'هتبدأ دلوقتي وتفضل ${contest['duration_minutes']} دقيقة، وكل الجمهور المحدد هيوصله إشعار.', 'It starts now and runs ${contest['duration_minutes']} minutes. Everyone in the audience gets a notification.'));
                  if (yes != true || !context.mounted) return;
                  await _run(context, ref, () => db.rpc('contest_publish', params: {'p_id': id, 'p_notify': true}),
                      ok: _t(context, 'المسابقة بدأت واتبعت الإشعار ✅', 'The contest started and the notification was sent ✅'));
                },
                icon: const Icon(Icons.campaign_rounded, size: 18),
                label: Text(_t(context, 'انشر وابعت إشعار', 'Publish and notify')),
              ),
            if (state == 'running') ...[
              OutlinedButton.icon(
                onPressed: () => _run(context, ref, () => db.rpc('contest_publish', params: {'p_id': id, 'p_notify': true}), ok: _t(context, 'اتبعت تذكير للجمهور', 'A reminder was sent')),
                icon: const Icon(Icons.notifications_active_outlined, size: 18),
                label: Text(_t(context, 'ذكّرهم', 'Remind')),
              ),
              OutlinedButton.icon(
                onPressed: () async {
                  final mins = await _pickMinutes(context);
                  if (mins == null || !context.mounted) return;
                  await _run(context, ref, () => db.rpc('contest_extend', params: {'p_id': id, 'p_minutes': mins}), ok: _t(context, 'اتمدّدت $mins دقيقة', 'Extended by $mins minutes'));
                },
                icon: const Icon(Icons.more_time_rounded, size: 18),
                label: Text(_t(context, 'مدّد الوقت', 'Extend')),
              ),
            ],
            if (state == 'ended' || state == 'closed')
              OutlinedButton.icon(
                onPressed: () async {
                  final mins = await _pickMinutes(context);
                  if (mins == null || !context.mounted) return;
                  await _run(context, ref, () => db.rpc('contest_extend', params: {'p_id': id, 'p_minutes': mins}), ok: _t(context, 'المسابقة اتفتحت تاني $mins دقيقة', 'Reopened for $mins minutes'));
                },
                icon: const Icon(Icons.replay_rounded, size: 18),
                label: Text(_t(context, 'افتحها تاني', 'Reopen')),
              ),
            if (state != 'draft')
              OutlinedButton.icon(
                onPressed: () => showModalBottomSheet<void>(context: context, isScrollControlled: true, showDragHandle: true, builder: (_) => _ResultsSheet(contestId: id, title: '${contest['title']}', announced: contest['announced_at'] != null)),
                icon: const Icon(Icons.leaderboard_rounded, size: 18),
                label: Text(_t(context, 'النتايج', 'Results')),
              ),
            if (state == 'running')
              OutlinedButton.icon(
                onPressed: () async {
                  final yes = await _confirm(context, _t(context, 'إيقاف المسابقة؟', 'Stop the contest?'), _t(context, 'محدّش هيقدر يشارك بعد كده.', 'Nobody can enter after this.'));
                  if (yes != true || !context.mounted) return;
                  await _run(context, ref, () => db.rpc('contest_set_status', params: {'p_id': id, 'p_status': 'closed'}), ok: _t(context, 'اتقفلت', 'Closed'));
                },
                icon: const Icon(Icons.stop_circle_outlined, size: 18),
                label: Text(_t(context, 'اوقفها', 'Stop')),
              ),
            if (entries == 0)
              OutlinedButton.icon(onPressed: () => onEdit(id), icon: const Icon(Icons.edit_outlined, size: 18), label: Text(_t(context, 'عدّل', 'Edit'))),
            OutlinedButton.icon(
              onPressed: () async {
                try {
                  final full = Map<String, dynamic>.from(await db.rpc('contest_admin_get', params: {'p_id': id}) as Map);
                  await onEdit(null, copyOf: full);
                } catch (e) {
                  if (context.mounted) showSnack(context, _contestError(context, e), error: true);
                }
              },
              icon: const Icon(Icons.copy_rounded, size: 18),
              label: Text(_t(context, 'انسخها', 'Copy')),
            ),
            TextButton.icon(
              onPressed: () async {
                final yes = await _confirm(context, _t(context, 'مسح المسابقة؟', 'Delete the contest?'), _t(context, 'هتتمسح هي ونتايجها.', 'It and its results will be deleted.'));
                if (yes != true || !context.mounted) return;
                await _run(context, ref, () => db.rpc('contest_delete', params: {'p_id': id}), ok: _t(context, 'اتمسحت', 'Deleted'));
              },
              icon: const Icon(Icons.delete_outline_rounded, size: 18, color: BrandColors.error),
              label: Text(_t(context, 'امسح', 'Delete'), style: const TextStyle(color: BrandColors.error)),
            ),
          ]),
        ]),
      ),
    );
  }
}

Future<bool?> _confirm(BuildContext context, String title, String body) => showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(_t(ctx, 'لأ', 'No'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(_t(ctx, 'تمام', 'Yes'))),
        ],
      ),
    );

Future<int?> _pickMinutes(BuildContext context) => showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(_t(ctx, 'كام دقيقة تزوّد؟', 'How many minutes to add?')),
        children: [
          for (final m in const [10, 30, 60, 180, 1440])
            SimpleDialogOption(onPressed: () => Navigator.pop(ctx, m), child: Text(m < 60 ? _t(ctx, '$m دقيقة', '$m minutes') : m == 1440 ? _t(ctx, 'يوم', 'One day') : _t(ctx, '${m ~/ 60} ساعة', '${m ~/ 60} hours'))),
        ],
      ),
    );

// ------------------------------------------------------------------ owner: results
class _ResultsSheet extends ConsumerStatefulWidget {
  const _ResultsSheet({required this.contestId, required this.title, required this.announced});
  final String contestId, title;
  final bool announced;
  @override
  ConsumerState<_ResultsSheet> createState() => _ResultsSheetState();
}

class _ResultsSheetState extends ConsumerState<_ResultsSheet> {
  List<Map<String, dynamic>>? _rows;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = _maps(await ref.read(supabaseProvider).rpc('contest_results', params: {'p_id': widget.contestId}));
      if (mounted) setState(() => _rows = r);
    } catch (e) {
      if (mounted) setState(() => _error = _contestError(context, e));
    }
  }

  Future<void> _toggle(Map<String, dynamic> r) async {
    final win = r['is_winner'] != true;
    try {
      await ref.read(supabaseProvider).rpc('contest_set_winner', params: {'p_entry': r['entry_id'], 'p_win': win});
      setState(() => r['is_winner'] = win);
    } catch (e) {
      if (mounted) showSnack(context, _contestError(context, e), error: true);
    }
  }

  Future<void> _announce() async {
    final yes = await _confirm(context, _t(context, 'إعلان الفايزين؟', 'Announce the winners?'),
        _t(context, 'المسابقة هتتقفل والفايزين (اللي علّمت عليهم، أو أحسن النتايج لو ما علّمتش حد) هيوصلهم إشعار.', 'The contest closes and the winners (the ones you ticked, or the best scores if none) get a notification.'));
    if (yes != true) return;
    setState(() => _busy = true);
    try {
      final n = await ref.read(supabaseProvider).rpc('contest_announce', params: {'p_id': widget.contestId});
      ref.invalidate(contestsAdminProvider);
      ref.invalidate(contestActiveProvider);
      if (mounted) {
        showSnack(context, _t(context, 'اتعلن $n فايز واتبعتلهم إشعار 🏆', '$n winner(s) announced and notified 🏆'));
        await _load();
      }
    } catch (e) {
      if (mounted) showSnack(context, _contestError(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('🏆 ${widget.title}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
            const SizedBox(height: 4),
            Text(_t(context, 'مرتّبين بأكتر إجابات صح ثم الأسرع. علّم (⭐) على اللي عايزه يفوز، أو سيب النظام يختار الأحسن.', 'Sorted by most right answers, then fastest. Tick ⭐ the winners you want, or let the system pick the best.'),
                style: const TextStyle(color: BrandColors.gray, fontSize: 12.5)),
            const SizedBox(height: 8),
            if (_error != null) Text(_error!, style: const TextStyle(color: BrandColors.error)),
            if (rows == null && _error == null) const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
            if (rows != null && rows.isEmpty) Padding(padding: const EdgeInsets.all(24), child: Center(child: Text(_t(context, 'لسه محدّش شارك.', 'Nobody has entered yet.')))),
            if (rows != null && rows.isNotEmpty)
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: rows.length,
                  itemBuilder: (_, i) {
                    final r = rows[i];
                    final answers = (r['answers'] as Map?) ?? const {};
                    final submitted = r['submitted_at'] != null;
                    final tot = (r['graded_total'] as num?)?.toInt() ?? 0;
                    return ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      leading: CircleAvatar(radius: 15, child: Text('${i + 1}', style: const TextStyle(fontSize: 12))),
                      title: Text('${r['name']}${r['is_team'] == true ? _t(context, '  (فريق)', '  (team)') : ''}', style: const TextStyle(fontWeight: FontWeight.w800)),
                      subtitle: Text(submitted
                          ? (tot > 0 ? _t(context, '${r['correct_count']} من $tot صح · ${r['seconds']} ث', '${r['correct_count']} of $tot right · ${r['seconds']}s') : _t(context, 'سلّم في ${r['seconds']} ث', 'Submitted in ${r['seconds']}s'))
                          : _t(context, 'دخل ولسه ما سلّمش', 'Entered, not submitted')),
                      trailing: IconButton(
                        tooltip: _t(context, 'فايز', 'Winner'),
                        icon: Icon(r['is_winner'] == true ? Icons.star_rounded : Icons.star_border_rounded, color: r['is_winner'] == true ? const Color(0xFFE8A317) : BrandColors.gray),
                        onPressed: () => _toggle(r),
                      ),
                      children: [
                        for (final a in answers.entries)
                          Align(alignment: AlignmentDirectional.centerStart, child: Padding(padding: const EdgeInsets.only(bottom: 4), child: Text('• ${a.value}'.isEmpty ? '•' : '• ${a.value}'))),
                        if (answers.isEmpty) Text(_t(context, 'مفيش إجابات.', 'No answers.')),
                        if (r['phone'] != null && '${r['phone']}'.isNotEmpty) Align(alignment: AlignmentDirectional.centerStart, child: Text('📞 ${r['phone']}', style: const TextStyle(color: BrandColors.gray, fontSize: 12.5))),
                        const SizedBox(height: 6),
                      ],
                    );
                  },
                ),
              ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: (_busy || rows == null || rows.isEmpty) ? null : _announce,
                icon: const Icon(Icons.emoji_events_rounded),
                label: Text(widget.announced ? _t(context, 'أعلن الفايزين تاني', 'Announce again') : _t(context, 'أعلن الفايزين', 'Announce winners')),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ owner: create / edit
class _QDraft {
  _QDraft({String body = '', this.kind = 'text', List<String>? options, String correct = ''})
      : body = TextEditingController(text: body),
        correct = TextEditingController(text: correct),
        options = List.generate(4, (i) => TextEditingController(text: (options != null && i < options.length) ? options[i] : ''));
  final TextEditingController body, correct;
  final List<TextEditingController> options;
  String kind;
  void dispose() {
    body.dispose();
    correct.dispose();
    for (final o in options) {
      o.dispose();
    }
  }
}

class _ContestEditor extends ConsumerStatefulWidget {
  const _ContestEditor({this.id, this.copyOf});
  final String? id;
  final Map<String, dynamic>? copyOf; // a contest to start from (copy), saved as a new one
  @override
  ConsumerState<_ContestEditor> createState() => _ContestEditorState();
}

class _ContestEditorState extends ConsumerState<_ContestEditor> {
  final _title = TextEditingController();
  final _intro = TextEditingController();
  final _prize = TextEditingController();
  final _minutes = TextEditingController(text: '60');
  String _audience = 'all';
  int? _answerSeconds = 60;
  int _winners = 1;
  bool _reveal = true;
  final List<_QDraft> _qs = [_QDraft()];
  bool _loading = false;
  bool _saving = false;
  String? _error;

  static const _cheers = [
    '🔥 جاهز للتحدي؟ جاوب صح وبسرعة واكسب جايزة!',
    '🧠 وريّنا شطارتك! سؤال بسيط وجايزة حلوة مستنياك.',
    '⚡ أسرع إجابة صح هي اللي تكسب. يلا نشوفك!',
  ];

  @override
  void initState() {
    super.initState();
    final src = widget.copyOf;
    if (widget.id != null) {
      _loading = true;
      ref.read(supabaseProvider).rpc('contest_admin_get', params: {'p_id': widget.id}).then((d) {
        if (mounted) setState(() => _fill(Map<String, dynamic>.from(d as Map), copy: false));
      }).catchError((Object e) {
        if (mounted) setState(() => _error = _contestError(context, e));
      }).whenComplete(() {
        if (mounted) setState(() => _loading = false);
      });
    } else if (src != null) {
      _fill(src, copy: true);
    }
  }

  void _fill(Map<String, dynamic> d, {required bool copy}) {
    _title.text = copy ? '${d['title']} (نسخة)' : '${d['title']}';
    _intro.text = (d['intro'] as String?) ?? '';
    _prize.text = (d['prize'] as String?) ?? '';
    _minutes.text = '${d['duration_minutes'] ?? 60}';
    _audience = '${d['audience'] ?? 'all'}';
    _answerSeconds = (d['answer_seconds'] as num?)?.toInt();
    _winners = (d['winners_count'] as num?)?.toInt() ?? 1;
    _reveal = d['reveal_answers'] != false;
    for (final q in _qs) {
      q.dispose();
    }
    _qs
      ..clear()
      ..addAll(_maps(d['questions']).map((q) => _QDraft(body: '${q['body']}', kind: '${q['kind']}', options: (q['options'] as List? ?? const []).map((e) => '$e').toList(), correct: (q['correct'] as String?) ?? '')));
    if (_qs.isEmpty) _qs.add(_QDraft());
  }

  @override
  void dispose() {
    _title.dispose();
    _intro.dispose();
    _prize.dispose();
    _minutes.dispose();
    for (final q in _qs) {
      q.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final mins = int.tryParse(_minutes.text.trim());
    if (_title.text.trim().length < 3) return setState(() => _error = _t(context, 'اكتب عنوان للمسابقة.', 'Give the contest a title.'));
    if (mins == null || mins < 1) return setState(() => _error = _t(context, 'اكتب مدة المسابقة بالدقايق.', 'Enter the contest length in minutes.'));
    final questions = <Map<String, dynamic>>[];
    for (final q in _qs) {
      final body = q.body.text.trim();
      if (body.length < 3) return setState(() => _error = _t(context, 'اكتب نص كل سؤال.', 'Write every question.'));
      final opts = q.options.map((o) => o.text.trim()).where((o) => o.isNotEmpty).toList();
      if (q.kind == 'choice' && opts.length < 2) return setState(() => _error = _t(context, 'سؤال الاختيار محتاج اختيارين على الأقل.', 'A choice question needs at least two options.'));
      final correct = q.correct.text.trim();
      if (q.kind == 'choice' && correct.isNotEmpty && !opts.contains(correct)) return setState(() => _error = _t(context, 'الإجابة الصح لازم تكون واحد من الاختيارات بالظبط.', 'The right answer must be exactly one of the options.'));
      questions.add({'body': body, 'kind': q.kind, if (q.kind == 'choice') 'options': opts, 'correct': correct});
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(supabaseProvider).rpc('contest_save', params: {
        'p_id': widget.id,
        'p_data': {
          'title': _title.text.trim(),
          'intro': _intro.text.trim(),
          'audience': _audience,
          'duration_minutes': mins,
          'answer_seconds': _answerSeconds,
          'winners_count': _winners,
          'prize': _prize.text.trim(),
          'reveal_answers': _reveal,
          'questions': questions,
        },
      });
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = _contestError(context, e);
        });
      }
    }
  }

  Widget _chips<T>(List<(T, String)> items, T? value, void Function(T) onPick) => Wrap(
        spacing: 8,
        runSpacing: 6,
        children: [for (final (v, label) in items) ChoiceChip(label: Text(label), selected: value == v, onSelected: (_) => setState(() => onPick(v)))],
      );

  @override
  Widget build(BuildContext context) {
    final editing = widget.id != null;
    return Scaffold(
      appBar: AppBar(title: Text(editing ? _t(context, 'تعديل المسابقة', 'Edit contest') : _t(context, 'مسابقة جديدة', 'New contest'))),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(16), children: [
              TextField(controller: _title, maxLength: 80, decoration: InputDecoration(labelText: _t(context, 'عنوان المسابقة', 'Title'), hintText: _t(context, 'مثلاً: تحدي الذكاء', 'e.g. Brain challenge'), border: const OutlineInputBorder())),
              const SizedBox(height: 8),
              TextField(controller: _intro, maxLength: 500, minLines: 2, maxLines: 4, decoration: InputDecoration(labelText: _t(context, 'النص التحفيزي (بيظهر في الإشعار وعلى الكارت)', 'Motivating text (shown in the notification and on the card)'), border: const OutlineInputBorder())),
              Wrap(spacing: 8, runSpacing: 4, children: [
                for (final c in _cheers) ActionChip(label: Text(c, style: const TextStyle(fontSize: 12)), onPressed: () => setState(() => _intro.text = c)),
              ]),
              const SizedBox(height: 16),
              Text(_t(context, 'مين يشوفها؟', 'Who sees it?'), style: const TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              _chips<String>([('all', _t(context, 'الفريق والعملاء', 'Team and customers')), ('team', _t(context, 'الفريق بس', 'Team only')), ('customers', _t(context, 'العملاء بس', 'Customers only'))], _audience, (v) => _audience = v),
              const SizedBox(height: 16),
              Text(_t(context, 'المسابقة تفضل مفتوحة قد إيه؟ (بالدقايق)', 'How long does the contest stay open? (minutes)'), style: const TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              _chips<String>([('15', _t(context, '15 دقيقة', '15 min')), ('60', _t(context, 'ساعة', '1 hour')), ('180', _t(context, '3 ساعات', '3 hours')), ('720', _t(context, '12 ساعة', '12 hours')), ('1440', _t(context, 'يوم', '1 day')), ('4320', _t(context, '3 أيام', '3 days'))], _minutes.text, (v) => _minutes.text = v),
              const SizedBox(height: 8),
              TextField(controller: _minutes, keyboardType: TextInputType.number, onChanged: (_) => setState(() {}), decoration: InputDecoration(labelText: _t(context, 'أو اكتب عدد الدقايق', 'Or type the minutes'), border: const OutlineInputBorder())),
              const SizedBox(height: 16),
              Text(_t(context, 'وقت الحل لكل واحد (بيبدأ لما يدوس ابدأ)', 'Time to answer for each person (starts when he taps Start)'), style: const TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              _chips<int?>([(null, _t(context, 'من غير حد', 'No limit')), (30, _t(context, '30 ثانية', '30 s')), (60, _t(context, '60 ثانية', '60 s')), (120, _t(context, 'دقيقتين', '2 min')), (300, _t(context, '5 دقايق', '5 min'))], _answerSeconds, (v) => _answerSeconds = v),
              const SizedBox(height: 16),
              Row(children: [
                Expanded(child: Text(_t(context, 'عدد الفايزين', 'Number of winners'), style: const TextStyle(fontWeight: FontWeight.w800))),
                IconButton(onPressed: _winners > 1 ? () => setState(() => _winners--) : null, icon: const Icon(Icons.remove_circle_outline)),
                Text('$_winners', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
                IconButton(onPressed: _winners < 50 ? () => setState(() => _winners++) : null, icon: const Icon(Icons.add_circle_outline)),
              ]),
              TextField(controller: _prize, maxLength: 200, decoration: InputDecoration(labelText: _t(context, 'الجايزة (اختياري)', 'Prize (optional)'), hintText: _t(context, 'مثلاً: كوبون خصم 50 ج', 'e.g. 50 EGP coupon'), border: const OutlineInputBorder())),
              SwitchListTile(contentPadding: EdgeInsets.zero, value: _reveal, onChanged: (v) => setState(() => _reveal = v), title: Text(_t(context, 'أظهر الإجابات الصح بعد ما المسابقة تخلص', 'Show the right answers after the contest ends'))),
              const Divider(height: 28),
              Text(_t(context, 'الأسئلة (لحد 3)', 'Questions (up to 3)'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
              const SizedBox(height: 8),
              for (var i = 0; i < _qs.length; i++) _questionCard(i),
              if (_qs.length < 3)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(onPressed: () => setState(() => _qs.add(_QDraft())), icon: const Icon(Icons.add_rounded), label: Text(_t(context, 'ضيف سؤال', 'Add a question'))),
                ),
              if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: const TextStyle(color: BrandColors.error, fontWeight: FontWeight.w700))),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save_rounded),
                label: Text(_t(context, 'احفظ المسابقة', 'Save contest')),
              ),
              const SizedBox(height: 6),
              Text(_t(context, 'بعد الحفظ هتلاقيها في القايمة، دوس «انشر وابعت إشعار» لما تبقى جاهز.', 'After saving, find it in the list and tap Publish and notify when you are ready.'), textAlign: TextAlign.center, style: const TextStyle(color: BrandColors.gray, fontSize: 12.5)),
              const SizedBox(height: 24),
            ]),
    );
  }

  Widget _questionCard(int i) {
    final q = _qs[i];
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(_t(context, 'السؤال ${i + 1}', 'Question ${i + 1}'), style: const TextStyle(fontWeight: FontWeight.w900))),
            SegmentedButton<String>(
              showSelectedIcon: false,
              segments: [ButtonSegment(value: 'text', label: Text(_t(context, 'كتابة', 'Typed'))), ButtonSegment(value: 'choice', label: Text(_t(context, 'اختيار', 'Choice')))],
              selected: {q.kind},
              onSelectionChanged: (s) => setState(() => q.kind = s.first),
            ),
            if (_qs.length > 1) IconButton(onPressed: () => setState(() => _qs.removeAt(i)), icon: const Icon(Icons.delete_outline_rounded, color: BrandColors.error)),
          ]),
          const SizedBox(height: 8),
          TextField(controller: q.body, minLines: 1, maxLines: 3, maxLength: 400, decoration: InputDecoration(labelText: _t(context, 'نص السؤال', 'Question'), border: const OutlineInputBorder())),
          if (q.kind == 'choice') ...[
            for (var k = 0; k < 4; k++)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: TextField(controller: q.options[k], decoration: InputDecoration(isDense: true, labelText: _t(context, 'الاختيار ${k + 1}${k < 2 ? '' : ' (اختياري)'}', 'Option ${k + 1}${k < 2 ? '' : ' (optional)'}'), border: const OutlineInputBorder())),
              ),
          ],
          const SizedBox(height: 4),
          TextField(
            controller: q.correct,
            decoration: InputDecoration(
              labelText: q.kind == 'choice' ? _t(context, 'الإجابة الصح (انسخها زي الاختيار بالظبط)', 'Right answer (exactly as one option)') : _t(context, 'الإجابة الصح (اختياري، افصل البدائل بـ |)', 'Right answer (optional, separate alternatives with |)'),
              helperText: _t(context, 'لو سبتها فاضية، إنت اللي بتختار الفايزين بنفسك.', 'Leave it empty to pick the winners yourself.'),
              border: const OutlineInputBorder(),
            ),
          ),
        ]),
      ),
    );
  }
}
