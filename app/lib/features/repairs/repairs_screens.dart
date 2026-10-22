import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/money.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../shared/states.dart';
import '../auth/auth_repository.dart';
import '../orders/orders_repository.dart';
import '../orders/orders_screens.dart';
import '../profile/profile_repository.dart';
import 'repairs_repository.dart';

Color repairStatusColor(String s) => switch (s) {
      'delivered' || 'repair_completed' || 'ready_for_pickup' => BrandColors.success,
      'cancelled' || 'unrepairable' => BrandColors.error,
      'awaiting_approval' || 'waiting_for_parts' => BrandColors.warning,
      _ => BrandColors.electric,
    };

String repairLabel(BuildContext context, Map<String, Map<String, dynamic>>? labels, String status) =>
    labels?[status] == null ? status : context.pick(labels![status]!, 'label');

// ---------------------------------------------------------------- request form
class RepairRequestScreen extends ConsumerStatefulWidget {
  const RepairRequestScreen({super.key});
  @override
  ConsumerState<RepairRequestScreen> createState() => _RepairRequestScreenState();
}

class _RepairRequestScreenState extends ConsumerState<RepairRequestScreen> {
  final _form = GlobalKey<FormState>();
  final _brand = TextEditingController();
  final _model = TextEditingController();
  final _imei = TextEditingController();
  final _problem = TextEditingController();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _photos = <XFile>[];
  bool _pickup = true;
  String? _addressId;
  String? _branchId;
  DateTime? _when;
  bool _callback = false;
  bool _busy = false;
  final _key = const Uuid().v4();
  static const _brands = ['Apple', 'Samsung', 'Xiaomi', 'Oppo', 'Vivo', 'Huawei', 'Realme', 'Infinix', 'Other'];

  @override
  void initState() {
    super.initState();
    final p = ref.read(profileProvider).valueOrNull;
    _name.text = (p?['full_name'] as String?) ?? '';
    _phone.text = (p?['phone'] as String?) ?? '';
  }

