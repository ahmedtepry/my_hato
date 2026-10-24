import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:url_launcher/url_launcher.dart';

import '../../core/config.dart';
import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../shared/product_card.dart';
import '../../shared/states.dart';
import '../admin/admin_repository.dart' show staffContextProvider;
import '../auth/auth_repository.dart';
import '../catalog/catalog_repository.dart';
import '../../shared/account_review.dart';
import '../../shared/avatars.dart';
import 'profile_repository.dart';

final _avatarUrlProvider = FutureProvider<String?>((ref) async {
  final p = await ref.watch(profileProvider.future);
  return ref.read(profileRepoProvider).avatarUrl(p?['avatar_path'] as String?);
});

Future<void> _pickAvatar(BuildContext context, WidgetRef ref, String? current) async {
  final id = await showAvatarPicker(context, current: current);
  if (id == null) return;
  try {
    await ref.read(profileRepoProvider).update(avatarId: id);
    ref.invalidate(profileProvider);
    if (context.mounted) showSnack(context, context.isAr ? 'اتغيّر الأفاتار' : 'Avatar updated');
  } catch (e) {
    if (context.mounted) showSnack(context, friendlyError(context, e), error: true);
  }
}

/// Profile picture: the chosen cartoon avatar (or an older uploaded photo), with a small edit badge.
class _AvatarButton extends StatelessWidget {
  const _AvatarButton({required this.avatarId, required this.photoUrl, required this.onPick, this.size = 68});
  final String? avatarId;
  final String? photoUrl;
  final VoidCallback onPick;
  final double size;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onPick,
        child: Stack(clipBehavior: Clip.none, children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            transitionBuilder: (c, a) => ScaleTransition(scale: CurvedAnimation(parent: a, curve: Curves.easeOutBack), child: c),
            child: isAvatarId(avatarId)
                ? HatoAvatar(key: ValueKey(avatarId), id: avatarId!, size: size)
                : CircleAvatar(
                    key: const ValueKey('none'),
                    radius: size / 2,
                    backgroundColor: BrandColors.navy,
                    backgroundImage: photoUrl != null ? NetworkImage(photoUrl!) : null,
                    child: photoUrl == null ? Icon(Icons.person_rounded, color: Colors.white, size: size / 2) : null,
                  ),
          ),
          PositionedDirectional(
            end: -2,
            bottom: -2,
            child: Container(
              padding: const EdgeInsets.all(5),
              decoration: BoxDecoration(color: BrandColors.electric, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 2)),
              child: Icon(isAvatarId(avatarId) ? Icons.edit_rounded : Icons.add_rounded, size: size * 0.2, color: Colors.white),
            ),
          ),
        ]),
      );
}

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    final profile = ref.watch(profileProvider);
    if (user == null) {
      return Scaffold(
        appBar: AppBar(title: Text(context.tr('nav_account'))),
        body: ListView(children: [
          EmptyState(icon: Icons.person_outline, title: context.tr('login_required'), action: context.tr('login'), onAction: () => context.push('/auth/login?redirect=%2Faccount')),
          ListTile(leading: const Icon(Icons.manage_search_rounded), title: Text(context.tr('track_repair')), onTap: () => context.push('/repairs/lookup')),
          ListTile(leading: const Icon(Icons.language), title: Text(context.tr('settings')), onTap: () => context.push('/account/settings')),
          ListTile(leading: const Icon(Icons.support_agent), title: Text(context.tr('help')), onTap: () => context.push('/account/help')),
          ListTile(leading: const Icon(Icons.privacy_tip_outlined), title: Text(context.tr('privacy')), onTap: () => context.push('/account/legal')),
        ]),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(context.tr('profile')),
        leading: IconButton(icon: const Icon(Icons.home_outlined), tooltip: context.tr('back_home'), onPressed: () => context.go('/')),
      ),
      body: profile.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(profileProvider)),
        data: (p) {
          final created = DateTime.parse((p?['created_at'] ?? user.createdAt) as String).toLocal();
          final review = ref.watch(accountReviewProvider).valueOrNull ?? 'approved';
          final verified = isAccountVerified(p) && review == 'approved';
          final phone = reachablePhone(p) ?? (p?['phone'] as String?);
          final customer = ref.watch(customerProvider).valueOrNull;
          final avatar = ref.watch(_avatarUrlProvider).valueOrNull;
          return ListView(padding: const EdgeInsets.all(16), children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(children: [
                  _AvatarButton(
                    avatarId: p?['avatar_id'] as String?,
                    photoUrl: avatar,
                    onPick: () => _pickAvatar(context, ref, p?['avatar_id'] as String?),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text((p?['full_name'] as String?)?.isNotEmpty == true ? p!['full_name'] as String : '—',
                          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
                      if (customer?['username'] != null)
                        Directionality(textDirection: TextDirection.ltr, child: Text('@${customer!['username']}', style: const TextStyle(color: BrandColors.electric, fontWeight: FontWeight.w700))),
                      if (p?['email'] != null)
                        Directionality(textDirection: TextDirection.ltr, child: Text(p!['email'] as String, style: const TextStyle(color: BrandColors.gray))),
                      if (phone != null) Directionality(textDirection: TextDirection.ltr, child: Text(phone)),
                      const SizedBox(height: 4),
                      Wrap(spacing: 6, runSpacing: 6, children: [
                        StatusChip(
                          label: verified
                              ? context.tr('account_verified')
                              : review == 'rejected'
                                  ? (context.isAr ? 'حساب مرفوض' : 'Account rejected')
                                  : review == 'pending'
                                      ? (context.isAr ? 'قيد التوثيق' : 'Being verified')
                                      : context.tr('account_not_verified'),
                          color: verified ? BrandColors.success : (review == 'rejected' ? BrandColors.error : BrandColors.warning),
                        ),
                        if (customer?['customer_code'] != null)
                          StatusChip(label: '${context.tr('customer_code')}: ${customer!['customer_code']}', color: BrandColors.navy),
                      ]),
                      Text(context.tr('member_since', {'date': DateFormat.yMMMd(context.lang).format(created)}),
                          style: const TextStyle(color: BrandColors.gray, fontSize: 12)),
                    ]),
                  ),
                ]),
              ),
            ),
            if (phone == null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.phone_outlined),
                  label: Text(context.tr('add_contact_phone')),
                  onPressed: () => context.push('/account/edit'),
                ),
              ),
            const SizedBox(height: 12),
            // team members only: their way into the team console
            if ((ref.watch(staffContextProvider).valueOrNull?.roles ?? const <String>{}).isNotEmpty) ...[
              Material(
                borderRadius: BorderRadius.circular(18),
                clipBehavior: Clip.antiAlias,
                child: Ink(
                  decoration: const BoxDecoration(gradient: LinearGradient(colors: [BrandColors.navyDeep, BrandColors.navy])),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    leading: const CircleAvatar(backgroundColor: Colors.white24, child: Icon(Icons.dashboard_customize_rounded, color: Colors.white)),
                    title: Text(context.isAr ? 'لوحة الفريق' : 'Team console', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
                    subtitle: Text(context.isAr ? 'الطلبات والصيانة وشغلك اليومي' : 'Orders, repairs and your daily work',
                        style: const TextStyle(color: Colors.white70, fontSize: 12.5)),
                    trailing: const Icon(Icons.chevron_left_rounded, color: Colors.white),
                    onTap: () => context.push('/hato-console'),
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
            Card(
              child: Column(children: [
                _tile(context, Icons.edit_rounded, 'edit_profile', '/account/edit', const Color(0xFF2F6FE0)),
                _tile(context, Icons.location_on_rounded, 'addresses', '/account/addresses', const Color(0xFFE23D52)),
                _tile(context, Icons.shopping_bag_rounded, 'my_orders', '/orders', const Color(0xFFF08A12)),
                _tile(context, Icons.build_rounded, 'repairs', '/orders?tab=1', const Color(0xFF566380)),
                ListTile(
                  leading: _iconTile(Icons.emoji_events_rounded, const Color(0xFFD99A00)),
                  title: Text(context.isAr ? 'مكافآت My Hatō' : 'My Hatō Rewards'),
                  subtitle: Text(context.isAr ? 'مهام ونقاط وجوايز' : 'Missions, points and prizes', style: const TextStyle(fontSize: 12)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push('/loyalty'),
                ),
                _tile(context, Icons.favorite_rounded, 'favorites', '/account/favorites', const Color(0xFFE0338A)),
                _tile(context, Icons.credit_card_rounded, 'saved_cards', '/account/cards', const Color(0xFF1B8FC4)),
                _tile(context, Icons.receipt_rounded, 'payments_history', '/payments', const Color(0xFF14A671)),
                _tile(context, Icons.notifications_rounded, 'notifications', '/notifications', const Color(0xFFEA5A14)),
              ]),
            ),
            const SizedBox(height: 12),
            Card(
              child: Column(children: [
                _tile(context, Icons.settings_rounded, 'settings', '/account/settings', const Color(0xFF5253D6)),
                _tile(context, Icons.support_agent_rounded, 'help', '/account/help', const Color(0xFF1B8FC4)),
                _tile(context, Icons.privacy_tip_rounded, 'privacy', '/account/legal', const Color(0xFF566380)),
              ]),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              icon: const Icon(Icons.logout),
              label: Text(context.tr('logout')),
              onPressed: () async {
                await ref.read(authRepoProvider).signOut();
                if (context.mounted) context.go('/');
              },
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: BrandColors.error),
              onPressed: p?['deletion_requested_at'] != null
                  ? null
                  : () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (c) => AlertDialog(
                          title: Text(context.tr('delete_account')),
                          content: Text(context.tr('delete_confirm')),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(c, false), child: Text(context.tr('cancel'))),
                            FilledButton(style: FilledButton.styleFrom(backgroundColor: BrandColors.error), onPressed: () => Navigator.pop(c, true), child: Text(context.tr('confirm'))),
                          ],
                        ),
                      );
                      if (ok != true) return;
                      await ref.read(profileRepoProvider).requestDeletion();
                      ref.invalidate(profileProvider);
                      if (context.mounted) showSnack(context, context.tr('deletion_requested'));
                    },
              child: Text(p?['deletion_requested_at'] != null ? context.tr('deletion_requested') : context.tr('delete_account')),
            ),
          ]);
        },
      ),
    );
  }

  // soft tinted square with a single-colour glyph; one accent per entry
  Widget _iconTile(IconData icon, Color c) => Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(color: c.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(13)),
        child: Icon(icon, color: c, size: 23),
      );

  Widget _tile(BuildContext context, IconData icon, String key, String route, Color color) => ListTile(
        leading: _iconTile(icon, color),
        title: Text(context.tr(key)),
        trailing: const Icon(Icons.chevron_right),
        onTap: () {
          if (route.startsWith('/orders')) {
            context.go(route);
          } else {
            context.push(route);
          }
        },
      );
}

