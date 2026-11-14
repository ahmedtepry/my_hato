// In-app update. Windows team app: finds the newest build, downloads the installer, checks its SHA-256 and runs it silently
// (the installer closes the app, replaces the files and reopens it). Android: downloads the new APK, checks its SHA-256 and hands it
// to the Android installer, which installs it over the old app (same signing key, so data and sign-in stay).
import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'config.dart';
import 'l10n.dart';
import '../shared/states.dart' show showSnack;
import 'supabase_providers.dart';
import '../shared/rail_tile.dart';
import 'theme.dart';

class AppUpdateInfo {
  const AppUpdateInfo({required this.build, required this.url, required this.sha256, this.size, this.notes});
  final int build;
  final String url, sha256;
  final int? size;
  final String? notes;
}

/// This build's number (set by the build pipeline; 0 when running from source).
const int kBuildNumber = int.fromEnvironment('BUILD_NUMBER', defaultValue: 0);

bool get _isAndroidApp => !kIsWeb && Platform.isAndroid && !AppConfig.teamOnly;
/// Google Play build (STORE_BUILD=true): Play updates the app itself, so the in-app updater is switched off.
const bool kStoreBuild = bool.fromEnvironment('STORE_BUILD');
bool get appUpdateSupported => !kStoreBuild && kBuildNumber > 0 && (_isAndroidApp || (AppConfig.teamOnly && Platform.isWindows));
const _updateChannel = MethodChannel('myhato/update');

/// Windows team app before sign-in: a device key of a member who already signed in on this computer (set by the
/// team login screen). With it the server tells this computer about new builds; without it, nothing before sign-in.
Future<String?> Function()? appUpdateDeviceKey;

class AppUpdateState {
  const AppUpdateState({this.available, this.checking = false, this.error});
  final AppUpdateInfo? available;
  final bool checking;
  final Object? error;
}

class AppUpdateController extends Notifier<AppUpdateState> {
  Timer? _timer;

  @override
  AppUpdateState build() {
    ref.onDispose(() => _timer?.cancel());
    if (appUpdateSupported) {
      Future.microtask(check);
      _timer = Timer.periodic(const Duration(minutes: 10), (_) => check());
    }
    return const AppUpdateState();
  }

  Future<void> check() async {
    if (!appUpdateSupported) return;
    state = AppUpdateState(available: state.available, checking: true);
    try {
      final db = ref.read(supabaseProvider);
      // the customer app asks before anyone signs in (public info); the Windows team app needs a signed-in member
      String? deviceKey;
      if (!_isAndroidApp && db.auth.currentUser == null) {
        deviceKey = await appUpdateDeviceKey?.call();
        if (deviceKey == null) {
          state = const AppUpdateState();
          return;
        }
      }
      final rows = (_isAndroidApp
              ? await db.rpc('latest_android_update')
              : deviceKey != null
                  ? await db.rpc('latest_windows_update_for_device', params: {'p_key': deviceKey})
                  : await db.rpc('latest_app_update', params: {'p_platform': 'windows'})) as List? ??
          const [];
      AppUpdateInfo? info;
      if (rows.isNotEmpty) {
        final r = Map<String, dynamic>.from(rows.first as Map);
        final build = (r['build'] as num).toInt();
        if (build > kBuildNumber) {
          info = AppUpdateInfo(
            build: build,
            url: db.storage.from('app-updates').getPublicUrl('${r['path']}'),
            sha256: '${r['sha256']}'.toLowerCase(),
            size: (r['size_bytes'] as num?)?.toInt(),
            notes: r['notes'] as String?,
          );
        }
      }
      state = AppUpdateState(available: info);
    } catch (e) {
      // no answer (offline, update table not installed yet): stay quiet, keep what we knew
      state = AppUpdateState(available: state.available, error: e);
    }
  }
}

final appUpdateProvider = NotifierProvider<AppUpdateController, AppUpdateState>(AppUpdateController.new);

