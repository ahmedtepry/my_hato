import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/theme.dart';
import '../../shared/barcode_scanner.dart';
import '../../shared/product_card.dart';
import '../../shared/states.dart';
import 'admin_repository.dart';

String _t(BuildContext c, String ar, String en) => c.isAr ? ar : en;

// =====================================================================================
// Receive stock by barcode: scan -> product -> how many arrived -> stock updated (loop)
// =====================================================================================

/// [onNewProduct] opens the product editor prefilled with an unknown barcode.
Future<void> receiveStockByBarcode(BuildContext context, WidgetRef ref, {required void Function(String sku) onNewProduct, VoidCallback? onChanged}) async {
  while (context.mounted) {
    final code = await scanBarcode(context);
    if (code == null || !context.mounted) return;
    final repo = ref.read(adminRepoProvider);
    Map<String, dynamic>? p;
    try {
      p = await repo.productBySku(code);
    } catch (e) {
      if (context.mounted) showSnack(context, friendlyError(context, e), error: true);
      return;
    }
    if (!context.mounted) return;
    if (p == null) {
      final add = await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          icon: const Icon(Icons.qr_code_2_rounded, size: 40, color: BrandColors.warning),
          title: Text(_t(context, 'الكود ده مش متسجل', 'Unknown barcode')),
          content: Directionality(textDirection: TextDirection.ltr, child: Text(code, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w800))),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: Text(context.tr('cancel'))),
            FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(_t(context, 'أضفه كمنتج جديد', 'Add as new product'))),
          ],
        ),
      );
      if (add == true) onNewProduct(code);
      return;
    }
    final again = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _ReceiveSheet(product: p!, onChanged: onChanged),
    );
    if (again != true) return;
  }
}

class _ReceiveSheet extends ConsumerStatefulWidget {
  const _ReceiveSheet({required this.product, this.onChanged});
  final Map<String, dynamic> product;
  final VoidCallback? onChanged;
  @override
  ConsumerState<_ReceiveSheet> createState() => _ReceiveSheetState();
}

class _ReceiveSheetState extends ConsumerState<_ReceiveSheet> {
  final _qty = TextEditingController(text: '1');
  bool _busy = false;

  int get _n => int.tryParse(_qty.text.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;

  @override
  void dispose() {
    _qty.dispose();
    super.dispose();
  }

  Future<void> _save({required bool scanNext}) async {
    final n = _n;
    if (n <= 0) return;
    setState(() => _busy = true);
    final p = widget.product;
    final current = (p['stock_quantity'] as num).toInt();
    try {
      await ref.read(adminRepoProvider).setStock(p['id'] as String, current, current + n, note: 'received stock (barcode)');
      widget.onChanged?.call();
      HapticFeedback.mediumImpact();
      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      final msg = _t(context, 'اتضاف $n — المخزون بقى ${current + n}', 'Added $n — stock is now ${current + n}');
      Navigator.of(context).pop(scanNext);
      messenger?.showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2), persist: false));
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(context, e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.product;
    final imgs = List<Map<String, dynamic>>.from(p['product_images'] as List? ?? const [])
      ..sort((a, b) => ((a['sort_order'] ?? 0) as num).compareTo((b['sort_order'] ?? 0) as num));
    final current = (p['stock_quantity'] as num).toInt();
    Widget step(IconData icon, int delta) => IconButton.filledTonal(
          onPressed: _busy ? null : () => setState(() => _qty.text = '${(_n + delta).clamp(1, 100000)}'),
          icon: Icon(icon),
        );
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(width: 64, height: 64, child: NetImage(path: imgs.isEmpty ? null : imgs.first['storage_path'] as String?, thumb: true)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text((context.isAr ? p['name_ar'] : p['name_en']) as String, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800)),
              Text('SKU ${p['sku']}', style: const TextStyle(color: BrandColors.gray, fontSize: 12)),
              Text(_t(context, 'في المخزن دلوقتي: $current', 'In stock now: $current'), style: const TextStyle(fontWeight: FontWeight.w700, color: BrandColors.electric)),
            ]),
          ),
        ]),
        const SizedBox(height: 18),
        Text(_t(context, 'الكمية اللي وصلت', 'Quantity received'), style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Row(children: [
          step(Icons.remove_rounded, -1),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: _qty,
              autofocus: true,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
              onChanged: (_) => setState(() {}),
            ),
          ),
          const SizedBox(width: 10),
          step(Icons.add_rounded, 1),
        ]),
        const SizedBox(height: 8),
        Wrap(spacing: 8, children: [
          for (final q in [5, 10, 20, 50]) ActionChip(label: Text('+$q'), onPressed: _busy ? null : () => setState(() => _qty.text = '${_n + q}')),
        ]),
        const SizedBox(height: 16),
        FilledButton.icon(
          icon: const Icon(Icons.qr_code_scanner_rounded),
          label: Text(_t(context, 'حفظ وامسح اللي بعده', 'Save & scan next')),
          onPressed: (_busy || _n <= 0) ? null : () => _save(scanNext: true),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: (_busy || _n <= 0) ? null : () => _save(scanNext: false),
          child: Text(_t(context, 'حفظ وخلاص', 'Save & finish')),
        ),
      ]),
    );
  }
}