  @override
  void dispose() {
    for (final c in [_brand, _model, _imei, _problem, _name, _phone]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _addPhoto() async {
    if (_photos.length >= 6) return;
    final x = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 70, maxWidth: 1600);
    if (x != null) setState(() => _photos.add(x));
  }

  Future<void> _pickTime() async {
    final now = DateTime.now();
    final d = await showDatePicker(context: context, firstDate: now, lastDate: now.add(const Duration(days: 30)), initialDate: now.add(const Duration(days: 1)));
    if (d == null || !mounted) return;
    final t = await showTimePicker(context: context, initialTime: const TimeOfDay(hour: 12, minute: 0));
    if (t == null) return;
    setState(() => _when = DateTime(d.year, d.month, d.day, t.hour, t.minute));
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    if (_pickup && _addressId == null) {
      showSnack(context, context.tr('err_invalid_address'), error: true);
      return;
    }
    if (!_pickup && _branchId == null) {
      showSnack(context, context.tr('err_invalid_branch'), error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      final repo = ref.read(repairsRepoProvider);
      final res = await repo.submit(
        idempotencyKey: _key,
        brand: _brand.text,
        model: _model.text,
        imei: _imei.text,
        problem: _problem.text,
        contactName: _name.text,
        contactPhone: _phone.text.replaceAll(' ', ''),
        pickupAddressId: _pickup ? _addressId : null,
        branchId: _pickup ? null : _branchId,
        preferredPickupAt: _callback ? null : _when,
        callback: _callback,
      );
      final id = res['repair_id'] as String;
      for (var i = 0; i < _photos.length; i++) {
        final x = _photos[i];
        try {
          await repo.uploadPhoto(id, await x.readAsBytes(), x.name.split('.').last, i);
        } catch (_) {/* request already saved; a failed photo must not lose it */}
      }
      ref.invalidate(myRepairsProvider);
      if (!mounted) return;
      context.go(Uri(path: '/repair-confirmed', queryParameters: {'id': id, 'ref': res['reference'] as String}).toString());
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final addresses = ref.watch(addressesProvider).valueOrNull ?? const [];
    final branches = ref.watch(branchesProvider).valueOrNull ?? const [];
    return Scaffold(
      appBar: AppBar(title: Text(context.tr('repair_request')), actions: [
        TextButton(onPressed: () => context.push('/repairs/lookup'), child: Text(context.tr('track_repair'))),
      ]),
      body: Form(
        key: _form,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          TextFormField(
            controller: _brand,
            decoration: InputDecoration(labelText: context.tr('device_brand'), prefixIcon: const Icon(Icons.phone_android)),
            validator: (v) => (v == null || v.trim().length < 2) ? context.tr('required') : null,
          ),
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final b in _brands)
              ActionChip(label: Text(b), onPressed: () => setState(() => _brand.text = b)),
          ]),
          const SizedBox(height: 12),
          TextFormField(
            controller: _model,
            decoration: InputDecoration(labelText: context.tr('device_model')),
            validator: (v) => (v == null || v.trim().isEmpty) ? context.tr('required') : null,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _imei,
            textDirection: TextDirection.ltr,
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9\-]')), LengthLimitingTextInputFormatter(30)],
            decoration: InputDecoration(labelText: context.tr('imei_optional')),
            validator: (v) => (v != null && v.isNotEmpty && v.length < 5) ? context.tr('invalid') : null,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _problem,
            maxLines: 4,
            maxLength: 2000,
            decoration: InputDecoration(labelText: context.tr('problem'), alignLabelWithHint: true),
            validator: (v) => (v == null || v.trim().length < 5) ? context.tr('required') : null,
          ),
          Text(context.tr('photos'), style: const TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (var i = 0; i < _photos.length; i++)
              Chip(label: Text('📷 ${i + 1}'), onDeleted: () => setState(() => _photos.removeAt(i))),
            if (_photos.length < 6) ActionChip(avatar: const Icon(Icons.add_a_photo_outlined, size: 18), label: Text(context.tr('add_photo')), onPressed: _addPhoto),
          ]),
          const SizedBox(height: 20),
          SegmentedButton<bool>(
            segments: [
              ButtonSegment(value: true, icon: const Icon(Icons.delivery_dining_outlined), label: Text(context.tr('pickup_from_me'))),
              ButtonSegment(value: false, icon: const Icon(Icons.storefront_outlined), label: Text(context.tr('drop_at_branch'))),
            ],
            selected: {_pickup},
            onSelectionChanged: (s) => setState(() => _pickup = s.first),
          ),
          const SizedBox(height: 12),
          if (_pickup) ...[
            for (final a in addresses)
              Card(
                child: RadioListTile<String>(
                  value: a['id'] as String,
                  groupValue: _addressId,
                  onChanged: (v) => setState(() => _addressId = v),
                  title: Text('${a['label'] ?? a['recipient_name']}'),
                  subtitle: Text('${a['governorate']} — ${a['city']} — ${a['street']}'),
                ),
              ),
            OutlinedButton.icon(
              icon: const Icon(Icons.add_location_alt_outlined),
              label: Text(context.tr('add_address')),
              onPressed: () async {
                await context.push('/account/addresses/new');
                ref.invalidate(addressesProvider);
              },
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(context.tr('callback')),
              value: _callback,
              onChanged: (v) => setState(() => _callback = v),
            ),
            if (!_callback)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.schedule_rounded),
                title: Text(context.tr('preferred_time')),
                subtitle: Text(_when == null ? '—' : fmtDate(context, _when!.toUtc().toIso8601String())),
                onTap: _pickTime,
              ),
          ] else
            for (final b in branches)
              Card(
                child: RadioListTile<String>(
                  value: b['id'] as String,
                  groupValue: _branchId,
                  onChanged: (v) => setState(() => _branchId = v),
                  title: Text(context.pick(b, 'name')),
                  subtitle: Text(context.pick(b, 'address')),
                ),
              ),
          const SizedBox(height: 20),
          Text(context.tr('contact_info'), style: const TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          TextFormField(
            controller: _name,
            decoration: InputDecoration(labelText: context.tr('full_name')),
            validator: (v) => (v == null || v.trim().length < 2) ? context.tr('required') : null,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            textDirection: TextDirection.ltr,
            decoration: InputDecoration(labelText: context.tr('phone'), hintText: '+2010xxxxxxxx'),
            validator: (v) => RegExp(r'^\+?[0-9]{8,15}$').hasMatch((v ?? '').replaceAll(' ', '')) ? null : context.tr('invalid'),
          ),
          const SizedBox(height: 24),
          FilledButton(onPressed: _busy ? null : _submit, child: _busy ? const CircularProgressIndicator(color: Colors.white) : Text(context.tr('submit_repair'))),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------- list
class MyRepairsList extends ConsumerWidget {
  const MyRepairsList({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(myRepairsProvider);
    final labels = ref.watch(repairLabelsProvider).valueOrNull;
    return data.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(myRepairsProvider)),
      data: (list) => list.isEmpty
          ? EmptyState(icon: Icons.build_outlined, title: context.tr('no_repairs'), action: context.tr('request_repair'), onAction: () => context.push('/repairs/new'))
          : RefreshIndicator(
              onRefresh: () async => ref.invalidate(myRepairsProvider),
              child: ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: list.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (_, i) {
                  final r = list[i];
                  final st = r['status'] as String;
                  return Card(
                    child: ListTile(
                      contentPadding: const EdgeInsets.all(12),
                      leading: const CircleAvatar(backgroundColor: BrandColors.navy, child: Icon(Icons.build_rounded, color: BrandColors.electric)),
                      title: Text(r['reference'] as String, style: const TextStyle(fontWeight: FontWeight.w800)),
                      subtitle: Text('${r['device_brand']} ${r['device_model']}\n${fmtDate(context, r['updated_at'] as String)}'),
                      isThreeLine: true,
                      trailing: StatusChip(label: repairLabel(context, labels, st), color: repairStatusColor(st)),
                      onTap: () => context.push('/repairs/${r['id']}'),
                    ),
                  );
                },
              ),
            ),
    );
  }
}

