import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/l10n.dart';
import '../../core/theme.dart';
import '../../shared/states.dart';

/// What the customer bought and until when each product is under warranty (read from the product's warranty text).
final myWarrantiesProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final r = await Supabase.instance.client.rpc('my_warranties');
  return List<Map<String, dynamic>>.from(r as List);
});

class WarrantiesScreen extends ConsumerWidget {
  const WarrantiesScreen({super.key});

  String _d(BuildContext c, String iso) {
    final t = DateTime.parse(iso).toLocal();
    return '${t.day}/${t.month}/${t.year}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ar = context.isAr;
    final async = ref.watch(myWarrantiesProvider);
    return Scaffold(
      appBar: AppBar(title: Text(ar ? 'ضماناتي' : 'My warranties')),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorView(error: e, onRetry: () => ref.invalidate(myWarrantiesProvider)),
        data: (rows) {
          if (rows.isEmpty) {
            return EmptyState(
              icon: Icons.verified_user_outlined,
              title: ar ? 'مفيش ضمانات لسه' : 'No warranties yet',
              body: ar ? 'بعد ما تستلم طلب عليه ضمان هتلاقيه هنا مع تاريخ انتهائه.' : 'After you receive an order with a warranty it appears here with its end date.',
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: rows.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (_, i) {
              final w = rows[i];
              final ends = w['ends_at'] as String?;
              final left = ends == null ? null : DateTime.parse(ends).difference(DateTime.now()).inDays;
              final active = left == null ? null : left >= 0;
              final txt = ar ? (w['warranty_ar'] ?? w['warranty_en']) : (w['warranty_en'] ?? w['warranty_ar']);
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Icon(Icons.verified_user_rounded, color: active == false ? BrandColors.gray : const Color(0xFF14A671)),
                      const SizedBox(width: 10),
                      Expanded(child: Text(ar ? '${w['name_ar']}' : '${w['name_en']}', style: const TextStyle(fontWeight: FontWeight.w800))),
                    ]),
                    const SizedBox(height: 8),
                    Text('${ar ? 'الطلب' : 'Order'}: ${w['reference']}  •  ${ar ? 'استلمته' : 'Received'}: ${_d(context, w['delivered_at'] as String)}', style: const TextStyle(fontSize: 12.5, color: BrandColors.gray)),
                    const SizedBox(height: 6),
                    if (ends != null)
                      Text(
                        active == true
                            ? (ar ? 'الضمان ساري لحد ${_d(context, ends)} (باقي $left يوم)' : 'Under warranty until ${_d(context, ends)} ($left days left)')
                            : (ar ? 'الضمان خلص في ${_d(context, ends)}' : 'Warranty ended on ${_d(context, ends)}'),
                        style: TextStyle(fontWeight: FontWeight.w700, color: active == true ? const Color(0xFF14A671) : BrandColors.gray),
                      )
                    else
                      Text(ar ? 'مدة الضمان: $txt' : 'Warranty: $txt', style: const TextStyle(fontWeight: FontWeight.w700)),
                    if (ends != null) Text(ar ? 'الشروط: $txt (التاريخ تقريبي من يوم الاستلام)' : 'Terms: $txt (date counted from delivery)', style: const TextStyle(fontSize: 12, color: BrandColors.gray)),
                  ]),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
