import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/appearance.dart';
import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/theme.dart';
import '../../shared/launch_animation.dart';
import '../../shared/states.dart';
import 'admin_repository.dart';

String _t(BuildContext c, String ar, String en) => c.isAr ? ar : en;

const _slots = ['primary', 'accent', 'background', 'success', 'danger'];
const _swatches = [
  '#0B2D5B', '#1D4ED8', '#00A3FF', '#0E9F9A', '#12B76A', '#84CC16', '#F79009', '#F04438',
  '#D92D20', '#E11D74', '#7C3AED', '#6D28D9', '#111827', '#475467', '#F8F9FA', '#FFFFFF', '#FFF7ED', '#ECFDF3',
];

Color _hex(String h) => Color(0xFF000000 | int.parse(h.substring(1), radix: 16));

/// Owner's "Appearance" page: five colours, the opening animation and the launcher icon, applied to every customer.
class AppearancePanel extends ConsumerStatefulWidget {
  const AppearancePanel({super.key});
  @override
  ConsumerState<AppearancePanel> createState() => _AppearancePanelState();
}

class _AppearancePanelState extends ConsumerState<AppearancePanel> {
  late Map<String, String> _palette;
  late String _anim;
  late String _icon;
  int _replay = 0;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final a = ref.read(appearanceProvider);
    _palette = {...AppPalette.defaults, ...a.palette};
    _anim = a.animation;
    _icon = a.icon;
  }

  String _slotName(BuildContext c, String k) => switch (k) {
        'primary' => _t(c, 'اللون الأساسي', 'Main colour'),
        'accent' => _t(c, 'لون التمييز', 'Accent'),
        'background' => _t(c, 'لون الخلفية', 'Background'),
        'success' => _t(c, 'أخضر النجاح', 'Success green'),
        _ => _t(c, 'أحمر التحذير', 'Warning red'),
      };

  String _slotHint(BuildContext c, String k) => switch (k) {
        'primary' => _t(c, 'العناوين والأزرار والشريط العلوي', 'Titles, buttons and top bar'),
        'accent' => _t(c, 'الروابط والتفاصيل المضيئة', 'Links and highlights'),
        'background' => _t(c, 'خلفية الشاشات', 'Screen background'),
        'success' => _t(c, 'تم / متوفر / تأكيد', 'Done, in stock, confirmed'),
        _ => _t(c, 'خطأ / إلغاء / نفد', 'Errors, cancel, sold out'),
      };

  Future<void> _pick(String slot) async {
    final ctl = TextEditingController(text: _palette[slot]);
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(ctx).viewInsets.bottom),
        child: StatefulBuilder(builder: (ctx, set) {
          final typed = ctl.text.toUpperCase();
          final valid = RegExp(r'^#[0-9A-F]{6}$').hasMatch(typed);
          return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_slotName(ctx, slot), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
            const SizedBox(height: 12),
            Wrap(spacing: 10, runSpacing: 10, children: [
              for (final h in _swatches)
                GestureDetector(
                  onTap: () => Navigator.pop(ctx, h),
                  child: Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(color: _hex(h), shape: BoxShape.circle, border: Border.all(color: BrandColors.border, width: 1.5)),
                    child: h == _palette[slot] ? Icon(Icons.check, size: 20, color: ThemeData.estimateBrightnessForColor(_hex(h)) == Brightness.dark ? Colors.white : Colors.black) : null,
                  ),
                ),
            ]),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: ctl,
                  textDirection: TextDirection.ltr,
                  maxLength: 7,
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[#0-9A-Fa-f]'))],
                  decoration: InputDecoration(labelText: _t(ctx, 'أو اكتب كود اللون', 'Or type a colour code'), hintText: '#00A3FF', counterText: ''),
                  onChanged: (_) => set(() {}),
                ),
              ),
              const SizedBox(width: 10),
              FilledButton(onPressed: valid ? () => Navigator.pop(ctx, typed) : null, child: Text(_t(ctx, 'تمام', 'OK'))),
            ]),
          ]);
        }),
      ),
    );
    if (picked != null) setState(() => _palette[slot] = picked.toUpperCase());
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ref.read(adminRepoProvider).setAppearance(_palette, _anim, _icon);
      await ref.read(appearanceProvider.notifier).refresh();
      if (mounted) showSnack(context, _t(context, 'اتطبّق. العملاء هيشوفوه في ثواني.', 'Applied. Customers will see it within seconds.'));
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(context, e), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = {for (final k in _slots) k: _hex(_palette[k]!)};
    final onPrimary = ThemeData.estimateBrightnessForColor(p['primary']!) == Brightness.dark ? Colors.white : Colors.black;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text(_t(context, 'اللي تغيّره هنا بيظهر لكل العملاء بعد ما تدوس «تطبيق».', 'What you change here reaches every customer after you tap Apply.'),
          style: const TextStyle(color: BrandColors.gray, fontSize: 13)),
      const SizedBox(height: 12),
      // live preview built from the draft colours
      Container(
        decoration: BoxDecoration(color: p['background'], borderRadius: BorderRadius.circular(18), border: Border.all(color: BrandColors.border)),
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(color: p['primary'], borderRadius: BorderRadius.circular(12)),
            child: Row(children: [
              Text('My Hatō', style: TextStyle(color: onPrimary, fontWeight: FontWeight.w900, fontSize: 16)),
              const Spacer(),
              Icon(Icons.shopping_bag_outlined, color: p['accent'], size: 20),
            ]),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: BrandColors.border)),
            child: Row(children: [
              Icon(Icons.headphones_rounded, size: 34, color: p['primary']),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_t(context, 'سماعة بلوتوث لاسلكية', 'Wireless Bluetooth headset'), style: TextStyle(fontWeight: FontWeight.w700, color: p['primary'])),
                  Text(_t(context, 'متوفر', 'In stock'), style: TextStyle(fontSize: 12, color: p['success'], fontWeight: FontWeight.w700)),
                ]),
              ),
              Text(_t(context, '١٬٢٥٠ ج.م', 'EGP 1,250'), style: TextStyle(fontWeight: FontWeight.w900, color: p['accent'])),
            ]),
          ),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: FilledButton(style: FilledButton.styleFrom(backgroundColor: p['primary'], foregroundColor: onPrimary), onPressed: () {}, child: Text(_t(context, 'أضف للسلة', 'Add to cart')))),
            const SizedBox(width: 8),
            Icon(Icons.error_outline, color: p['danger']),
            Text(_t(context, ' نفد', ' Sold out'), style: TextStyle(color: p['danger'], fontWeight: FontWeight.w700, fontSize: 12.5)),
          ]),
        ]),
      ),
      const SizedBox(height: 18),
      Text(_t(context, 'الألوان الخمسة', 'The five colours'), style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
      const SizedBox(height: 8),
      for (final k in _slots)
        Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            onTap: () => _pick(k),
            leading: Container(width: 38, height: 38, decoration: BoxDecoration(color: p[k], shape: BoxShape.circle, border: Border.all(color: BrandColors.border, width: 1.5))),
            title: Text(_slotName(context, k), style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text('${_slotHint(context, k)} · ${_palette[k]}', style: const TextStyle(fontSize: 12)),
            trailing: const Icon(Icons.edit_outlined, size: 18),
          ),
        ),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton.icon(
          onPressed: () => setState(() => _palette = {...AppPalette.defaults}),
          icon: const Icon(Icons.restart_alt_rounded, size: 18),
          label: Text(_t(context, 'رجّع الألوان الأصلية', 'Back to the original colours')),
        ),
      ),
      const Divider(height: 28),
      Text(_t(context, 'أيقونة التطبيق', 'App icon'), style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
      const SizedBox(height: 4),
      Text(_t(context, 'بتتغيّر على الشاشة الرئيسية عند العملاء أول ما يفتحوا التطبيق. بعض الموبايلات بتتأخر شوية، ومش بتتغيّر عند اللي ما فتحش التطبيق.',
          'It changes on each customer\'s home screen the next time they open the app. Some phones take a moment, and it will not change for someone who has not opened the app.'),
          style: const TextStyle(color: BrandColors.gray, fontSize: 12.5)),
      const SizedBox(height: 10),
      Row(children: [
        for (final i in appIcons)
          Expanded(
            child: GestureDetector(
              onTap: () => setState(() => _icon = i),
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 4),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: _icon == i ? BrandColors.electric : BrandColors.border, width: _icon == i ? 2.5 : 1),
                ),
                child: Column(children: [
                  ClipRRect(borderRadius: BorderRadius.circular(14), child: Image.asset(i == 'default' ? 'assets/brand/app_icon.png' : 'assets/brand/icon_$i.png', width: 60, height: 60, fit: BoxFit.cover)),
                  const SizedBox(height: 6),
                  Text(i == 'default' ? _t(context, 'الحالية', 'Current') : _t(context, 'شكل ${{'a': 'ا', 'b': 'ب', 'c': 'ج'}[i]}', 'Style ${i.toUpperCase()}'), style: TextStyle(fontSize: 12, fontWeight: _icon == i ? FontWeight.w900 : FontWeight.w500)),
                ]),
              ),
            ),
          ),
      ]),
      const Divider(height: 28),
      Text(_t(context, 'حركة فتح التطبيق', 'Opening animation'), style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
      const SizedBox(height: 4),
      Text(_t(context, 'بتتغيّر عند العملاء أول ما يقفلوا التطبيق ويفتحوه تاني.', 'It changes for customers the next time they close and reopen the app.'), style: const TextStyle(color: BrandColors.gray, fontSize: 12.5)),
      const SizedBox(height: 10),
      Container(
        height: 190,
        decoration: BoxDecoration(color: p['primary'], borderRadius: BorderRadius.circular(18)),
        child: Stack(children: [
          Center(child: LaunchAnimation(key: ValueKey('$_anim$_replay'), variant: _anim, scale: 0.8)),
          PositionedDirectional(
            top: 6,
            end: 6,
            child: IconButton(onPressed: () => setState(() => _replay++), icon: const Icon(Icons.replay_rounded, color: Colors.white), tooltip: _t(context, 'شغّل تاني', 'Replay')),
          ),
        ]),
      ),
      const SizedBox(height: 10),
      SegmentedButton<String>(
        showSelectedIcon: false,
        segments: [
          ButtonSegment(value: 'classic', label: Text(_t(context, 'كلاسيك', 'Classic'))),
          ButtonSegment(value: 'zoom', label: Text(_t(context, 'تكبير', 'Zoom'))),
          ButtonSegment(value: 'slide', label: Text(_t(context, 'انزلاق', 'Slide'))),
        ],
        selected: {_anim},
        onSelectionChanged: (s) => setState(() {
          _anim = s.first;
          _replay++;
        }),
      ),
      const SizedBox(height: 22),
      FilledButton.icon(
        onPressed: _saving ? null : _save,
        icon: _saving ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.check_rounded),
        label: Text(_t(context, 'تطبيق على كل العملاء', 'Apply to all customers')),
      ),
      const SizedBox(height: 24),
    ]);
  }
}
