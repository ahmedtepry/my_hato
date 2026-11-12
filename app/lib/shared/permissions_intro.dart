// Customer app (Android) only: one friendly screen, once after install, that explains why each permission helps and asks
// for it with one tap: notifications, camera, location and installing updates. Nothing is forced; "later" is always fine.
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/config.dart';
import '../core/l10n.dart';
import '../core/supabase_providers.dart';
import '../core/theme.dart';
import 'app_sheet.dart';

const _seenKey = 'permissions_intro_v1';

class _Perm {
  const _Perm(this.permission, this.icon, this.ar, this.en, this.whyAr, this.whyEn);
  final Permission permission;
  final IconData icon;
  final String ar, en, whyAr, whyEn;
}

const _perms = [
  _Perm(Permission.notification, Icons.notifications_active_rounded, 'الإشعارات', 'Notifications',
      'نبلّغك أول ما طلبك يتأكد أو يخرج للتوصيل، ولما موبايلك يخلص من الصيانة، وبالعروض والكوبونات.',
      'We tell you when your order is confirmed or out for delivery, when your phone repair is done, and about offers.'),
  _Perm(Permission.camera, Icons.photo_camera_rounded, 'الكاميرا', 'Camera',
      'تمسح باركود أي منتج في المحل وتلاقيه في التطبيق، وتصوّر موبايلك وإنت بتطلب صيانة.',
      'Scan any product barcode in the shop to find it, and take photos of your phone when you request a repair.'),
  _Perm(Permission.locationWhenInUse, Icons.location_on_rounded, 'الموقع', 'Location',
      'عنوان التوصيل يتحدد لوحده من غير ما تكتبه، ونعرّفك أقرب فرع ليك.',
      'Your delivery address fills itself in, and we show you the nearest branch.'),
  _Perm(Permission.requestInstallPackages, Icons.system_update_rounded, 'تثبيت التحديثات', 'Install updates',
      'لما تنزل نسخة جديدة فيها مميزات، التطبيق يحدّث نفسه بضغطة واحدة.',
      'When a new version is out, the app updates itself with one tap.'),
];

/// Put once in the customer home screen: shows the intro the first time only.
class PermissionsIntroGate extends ConsumerStatefulWidget {
  const PermissionsIntroGate({super.key});
  @override
  ConsumerState<PermissionsIntroGate> createState() => _PermissionsIntroGateState();
}

class _PermissionsIntroGateState extends ConsumerState<PermissionsIntroGate> {
  static bool _checked = false;

  @override
  void initState() {
    super.initState();
    if (_checked || kIsWeb || AppConfig.teamOnly || !Platform.isAndroid) return;
    _checked = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final prefs = ref.read(sharedPrefsProvider);
      if (prefs.getBool(_seenKey) == true || !mounted) return;
      await Future<void>.delayed(const Duration(milliseconds: 900)); // let the home screen appear first
      if (!mounted) return;
      await showPermissionsIntro(context);
      await prefs.setBool(_seenKey, true);
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// Also reachable from the account screen ("Permissions").
Future<void> showPermissionsIntro(BuildContext context) => showAppSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _IntroSheet(),
    );

class _IntroSheet extends StatefulWidget {
  const _IntroSheet();
  @override
  State<_IntroSheet> createState() => _IntroSheetState();
}

class _IntroSheetState extends State<_IntroSheet> with WidgetsBindingObserver {
  final Map<Permission, PermissionStatus> _status = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // coming back from the settings screen: read the new state
  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    for (final p in _perms) {
      try {
        _status[p.permission] = await p.permission.status;
      } catch (_) {}
    }
    if (mounted) setState(() {});
  }

  Future<void> _ask(Permission p) async {
    try {
      final s = await p.request();
      if (s.isPermanentlyDenied) await openAppSettings();
    } catch (_) {}
    await _refresh();
  }

  Future<void> _askAll() async {
    for (final p in _perms) {
      if (_status[p.permission]?.isGranted == true) continue;
      if (p.permission == Permission.requestInstallPackages) continue; // opens a settings page: only on its own button
      try {
        await p.permission.request();
      } catch (_) {}
    }
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final ar = context.isAr;
    final ink = inkColor(context);
    final allDone = _perms.every((p) => _status[p.permission]?.isGranted == true);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: ListView(shrinkWrap: true, children: [
          Text(ar ? 'خلّي التطبيق يخدمك أحسن' : 'Let the app help you more', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
          const SizedBox(height: 4),
          Text(ar ? 'كل حاجة هنا اختيارية وتقدر تغيّرها بعدين من إعدادات الموبايل.' : 'Everything here is optional; you can change it later in your phone settings.',
              style: TextStyle(color: ink.withValues(alpha: 0.65))),
          const SizedBox(height: 12),
          for (final p in _perms) _row(p, ar, ink),
          const SizedBox(height: 12),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(double.infinity, 54)),
            onPressed: allDone ? () => Navigator.pop(context) : _askAll,
            child: Text(allDone ? (ar ? 'تمام' : 'Done') : (ar ? 'اسمح بالكل' : 'Allow all'), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
          ),
          TextButton(onPressed: () => Navigator.pop(context), child: Text(ar ? 'بعدين' : 'Later')),
        ]),
      ),
    );
  }

  Widget _row(_Perm p, bool ar, Color ink) {
    final granted = _status[p.permission]?.isGranted == true;
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: panelColor(context), borderRadius: BorderRadius.circular(16), border: Border.all(color: panelLine(context))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(p.icon, size: 30, color: granted ? BrandColors.success : BrandColors.electric),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(ar ? p.ar : p.en, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            const SizedBox(height: 2),
            Text(ar ? p.whyAr : p.whyEn, style: TextStyle(fontSize: 13.5, height: 1.5, color: ink.withValues(alpha: 0.7))),
          ]),
        ),
        const SizedBox(width: 8),
        granted
            ? const Padding(padding: EdgeInsets.only(top: 6), child: Icon(Icons.check_circle_rounded, color: BrandColors.success))
            : OutlinedButton(
                style: OutlinedButton.styleFrom(minimumSize: const Size(72, 42)),
                onPressed: () => _ask(p.permission),
                child: Text(ar ? 'اسمح' : 'Allow'),
              ),
      ]),
    );
  }
}