class EditProfileScreen extends ConsumerStatefulWidget {
  const EditProfileScreen({super.key});
  @override
  ConsumerState<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends ConsumerState<EditProfileScreen> {
  late final _name = TextEditingController(text: (ref.read(profileProvider).valueOrNull?['full_name'] as String?) ?? '');
  late final _phone = TextEditingController(text: _localPhone(ref.read(profileProvider).valueOrNull?['contact_phone'] as String?));
  late final String _email0 = _realEmail(ref.read(currentUserProvider)?.email ?? ref.read(profileProvider).valueOrNull?['email'] as String?);
  late final _email = TextEditingController(text: _email0);
  final _curPass = TextEditingController();
  bool _showPass = false;
  bool _busy = false;
  String? _phoneError;
  String? _emailError;
  String? _passError;

  /// Team accounts carry a placeholder address: treat it as "no email yet".
  static String _realEmail(String? e) => (e == null || e.endsWith('@team.myhato.app')) ? '' : e;
  bool get _emailChanged => _email.text.trim().toLowerCase() != _email0.toLowerCase();

  static String _localPhone(String? e164) => (e164 != null && e164.startsWith('+20')) ? '0${e164.substring(3)}' : (e164 ?? '');

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _email.dispose();
    _curPass.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(context.tr('edit_profile'))),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          Center(
            child: Builder(builder: (context) {
              final id = ref.watch(profileProvider).valueOrNull?['avatar_id'] as String?;
              return Column(children: [
                _AvatarButton(avatarId: id, photoUrl: null, size: 96, onPick: () => _pickAvatar(context, ref, id)),
                TextButton.icon(
                  icon: const Icon(Icons.face_retouching_natural_rounded),
                  label: Text(context.isAr ? 'اختار الأفاتار' : 'Choose avatar'),
                  onPressed: () => _pickAvatar(context, ref, id),
                ),
              ]);
            }),
          ),
          const SizedBox(height: 8),
          TextField(controller: _name, decoration: InputDecoration(labelText: context.tr('full_name'))),
          const SizedBox(height: 12),
          TextField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            textDirection: TextDirection.ltr,
            decoration: InputDecoration(
              labelText: context.tr('contact_phone'),
              hintText: '01XXXXXXXXX',
              helperText: context.tr('contact_phone_help'),
              errorText: _phoneError,
              prefixIcon: const Icon(Icons.phone_outlined),
            ),
          ),
          const SizedBox(height: 12),
          if (_email0.isEmpty)
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: BrandColors.electric.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12)),
              child: Row(children: [
                const Icon(Icons.mark_email_unread_outlined, color: BrandColors.electric),
                const SizedBox(width: 10),
                Expanded(child: Text(context.tr('email_add_hint'), style: const TextStyle(height: 1.5))),
              ]),
            ),
          TextField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            textDirection: TextDirection.ltr,
            autocorrect: false,
            onChanged: (_) => setState(() => _showPass = _email0.isNotEmpty && _emailChanged),
            decoration: InputDecoration(
              labelText: context.tr('email_label'),
              errorText: _emailError,
              prefixIcon: const Icon(Icons.alternate_email_rounded),
            ),
          ),
          if (_showPass) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _curPass,
              obscureText: true,
              textDirection: TextDirection.ltr,
              decoration: InputDecoration(
                labelText: context.tr('current_password'),
                helperText: context.tr('email_change_hint'),
                helperMaxLines: 2,
                errorText: _passError,
                prefixIcon: const Icon(Icons.lock_outline_rounded),
              ),
            ),
          ],
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _busy
                ? null
                : () async {
                    if (_name.text.trim().length < 2) return;
                    final newEmail = _email.text.trim().toLowerCase();
                    final wantsEmail = newEmail.isNotEmpty && _emailChanged;
                    if (wantsEmail && !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(newEmail)) {
                      setState(() => _emailError = context.tr('err_invalid_email'));
                      return;
                    }
                    if (wantsEmail && _email0.isNotEmpty && _curPass.text.isEmpty) {
                      setState(() => _passError = context.tr('required'));
                      return;
                    }
                    setState(() {
                      _emailError = null;
                      _passError = null;
                    });
                    final raw = _phone.text.trim();
                    final phone = raw.isEmpty ? '' : normalizeEgyptMobile(raw);
                    if (phone == null) {
                      setState(() => _phoneError = context.tr('invalid_phone'));
                      return;
                    }
                    setState(() {
                      _phoneError = null;
                      _busy = true;
                    });
                    try {
                      await ref.read(profileRepoProvider).update(fullName: _name.text, contactPhone: phone);
                      if (wantsEmail) {
                        await ref.read(authRepoProvider).changeEmail(newEmail, _curPass.text);
                      }
                      ref.invalidate(profileProvider);
                      if (context.mounted) {
                        showSnack(context, context.tr(wantsEmail ? 'email_saved' : 'saved'));
                        context.pop();
                      }
                    } catch (e) {
                      if (context.mounted && '$e'.contains('WRONG_PASSWORD')) setState(() => _passError = context.tr('err_wrong_password'));
                      if (context.mounted) showSnack(context, friendlyError(context, e), error: true);
                    } finally {
                      if (mounted) setState(() => _busy = false);
                    }
                  },
            child: Text(context.tr('save')),
          ),
        ]),
      );
}