// =====================================================================================
// Excel: export every product; import prices / stock from the same sheet
// =====================================================================================

const _hSku = 'SKU';
const _hNameAr = 'الاسم بالعربي';
const _hNameEn = 'الاسم بالإنجليزي';
const _hCategory = 'القسم';
const _hBrand = 'الماركة';
const _hModel = 'الموديل';
const _hPrice = 'السعر';
const _hCompare = 'السعر قبل الخصم';
const _hStock = 'الكمية';
const _hStatus = 'الحالة';

Future<void> exportProductsExcel(BuildContext context, WidgetRef ref) async {
  try {
    final rows = await ref.read(adminRepoProvider).allProductsForSheet();
    final excel = Excel.createExcel();
    final sheet = excel['المنتجات'];
    excel.setDefaultSheet('المنتجات');
    if (excel.sheets.containsKey('Sheet1')) excel.delete('Sheet1');
    sheet.appendRow([for (final h in [_hSku, _hNameAr, _hNameEn, _hCategory, _hBrand, _hModel, _hPrice, _hCompare, _hStock, _hStatus]) TextCellValue(h)]);
    for (final p in rows) {
      sheet.appendRow([
        TextCellValue('${p['sku']}'),
        TextCellValue('${p['name_ar'] ?? ''}'),
        TextCellValue('${p['name_en'] ?? ''}'),
        TextCellValue('${(p['categories'] as Map?)?['name_ar'] ?? ''}'),
        TextCellValue('${(p['brands'] as Map?)?['name_en'] ?? ''}'),
        TextCellValue('${p['model'] ?? ''}'),
        DoubleCellValue((p['price_minor'] as num) / 100),
        p['compare_at_price_minor'] == null ? TextCellValue('') : DoubleCellValue((p['compare_at_price_minor'] as num) / 100),
        IntCellValue((p['stock_quantity'] as num).toInt()),
        TextCellValue(p['status'] == 'published' ? 'ظاهر' : 'مخفي'),
      ]);
    }
    final bytes = Uint8List.fromList(excel.save()!);
    final now = DateTime.now();
    final name = 'MyHato-products-${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}.xlsx';
    await Share.shareXFiles([XFile.fromData(bytes, name: name, mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet')],
        fileNameOverrides: [name]);
  } catch (e) {
    if (context.mounted) showSnack(context, friendlyError(context, e), error: true);
  }
}

class _Change {
  _Change(this.product, {this.price, this.compare, this.clearCompare = false, this.stock});
  final Map<String, dynamic> product;
  final int? price; // minor units
  final int? compare;
  final bool clearCompare;
  final int? stock;
}

int? _money(String? s) {
  if (s == null) return null;
  final t = s.replaceAll(RegExp(r'[^0-9.]'), '');
  if (t.isEmpty) return null;
  final v = double.tryParse(t);
  return v == null ? null : (v * 100).round();
}

int? _int(String? s) {
  if (s == null) return null;
  final t = s.replaceAll(RegExp(r'[^0-9]'), '');
  return t.isEmpty ? null : int.tryParse(t);
}

String? _cell(Data? d) {
  final v = d?.value;
  if (v == null) return null;
  return switch (v) {
    TextCellValue() => v.value.text,
    IntCellValue() => '${v.value}',
    DoubleCellValue() => '${v.value}',
    _ => v.toString(),
  }
      ?.trim();
}

Future<void> importProductsExcel(BuildContext context, WidgetRef ref, {VoidCallback? onDone}) async {
  try {
    final pick = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['xlsx'], withData: true);
    final bytes = pick?.files.single.bytes;
    if (bytes == null || !context.mounted) return;
    final excel = Excel.decodeBytes(bytes);
    final table = excel.tables.values.firstWhere((t) => t.maxRows > 1, orElse: () => throw Exception('EMPTY_SHEET'));
    final header = [for (final c in table.rows.first) _cell(c) ?? ''];
    int col(String h) => header.indexWhere((x) => x.trim() == h);
    final iSku = col(_hSku), iPrice = col(_hPrice), iCompare = col(_hCompare), iStock = col(_hStock);
    if (iSku < 0) throw Exception('SKU_COLUMN_MISSING');

    final current = {for (final p in await ref.read(adminRepoProvider).allProductsForSheet()) p['sku'] as String: p};
    final changes = <_Change>[];
    final unknown = <String>[];
    for (final row in table.rows.skip(1)) {
      String? at(int i) => (i < 0 || i >= row.length) ? null : _cell(row[i]);
      final sku = at(iSku);
      if (sku == null || sku.isEmpty) continue;
      final p = current[sku];
      if (p == null) {
        unknown.add(sku);
        continue;
      }
      final price = _money(at(iPrice));
      final compareRaw = at(iCompare);
      final compare = _money(compareRaw);
      final stock = _int(at(iStock));
      final c = _Change(
        p,
        price: (price != null && price > 0 && price != p['price_minor']) ? price : null,
        compare: (compare != null && compare != p['compare_at_price_minor']) ? compare : null,
        clearCompare: iCompare >= 0 && (compareRaw == null || compareRaw.isEmpty) && p['compare_at_price_minor'] != null,
        stock: (stock != null && stock != p['stock_quantity']) ? stock : null,
      );
      if (c.price != null || c.compare != null || c.clearCompare || c.stock != null) changes.add(c);
    }
    if (!context.mounted) return;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _ImportPreview(changes: changes, unknown: unknown, onDone: onDone),
    );
  } catch (e) {
    if (!context.mounted) return;
    final msg = e.toString();
    showSnack(
      context,
      msg.contains('SKU_COLUMN_MISSING')
          ? _t(context, 'الشيت لازم يكون فيه عمود اسمه SKU — نزّل الشيت من "تصدير Excel" وعدّل عليه.', 'The sheet needs an "SKU" column — export first and edit that file.')
          : msg.contains('EMPTY_SHEET')
              ? _t(context, 'الشيت فاضي.', 'The sheet is empty.')
              : friendlyError(context, e),
      error: true,
    );
  }
}

