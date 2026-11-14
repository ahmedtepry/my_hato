// Quick sign-in on the Windows team app: by face or by fingerprint (Windows Hello).
// After a normal password sign-in on this computer the app keeps a random device key for that member in the Windows
// Credential Manager (the server keeps only its SHA-256). Later the member signs in with that key PLUS a matching face,
// or, when they turned it on in "My profile", a Windows Hello fingerprint that unlocks the key. A face alone, or a key
// alone, never signs anyone in. The server (edge function staff-quick-login) decides and hands back a one-time token.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/config.dart';
import 'face_core.dart' show faceModelId;

class QuickAccount {
  QuickAccount(this.uid, this.name, this.key, this.hello);
  final String uid, name, key;
  final bool hello;
  Map<String, Object> toJson() => {'uid': uid, 'name': name, 'key': key, 'hello': hello};
  static QuickAccount? fromJson(Object? j) {
    if (j is! Map) return null;
    final uid = j['uid'], key = j['key'];
    if (uid is! String || key is! String) return null;
    return QuickAccount(uid, '${j['name'] ?? ''}', key, j['hello'] == true);
  }
}

class QuickLogin {
  static const _store = FlutterSecureStorage();
  static const _index = 'myhato_quick_index';
  static String _slot(String uid) => 'myhato_quick_$uid';

  /// Only the Windows team app.
  static bool get supported => !kIsWeb && AppConfig.teamOnly && Platform.isWindows;