/// Downloads [url] into [file] (reporting progress) and checks the SHA-256.
Future<void> _download(AppUpdateInfo info, File file, void Function(double) onProgress) async {
  await file.parent.create(recursive: true);
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    final req = await client.getUrl(Uri.parse(info.url));
    final res = await req.close();
    if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
    final total = res.contentLength > 0 ? res.contentLength : (info.size ?? 0);
    final sink = file.openWrite();
    var got = 0;
    final digestOut = AccumulatorSink<Digest>();
    final hasher = sha256.startChunkedConversion(digestOut);
    await for (final chunk in res) {
      sink.add(chunk);
      hasher.add(chunk);
      got += chunk.length;
      if (total > 0) onProgress(got / total);
    }
    await sink.flush();
    await sink.close();
    hasher.close();
    if (digestOut.events.single.toString() != info.sha256) {
      try {
        await file.delete();
      } catch (_) {}
      throw const FormatException('CHECKSUM_MISMATCH');
    }
  } finally {
    client.close();
  }
}

/// Downloads the new build, verifies it and installs it. Windows: runs the installer silently and quits (returns never).
/// Android: opens the system installer and returns 'started', or 'need_permission' when the member must first allow
/// "install unknown apps" for My Hatō.
Future<String> installAppUpdate(AppUpdateInfo info, void Function(double) onProgress) async {
  if (_isAndroidApp) {
    final dir = await _updateChannel.invokeMethod<String>('cacheDir') ?? Directory.systemTemp.path;
    final file = File('$dir/updates/myhato-${info.build}.apk');
    await _download(info, file, onProgress);
    return await _updateChannel.invokeMethod<String>('install', file.path) ?? 'started';
  }
  final file = File('${Directory.systemTemp.path}${Platform.pathSeparator}MyHatoTeam-Setup-${info.build}.exe');
  await _download(info, file, onProgress);
  await Process.start(
    file.path,
    ['/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CLOSEAPPLICATIONS', '/RESTARTAPPLICATIONS'],
    mode: ProcessStartMode.detached,
  );
  await Future<void>.delayed(const Duration(milliseconds: 600));
  exit(0);
}

