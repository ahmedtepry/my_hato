import 'package:flutter/material.dart';

import '../core/l10n.dart';
import 'states.dart';

String _t(BuildContext c, String ar, String en) => c.isAr ? ar : en;

/// Tells the customer what a like earned. [res] is the answer of toggle_review_like / toggle_product_like.
/// The first rewarded like explains the whole deal once; later ones are a short note.
Future<void> showLikeReward(BuildContext context, Map<String, dynamic> res, {required bool review}) async {
  if (res['liked'] != true) return;
  final pts = (res['points'] as num?)?.toInt() ?? 0;
  final cap = (res['cap'] as num?)?.toInt() ?? 3;
  final per = (res['per'] as num?)?.toInt() ?? 5;
  final left = (res['remaining'] as num?)?.toInt() ?? 0;
  final what = review ? _t(context, 'تقييم', 'review') : _t(context, 'منتج', 'product');
  if (pts > 0 && res['first'] == true) {
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(_t(c, 'لايك محسوب! 🎉', 'Like counted! 🎉')),
        content: Text(_t(
            'كل لايك على $what بيجهّزلك $per نقاط، وإنت اللي بتستلمهم بإيدك من تاب «المهام» في صفحة المكافآت. لحد $cap في اليوم، ومرة واحدة لكل ${review ? 'تقييم' : 'منتج'}.',
            'Every $what you like prepares $per points, and you collect them yourself from the Missions tab in Rewards. Up to $cap a day, once per ${review ? 'review' : 'product'}.')),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: Text(_t(c, 'تمام', 'Got it')))],
      ),
    );
  } else if (pts > 0) {
    showSnack(context, _t(context, '+$pts نقاط جاهزة، استلمها من «المهام» (باقي $left النهارده)', '+$pts points ready, collect them in Missions ($left left today)'));
  } else if (left == 0) {
    showSnack(context, _t(context, 'وصلت للحد اليومي ($cap) للايكات اللي بتجيب نقاط. تعالى بكرة!', 'You reached today\'s limit ($cap) of likes that earn points. Come back tomorrow!'));
  }
}
