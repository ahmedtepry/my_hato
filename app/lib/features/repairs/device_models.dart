import 'package:flutter/material.dart';

import '../../core/l10n.dart';

/// Phone models per brand, so the customer picks instead of typing. Anything not in the list can still be typed.
final Map<String, List<String>> kDeviceModels = {
  'Apple': [
    for (final m in ['5', '5c', '5s', '6', '6 Plus', '6s', '6s Plus', 'SE (2016)', '7', '7 Plus', '8', '8 Plus', 'X', 'XR', 'XS', 'XS Max', '11', '11 Pro', '11 Pro Max', 'SE (2020)', '12 mini', '12', '12 Pro', '12 Pro Max', '13 mini', '13', '13 Pro', '13 Pro Max', 'SE (2022)', '14', '14 Plus', '14 Pro', '14 Pro Max', '15', '15 Plus', '15 Pro', '15 Pro Max', '16e', '16', '16 Plus', '16 Pro', '16 Pro Max', '17', 'Air', '17 Pro', '17 Pro Max'])
      m == 'Air' ? 'iPhone Air' : 'iPhone $m',
  ],
  'Samsung': [
    for (final s in [6, 7, 8, 9, 10, 20, 21, 22, 23, 24, 25]) ...[
      if (s <= 7) 'Galaxy S$s' else if (s <= 9) ...['Galaxy S$s', 'Galaxy S$s+'] else if (s == 10) ...['Galaxy S10e', 'Galaxy S10', 'Galaxy S10+'] else ...['Galaxy S$s', 'Galaxy S$s+', 'Galaxy S$s Ultra'],
      if (s >= 20 && s <= 24) 'Galaxy S$s FE',
    ],
    'Galaxy S6 Edge', 'Galaxy S7 Edge', 'Galaxy Note 8', 'Galaxy Note 9', 'Galaxy Note 10', 'Galaxy Note 10+', 'Galaxy Note 20', 'Galaxy Note 20 Ultra',
    for (final a in ['01', '02', '03', '03 Core', '04', '04s', '05', '05s', '10', '11', '12', '13', '14', '15', '16', '20', '21s', '22', '23', '24', '25', '26', '30', '31', '32', '33', '34', '35', '36', '50', '51', '52', '53', '54', '55', '56', '70', '71', '72', '73']) 'Galaxy A$a',
    for (final m in ['11', '12', '13', '14', '15', '21', '22', '23', '31', '32', '33', '34', '51', '52', '53', '54', '55']) 'Galaxy M$m',
    'Galaxy Z Flip', 'Galaxy Z Flip 3', 'Galaxy Z Flip 4', 'Galaxy Z Flip 5', 'Galaxy Z Flip 6', 'Galaxy Z Flip 7',
    'Galaxy Z Fold', 'Galaxy Z Fold 2', 'Galaxy Z Fold 3', 'Galaxy Z Fold 4', 'Galaxy Z Fold 5', 'Galaxy Z Fold 6', 'Galaxy Z Fold 7',
    'Galaxy J2', 'Galaxy J5', 'Galaxy J7', 'Galaxy J7 Prime', 'Galaxy Tab A', 'Galaxy Tab S',
  ],
  'Xiaomi': [
    for (final r in ['Redmi 9', 'Redmi 9A', 'Redmi 9C', 'Redmi 10', 'Redmi 10A', 'Redmi 10C', 'Redmi 12', 'Redmi 12C', 'Redmi 13', 'Redmi 13C', 'Redmi 14C', 'Redmi A1', 'Redmi A2', 'Redmi A3', 'Redmi A5', 'Redmi Note 8', 'Redmi Note 8 Pro', 'Redmi Note 9', 'Redmi Note 9 Pro', 'Redmi Note 10', 'Redmi Note 10 Pro', 'Redmi Note 10S', 'Redmi Note 11', 'Redmi Note 11 Pro', 'Redmi Note 11S', 'Redmi Note 12', 'Redmi Note 12 Pro', 'Redmi Note 12 Pro+', 'Redmi Note 13', 'Redmi Note 13 Pro', 'Redmi Note 13 Pro+', 'Redmi Note 14', 'Redmi Note 14 Pro', 'Redmi Note 14 Pro+']) r,
    for (final p in ['Poco C40', 'Poco C55', 'Poco C65', 'Poco C75', 'Poco M4 Pro', 'Poco M5', 'Poco M6', 'Poco M6 Pro', 'Poco X3 Pro', 'Poco X4 Pro', 'Poco X5', 'Poco X5 Pro', 'Poco X6', 'Poco X6 Pro', 'Poco X7', 'Poco X7 Pro', 'Poco F3', 'Poco F4', 'Poco F5', 'Poco F6', 'Poco F7']) p,
    for (final m in ['Mi 9', 'Mi 10', 'Mi 11', 'Mi 11 Lite', 'Xiaomi 11T', 'Xiaomi 11T Pro', 'Xiaomi 12', 'Xiaomi 12T', 'Xiaomi 13', 'Xiaomi 13T', 'Xiaomi 14', 'Xiaomi 14T', 'Xiaomi 15', 'Xiaomi 15T']) m,
  ],
  'Oppo': [
    for (final m in ['A3s', 'A5', 'A5s', 'A9', 'A12', 'A15', 'A16', 'A17', 'A18', 'A31', 'A38', 'A53', 'A54', 'A55', 'A57', 'A58', 'A60', 'A74', 'A76', 'A77', 'A78', 'A79', 'A93', 'A94', 'A96']) 'Oppo $m',
    for (final m in ['Reno 2', 'Reno 3', 'Reno 4', 'Reno 5', 'Reno 6', 'Reno 7', 'Reno 8', 'Reno 10', 'Reno 11', 'Reno 12', 'Reno 13']) 'Oppo $m',
    for (final m in ['Find X2', 'Find X3', 'Find X5', 'Find X6', 'Find X7', 'Find X8', 'F11', 'F17']) 'Oppo $m',
  ],
  'Vivo': [
    for (final m in ['Y11', 'Y12', 'Y15', 'Y17', 'Y20', 'Y21', 'Y22', 'Y27', 'Y28', 'Y33s', 'Y36', 'Y53s', 'Y91', 'Y93', 'Y95', 'V15', 'V17', 'V19', 'V20', 'V21', 'V23', 'V25', 'V27', 'V29', 'V30', 'V40', 'V50', 'X60', 'X70', 'X80', 'X90', 'X100', 'X200', 'T1', 'T2', 'T3']) 'Vivo $m',
  ],
  'Huawei': [
    for (final m in ['P8', 'P9', 'P10', 'P20', 'P20 Lite', 'P20 Pro', 'P30', 'P30 Lite', 'P30 Pro', 'P40', 'P40 Lite', 'P40 Pro', 'P50', 'P50 Pro', 'P60 Pro', 'Mate 10', 'Mate 20', 'Mate 20 Pro', 'Mate 30', 'Mate 40 Pro', 'Mate 50', 'Mate 60 Pro', 'Nova 3', 'Nova 5T', 'Nova 7i', 'Nova 8i', 'Nova 9', 'Nova 10', 'Nova 11', 'Nova 12', 'Y5', 'Y6', 'Y7', 'Y7 Prime', 'Y9', 'Y9 Prime', 'Y9s', 'Honor 8X', 'Honor 9X', 'Honor X8', 'Honor X9', 'Honor 50', 'Honor 70', 'Honor 90', 'Honor Magic 5', 'Honor Magic 6']) m.startsWith('Honor') ? m : 'Huawei $m',
  ],
  'Realme': [
    for (final m in ['C2', 'C3', 'C11', 'C12', 'C15', 'C20', 'C21', 'C21Y', 'C25', 'C30', 'C31', 'C33', 'C35', 'C51', 'C53', 'C55', 'C61', 'C63', 'C65', '5', '6', '7', '8', '8 Pro', '9', '9 Pro', '10', '11', '12', '13', 'Narzo 30', 'Narzo 50', 'Narzo 60', 'GT 2 Pro', 'GT 5', 'GT 6']) m.startsWith('C') || RegExp(r'^\d').hasMatch(m) ? 'Realme $m' : 'Realme $m',
  ],
  'Infinix': [
    for (final m in ['Hot 8', 'Hot 9', 'Hot 10', 'Hot 10 Play', 'Hot 11', 'Hot 11S', 'Hot 12', 'Hot 12 Play', 'Hot 20', 'Hot 30', 'Hot 40', 'Hot 40 Pro', 'Hot 50', 'Note 7', 'Note 8', 'Note 10', 'Note 11', 'Note 12', 'Note 30', 'Note 40', 'Note 40 Pro', 'Smart 5', 'Smart 6', 'Smart 7', 'Smart 8', 'Smart 9', 'Zero 5G', 'Zero 20', 'Zero 30', 'Zero 40', 'Zero Ultra']) 'Infinix $m',
  ],
};