/// The button next to the colours button: quiet when up to date, a bright "update the app" when a newer build is out.
class AppUpdateButton extends ConsumerWidget {
  const AppUpdateButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!appUpdateSupported) return const SizedBox.shrink();
    final st = ref.watch(appUpdateProvider);
    final info = st.available;
    final ar = context.isAr;
    Widget tile({required Widget icon, required String label, required Color bg, required Color fg, required VoidCallback? onTap, required String tip, bool glow = false}) =>
        RailTile(tooltip: tip, onTap: onTap, icon: icon, label: label, bg: bg, fg: fg, glow: glow);
    if (info == null) {
      return tile(
        tip: ar ? 'البرنامج محدّث (نسخة $kBuildNumber). اضغط للتأكد من وجود تحديث' : 'Up to date (build $kBuildNumber). Tap to check',
        icon: st.checking
            ? const SizedBox(width: 30, height: 30, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.system_update_alt_rounded, size: 32, color: BrandColors.gray),
        label: ar ? 'محدّث' : 'Updated',
        bg: Colors.white,
        fg: BrandColors.gray,
        onTap: st.checking ? null : () => ref.read(appUpdateProvider.notifier).check(),
      );
    }
    return tile(
      tip: ar ? 'نسخة جديدة جاهزة، اضغط لتحديث البرنامج' : 'A new version is ready',
      icon: const Icon(Icons.system_update_alt_rounded, size: 32, color: Colors.white),
      label: ar ? 'تحديث' : 'Update',
      bg: BrandColors.warning,
      fg: Colors.white,
      glow: true,
      onTap: () => showDialog<void>(context: context, barrierDismissible: false, builder: (_) => _UpdateDialog(info: info)),
    );
  }
}

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog({required this.info});
  final AppUpdateInfo info;
  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  double? _progress;
  String? _error;

  Future<void> _start() async {
    setState(() {
      _progress = 0;
      _error = null;
    });
    try {
      final r = await installAppUpdate(widget.info, (p) {
        if (mounted) setState(() => _progress = p);
      });
      if (mounted && _isAndroidApp) {
        if (r == 'need_permission') {
          setState(() {
            _progress = null;
            _error = context.isAr ? 'فعّل «السماح بالتثبيت» لـ My Hatō في الشاشة اللي فتحت، وارجع واضغط حدّث تاني' : 'Allow installing from My Hatō in the settings screen, then come back and tap Update again';
          });
        } else {
          Navigator.of(context).pop();
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _progress = null;
          _error = e is FormatException ? (context.isAr ? 'الملف اتلخبط في التحميل، جرّب تاني' : 'The download was damaged, try again') : '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ar = context.isAr;
    final busy = _progress != null;
    return AlertDialog(
      icon: const Icon(Icons.system_update_alt_rounded, size: 42, color: BrandColors.warning),
      title: Text(ar ? 'تحديث جديد للبرنامج' : 'A new version is ready', textAlign: TextAlign.center),
      content: SizedBox(
        width: 360,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(ar ? 'النسخة الحالية $kBuildNumber ← الجديدة ${widget.info.build}' : 'Current $kBuildNumber → new ${widget.info.build}',
              style: const TextStyle(fontWeight: FontWeight.w700)),
          if ((widget.info.notes ?? '').isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(widget.info.notes!, textAlign: TextAlign.center, style: const TextStyle(color: BrandColors.gray, fontSize: 13)),
          ],
          const SizedBox(height: 12),
          if (busy) ...[
            LinearProgressIndicator(value: (_progress ?? 0) >= 1 ? null : _progress),
            const SizedBox(height: 8),
            Text(
              (_progress ?? 0) >= 1
                  ? (ar ? 'بيتثبّت… البرنامج هيتقفل ويفتح لوحده' : 'Installing… the app will close and reopen by itself')
                  : (ar ? 'بينزّل ${((_progress ?? 0) * 100).round()}%' : 'Downloading ${((_progress ?? 0) * 100).round()}%'),
              style: const TextStyle(fontSize: 13),
            ),
          ] else
            Text(
                _isAndroidApp
                    ? (ar ? 'هننزّل النسخة الجديدة وبعدها هتفتحلك شاشة التثبيت. دوس «تثبيت» وبعدها افتح التطبيق. بياناتك وحسابك زي ما هم.' : 'The new version downloads, then the install screen opens. Tap Install, then open the app. Your data and sign-in stay.')
                    : (ar ? 'هنزّل النسخة الجديدة ونثبّتها، والبرنامج هيفتح تاني لوحده. اقفل أي عملية بيع قبل ما تكمّل.' : 'The new version is downloaded and installed; the app reopens by itself. Finish any sale first.'),
                textAlign: TextAlign.center, style: const TextStyle(fontSize: 13)),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: const TextStyle(color: BrandColors.error, fontSize: 12.5), textAlign: TextAlign.center),
          ],
        ]),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        TextButton(onPressed: busy ? null : () => Navigator.pop(context), child: Text(ar ? 'بعدين' : 'Later')),
        FilledButton.icon(
          onPressed: busy ? null : _start,
          icon: const Icon(Icons.download_rounded),
          label: Text(ar ? 'حدّث دلوقتي' : 'Update now'),
        ),
      ],
    );
  }
}

/// A tiny helper: collects the single digest produced by a chunked hash conversion.
class AccumulatorSink<T> implements Sink<T> {
  final List<T> events = [];
  @override
  void add(T data) => events.add(data);
  @override
  void close() {}
}


/// Android: a slim banner at the top of the app when a newer build is out. One tap downloads and installs it.
class AppUpdateBanner extends ConsumerStatefulWidget {
  const AppUpdateBanner({super.key});
  @override
  ConsumerState<AppUpdateBanner> createState() => _AppUpdateBannerState();
}