// ---------------------------------------------------------------- details
class RepairDetailsScreen extends ConsumerStatefulWidget {
  const RepairDetailsScreen({super.key, required this.id});
  final String id;
  @override
  ConsumerState<RepairDetailsScreen> createState() => _RepairDetailsScreenState();
}

class _RepairDetailsScreenState extends ConsumerState<RepairDetailsScreen> {
  RealtimeChannel? _channel;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final db = ref.read(supabaseProvider);
    void refresh(_) {
      ref.invalidate(repairProvider(widget.id));
      ref.invalidate(myRepairsProvider);
    }

    _channel = db
        .channel('repair:${widget.id}')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'repair_status_history',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'repair_id', value: widget.id),
          callback: refresh,
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'repair_quotes',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'repair_id', value: widget.id),
          callback: refresh,
        )
        .subscribe();
  }

  @override
  void dispose() {
    if (_channel != null) ref.read(supabaseProvider).removeChannel(_channel!);
    super.dispose();
  }

  Future<void> _respond(Map<String, dynamic> quote, bool approve) async {
    final amount = formatEgp((quote['amount_minor'] as num).toInt(), context.lang);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(context.tr('quote_title')),
        content: Text(approve ? context.tr('approve_confirm', {'amount': amount}) : context.tr('reject_confirm')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(context.tr('cancel'))),
          FilledButton(
            style: approve ? null : FilledButton.styleFrom(backgroundColor: BrandColors.error),
            onPressed: () => Navigator.pop(c, true),
            child: Text(approve ? context.tr('approve') : context.tr('reject')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await ref.read(repairsRepoProvider).respondToQuote(quote['id'] as String, approve);
      ref.invalidate(repairProvider(widget.id));
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(repairProvider(widget.id));
    final labels = ref.watch(repairLabelsProvider).valueOrNull;
    final lang = context.lang;
    return Scaffold(
      appBar: AppBar(leading: const BackOrHomeButton(), title: Text(context.tr('repair_request'))),
      bottomNavigationBar: const BackHomeBar(),
      body: data.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(repairProvider(widget.id))),
        data: (r) {
          final st = r['status'] as String;
          final history = List<Map<String, dynamic>>.from(r['history'] as List);
          final quotes = List<Map<String, dynamic>>.from(r['quotes'] as List);
          final pending = quotes.where((q) => q['status'] == 'pending').firstOrNull;
          final photos = List<String>.from(r['photo_urls'] as List);
          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(repairProvider(widget.id)),
            child: ListView(padding: const EdgeInsets.all(16), children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(context.tr('repair_ref'), style: const TextStyle(color: BrandColors.gray)),
                    SelectableText(r['reference'] as String, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 22)),
                    const SizedBox(height: 8),
                    Text('${r['device_brand']} ${r['device_model']}', style: const TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 12),
                    Text(context.tr('current_status'), style: const TextStyle(color: BrandColors.gray)),
                    const SizedBox(height: 4),
                    StatusChip(label: repairLabel(context, labels, st), color: repairStatusColor(st)),
                    if (labels?[st] != null) ...[
                      const SizedBox(height: 8),
                      Text(context.pick(labels![st]!, 'message')),
                    ],
                  ]),
                ),
              ),
              if (pending != null && st == 'awaiting_approval') ...[
                const SizedBox(height: 12),
                Card(
                  color: BrandColors.warning.withOpacity(0.08),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(context.tr('quote_title'), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                      const SizedBox(height: 8),
                      Text(formatEgp((pending['amount_minor'] as num).toInt(), lang),
                          style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 28, color: BrandColors.navy)),
                      if ((pending['description'] as String?)?.isNotEmpty ?? false) Text(pending['description'] as String),
                      if ((r['diagnosis'] as String?)?.isNotEmpty ?? false) ...[
                        const SizedBox(height: 8),
                        Text('${context.tr('diagnosis')}: ${r['diagnosis']}'),
                      ],
                      const SizedBox(height: 16),
                      Row(children: [
                        Expanded(child: OutlinedButton(onPressed: _busy ? null : () => _respond(pending, false), child: Text(context.tr('reject')))),
                        const SizedBox(width: 12),
                        Expanded(child: FilledButton(onPressed: _busy ? null : () => _respond(pending, true), child: Text(context.tr('approve')))),
                      ]),
                    ]),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(children: [
                    _kv(context.tr('problem'), r['problem_description'] as String),
                    if (r['diagnosis'] != null) _kv(context.tr('diagnosis'), r['diagnosis'] as String),
                    if (r['estimated_cost_minor'] != null) _kv(context.tr('estimated_cost'), formatEgp((r['estimated_cost_minor'] as num).toInt(), lang)),
                    if (r['approved_cost_minor'] != null) _kv(context.tr('approved_cost'), formatEgp((r['approved_cost_minor'] as num).toInt(), lang)),
                    if (r['expected_completion_at'] != null) _kv(context.tr('expected_completion'), fmtDate(context, r['expected_completion_at'] as String)),
                    if (r['customer_notes'] != null) _kv(context.tr('notes_for_you'), r['customer_notes'] as String),
                    if (r['warranty_terms'] != null) _kv(context.tr('warranty'), r['warranty_terms'] as String),
                  ]),
                ),
              ),
              if (photos.isNotEmpty) ...[
                const SizedBox(height: 12),
                SizedBox(
                  height: 90,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: photos.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (_, i) => ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.network(photos[i], width: 90, height: 90, fit: BoxFit.cover)),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Text(context.tr('timeline'), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              const SizedBox(height: 8),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Timeline(entries: [
                    for (final h in history)
                      TimelineEntry(
                        title: repairLabel(context, labels, h['to_status'] as String),
                        body: lang == 'ar' ? h['customer_message_ar'] as String? : h['customer_message_en'] as String?,
                        subtitle: fmtDate(context, h['created_at'] as String),
                      ),
                  ]),
                ),
              ),
            ]),
          );
        },
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 130, child: Text(k, style: const TextStyle(color: BrandColors.gray))),
          Expanded(child: Text(v, style: const TextStyle(fontWeight: FontWeight.w600))),
        ]),
      );
}

