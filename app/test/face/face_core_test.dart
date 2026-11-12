// Checks the Dart face engine against the numpy reference (tool/face/face_ref.py) on real pictures.
// Needs: FACE_DIR (models/ and ref/ from face_ref.py) and ORT_DLL (onnxruntime.dll). Skipped when they are missing,
// so the normal test run is unaffected; the face-check workflow sets them on a Windows runner.
@TestOn('windows')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:myhato/features/admin/face/face_core.dart';

void main() {
  final dir = Platform.environment['FACE_DIR'];
  final dll = Platform.environment['ORT_DLL'];
  final ready = dir != null && dll != null && File('$dir/ref/ref.json').existsSync();

  test('face engine matches the reference', () {
    final core = FaceCore.load(
      dll!,
      File('$dir/models/face_detection_yunet_2023mar.onnx').readAsBytesSync(),
      File('$dir/models/face_recognition_sface_2021dec.onnx').readAsBytesSync(),
    );
    final ref = jsonDecode(File('$dir/ref/ref.json').readAsStringSync()) as Map<String, dynamic>;
    final prints = <String, List<double>>{};
    for (final e in ref.entries) {
      final r = e.value as Map<String, dynamic>;
      final sw = Stopwatch()..start();
      final res = core.analyze(File('$dir/ref/${e.key}').readAsBytesSync());
      sw.stop();
      expect(res, isNotNull, reason: '${e.key}: no face found');
      final box = (r['box'] as List).cast<num>();
      final want = (r['print'] as List).cast<num>().map((x) => x.toDouble()).toList();
      var cos = 0.0;
      for (var i = 0; i < 128; i++) {
        cos += want[i] * res!.print[i];
      }
      // ignore: avoid_print
      print('${e.key}: faces ${res!.faces}/${r['faces']} box ${[res.box.x, res.box.y, res.box.w, res.box.h].map((v) => v.toStringAsFixed(1))} '
          'vs ${box.map((v) => v.toStringAsFixed(1))} cos ${cos.toStringAsFixed(5)} yaw ${res.box.yaw.toStringAsFixed(3)} ${sw.elapsedMilliseconds} ms');
      expect(res.faces, r['faces']);
      expect((res.box.x - box[0]).abs() < 1.5 && (res.box.w - box[2]).abs() < 1.5, isTrue, reason: '${e.key}: box differs');
      expect(cos, greaterThan(0.995), reason: '${e.key}: print differs from the reference');
      prints[e.key] = res.print.map((x) => x.toDouble()).toList();
    }
    double sim(String a, String b) => List.generate(128, (i) => prints[a]![i] * prints[b]![i]).fold(0.0, (s, x) => s + x);
    // same person (flip / dark) far above different people
    final same = [sim('lena.png', 'lena_flip.png'), sim('lena.png', 'lena_dark.png'), sim('Tom_Hanks_54745.png', 'Tom_Hanks_54745_flip.png')];
    final diff = [sim('lena.png', 'messi5.png'), sim('lena.png', 'Tom_Hanks_54745.png'), sim('messi5.png', 'Tom_Hanks_54745.png')];
    // ignore: avoid_print
    print('same ${same.map((v) => v.toStringAsFixed(3))} different ${diff.map((v) => v.toStringAsFixed(3))}');
    expect(same.reduce(math.min), greaterThan(0.6));
    expect(diff.reduce(math.max), lessThan(0.4));
    core.dispose();
  }, skip: ready ? false : 'set FACE_DIR and ORT_DLL to run');
}
