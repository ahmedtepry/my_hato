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
import '../../shared/delivery_location.dart';
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
    for (final k in ['label', 'recipient_name', 'phone', 'city', 'street', 'building', 'landmark', 'location_note'])
      k: TextEditingController(text: widget.existing?[k] as String? ?? ''),
  };
  late String? _gov = widget.existing?['governorate'] as String?;
  late bool _default = widget.existing?['is_default'] == true;
  bool _busy = false;
  bool _locating = false;
  late bool _confirmed = widget.existing?['location_confirmed'] == true;
  late double? _lat = (widget.existing?['latitude'] as num?)?.toDouble();
  late double? _lng = (widget.existing?['longitude'] as num?)?.toDouble();

  Future<void> _pickLocation() async {
    setState(() => _locating = true);
    final pos = await currentPosition();
    if (!mounted) return;
    setState(() {
      _locating = false;
      if (pos != null) {
        _lat = pos.latitude;
        _lng = pos.longitude;
      }
    });
    if (pos == null) showSnack(context, context.tr('location_denied'), error: true);
  }

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
          TextFormField(
            controller: _c['landmark'],
            decoration: InputDecoration(labelText: context.tr('landmark'), helperText: _lat == null ? context.tr('landmark_help') : null),
            validator: (v) => _lat == null && (v == null || v.trim().isEmpty) ? context.tr('required') : null,
          ),
          const SizedBox(height: 20),
          Text(context.tr('location_title'), style: const TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(context.tr('location_hint'), style: const TextStyle(color: BrandColors.gray, fontSize: 13)),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            icon: _locating
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(_lat != null ? Icons.check_circle_rounded : Icons.my_location_rounded),
            label: Text(_lat != null ? context.tr('location_done') : context.tr('location_pick')),
            onPressed: _locating ? null : _pickLocation,
          ),
          const SizedBox(height: 12),
          TextFormField(controller: _c['location_note'], maxLength: 500, maxLines: 2, decoration: InputDecoration(labelText: context.tr('location_note'))),
          if (_lat == null)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _confirmed,
              onChanged: (v) => setState(() => _confirmed = v ?? false),
              title: Text(context.tr('location_confirm'), style: const TextStyle(fontSize: 14)),
            ),
          SwitchListTile(contentPadding: EdgeInsets.zero, value: _default, onChanged: (v) => setState(() => _default = v), title: Text(context.tr('make_default'))),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _busy
                ? null
                : () async {
                    if (!_form.currentState!.validate()) return;
                    if (_lat == null && _c['location_note']!.text.trim().isEmpty) {
                      showSnack(context, context.tr('location_required'), error: true);
                      return;
                    }
                    if (_lat == null && !_confirmed) {
                      showSnack(context, context.tr('location_confirm_needed'), error: true);
                      return;
                    }
                    setState(() => _busy = true);
                    try {
                      await ref.read(profileRepoProvider).saveAddress({
                        for (final e in _c.entries) e.key: e.value.text.trim().isEmpty ? null : e.value.text.trim(),
                        'phone': _c['phone']!.text.replaceAll(' ', ''),
                        'governorate': _gov,
                        'latitude': _lat,
                        'longitude': _lng,
                        'location_confirmed': _lat != null || _confirmed,
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

/// Privacy policy and terms, kept short on purpose: seven small cards a customer can read in under a minute.
class LegalScreen extends ConsumerWidget {
  const LegalScreen({super.key});

  static const _updated = '24/10/2026';

  // (icon, colour, Arabic title, Arabic text, English title, English text)
  static const _cards = <(IconData, Color, String, String, String, String)>[
    (Icons.lock_rounded, Color(0xFF2F6FE0), 'بياناتك معانا', 'بنستخدمها لتنفيذ طلباتك وصيانتك بس. مش بنبيعها لحد، وبطاقتك مش بنخزّنها.',
        'Your data', 'We use it only for your orders and repairs. We never sell it, and we do not store your card.'),
    (Icons.bookmark_rounded, Color(0xFFE23D52), 'حسابك محفوظ', 'حسابك وطلباتك وصيانتك ونقاطك بتفضل محفوظة، وتقدر تعدّل بياناتك في أي وقت من «حسابي».',
        'Your account is kept', 'Your account, orders, repairs and points stay saved, and you can edit your details any time from Account.'),
    (Icons.shopping_bag_rounded, Color(0xFFF08A12), 'المشتريات', 'الأسعار بالجنيه المصري وفريقنا بيأكدها. الضمان لعيوب التصنيع بس، مش الكسر أو المياه. افحص المنتج وقت الاستلام.',
        'Purchases', 'Prices are in EGP and confirmed by our team. Warranty covers manufacturing defects only, not breakage or water. Check the product when you receive it.'),
    (Icons.build_rounded, Color(0xFF566380), 'الصيانة', 'مفيش تكلفة من غير موافقتك. خد نسخة احتياطية من بياناتك، وتأكد إن الجهاز بتاعك، واستلمه أول ما يبقى جاهز.',
        'Repairs', 'No cost starts without your approval. Back up your data, make sure the device is yours, and collect it as soon as it is ready.'),
    (Icons.emoji_events_rounded, Color(0xFFD99A00), 'المكافآت والهدايا', 'النقاط والهدايا ليك إنت بس ومالهاش قيمة نقدية. كود الهدية بيتستخدم مرة واحدة، وأي تلاعب بيلغي النقاط.',
        'Rewards and gifts', 'Points and gifts are yours alone and have no cash value. A gift code works once, and any cheating cancels your points.'),
    (Icons.shield_rounded, Color(0xFF14A671), 'استخدام التطبيق', 'ممنوع الاختراق والحسابات المتكررة والتقييمات الوهمية. المخالفة ممكن توقف الحساب.',
        'Using the app', 'No hacking, duplicate accounts or fake reviews. Breaking these rules can suspend your account.'),
  ];

  /// '# ' title, '## ' heading, '- ' bullet, anything else a paragraph (see migration 0050).
  static List<Widget> _formatted(BuildContext context, String text) {
    final out = <Widget>[];
    for (final raw in text.split('\n')) {
      final line = raw.trimRight();
      if (line.isEmpty) {
        out.add(const SizedBox(height: 8));
      } else if (line.startsWith('## ')) {
        out.add(Padding(padding: const EdgeInsets.only(top: 14, bottom: 4), child: Text(line.substring(3), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17, color: BrandColors.navy))));
      } else if (line.startsWith('# ')) {
        out.add(Text(line.substring(2), style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900)));
      } else if (line.startsWith('- ')) {
        out.add(Padding(
          padding: const EdgeInsetsDirectional.only(start: 6, top: 3),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('•  ', style: TextStyle(height: 1.7)),
            Expanded(child: Text(line.substring(2), style: const TextStyle(height: 1.7))),
          ]),
        ));
      } else {
        out.add(Text(line, style: const TextStyle(height: 1.7)));
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ar = context.isAr;
    final theme = Theme.of(context).textTheme;
    // the full policy is stored in the database (one text per language) so it can change without a new app release
    final stored = ref.watch(publicSettingsProvider).valueOrNull?['legal_privacy_${ar ? 'ar' : 'en'}'];
    final full = stored is String && stored.trim().isNotEmpty ? stored : null;
    final contact = Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: BrandColors.electric.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(14)),
      child: Row(children: [
        const Icon(Icons.support_agent_rounded, color: BrandColors.electric),
        const SizedBox(width: 10),
        Expanded(child: Text(ar ? 'أي سؤال؟ كلمنا: ${AppConfig.supportPhone}' : 'Any question? Call us: ${AppConfig.supportPhone}', style: const TextStyle(fontWeight: FontWeight.w700))),
      ]),
    );
    return Scaffold(
      appBar: AppBar(title: Text(context.tr('privacy'))),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(publicSettingsProvider);
          await ref.read(publicSettingsProvider.future);
        },
        child: ListView(physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.fromLTRB(16, 16, 16, 32), children: full != null
            ? [..._formatted(context, full), const SizedBox(height: 20), contact]
            : _summary(context, ar, theme, contact)),
      ),
    );
  }

  // shown when the full text is not available (offline, or before the database text exists)
  List<Widget> _summary(BuildContext context, bool ar, TextTheme theme, Widget contact) {
    return [
        Text(ar ? 'باختصار' : 'In short', style: theme.headlineSmall?.copyWith(fontWeight: FontWeight.w900)),
        const SizedBox(height: 2),
        Text(ar ? 'My Hatō · آخر تحديث $_updated' : 'My Hatō · Updated $_updated', style: theme.bodySmall?.copyWith(color: BrandColors.gray)),
        const SizedBox(height: 14),
        for (final c in _cards)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: BrandColors.border)),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(color: c.$2.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(13)),
                  child: Icon(c.$1, color: c.$2, size: 23),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(ar ? c.$3 : c.$5, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                    const SizedBox(height: 4),
                    Text(ar ? c.$4 : c.$6, style: const TextStyle(height: 1.6, color: BrandColors.gray)),
                  ]),
                ),
              ]),
            ),
          ),
        const SizedBox(height: 6),
        contact,
    ];
  }
}
