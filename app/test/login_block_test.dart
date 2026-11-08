import 'package:flutter_test/flutter_test.dart';
import 'package:myhato/core/errors.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test('reads the lock marker and the raised error the same way', () {
    expect(parseLoginBlock('!locked:900')?.kind, 'locked');
    expect(parseLoginBlock('!locked:900')?.seconds, 900);
    expect(parseLoginBlock(const PostgrestException(message: 'ACCOUNT_LOCKED:3600'))?.seconds, 3600);
  });
  test('reads blocked and suspended', () {
    expect(parseLoginBlock('!blocked')?.kind, 'blocked');
    expect(parseLoginBlock(const PostgrestException(message: 'ACCOUNT_BLOCKED'))?.kind, 'blocked');
    expect(parseLoginBlock(const PostgrestException(message: 'ACCOUNT_SUSPENDED'))?.kind, 'suspended');
  });
  test('a normal email or error is not a block', () {
    expect(parseLoginBlock('ali@example.com'), isNull);
    expect(parseLoginBlock(null), isNull);
    expect(parseLoginBlock(Exception('network')), isNull);
  });
  test('the messages carry the support number, minutes and an hour', () {
    final locked = loginBlockedText(const LoginBlocked('locked', 900));
    expect(locked, contains('15 دقيقة'));
    expect(locked, contains('0'));
    expect(loginBlockedText(const LoginBlocked('locked', 3600)), contains('ساعة'));
    expect(loginBlockedText(const LoginBlocked('blocked')), contains('تم حظر الحساب'));
    expect(loginBlockedText(const LoginBlocked('blocked'), ar: false), contains('blocked'));
  });
}