class _AppUpdateBannerState extends ConsumerState<AppUpdateBanner> with WidgetsBindingObserver {
  double? _progress;
  String? _msg;
  int? _hidden; // the build the member dismissed
  bool _prompt = true; // the full "update the app" card, shown once when the app opens

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // coming back to the app: look for a newer build again
    if (state == AppLifecycleState.resumed && _isAndroidApp) ref.read(appUpdateProvider.notifier).check();
  }

  Future<void> _go(AppUpdateInfo info) async {
    final ar = context.isAr;
    setState(() {
      _progress = 0;
      _msg = null;
    });
    try {
      final r = await installAppUpdate(info, (p) {
        if (mounted) setState(() => _progress = p);
      });
      if (!mounted) return;
      setState(() {
        _progress = null;
        _msg = r == 'need_permission'
            ? (ar ? 'فعّل «السماح بالتثبيت» لـ My Hatō ثم اضغط تحديث تاني' : 'Allow installing from My Hatō, then tap Update again')
            : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _progress = null;
        _msg = e is FormatException ? (ar ? 'التحميل اتلخبط، جرّب تاني' : 'The download was damaged, try again') : (ar ? 'ماقدرناش نحدّث دلوقتي، جرّب تاني' : 'Could not update, try again');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_isAndroidApp || kStoreBuild) return const SizedBox.shrink();
    final info = ref.watch(appUpdateProvider).available;
    if (info == null) return const SizedBox.shrink();
    final ar = context.isAr;
    final busy = _progress != null;
    if (_prompt) {
      // full-screen card when the app opens with an old version
      return Material(
        color: Colors.black54,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Material(
              color: Colors.white,
              borderRadius: BorderRadius.circular(22),
              elevation: 8,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(22, 24, 22, 18),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.system_update_alt_rounded, size: 54, color: BrandColors.warning),
                  const SizedBox(height: 12),
                  Text(ar ? 'لازم تحدّث التطبيق' : 'Please update the app', textAlign: TextAlign.center, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: BrandColors.navy)),
                  const SizedBox(height: 8),
                  Text(ar ? 'فيه نسخة أحدث من التطبيق فيها تحسينات وإصلاحات. اضغط تحديث وهتتثبّت فوق النسخة الحالية، وحسابك وبياناتك زي ما هي.' : 'A newer version with improvements is available. Tap Update to install it over this one; your data stays.',
                      textAlign: TextAlign.center, style: const TextStyle(fontSize: 14, height: 1.6, color: BrandColors.gray)),
                  if (busy) ...[
                    const SizedBox(height: 16),
                    LinearProgressIndicator(value: (_progress ?? 0) >= 1 ? null : _progress),
                    const SizedBox(height: 6),
                    Text(ar ? 'بينزّل ${((_progress ?? 0) * 100).round()}%' : 'Downloading ${((_progress ?? 0) * 100).round()}%', style: const TextStyle(fontSize: 13)),
                  ],
                  if (_msg != null) ...[
                    const SizedBox(height: 10),
                    Text(_msg!, textAlign: TextAlign.center, style: const TextStyle(color: BrandColors.error, fontSize: 13)),
                  ],
                  const SizedBox(height: 18),
                  Row(children: [
                    // the update is required: "Later" only appears if the update itself failed (offline, damaged download), so nobody gets stuck
                    if (_msg != null) ...[
                      Expanded(child: OutlinedButton(onPressed: busy ? null : () => setState(() => _prompt = false), child: Text(ar ? 'بعدين' : 'Later'))),
                      const SizedBox(width: 10),
                    ],
                    Expanded(flex: 2, child: FilledButton.icon(onPressed: busy ? null : () => _go(info), icon: const Icon(Icons.download_rounded), label: Text(ar ? 'تحديث' : 'Update'))),
                  ]),
                ]),
              ),
            ),
          ),
        ),
      );
    }
    if (_hidden == info.build) return const SizedBox.shrink();
    return Align(alignment: Alignment.topCenter, child: SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
        child: Material(
          color: BrandColors.warning,
          elevation: 6,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 6, 8),
            child: Row(children: [
              const Icon(Icons.system_update_alt_rounded, color: Colors.white),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text(
                    busy ? (ar ? 'بينزّل ${((_progress ?? 0) * 100).round()}%' : 'Downloading ${((_progress ?? 0) * 100).round()}%') : (ar ? 'فيه نسخة جديدة من التطبيق' : 'A new version is ready'),
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 14),
                  ),
                  if (busy) Padding(padding: const EdgeInsets.only(top: 4), child: LinearProgressIndicator(value: (_progress ?? 0) >= 1 ? null : _progress, color: Colors.white, backgroundColor: Colors.white24)),
                  if (_msg != null) Text(_msg!, style: const TextStyle(color: Colors.white, fontSize: 12)),
                ]),
              ),
              if (!busy) ...[
                TextButton(
                  style: TextButton.styleFrom(backgroundColor: Colors.white, foregroundColor: BrandColors.warning, padding: const EdgeInsets.symmetric(horizontal: 14)),
                  onPressed: () => _go(info),
                  child: Text(ar ? 'تحديث' : 'Update', style: const TextStyle(fontWeight: FontWeight.w900)),
                ),
                IconButton(icon: const Icon(Icons.close_rounded, color: Colors.white), onPressed: () => setState(() => _hidden = info.build)),
              ],
            ]),
          ),
        ),
      ),
    ));
  }
}


