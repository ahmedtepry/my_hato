// Owner: the wallet numbers customers transfer to (Vodafone Cash, Etisalat Cash, InstaPay). Windows team app only.
// An empty number hides that wallet from the checkout.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../shared/states.dart';

String _t(BuildContext c, String ar, String en) => c.isAr ? ar : en;

class WalletNumbersPanel extends ConsumerStatefulWidget {
  const WalletNumbersPanel({super.key});
  @override
  ConsumerState<WalletNumbersPanel> createState() => _WalletNumbersPanelState();
}

class _WalletNumbersPanelState extends ConsumerState<WalletNumbersPanel> {
  final _c = {for (final k in ['vodafone', 'etisalat', 'instapay']) k: TextEditingController()};
  bool _loaded = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = await ref.read(supabaseProvider).rpc('wallet_numbers_get');
      if (r is Map) {
        for (final e in _c.entries) {
          e.value.text = '${r[e.key] ?? ''}';
        }
      }
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(context, e), error: true);
    }
    if (mounted) setState(() => _loaded = true);
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await ref.read(supabaseProvider).rpc('wallet_numbers_set', params: {
        'p_numbers': {for (final e in _c.entries) e.key: e.value.text.trim()},
      });
      if (mounted) showSnack(context, _t(context, 'اتحفظت أرقام المحافظ', 'Wallet numbers saved'));
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const Center(child: CircularProgressIndicator());
    const names = {'vodafone': ('فودافون كاش', 'Vodafone Cash'), 'etisalat': ('اتصالات كاش', 'Etisalat Cash'), 'instapay': ('إنستا باي', 'InstaPay')};
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text(_t(context, 'الأرقام اللي العميل هيحوّل عليها. سيب الخانة فاضية لو مش عايز المحفظة دي تظهر في الدفع.',
          'The numbers customers transfer to. Leave one empty to hide that wallet at checkout.'), style: const TextStyle(color: BrandColors.gray, height: 1.5)),
      const SizedBox(height: 12),
      for (final e in _c.entries) ...[
        TextField(
          controller: e.value,
          textDirection: TextDirection.ltr,
          keyboardType: TextInputType.phone,
          decoration: InputDecoration(labelText: _t(context, names[e.key]!.$1, names[e.key]!.$2), prefixIcon: const Icon(Icons.account_balance_wallet_outlined)),
        ),
        const SizedBox(height: 12),
      ],
      FilledButton(onPressed: _busy ? null : _save, child: Text(_t(context, 'حفظ', 'Save'))),
    ]);
  }
}