class AddressesScreen extends ConsumerWidget {
  const AddressesScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(addressesProvider);
    return Scaffold(
      appBar: AppBar(title: Text(context.tr('addresses'))),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: BrandColors.electric,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: Text(context.tr('add_address')),
        onPressed: () async {
          await context.push('/account/addresses/new');
          ref.invalidate(addressesProvider);
        },
      ),
      body: data.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(addressesProvider)),
        data: (list) => list.isEmpty
            ? EmptyState(icon: Icons.location_off_outlined, title: context.tr('add_address'))
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                itemCount: list.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (_, i) {
                  final a = list[i];
                  return Card(
                    child: ListTile(
                      leading: Icon(a['is_default'] == true ? Icons.home_rounded : Icons.location_on_outlined, color: BrandColors.electric),
                      title: Text('${a['label'] ?? a['recipient_name']}', style: const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text('${a['governorate']} — ${a['city']} — ${a['street']}\n${a['phone']}'),
                      isThreeLine: true,
                      onTap: () async {
                        await context.push('/account/addresses/edit', extra: a);
                        ref.invalidate(addressesProvider);
                      },
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline, color: BrandColors.error),
                        onPressed: () async {
                          await ref.read(profileRepoProvider).deleteAddress(a['id'] as String);
                          ref.invalidate(addressesProvider);
                        },
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}

class AddressFormScreen extends ConsumerStatefulWidget {
  const AddressFormScreen({super.key, this.existing});
  final Map<String, dynamic>? existing;
  @override
  ConsumerState<AddressFormScreen> createState() => _AddressFormScreenState();
}

class _AddressFormScreenState extends ConsumerState<AddressFormScreen> {
  final _form = GlobalKey<FormState>();
  late final Map<String, TextEditingController> _c = {
    for (final k in ['label', 'recipient_name', 'phone', 'city', 'street', 'building', 'landmark'])
      k: TextEditingController(text: widget.existing?[k] as String? ?? ''),
  };
  late String? _gov = widget.existing?['governorate'] as String?;
  late bool _default = widget.existing?['is_default'] == true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.existing == null) {
      final p = ref.read(profileProvider).valueOrNull;
      _c['recipient_name']!.text = (p?['full_name'] as String?) ?? '';
      _c['phone']!.text = (p?['phone'] as String?) ?? '';
    }
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    String? req(String? v) => (v == null || v.trim().isEmpty) ? context.tr('required') : null;
    return Scaffold(
      appBar: AppBar(title: Text(context.tr('add_address'))),
      body: Form(
        key: _form,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          TextFormField(controller: _c['label'], decoration: InputDecoration(labelText: context.isAr ? 'اسم العنوان (البيت، الشغل…)' : 'Label (Home, Work…)')),
          const SizedBox(height: 12),
          TextFormField(controller: _c['recipient_name'], decoration: InputDecoration(labelText: context.tr('recipient_name')), validator: req),
          const SizedBox(height: 12),
          TextFormField(
            controller: _c['phone'],
            keyboardType: TextInputType.phone,
            textDirection: TextDirection.ltr,
            decoration: InputDecoration(labelText: context.tr('phone')),
            validator: (v) => RegExp(r'^\+?[0-9]{8,15}$').hasMatch((v ?? '').replaceAll(' ', '')) ? null : context.tr('invalid'),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: _gov,
            isExpanded: true,
            decoration: InputDecoration(labelText: context.tr('governorate')),
            items: [for (final g in egyptGovernorates) DropdownMenuItem(value: g, child: Text(g))],
            onChanged: (v) => setState(() => _gov = v),
            validator: (v) => v == null ? context.tr('required') : null,
          ),
          const SizedBox(height: 12),
          TextFormField(controller: _c['city'], decoration: InputDecoration(labelText: context.tr('city')), validator: req),
          const SizedBox(height: 12),
          TextFormField(controller: _c['street'], decoration: InputDecoration(labelText: context.tr('street')), validator: req),
          const SizedBox(height: 12),
          TextFormField(controller: _c['building'], decoration: InputDecoration(labelText: context.tr('building'))),
          const SizedBox(height: 12),
          TextFormField(controller: _c['landmark'], decoration: InputDecoration(labelText: context.tr('landmark'))),
          SwitchListTile(contentPadding: EdgeInsets.zero, value: _default, onChanged: (v) => setState(() => _default = v), title: Text(context.tr('make_default'))),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _busy
                ? null
                : () async {
                    if (!_form.currentState!.validate()) return;
                    setState(() => _busy = true);
                    try {
                      await ref.read(profileRepoProvider).saveAddress({
                        for (final e in _c.entries) e.key: e.value.text.trim().isEmpty ? null : e.value.text.trim(),
                        'phone': _c['phone']!.text.replaceAll(' ', ''),
                        'governorate': _gov,
                        'is_default': _default,
                      }, id: widget.existing?['id'] as String?);
                      if (context.mounted) context.pop();
                    } catch (e) {
                      if (context.mounted) showSnack(context, friendlyError(context, e), error: true);
                    } finally {
                      if (mounted) setState(() => _busy = false);
                    }
                  },
            child: Text(context.tr('save')),
          ),
        ]),
      ),
    );
  }
}

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(profileProvider).valueOrNull;
    final signedIn = ref.watch(currentUserProvider) != null;
    Future<void> setPref({bool? o, bool? r, bool? pr}) async {
      await ref.read(profileRepoProvider).update(notifyOrders: o, notifyRepairs: r, notifyPromotions: pr);
      ref.invalidate(profileProvider);
    }

    return Scaffold(
      appBar: AppBar(title: Text(context.tr('settings'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text(context.tr('language'), style: const TextStyle(fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          showSelectedIcon: false,
          segments: [
            ButtonSegment(value: 'ar', label: Text(context.tr('arabic'))),
            ButtonSegment(value: 'en', label: Text(context.tr('english'))),
          ],
          selected: {context.lang},
          onSelectionChanged: (s) async {
            await ref.read(localeProvider.notifier).set(Locale(s.first));
            if (signedIn) await ref.read(profileRepoProvider).update(locale: s.first);
          },
        ),
        if (signedIn && p != null) ...[
          const SizedBox(height: 24),
          Text(context.tr('notifications'), style: const TextStyle(fontWeight: FontWeight.w800)),
          SwitchListTile(contentPadding: EdgeInsets.zero, title: Text(context.tr('notify_orders')), value: p['notify_orders'] == true, onChanged: (v) => setPref(o: v)),
          SwitchListTile(contentPadding: EdgeInsets.zero, title: Text(context.tr('notify_repairs')), value: p['notify_repairs'] == true, onChanged: (v) => setPref(r: v)),
          SwitchListTile(contentPadding: EdgeInsets.zero, title: Text(context.tr('notify_promotions')), value: p['notify_promotions'] == true, onChanged: (v) => setPref(pr: v)),
        ],
      ]),
    );
  }
}

