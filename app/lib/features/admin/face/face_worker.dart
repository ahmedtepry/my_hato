// Runs the face engine in a background isolate, so the camera and the scan animation never stutter.
// The models and onnxruntime.dll are only in the Windows team build; everywhere else [FaceWorker.instance] says "not available".
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'face_core.dart';

/// What the engine saw in one camera picture.
class FaceScan {
  FaceScan(this.print, this.yaw, this.faces, this.sizeRatio, this.score);
  final List<double> print;
  final double yaw;
  final int faces;

  /// face width / picture width (too small = too far from the camera)
  final double sizeRatio;
  final double score;
}

class FaceUnavailable implements Exception {
  FaceUnavailable(this.reason);
  final String reason;
  @override
  String toString() => 'FaceUnavailable: $reason';
}

class FaceWorker {
  FaceWorker._(this._send, this._iso);
  final SendPort _send;
  final Isolate _iso;
  final _pending = <int, Completer<Object?>>{};
  var _next = 0;

  static Future<FaceWorker>? _instance;

  /// Starts once, then reused. Throws [FaceUnavailable] off Windows or when the build has no models.
  static Future<FaceWorker> get instance => _instance ??= _start().catchError((Object e) {
        _instance = null;
        throw e is FaceUnavailable ? e : FaceUnavailable('$e');
      });

  static Future<FaceWorker> _start() async {
    if (kIsWeb || !Platform.isWindows) throw FaceUnavailable('windows only');
    final dll = '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}onnxruntime.dll';
    if (!File(dll).existsSync()) throw FaceUnavailable('onnxruntime.dll missing');
    final ByteData det, rec;
    try {
      det = await rootBundle.load('assets/face/face_detection_yunet_2023mar.onnx');
      rec = await rootBundle.load('assets/face/face_recognition_sface_2021dec.onnx');
    } catch (_) {
      throw FaceUnavailable('models missing');
    }
    final rx = ReceivePort();
    final iso = await Isolate.spawn(_main, [
      rx.sendPort,
      dll,
      TransferableTypedData.fromList([det.buffer.asUint8List(det.offsetInBytes, det.lengthInBytes)]),
      TransferableTypedData.fromList([rec.buffer.asUint8List(rec.offsetInBytes, rec.lengthInBytes)]),
    ]);
    final first = Completer<Object?>();
    late FaceWorker w;
    rx.listen((m) {
      if (!first.isCompleted) {
        first.complete(m);
        return;
      }
      final l = m as List;
      w._pending.remove(l[0] as int)?.complete(l[1]);
    });
    final hello = await first.future.timeout(const Duration(seconds: 30));
    if (hello is String) {
      iso.kill();
      throw FaceUnavailable(hello);
    }
    w = FaceWorker._(hello as SendPort, iso);
    return w;
  }

  /// Analyzes one encoded picture (jpg/png/bmp). Null when there is no face.
  Future<FaceScan?> analyze(Uint8List picture) async {
    final id = _next++;
    final c = Completer<Object?>();
    _pending[id] = c;
    _send.send([id, TransferableTypedData.fromList([picture])]);
    final r = await c.future.timeout(const Duration(seconds: 20));
    if (r is String) throw Exception(r);
    if (r == null) return null;
    final m = r as Map;
    return FaceScan((m['print'] as List).cast<double>(), m['yaw'] as double, m['faces'] as int, m['size'] as double, m['score'] as double);
  }

  void dispose() {
    _iso.kill(priority: Isolate.immediate);
    _instance = null;
  }

  static void _main(List<Object?> a) {
    final out = a[0] as SendPort;
    final FaceCore core;
    try {
      core = FaceCore.load(a[1] as String, (a[2] as TransferableTypedData).materialize().asUint8List(),
          (a[3] as TransferableTypedData).materialize().asUint8List());
    } catch (e) {
      out.send('engine failed to start: $e');
      return;
    }
    final rx = ReceivePort();
    out.send(rx.sendPort);
    rx.listen((m) {
      final l = m as List;
      final id = l[0] as int;
      try {
        final r = core.analyze((l[1] as TransferableTypedData).materialize().asUint8List());
        out.send([
          id,
          r == null
              ? null
              : {
                  'print': [for (final v in r.print) v.toDouble()],
                  'yaw': r.box.yaw,
                  'faces': r.faces,
                  'size': r.box.w / r.imageW,
                  'score': r.box.score,
                },
        ]);
      } catch (e) {
        out.send([id, 'analyze failed: $e']);
      }
    });
  }
}