  static Future<List<QuickAccount>> accounts() async {
    if (!supported) return [];
    try {
      final ids = (jsonDecode(await _store.read(key: _index) ?? '[]') as List).cast<String>();
      final out = <QuickAccount>[];
      for (final id in ids) {
        final a = QuickAccount.fromJson(jsonDecode(await _store.read(key: _slot(id)) ?? 'null'));
        if (a != null) out.add(a);
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  /// Any device key on this computer (for the update check before sign-in), or null.
  static Future<String?> anyKey() async {
    final l = await accounts();
    return l.isEmpty ? null : l.first.key;
  }

  static Future<QuickAccount?> account(String uid) async => (await accounts()).where((a) => a.uid == uid).firstOrNull;

  static Future<void> _put(QuickAccount a) async {
    final ids = (await accounts()).map((x) => x.uid).toList();
    if (!ids.contains(a.uid)) ids.add(a.uid);
    await _store.write(key: _slot(a.uid), value: jsonEncode(a.toJson()));
    await _store.write(key: _index, value: jsonEncode(ids));
  }

  static String _newKey() {
    final r = Random.secure();
    return base64Url.encode(List<int>.generate(32, (_) => r.nextInt(256))).replaceAll('=', '');
  }

  /// Right after a successful password sign-in: keep (or refresh) this member's device key. Never throws.
  static Future<void> rememberAfterPasswordLogin(SupabaseClient db, String name) async {
    if (!supported) return;
    final uid = db.auth.currentUser?.id;
    if (uid == null) return;
    try {
      final old = await account(uid);
      final key = old?.key ?? _newKey();
      await db.rpc('quick_login_register', params: {'p_key': key, 'p_label': Platform.localHostname, 'p_hello': null});
      await _put(QuickAccount(uid, name.trim().isEmpty ? (old?.name ?? '') : name.trim(), key, old?.hello ?? false));
    } catch (_) {}
  }

  static String? _ensured;

  /// Called whenever a team member is signed in (fresh password sign-in or a kept session): keeps a device key for
  /// them on this computer once per run. Never throws, never blocks.
  static void ensureForCurrent(SupabaseClient db) {
    final uid = db.auth.currentUser?.id;
    if (!supported || uid == null || _ensured == uid) return;
    _ensured = uid;
    () async {
      var name = '';
      try {
        final p = await db.rpc('my_profile');
        if (p is Map) name = '${p['name'] ?? p['display'] ?? ''}';
      } catch (_) {}
      if (name.isEmpty) name = (await account(uid))?.name ?? (db.auth.currentUser?.email ?? '').split('@').first;
      await rememberAfterPasswordLogin(db, name);
      if ((await account(uid)) == null) _ensured = null; // failed: try again next time
    }();
  }

  /// Turns the fingerprint sign-in on/off for the signed-in member on this computer. Turning on asks Windows Hello first.
  /// Returns null when done, otherwise a short reason.
  static Future<String?> setHello(SupabaseClient db, bool on, {required String reason}) async {
    final uid = db.auth.currentUser?.id;
    if (!supported || uid == null) return 'unsupported';
    if (on) {
      final h = await helloPrompt(reason);
      if (h != null) return h;
    }
    var a = await account(uid);
    if (a == null) {
      await rememberAfterPasswordLogin(db, '');
      a = await account(uid);
      if (a == null) return 'failed';
    }
    await db.rpc('quick_login_register', params: {'p_key': a.key, 'p_label': Platform.localHostname, 'p_hello': on});
    await _put(QuickAccount(a.uid, a.name, a.key, on));
    return null;
  }

  static Future<void> forget(SupabaseClient db, String uid) async {
    final a = await account(uid);
    if (a == null) return;
    try {
      if (db.auth.currentUser?.id == uid) await db.rpc('quick_login_forget', params: {'p_key': a.key});
    } catch (_) {}
    final ids = (await accounts()).map((x) => x.uid).where((x) => x != uid).toList();
    await _store.delete(key: _slot(uid));
    await _store.write(key: _index, value: jsonEncode(ids));
  }

  /// Face sign-in: the print from the camera + every device key on this computer. {ok, name} or {ok:false, error}.
  static Future<Map<String, dynamic>> loginWithFace(SupabaseClient db, List<double> print) async {
    final list = await accounts();
    if (list.isEmpty) return {'ok': false, 'error': 'NO_DEVICE'};
    return _ask(db, {'keys': [for (final a in list) a.key], 'print': print, 'model': faceModelId});
  }

  /// Fingerprint sign-in for one remembered member.
  static Future<Map<String, dynamic>> loginWithHello(SupabaseClient db, QuickAccount a, {required String reason}) async {
    final h = await helloPrompt(reason);
    if (h != null) return {'ok': false, 'error': h};
    return _ask(db, {'keys': [a.key]});
  }

  static Future<Map<String, dynamic>> _ask(SupabaseClient db, Map<String, Object> body) async {
    final res = await db.functions.invoke('staff-quick-login', body: {...body, 'v': 2});
    final r = res.data is Map ? Map<String, dynamic>.from(res.data as Map) : <String, dynamic>{'ok': false, 'error': 'server'};
    if (r['ok'] == true) {
      final session = r['session'];
      if (session is Map && session['refresh_token'] != null) {
        // the server already opened the session: use it directly (saves a round trip)
        await db.auth.recoverSession(jsonEncode(session));
      } else {
        final th = r['token_hash'] as String?;
        if (th == null) return {'ok': false, 'error': 'server'};
        await db.auth.verifyOTP(type: OtpType.magiclink, tokenHash: th);
      }
    }
    return r;
  }

  /// Wakes the sign-in server function while the login screen is open, so the real call does not pay its start-up time.
  static void warmServer() {
    if (!supported) return;
    Supabase.instance.client.functions.invoke('staff-quick-login', body: {'ping': true}).then((_) {}, onError: (_) {});
  }

  /// Shows the Windows Hello prompt (fingerprint / face / Windows PIN of this computer) in a separate process, so the app
  /// window never freezes. Null when verified, otherwise 'NO_HELLO' (not set up on this computer) or 'CANCELED'.
  static Future<String?> helloPrompt(String reason) async {
    if (!supported) return 'NO_HELLO';
    final safe = reason.replaceAll("'", "''");
    final script = '''
\$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Runtime.WindowsRuntime
\$asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { \$_.Name -eq 'AsTask' -and \$_.GetParameters().Count -eq 1 -and \$_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
function Await(\$op, [Type]\$t) { \$task = \$asTask.MakeGenericMethod(\$t).Invoke(\$null, @(\$op)); \$task.Wait(-1) | Out-Null; \$task.Result }
[Windows.Security.Credentials.UI.UserConsentVerifier, Windows.Security.Credentials.UI, ContentType = WindowsRuntime] | Out-Null
\$a = Await ([Windows.Security.Credentials.UI.UserConsentVerifier]::CheckAvailabilityAsync()) ([Windows.Security.Credentials.UI.UserConsentVerifierAvailability])
if ("\$a" -ne 'Available') { Write-Output "NA:\$a"; exit 0 }
\$r = Await ([Windows.Security.Credentials.UI.UserConsentVerifier]::RequestVerificationAsync('$safe')) ([Windows.Security.Credentials.UI.UserConsentVerificationResult])
Write-Output "R:\$r"
''';
    final units = <int>[];
    for (final c in script.codeUnits) {
      units
        ..add(c & 0xff)
        ..add(c >> 8);
    }
    try {
      final p = await Process.run('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-EncodedCommand', base64.encode(units)])
          .timeout(const Duration(minutes: 2));
      final out = '${p.stdout}'.trim();
      if (out.contains('R:Verified')) return null;
      if (out.contains('NA:')) return 'NO_HELLO';
      return 'CANCELED';
    } catch (_) {
      return 'NO_HELLO';
    }
  }
}