class FavoritesScreen extends ConsumerWidget {
  const FavoritesScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(favoritesProvider);
    return Scaffold(
      appBar: AppBar(title: Text(context.tr('favorites'))),
      body: data.when(
        loading: () => const SingleChildScrollView(child: ProductGridSkeleton()),
        error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(favoritesProvider)),
        data: (list) => list.isEmpty
            ? EmptyState(icon: Icons.favorite_border, title: context.tr('favorites'), action: context.tr('continue_shopping'), onAction: () => context.go('/'))
            : GridView.builder(
                padding: const EdgeInsets.all(16),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 220, mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: 0.84),
                itemCount: list.length,
                itemBuilder: (_, i) => ProductCard(p: list[i]),
              ),
      ),
    );
  }
}

class HelpScreen extends ConsumerStatefulWidget {
  const HelpScreen({super.key});
  @override
  ConsumerState<HelpScreen> createState() => _HelpScreenState();
}

class _HelpScreenState extends ConsumerState<HelpScreen> {
  final _subject = TextEditingController();
  final _message = TextEditingController();
  bool _busy = false;
  @override
  void dispose() {
    _subject.dispose();
    _message.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final signedIn = ref.watch(currentUserProvider) != null;
    return Scaffold(
      appBar: AppBar(title: Text(context.tr('help'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (AppConfig.supportPhone.isNotEmpty)
          Card(child: ListTile(leading: const Icon(Icons.call_outlined), title: Text(context.tr('call_us')), subtitle: Text(AppConfig.supportPhone), onTap: () => launchUrl(Uri.parse('tel:${AppConfig.supportPhone}')))),
        if (AppConfig.supportWhatsapp.isNotEmpty)
          Card(
              child: ListTile(
                  leading: const Icon(Icons.chat_outlined),
                  title: Text(context.tr('whatsapp')),
                  onTap: () => launchUrl(Uri.parse('https://wa.me/${AppConfig.supportWhatsapp}'), mode: LaunchMode.externalApplication))),
        const SizedBox(height: 12),
        if (signedIn) ...[
          TextField(controller: _subject, maxLength: 200, decoration: InputDecoration(labelText: context.tr('support_subject'))),
          TextField(controller: _message, maxLength: 4000, maxLines: 5, decoration: InputDecoration(labelText: context.tr('support_message'), alignLabelWithHint: true)),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _busy
                ? null
                : () async {
                    if (_subject.text.trim().length < 3 || _message.text.trim().length < 5) return;
                    setState(() => _busy = true);
                    try {
                      await ref.read(profileRepoProvider).sendSupport(_subject.text.trim(), _message.text.trim(), null);
                      _subject.clear();
                      _message.clear();
                      if (context.mounted) showSnack(context, context.tr('sent_ok'));
                    } catch (e) {
                      if (context.mounted) showSnack(context, friendlyError(context, e), error: true);
                    } finally {
                      if (mounted) setState(() => _busy = false);
                    }
                  },
            child: Text(context.tr('send')),
          ),
        ] else
          OutlinedButton(onPressed: () => context.push('/auth/login'), child: Text(context.tr('login'))),
      ]),
    );
  }
}

