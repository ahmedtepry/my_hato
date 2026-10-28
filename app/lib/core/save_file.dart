import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../shared/states.dart';
import 'l10n.dart';

const xlsxMime = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';

/// Gives the person a file: on the Windows team app it is saved in the Downloads folder and opened (the Windows
/// share sheet is not reliable); on phones it goes through the normal share sheet.
Future<void> deliverFile(BuildContext context, Uint8List bytes, String name, String mime) async {
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
    var dir = home == null ? Directory.systemTemp : Directory('$home${Platform.pathSeparator}Downloads');
    if (!await dir.exists()) dir = Directory.systemTemp;
    var path = '${dir.path}${Platform.pathSeparator}$name';
    if (await File(path).exists()) {
      final dot = name.lastIndexOf('.');
      final stamp = DateTime.now().millisecondsSinceEpoch;
      path = '${dir.path}${Platform.pathSeparator}${dot > 0 ? '${name.substring(0, dot)}-$stamp${name.substring(dot)}' : '$name-$stamp'}';
    }
    await File(path).writeAsBytes(bytes, flush: true);
    try {
      if (Platform.isWindows) {
        await Process.run('explorer.exe', [path]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [path]);
      } else {
        await Process.run('xdg-open', [path]);
      }
    } catch (_) {/* saved anyway */}
    if (context.mounted) {
      showSnack(context, context.isAr ? 'اتحفظ الملف في مجلد التنزيلات:\n$path' : 'Saved to your Downloads folder:\n$path');
    }
    return;
  }
  await Share.shareXFiles([XFile.fromData(bytes, name: name, mimeType: mime)], fileNameOverrides: [name]);
}