/// Model text field with a searchable suggestion list for the chosen brand. The customer can always type their own model.
class ModelPicker extends StatefulWidget {
  const ModelPicker({super.key, required this.controller, required this.brand, this.validator});
  final String? Function(String?)? validator;
  final TextEditingController controller;
  final TextEditingController brand;
  @override
  State<ModelPicker> createState() => _ModelPickerState();
}

class _ModelPickerState extends State<ModelPicker> {
  final _focus = FocusNode();
  bool _picked = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
    widget.controller.addListener(_rebuild);
    widget.brand.addListener(_rebuild);
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_rebuild);
    widget.brand.removeListener(_rebuild);
    _focus.dispose();
    super.dispose();
  }

  List<String> get _matches {
    final all = kDeviceModels[widget.brand.text.trim()] ?? const <String>[];
    final q = widget.controller.text.trim().toLowerCase();
    if (all.isEmpty) return const [];
    final words = q.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final r = all.where((m) {
      final l = m.toLowerCase();
      return words.every(l.contains);
    }).toList();
    return r.take(40).toList();
  }

  @override
  Widget build(BuildContext context) {
    final show = _focus.hasFocus && !_picked && _matches.isNotEmpty;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextFormField(
        controller: widget.controller,
        focusNode: _focus,
        validator: widget.validator,
        onChanged: (_) => _picked = false,
        decoration: InputDecoration(
          labelText: context.tr('device_model'),
          prefixIcon: const Icon(Icons.search),
          helperText: context.isAr ? 'اختار من القائمة أو اكتب موديل جهازك لو مش موجود' : 'Pick from the list, or type your model if it is not there',
        ),
      ),
      if (show)
        Container(
          margin: const EdgeInsets.only(top: 6),
          constraints: const BoxConstraints(maxHeight: 220),
          decoration: BoxDecoration(border: Border.all(color: Colors.black12), borderRadius: BorderRadius.circular(14), color: Theme.of(context).cardColor),
          child: ListView(shrinkWrap: true, padding: EdgeInsets.zero, children: [
            for (final m in _matches)
              ListTile(
                dense: true,
                title: Text(m, textDirection: TextDirection.ltr, textAlign: TextAlign.start),
                onTap: () {
                  _picked = true;
                  widget.controller.text = m;
                  _focus.unfocus();
                  setState(() {});
                },
              ),
          ]),
        ),
    ]);
  }
}