/// A row for the account page: "Update the app". Shows whether a newer build is out; tapping checks again and offers the update.
class AppUpdateTile extends ConsumerWidget {
  const AppUpdateTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!appUpdateSupported) return const SizedBox.shrink();
    final st = ref.watch(appUpdateProvider);
    final info = st.available;
    final ar = context.isAr;
    final color = info != null ? BrandColors.warning : BrandColors.electric;
    return ListTile(
      leading: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(13)),
        child: Icon(Icons.system_update_alt_rounded, color: color, size: 23),
      ),
      title: Text(ar ? 'تحديث التطبيق' : 'Update the app'),
      subtitle: Text(
        info != null ? (ar ? 'فيه نسخة جديدة (${info.build})، اضغط للتحديث' : 'A new version (${info.build}) is ready, tap to update') : (ar ? 'النسخة $kBuildNumber · إنت على أحدث نسخة' : 'Build $kBuildNumber · up to date'),
        style: TextStyle(color: info != null ? BrandColors.warning : BrandColors.gray, fontWeight: info != null ? FontWeight.w700 : FontWeight.w400),
      ),
      trailing: st.checking ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.chevron_right),
      onTap: () async {
        await ref.read(appUpdateProvider.notifier).check();
        final i = ref.read(appUpdateProvider).available;
        if (!context.mounted) return;
        if (i == null) {
          showSnack(context, ar ? 'إنت على أحدث نسخة ✅' : 'You have the latest version ✅');
        } else {
          await showDialog<void>(context: context, barrierDismissible: false, builder: (_) => _UpdateDialog(info: i));
        }
      },
    );
  }
}


/// The update button in a corner of the team sign-in screen: one tap checks for a new version and installs it, so
/// staff can update before they start work. Orange with a dot when a new version is waiting.
class LoginUpdateButton extends ConsumerWidget {
  const LoginUpdateButton({super.key, this.onDark = false});
  final bool onDark;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!appUpdateSupported) return const SizedBox.shrink();
    final st = ref.watch(appUpdateProvider);
    final info = st.available;
    final ar = context.isAr;
    final fg = info != null ? Colors.white : (onDark ? Colors.white : const Color(0xFF1F5FD6));
    return Tooltip(
      message: ar ? 'نسختك $kBuildNumber · دوس علشان تشوف لو فيه تحديث' : 'Build $kBuildNumber · tap to check for an update',
      child: Material(
        color: info != null ? BrandColors.warning : (onDark ? Colors.white.withValues(alpha: 0.10) : Colors.white),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: info != null ? BrandColors.warning : (onDark ? Colors.white24 : const Color(0xFFC9D4E8)), width: 1.4),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: st.checking
              ? null
              : () async {
                  await ref.read(appUpdateProvider.notifier).check();
                  if (!context.mounted) return;
                  final i = ref.read(appUpdateProvider).available;
                  final err = ref.read(appUpdateProvider).error;
                  if (i != null) {
                    await showDialog<void>(context: context, barrierDismissible: false, builder: (_) => _UpdateDialog(info: i));
                  } else if (appUpdateDeviceKey != null && await appUpdateDeviceKey!() == null) {
                    if (context.mounted) {
                      showSnack(context, ar ? 'الجهاز ده بيشوف التحديثات بعد أول دخول لموظف عليه' : 'This computer sees updates after a team member signs in once');
                    }
                  } else if (err != null) {
                    showSnack(context, ar ? 'مفيش نت أو السيرفر مش بيرد، جرّب تاني' : 'No connection, try again', error: true);
                  } else {
                    showSnack(context, ar ? 'إنت على أحدث نسخة ($kBuildNumber) ✅' : 'You have the latest version ($kBuildNumber) ✅');
                  }
                },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              st.checking
                  ? SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.2, color: fg))
                  : Icon(info != null ? Icons.system_update_alt_rounded : Icons.sync_rounded, size: 22, color: fg),
              const SizedBox(width: 8),
              Text(info != null ? (ar ? 'حدّث دلوقتي' : 'Update now') : (ar ? 'تحديث' : 'Update'),
                  style: TextStyle(color: fg, fontWeight: FontWeight.w800, fontSize: 14.5)),
              if (info == null) ...[
                const SizedBox(width: 6),
                Text('$kBuildNumber', style: TextStyle(color: fg.withValues(alpha: 0.6), fontSize: 12)),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}
