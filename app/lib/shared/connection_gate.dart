import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../core/config.dart';
import '../core/l10n.dart';
import '../core/theme.dart';

/// Covers the app with a clear "no internet" page while the phone cannot reach the store's server,
/// and lifts it by itself as soon as the connection is back.
class ConnectionGate extends StatefulWidget {
  const ConnectionGate({super.key, required this.child});
  final Widget child;
  @override
  State<ConnectionGate> createState() => _ConnectionGateState();
}

class _ConnectionGateState extends State<ConnectionGate> with WidgetsBindingObserver {
  Timer? _timer;
  bool _offline = false;
  bool _checking = false;
  int _misses = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
    _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer.periodic(Duration(seconds: _offline ? 4 : 20), (_) => _check());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<bool> _reachable() async {
    try {
      final host = Uri.parse(AppConfig.supabaseUrl).host;
      final r = await InternetAddress.lookup(host.isEmpty ? 'google.com' : host).timeout(const Duration(seconds: 4));
      return r.isNotEmpty && r.first.rawAddress.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<void> _check() async {
    if (_checking || !mounted) return;
    setState(() => _checking = true);
    final ok = await _reachable();
    if (!mounted) return;
    // two misses in a row before the page appears, so one slow lookup does not flash it
    _misses = ok ? 0 : _misses + 1;
    final off = _misses >= 2 || (_offline && !ok);
    final changed = off != _offline;
    setState(() {
      _checking = false;
      _offline = off;
    });
    if (changed) _schedule();
    if (!ok && !off) Future.delayed(const Duration(seconds: 2), _check);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      Positioned.fill(child: widget.child),
      if (_offline)
        Positioned.fill(
          child: Material(
            color: Theme.of(context).scaffoldBackgroundColor,
            child: SafeArea(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 360),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Container(
                        width: 88,
                        height: 88,
                        decoration: BoxDecoration(color: BrandColors.electric.withValues(alpha: 0.10), shape: BoxShape.circle),
                        child: const Icon(Icons.wifi_off_rounded, size: 42, color: BrandColors.electric),
                      ),
                      const SizedBox(height: 24),
                      Text(context.tr('no_internet_title'),
                          textAlign: TextAlign.center, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: BrandColors.navy)),
                      const SizedBox(height: 10),
                      Text(context.tr('no_internet_body'),
                          textAlign: TextAlign.center, style: const TextStyle(fontSize: 15, height: 1.7, color: BrandColors.gray)),
                      const SizedBox(height: 28),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _checking ? null : _check,
                          icon: _checking
                              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                              : const Icon(Icons.refresh_rounded),
                          label: Text(context.tr(_checking ? 'no_internet_checking' : 'no_internet_retry')),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(context.tr('no_internet_auto'),
                          textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, color: BrandColors.gray)),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        ),
    ]);
  }
}