/// Privacy policy and terms. Written as sections so each part is easy to scan; keep the Arabic and English in step.
class LegalScreen extends StatelessWidget {
  const LegalScreen({super.key});

  static const _updated = '24/10/2026';

  static const _ar = <(String, String)>[
    ('عن السياسة دي', 'السياسة دي بتوضّح إزاي My Hatō بتتعامل مع بياناتك، وإيه القواعد اللي بتحكم الشراء والصيانة ونظام المكافآت والهدايا. باستخدامك للتطبيق وإنشاء حساب إنت موافق عليها.'),
    ('البيانات اللي بنجمعها', '• بيانات الحساب: الاسم، رقم الموبايل، الإيميل، والعناوين.\n• الطلبات والمدفوعات: تفاصيل الطلبات وحالتها وسجل الدفع.\n• الصيانة: بيانات الجهاز، رقم IMEI، وصف العطل، والصور اللي بترفعها.\n• التفاعل: التقييمات، اللايكات، المفضلة، والإشعارات.\n• المكافآت: النقاط والمستوى والهدايا وأكوادها.\n• بيانات تقنية بسيطة لتشغيل التطبيق وحمايته.'),
    ('إزاي بنستخدم بياناتك', '• تنفيذ طلباتك وصيانتك والتواصل معاك بخصوصها.\n• إرسال إشعارات عن حالة الطلب أو الصيانة، وعروض لو إنت وافقت عليها.\n• تشغيل نظام المكافآت ومنع التلاعب.\n• تحسين الخدمة وحماية التطبيق والحسابات.\nمش بنبيع بياناتك ولا بنشاركها مع أي طرف للإعلان.'),
    ('حماية بياناتك', '• الاتصال بين التطبيق والسيرفر مشفّر.\n• صور الأجهزة ورقم IMEI محفوظة بشكل خاص ومتاحة لك وللموظفين المختصين بس.\n• وصول الموظفين بيتحدد حسب دور كل واحد، والعمليات المهمة بتتسجل.\n• بيانات البطاقة مش بتتخزن عندنا: بنحتفظ بس بآخر 4 أرقام ونوع البطاقة وتاريخ الانتهاء من مزوّد الدفع، وتأكيد الدفع بيجي من المزوّد نفسه مش من التطبيق.\n• أكواد التحقق مش بتتخزن.'),
    ('الاحتفاظ بالبيانات وحذفها', '• تقدر تعدّل بياناتك أو تطلب حذف حسابك من صفحة حسابي. بنحذف بياناتك الشخصية خلال 30 يوم.\n• بنحتفظ بسجلات الطلبات والفواتير 5 سنين لأغراض محاسبية وقانونية.'),
    ('الشراء والطلبات', '• الأسعار بالجنيه المصري، والتوفر والسعر النهائي بيتأكدوا لما فريقنا يأكد الطلب.\n• الدفع عند الاستلام أو في الفرع، أو بالطرق الأونلاين المتاحة في التطبيق.\n• ممكن نرفض أو نلغي طلب لو فيه بيانات غير صحيحة أو شبهة احتيال أو المنتج مش متاح، وبنرجّع أي مبلغ اتدفع.\n• الضمان حسب المكتوب على كل منتج، وبيشمل عيوب التصنيع بس، مش سوء الاستخدام أو الكسر أو السوائل.\n• عند الاستلام افحص المنتج قبل ما تمشي، وأي مشكلة بلّغنا بيها بأسرع وقت.'),
    ('الصيانة', '• بنفحص الجهاز وبنبلّغك بالتشخيص والتكلفة، ومفيش صيانة بتكلفة بتبدأ إلا بموافقتك.\n• كل طلب صيانة ليه كود تتابع بيه الحالة، ومتشاركوش مع حد.\n• إنت بتقرّ إن الجهاز بتاعك أو معاك تفويض بصيانته. لو الجهاز مشتبه إنه مسروق أو الـIMEI مش مظبوط، بنرفض الصيانة ونقدر نبلّغ الجهات المختصة.\n• خد نسخة احتياطية من بياناتك قبل التسليم. إحنا مش مسؤولين عن فقدان البيانات أثناء الصيانة.\n• ممكن يتضح إن الجهاز مش قابل للإصلاح، وساعتها بنبلّغك وبنرجّعه.\n• لازم تستلم جهازك بعد ما يبقى جاهز، وبنتواصل معاك عدة مرات. الأجهزة اللي مش بتتسلّم بعد المدة اللي بنبلّغك بيها مش بنتحمّل مسؤولية تخزينها.\n• ضمان الصيانة بيشمل القطعة أو العطل اللي اتصلّح بس، حسب المكتوب في تفاصيل الصيانة.'),
    ('المكافآت والهدايا', '• النقاط والمستويات والهدايا ملكك الشخصي، مش ليها قيمة نقدية، ومينفعش تتحوّل أو تتباع أو تتنقل لحساب تاني.\n• النقاط بتتضاف بعد تسليم الطلبات، ولو الطلب اتلغى أو اتسترد، أو التقييم اتشال، النقاط بتتسحب.\n• نقاط التقييمات واللايكات ليها حدود يومية وأسبوعية، وبتستلمها بنفسك من صفحة المكافآت.\n• المستويات سرية، والهدية لكل مستوى بتحددها الإدارة وتظهرلك بس لما نحددها.\n• كود الهدية خاص بيك وبيتستخدم مرة واحدة، ولما الهدية تتسلّم الكود بيتقفل. متشاركوش مع حد.\n• الاستلام بيكون من الفرع أو بالتنسيق مع فريقنا، وبنطلب إثبات إنك صاحب الحساب.\n• نقدر نعدّل نظام المكافآت أو نوقفه أو نغيّر الهدايا في أي وقت، من غير ما ده يمس النقاط اللي اتكسبت بشكل سليم.\n• أي تلاعب (حسابات مكررة، تقييمات أو لايكات وهمية، استغلال ثغرات، استخدام برامج آلية) بيخلّينا نلغي النقاط والهدايا ونوقف الحساب.'),
    ('الاستخدام المسموح وحماية التطبيق', 'ممنوع:\n• محاولة اختراق التطبيق أو السيرفر، أو الوصول لبيانات حد تاني.\n• فك التطبيق أو تعديله، أو استخدام برامج آلية لسحب البيانات أو تنفيذ عمليات.\n• إنشاء حسابات متعددة للاستفادة من المكافآت أو العروض.\n• كتابة تقييمات مسيئة أو وهمية أو فيها أرقام تليفونات أو إعلانات.\n• رفع محتوى مخالف للقانون أو مش بتاعك.\nبنراجع التقييمات اللي فيها ألفاظ مش لائقة قبل نشرها، ونقدر نشيل أي محتوى مخالف.\nلو حصل مخالفة، نقدر نحد من الحساب أو نوقفه مؤقتًا أو نهائيًا ونتخذ الإجراء القانوني المناسب.'),
    ('حسابك', '• بيانات الدخول مسؤوليتك، متشاركهاش مع حد. بلّغنا فورًا لو شكيت إن حد دخل على حسابك.\n• بعض الخدمات ممكن تتطلب توثيق الحساب من فريقنا.'),
    ('الإشعارات', 'بنبعتلك إشعارات عن طلباتك وصيانتك وهداياك. العروض ممكن تقفلها من إعدادات الإشعارات في حسابك.'),
    ('تعديل السياسة والتواصل', 'ممكن نحدّث السياسة من وقت للتاني، وبنبلّغك بالتعديلات المهمة. استمرارك في الاستخدام معناه موافقتك على النسخة الجديدة.'),
  ];

