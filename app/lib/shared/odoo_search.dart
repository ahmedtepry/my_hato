// Odoo-style search: one box holding search words, filter "facets", a group-by and saved favourites.
//   final s = OdooSearchState(); ... OdooSearchBar(state: s, filters: [...], groups: [...], onChanged: () => setState(() {}), storeKey: 'purchases')
//   final rows = s.apply(list, textOf: (r) => '...');   // filtered
//   final groups = s.group(rows, groups);               // [(title, rows)] or one unnamed group
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/l10n.dart';
import '../core/theme.dart';

class OdooFilter {
  const OdooFilter(this.id, this.ar, this.en, this.test, {this.exclusiveWith = ''});
  final String id, ar, en;
  final bool Function(Map<String, dynamic> row) test;

  /// Filters sharing the same non-empty tag are alternatives (ANY of them), like Odoo's filter groups; different tags are combined (ALL).
  final String exclusiveWith;
}

class OdooGroup {
  const OdooGroup(this.id, this.ar, this.en, this.key);
  final String id, ar, en;
  final String Function(Map<String, dynamic> row) key;
}

class OdooSearchState {
  final List<String> words = [];
  final Set<String> filters = {};
  String? groupBy;

  bool get isEmpty => words.isEmpty && filters.isEmpty && groupBy == null;
  void clear() {
    words.clear();
    filters.clear();
    groupBy = null;
  }

  Map<String, dynamic> toJson() => {'w': words, 'f': filters.toList(), 'g': groupBy};
  void load(Map<String, dynamic> j) {
    clear();
    words.addAll([for (final e in (j['w'] as List? ?? const [])) '$e']);
    filters.addAll([for (final e in (j['f'] as List? ?? const [])) '$e']);
    groupBy = j['g'] as String?;
  }

  /// Every word must be found somewhere in the row's text (any order), then the filters apply.
  List<Map<String, dynamic>> apply(List<Map<String, dynamic>> rows, {required String Function(Map<String, dynamic>) textOf, List<OdooFilter> defs = const []}) {
    final byTag = <String, List<OdooFilter>>{};
    for (final d in defs) {
      if (filters.contains(d.id)) byTag.putIfAbsent(d.exclusiveWith.isEmpty ? d.id : d.exclusiveWith, () => []).add(d);
    }
    return [
      for (final r in rows)
        if (words.every((w) => textOf(r).toLowerCase().contains(w.toLowerCase())) && byTag.values.every((alts) => alts.any((f) => f.test(r)))) r,
    ];
  }

  List<(String, List<Map<String, dynamic>>)> group(List<Map<String, dynamic>> rows, List<OdooGroup> defs) {
    final g = defs.where((d) => d.id == groupBy).firstOrNull;
    if (g == null) return [('', rows)];
    final m = <String, List<Map<String, dynamic>>>{};
    for (final r in rows) {
      m.putIfAbsent(g.key(r), () => []).add(r);
    }
    final keys = m.keys.toList()..sort();
    return [for (final k in keys) (k, m[k]!)];
  }
}

class OdooSearchBar extends StatefulWidget {
  const OdooSearchBar({super.key, required this.state, required this.filters, required this.groups, required this.onChanged, required this.storeKey, this.hintAr = 'ابحث...', this.hintEn = 'Search...'});
  final OdooSearchState state;
  final List<OdooFilter> filters;
  final List<OdooGroup> groups;
  final VoidCallback onChanged;
  final String storeKey, hintAr, hintEn;
  @override
  State<OdooSearchBar> createState() => _OdooSearchBarState();
}

class _OdooSearchBarState extends State<OdooSearchBar> {
  final _c = TextEditingController();
  final _node = FocusNode();
  List<Map<String, dynamic>> _favs = [];

  @override
  void initState() {
    super.initState();
    _loadFavs();
  }

  @override
  void dispose() {
    _c.dispose();
    _node.dispose();
    super.dispose();
  }

