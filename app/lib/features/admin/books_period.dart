import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/l10n.dart';

/// A reporting period: from (inclusive) to (exclusive), in the person's local time.
class Period {
  const Period(this.key, this.from, this.to);
  final String key;
  final DateTime from, to;

  @override
  bool operator ==(Object other) => other is Period && other.from == from && other.to == to;
  @override
  int get hashCode => Object.hash(from, to);

  static DateTime _d(DateTime x) => DateTime(x.year, x.month, x.day);

  static Period today() {
    final d = _d(DateTime.now());
    return Period('today', d, d.add(const Duration(days: 1)));
  }

  static Period yesterday() {
    final d = _d(DateTime.now());
    return Period('yesterday', d.subtract(const Duration(days: 1)), d);
  }

  static Period lastDays(int n) {
    final d = _d(DateTime.now());
    return Period('d$n', d.subtract(Duration(days: n - 1)), d.add(const Duration(days: 1)));
  }

  static Period month(DateTime any, {String key = 'month'}) => Period(key, DateTime(any.year, any.month), DateTime(any.year, any.month + 1));
  static Period year(DateTime any, {String key = 'year'}) => Period(key, DateTime(any.year), DateTime(any.year + 1));
  static Period day(DateTime any) => Period('day', _d(any), _d(any).add(const Duration(days: 1)));
  static Period range(DateTime a, DateTime b) {
    final s = _d(a.isBefore(b) ? a : b), e = _d(a.isBefore(b) ? b : a);
    return Period('range', s, e.add(const Duration(days: 1)));
  }

  String label(BuildContext c) {
    final ar = c.isAr;
    final f = DateFormat('d/M/yyyy');
    switch (key) {
      case 'today':
        return ar ? 'النهارده' : 'Today';
      case 'yesterday':
        return ar ? 'إمبارح' : 'Yesterday';
      case 'd7':
        return ar ? 'آخر ٧ أيام' : 'Last 7 days';
      case 'd30':
        return ar ? 'آخر ٣٠ يوم' : 'Last 30 days';
      case 'month':
      case 'lastMonth':
      case 'pickMonth':
        return DateFormat('MMMM yyyy', ar ? 'ar' : 'en').format(from);
      case 'year':
      case 'pickYear':
        return ar ? 'سنة ${from.year}' : 'Year ${from.year}';
      case 'day':
        return f.format(from);
      default:
        return '${f.format(from)} → ${f.format(to.subtract(const Duration(days: 1)))}';
    }
  }
}

/// The period chooser of the accountant. Without the period right only today / 7 days / 30 days are offered.
class PeriodBar extends StatelessWidget {
  const PeriodBar({super.key, required this.period, required this.canPick, required this.onChanged});
  final Period period;
  final bool canPick;
  final ValueChanged<Period> onChanged;

  Future<void> _pickDay(BuildContext c) async {
    final d = await showDatePicker(context: c, initialDate: period.from, firstDate: DateTime(2023), lastDate: DateTime.now());
    if (d != null) onChanged(Period.day(d));
  }

  Future<void> _pickRange(BuildContext c) async {
    final r = await showDateRangePicker(
      context: c,
      firstDate: DateTime(2023),
      lastDate: DateTime.now(),
      initialDateRange: DateTimeRange(start: period.from, end: period.to.subtract(const Duration(days: 1)).isBefore(period.from) ? period.from : period.to.subtract(const Duration(days: 1))),
    );
    if (r != null) onChanged(Period.range(r.start, r.end));
  }

  Future<void> _pickMonth(BuildContext c) async {
    final d = await showDatePicker(context: c, initialDate: period.from, firstDate: DateTime(2023), lastDate: DateTime.now(), initialDatePickerMode: DatePickerMode.year, helpText: c.isAr ? 'اختار أي يوم في الشهر' : 'Pick any day of the month');
    if (d != null) onChanged(Period.month(d, key: 'pickMonth'));
  }

  Future<void> _pickYear(BuildContext c) async {
    final d = await showDatePicker(context: c, initialDate: period.from, firstDate: DateTime(2023), lastDate: DateTime.now(), initialDatePickerMode: DatePickerMode.year, helpText: c.isAr ? 'اختار السنة' : 'Pick the year');
    if (d != null) onChanged(Period.year(d, key: 'pickYear'));
  }

  @override
  Widget build(BuildContext context) {
    final ar = context.isAr;
    Widget chip(String label, Period p) => ChoiceChip(label: Text(label), selected: period.key == p.key && period == p, onSelected: (_) => onChanged(p));
    final now = DateTime.now();
    return Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
      chip(ar ? 'النهارده' : 'Today', Period.today()),
      if (canPick) chip(ar ? 'إمبارح' : 'Yesterday', Period.yesterday()),
      chip(ar ? '٧ أيام' : '7 days', Period.lastDays(7)),
      chip(ar ? '٣٠ يوم' : '30 days', Period.lastDays(30)),
      if (canPick) ...[
        chip(ar ? 'الشهر ده' : 'This month', Period.month(now)),
        chip(ar ? 'الشهر اللي فات' : 'Last month', Period.month(DateTime(now.year, now.month - 1), key: 'lastMonth')),
        chip(ar ? 'السنة دي' : 'This year', Period.year(now)),
        ActionChip(avatar: const Icon(Icons.event_rounded, size: 18), label: Text(ar ? 'يوم محدد' : 'A day'), onPressed: () => _pickDay(context)),
        ActionChip(avatar: const Icon(Icons.date_range_rounded, size: 18), label: Text(ar ? 'فترة محددة' : 'Date range'), onPressed: () => _pickRange(context)),
        ActionChip(avatar: const Icon(Icons.calendar_month_rounded, size: 18), label: Text(ar ? 'شهر محدد' : 'A month'), onPressed: () => _pickMonth(context)),
        ActionChip(avatar: const Icon(Icons.calendar_today_rounded, size: 18), label: Text(ar ? 'سنة محددة' : 'A year'), onPressed: () => _pickYear(context)),
      ],
    ]);
  }
}