  static const _en = <(String, String)>[
    ('About this policy', 'This policy explains how My Hatō handles your data and the rules for purchases, repairs, and the rewards and gifts system. By using the app and creating an account you agree to it.'),
    ('Data we collect', '• Account: name, mobile number, email and addresses.\n• Orders and payments: order details, status and payment history.\n• Repairs: device details, IMEI, fault description and the photos you upload.\n• Activity: reviews, likes, favourites and notifications.\n• Rewards: points, level, gifts and their codes.\n• Basic technical data to run and protect the app.'),
    ('How we use your data', '• To fulfil your orders and repairs and contact you about them.\n• To send notifications about your order or repair, and offers if you agreed to them.\n• To run the rewards system and prevent abuse.\n• To improve the service and protect the app and accounts.\nWe never sell your data or share it for advertising.'),
    ('How we protect it', '• The connection between the app and our server is encrypted.\n• Device photos and IMEI are private and visible only to you and authorised staff.\n• Staff access depends on each person\'s role, and important actions are logged.\n• We do not store card data: we only keep the last 4 digits, card brand and expiry from the payment provider, and payment confirmation comes from the provider, not the app.\n• Verification codes are never stored.'),
    ('Retention and deletion', '• You can edit your data or request account deletion from Account. We delete your personal data within 30 days.\n• Order and invoice records are kept for 5 years for accounting and legal reasons.'),
    ('Purchases and orders', '• Prices are in Egyptian Pounds; availability and final price are confirmed when our team confirms the order.\n• Payment is cash on delivery or at the branch, or by the online methods offered in the app.\n• We may decline or cancel an order for incorrect details, suspected fraud or unavailability, and refund anything paid.\n• Warranty is as stated on each product and covers manufacturing defects only, not misuse, breakage or liquid damage.\n• Check the product when you receive it and report any problem as soon as possible.'),
    ('Repairs', '• We inspect the device and tell you the diagnosis and cost; no chargeable repair starts without your approval.\n• Each repair has a code to track its status. Do not share it.\n• You confirm the device is yours or that you are authorised to repair it. If a device is suspected stolen or the IMEI does not match, we refuse the repair and may notify the authorities.\n• Back up your data before handing the device over. We are not responsible for data loss during repair.\n• A device may turn out to be unrepairable; we will tell you and return it.\n• Collect your device once it is ready; we contact you several times. We are not responsible for storing devices left uncollected after the period we tell you about.\n• Repair warranty covers only the part or fault that was repaired, as stated in the repair details.'),
    ('Rewards and gifts', '• Points, levels and gifts are personal, have no cash value, and cannot be sold, transferred or moved to another account.\n• Points are added after orders are delivered; if an order is cancelled or refunded, or a review is removed, the points are taken back.\n• Review and like points have daily and weekly limits, and you collect them yourself from the Rewards page.\n• Levels are private, and the gift for each level is decided by management and shown to you only when we set it.\n• A gift code is yours alone and works once; after the gift is delivered the code is locked. Do not share it.\n• Gifts are collected at the branch or arranged with our team, and we may ask you to prove you own the account.\n• We may change or stop the rewards system or change gifts at any time, without affecting points that were properly earned.\n• Any abuse (duplicate accounts, fake reviews or likes, exploiting bugs, automated tools) lets us cancel points and gifts and suspend the account.'),
    ('Acceptable use and app protection', 'You must not:\n• try to break into the app or server, or access anyone else\'s data.\n• reverse engineer or modify the app, or use automated tools to scrape data or perform actions.\n• create multiple accounts to take advantage of rewards or offers.\n• post abusive or fake reviews, or ones containing phone numbers or ads.\n• upload content that is unlawful or not yours.\nReviews with inappropriate language are checked before publishing, and we may remove anything that breaks these rules.\nIf the rules are broken we may restrict or suspend the account, temporarily or permanently, and take appropriate legal action.'),
    ('Your account', '• You are responsible for your login details; do not share them. Tell us immediately if you think someone accessed your account.\n• Some services may require our team to verify your account.'),
    ('Notifications', 'We send notifications about your orders, repairs and gifts. You can turn offers off from notification settings in your account.'),
    ('Changes and contact', 'We may update this policy from time to time and will tell you about important changes. Continuing to use the app means you accept the new version.'),
  ];