class _ImportPreview extends ConsumerStatefulWidget {
  const _ImportPreview({required this.changes, required this.unknown, this.onDone});
  final List<_Change> changes;
  final List<String> unknown;
  final VoidCallback? onDone;
  @override
  ConsumerState<_ImportPreview> createState() => _ImportPreviewState();
}

class _ImportPreviewState extends ConsumerState<_ImportPreview> {
  bool _busy = false;
  int _done = 0;

  String _egp(int minor) => '${(minor / 100).toStringAsFixed(minor % 100 == 0 ? 0 : 2)}';

  Future<void> _apply() async {
    setState(() => _busy = true);
    final repo = ref.read(adminRepoProvider);
    var failed = 0;
    for (final c in widget.changes) {
      try {
        final fields = <String, dynamic>{
          if (c.price != null) 'price_minor': c.price,
          if (c.compare != null) 'compare_at_price_minor': (c.compare! > (c.price ?? (c.product['price_minor'] as num).toInt())) ? c.compare : null,
          if (c.clearCompare) 'compare_at_price_minor': null,
        };
        if (fields.isNotEmpty) await repo.updateProduct(c.product['id'] as String, fields);
        if (c.stock != null) {
          await repo.setStock(c.product['id'] as String, (c.product['stock_quantity'] as num).toInt(), c.stock!, note: 'excel import');
        }
      } catch (_) {
        failed++;
      }
      if (mounted) setState(() => _done++);
    }
    widget.onDone?.call();
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final msg = failed == 0
        ? _t(context, 'اتحدّث ${widget.changes.length} منتج ✅', '${widget.changes.length} products updated ✅')
        : _t(context, 'اتحدّث ${widget.changes.length - failed} — وفشل $failed', '${widget.changes.length - failed} updated, $failed failed');
    Navigator.of(context).pop();
    messenger?.showSnackBar(SnackBar(content: Text(msg), persist: false, duration: const Duration(seconds: 3)));
  }

  @override
  Widget build(BuildContext context) {
    final ch = widget.changes;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.8,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_t(context, 'مراجعة قبل التحديث', 'Review before updating'), style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              Text(
                _t(context, '${ch.length} منتج هيتغيّر${widget.unknown.isEmpty ? '' : ' • ${widget.unknown.length} كود مش موجود هيتجاهل'}',
                    '${ch.length} products will change${widget.unknown.isEmpty ? '' : ' • ${widget.unknown.length} unknown SKUs skipped'}'),
                style: const TextStyle(color: BrandColors.gray),
              ),
            ]),
          ),
          Expanded(
            child: ch.isEmpty
                ? Center(child: Text(_t(context, 'مفيش أي تغيير عن الموجود في المتجر.', 'Nothing differs from the store.')))
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: ch.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final c = ch[i];
                      final p = c.product;
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text((context.isAr ? p['name_ar'] : p['name_en']) as String, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                        subtitle: Text([
                          if (c.price != null) '${_t(context, 'السعر', 'Price')}: ${_egp((p['price_minor'] as num).toInt())} ← ${_egp(c.price!)}',
                          if (c.compare != null) '${_t(context, 'قبل الخصم', 'Was')}: ${_egp(c.compare!)}',
                          if (c.clearCompare) _t(context, 'إلغاء السعر قبل الخصم', 'Remove was-price'),
                          if (c.stock != null) '${_t(context, 'الكمية', 'Stock')}: ${p['stock_quantity']} ← ${c.stock}',
                        ].join('   •   ')),
                        leading: Text('${p['sku']}', style: const TextStyle(fontSize: 11, color: BrandColors.gray)),
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton.icon(
              icon: _busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white))
                  : const Icon(Icons.check_rounded),
              label: Text(_busy ? '$_done / ${ch.length}' : _t(context, 'طبّق التغييرات', 'Apply changes')),
              onPressed: (_busy || ch.isEmpty) ? null : _apply,
            ),
          ),
        ]),
      ),
    );
  }
}