// ---------------------------------------------------------------- guest lookup
class RepairLookupScreen extends ConsumerStatefulWidget {
  const RepairLookupScreen({super.key});
  @override
  ConsumerState<RepairLookupScreen> createState() => _RepairLookupScreenState();
}

class _RepairLookupScreenState extends ConsumerState<RepairLookupScreen> {
  final _form = GlobalKey<FormState>();
  final _ref = TextEditingController();
  final _phone = TextEditingController();
  bool _busy = false;
  bool _notFound = false;
  Map<String, dynamic>? _result;

  @override
  void dispose() {
    _ref.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _lookup() async {
    if (!_form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _notFound = false;
      _result = null;
    });
    try {
      final r = await ref.read(repairsRepoProvider).guestLookup(_ref.text, _phone.text);
      if (mounted) setState(() => r == null ? _notFound = true : _result = r);
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final signedIn = ref.watch(currentUserProvider) != null;
    final labels = ref.watch(repairLabelsProvider).valueOrNull;
    return Scaffold(
      appBar: AppBar(title: Text(context.tr('lookup_title'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (signedIn)
          Card(
            child: ListTile(
              leading: const Icon(Icons.list_alt_rounded, color: BrandColors.electric),
              title: Text(context.tr('repairs')),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.go('/orders?tab=1'),
            ),
          ),
        const SizedBox(height: 12),
        Text(context.tr('lookup_body'), style: const TextStyle(color: BrandColors.gray, height: 1.6)),
        const SizedBox(height: 16),
        Form(
          key: _form,
          child: Column(children: [
            TextFormField(
              controller: _ref,
              textDirection: TextDirection.ltr,
              textCapitalization: TextCapitalization.characters,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: context.tr('repair_ref'),
                hintText: context.tr('lookup_hint'),
                prefixIcon: const Icon(Icons.confirmation_number_outlined),
              ),
              validator: (v) => RegExp(r'\d').hasMatch(v ?? '') ? null : context.tr('required'),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              textDirection: TextDirection.ltr,
              textInputAction: TextInputAction.done,
              onFieldSubmitted: (_) => _lookup(),
              decoration: InputDecoration(
                labelText: context.tr('lookup_phone'),
                hintText: '01XXXXXXXXX',
                prefixIcon: const Icon(Icons.phone_iphone_rounded),
              ),
              validator: (v) => normalizeEgyptMobile(v ?? '') == null ? context.tr('invalid_phone') : null,
            ),
          ]),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          icon: _busy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white))
              : const Icon(Icons.search_rounded),
          label: Text(context.tr('lookup_btn')),
          onPressed: _busy ? null : _lookup,
        ),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          child: _notFound
              ? Container(
                  key: const ValueKey('nf'),
                  margin: const EdgeInsets.only(top: 16),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: const Color(0xFFFFFAEB), borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFFFEDF89))),
                  child: Text(context.tr('lookup_not_found'), style: const TextStyle(color: Color(0xFF93370D), height: 1.6)),
                )
              : const SizedBox.shrink(key: ValueKey('none')),
        ),
        if (_result != null) ...[
          const SizedBox(height: 20),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(_result!['reference'] as String, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 20)),
                Text(_result!['device'] as String? ?? ''),
                const SizedBox(height: 8),
                StatusChip(label: context.pick(_result!, 'label'), color: repairStatusColor(_result!['status'] as String)),
                if (_result!['estimated_cost_minor'] != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text('${context.tr('estimated_cost')}: ${formatEgp((_result!['estimated_cost_minor'] as num).toInt(), context.lang)}'),
                  ),
                const Divider(height: 24),
                Timeline(entries: [
                  for (final h in List<Map<String, dynamic>>.from(_result!['timeline'] as List? ?? const []))
                    TimelineEntry(
                      title: repairLabel(context, labels, h['status'] as String),
                      body: context.isAr ? h['message_ar'] as String? : h['message_en'] as String?,
                      subtitle: fmtDate(context, h['at'] as String),
                    ),
                ]),
              ]),
            ),
          ),
        ],
      ]),
    );
  }
}