  @override
  Widget build(BuildContext context) {
    final ar = context.isAr;
    final sections = ar ? _ar : _en;
    final theme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(context.tr('privacy'))),
      body: ListView(padding: const EdgeInsets.fromLTRB(20, 16, 20, 32), children: [
        Text(ar ? 'سياسة الخصوصية والشروط' : 'Privacy policy and terms', style: theme.titleLarge?.copyWith(fontWeight: FontWeight.w900)),
        const SizedBox(height: 4),
        Text(ar ? 'My Hatō · آخر تحديث $_updated' : 'My Hatō · Last updated $_updated', style: theme.bodySmall?.copyWith(color: BrandColors.gray)),
        const SizedBox(height: 12),
        for (final s in sections) ...[
          const SizedBox(height: 14),
          Text(s.$1, style: theme.titleMedium?.copyWith(fontWeight: FontWeight.w800, color: BrandColors.navy)),
          const SizedBox(height: 6),
          Text(s.$2, style: const TextStyle(height: 1.8)),
        ],
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: BrandColors.electric.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(14)),
          child: Row(children: [
            const Icon(Icons.support_agent_rounded, color: BrandColors.electric),
            const SizedBox(width: 10),
            Expanded(child: Text(ar ? 'أي استفسار أو طلب بخصوص بياناتك: ${AppConfig.supportPhone}' : 'Questions or requests about your data: ${AppConfig.supportPhone}', style: const TextStyle(fontWeight: FontWeight.w700))),
          ]),
        ),
      ]),
    );
  }
}
