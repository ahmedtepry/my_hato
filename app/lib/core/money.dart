import 'package:intl/intl.dart';

/// Money is always handled as integer piasters (1 EGP = 100). Never double math.
String formatEgp(int? minor, String languageCode) {
  if (minor == null) return '—';
  final pounds = minor ~/ 100;
  final piasters = minor.abs() % 100;
  final f = NumberFormat.decimalPattern('en');
  final amount = piasters == 0 ? f.format(pounds) : '${f.format(pounds)}.${piasters.toString().padLeft(2, '0')}';
  return languageCode == 'ar' ? '$amount ج.م' : 'EGP $amount';
}

/// Parses an admin/customer-entered EGP amount ("200", "199.5") into piasters without floats.
int? parseEgpToMinor(String input) {
  final s = input.trim().replaceAll(',', '');
  final m = RegExp(r'^(\d{1,9})(?:\.(\d{1,2}))?$').firstMatch(s);
  if (m == null) return null;
  final whole = int.parse(m.group(1)!);
  final frac = (m.group(2) ?? '').padRight(2, '0');
  return whole * 100 + int.parse(frac);
}
