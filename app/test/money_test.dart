import 'package:flutter_test/flutter_test.dart';
import 'package:myhato/core/money.dart';

void main() {
  test('formats piasters as EGP in both languages', () {
    expect(formatEgp(20000, 'ar'), '200 ج.م');
    expect(formatEgp(20000, 'en'), 'EGP 200');
    expect(formatEgp(4500000, 'ar'), '45,000 ج.م');
    expect(formatEgp(79950, 'en'), 'EGP 799.50');
    expect(formatEgp(null, 'ar'), '—');
  });

  test('parses EGP input to integer piasters without floats', () {
    expect(parseEgpToMinor('200'), 20000);
    expect(parseEgpToMinor('199.5'), 19950);
    expect(parseEgpToMinor('1,250.25'), 125025);
    expect(parseEgpToMinor('-5'), isNull);
    expect(parseEgpToMinor('abc'), isNull);
    expect(parseEgpToMinor('0.1'), 10); // 0.1 + 0.2 style float bugs impossible
  });
}