  Future<void> _loadFavs() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString('odoo_favs_${widget.storeKey}');
      if (raw != null && mounted) setState(() => _favs = [for (final e in jsonDecode(raw) as List) Map<String, dynamic>.from(e as Map)]);
    } catch (_) {}
  }

  Future<void> _saveFavs() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('odoo_favs_${widget.storeKey}', jsonEncode(_favs));
    } catch (_) {}
  }

  void _changed() {
    widget.onChanged();
    if (mounted) setState(() {});
  }

  void _commitWord() {
    final w = _c.text.trim();
    if (w.isEmpty) return;
    widget.state.words.add(w);
    _c.clear();
    _changed();
  }

  String _t(String ar, String en) => context.isAr ? ar : en;

  Future<void> _saveCurrent() async {
    final name = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_t('حفظ البحث الحالي', 'Save current search')),
        content: TextField(controller: name, autofocus: true, maxLength: 40, decoration: InputDecoration(labelText: _t('اسم المفضلة', 'Favourite name'))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(_t('إلغاء', 'Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(_t('حفظ', 'Save'))),
        ],
      ),
    );
    final n = name.text.trim();
    name.dispose();
    if (ok == true && n.isNotEmpty) {
      _favs.removeWhere((f) => f['name'] == n);
      _favs.add({'name': n, ...widget.state.toJson()});
      if (_favs.length > 12) _favs.removeAt(0);
      await _saveFavs();
      if (mounted) setState(() {});
    }
  }

  Future<void> _openMenu() async {
    final s = widget.state;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        Widget head(String t) => Padding(padding: const EdgeInsets.fromLTRB(4, 10, 4, 4), child: Text(t, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: BrandColors.gray)));
        return Dialog(
          alignment: Alignment.topCenter,
          insetPadding: const EdgeInsets.fromLTRB(16, 90, 16, 16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640, maxHeight: 460),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(14),
              child: Wrap(spacing: 24, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.start, children: [
                SizedBox(width: 190, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  head(_t('🔍 فلاتر', '🔍 Filters')),
                  for (final f in widget.filters)
                    CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      value: s.filters.contains(f.id),
                      title: Text(_t(f.ar, f.en), style: const TextStyle(fontSize: 13)),
                      onChanged: (v) {
                        v == true ? s.filters.add(f.id) : s.filters.remove(f.id);
                        set(() {});
                        _changed();
                      },
                    ),
                ])),
                if (widget.groups.isNotEmpty)
                  SizedBox(width: 190, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    head(_t('🗂️ تجميع حسب', '🗂️ Group by')),
                    for (final g in widget.groups)
                      RadioListTile<String>(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        value: g.id,
                        groupValue: s.groupBy,
                        title: Text(_t(g.ar, g.en), style: const TextStyle(fontSize: 13)),
                        onChanged: (v) {
                          s.groupBy = v;
                          set(() {});
                          _changed();
                        },
                        toggleable: true,
                      ),
                  ])),
                SizedBox(width: 190, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  head(_t('⭐ المفضلة', '⭐ Favourites')),
                  for (final f in _favs)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text('${f['name']}', style: const TextStyle(fontSize: 13)),
                      onTap: () {
                        s.load(f);
                        _changed();
                        Navigator.pop(ctx);
                      },
                      trailing: IconButton(
                        icon: const Icon(Icons.close_rounded, size: 16),
                        onPressed: () async {
                          _favs.remove(f);
                          await _saveFavs();
                          set(() {});
                        },
                      ),
                    ),
                  TextButton.icon(
                    onPressed: s.isEmpty
                        ? null
                        : () async {
                            Navigator.pop(ctx);
                            await _saveCurrent();
                          },
                    icon: const Icon(Icons.star_border_rounded, size: 18),
                    label: Text(_t('احفظ البحث الحالي', 'Save current search')),
                  ),
                ])),
              ]),
            ),
          ),
        );
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    InputChip facet(String text, Color c, VoidCallback onDelete) => InputChip(
          label: Text(text, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
          backgroundColor: c.withValues(alpha: .12),
          side: BorderSide(color: c.withValues(alpha: .5)),
          visualDensity: VisualDensity.compact,
          onDeleted: onDelete,
        );
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: panelColor(context), borderRadius: BorderRadius.circular(14), border: Border.all(color: _node.hasFocus ? BrandColors.electric : BrandColors.border)),
      child: Row(children: [
        const Icon(Icons.search_rounded, color: BrandColors.gray, size: 20),
        const SizedBox(width: 6),
        Expanded(
          child: Wrap(spacing: 6, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
            for (final w in s.words.toList()) facet('🔎 $w', BrandColors.electric, () { s.words.remove(w); _changed(); }),
            for (final f in widget.filters)
              if (s.filters.contains(f.id)) facet(_t(f.ar, f.en), const Color(0xFF7F56D9), () { s.filters.remove(f.id); _changed(); }),
            if (s.groupBy != null)
              facet('${_t('تجميع', 'Group')}: ${_t(widget.groups.firstWhere((g) => g.id == s.groupBy).ar, widget.groups.firstWhere((g) => g.id == s.groupBy).en)}', const Color(0xFF12B76A), () { s.groupBy = null; _changed(); }),
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 120, maxWidth: 260),
              child: TextField(
                controller: _c,
                focusNode: _node,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) {
                  _commitWord();
                  _node.requestFocus();
                },
                onChanged: (v) {
                  if (v.endsWith(' ') && v.trim().isNotEmpty) _commitWord();
                },
                onTap: () => setState(() {}),
                decoration: InputDecoration(border: InputBorder.none, isDense: true, hintText: s.isEmpty ? _t(widget.hintAr, widget.hintEn) : '', contentPadding: const EdgeInsets.symmetric(vertical: 10)),
              ),
            ),
          ]),
        ),
        if (!s.isEmpty) IconButton(tooltip: _t('مسح الكل', 'Clear all'), icon: const Icon(Icons.close_rounded, size: 18), onPressed: () { s.clear(); _c.clear(); _changed(); }),
        IconButton(tooltip: _t('فلاتر وتجميع ومفضلة', 'Filters, group by, favourites'), icon: const Icon(Icons.arrow_drop_down_rounded), onPressed: _openMenu),
      ]),
    );
  }
}
