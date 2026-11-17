// Runs the face engine in a background isolate, so the camera and the scan animation never stutter.
// The models and onnxruntime.dll are only in the Windows team build; everywhere else [FaceWorker.instance] says "not available".
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
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
    final det = await _model('face_detection_yunet_2023mar.onnx', '8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4');
    final rec = await _model('face_recognition_sface_2021dec.onnx', '0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79');
    final rx = ReceivePort();
    final iso = await Isolate.spawn(_main, [
      rx.sendPort,
      dll,
      TransferableTypedData.fromList([det]),
      TransferableTypedData.fromList([rec]),
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

  // GitHub Releases first (free, no download limit), the Supabase copy only if GitHub cannot be reached
  static const _modelBases = [
    'https://github.com/ahmedtepry/my_hato/releases/download/face-models',
    'https://efdomvgypdkpqubkkjwm.supabase.co/storage/v1/object/public/app-updates/face',
  ];

  /// A model file: from the app's assets when the build carries it (the small detector), otherwise downloaded once
  /// from the update store into %LOCALAPPDATA%\MyHato\face (the 38 MB recognizer; installers over 50 MB cannot be
  /// published). The SHA-256 is checked every time, so a damaged or swapped file is never used.
  static Future<Uint8List> _model(String name, String sha) async {
    try {
      final b = await rootBundle.load('assets/face/$name');
      return b.buffer.asUint8List(b.offsetInBytes, b.lengthInBytes);
    } catch (_) {}
    final base = Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path;
    final dir = Directory('$base${Platform.pathSeparator}MyHato${Platform.pathSeparator}face');
    final file = File('${dir.path}${Platform.pathSeparator}$name');
    if (file.existsSync()) {
      final bytes = await file.readAsBytes();
      if (crypto.sha256.convert(bytes).toString() == sha) return bytes;
    }
    Object? last;
    for (final base in _modelBases) {
      try {
        final bytes = await _fetch('$base/$name');
        if (crypto.sha256.convert(bytes).toString() != sha) throw FaceUnavailable('model file damaged');
        await dir.create(recursive: true);
        await file.writeAsBytes(bytes, flush: true);
        return bytes;
      } catch (e) {
        last = e;
      }
    }
    throw last is FaceUnavailable ? last : FaceUnavailable('model download failed: $last');
  }

  static Future<Uint8List> _fetch(String url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final req = await client.getUrl(Uri.parse(url));
      final res = await req.close().timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) throw FaceUnavailable('model download failed (${res.statusCode})');
      final parts = <List<int>>[];
      var total = 0;
      await for (final chunk in res.timeout(const Duration(seconds: 90))) {
        parts.add(chunk);
        total += chunk.length;
      }
      final bytes = Uint8List(total);
      var at = 0;
      for (final c in parts) {
        bytes.setRange(at, at + c.length, c);
        at += c.length;
      }
      return bytes;
    } finally {
      client.close(force: true);
    }
  }

  /// Analyzes one encoded picture (jpg/png/bmp). Null when there is no face.
  Future<FaceScan?> analyze(Uint8List picture) => _ask([TransferableTypedData.fromList([picture])]);

  /// Analyzes raw RGBA pixels (a snapshot of the camera preview). Null when there is no face.
  Future<FaceScan?> analyzeRgba(Uint8List rgba, int width, int height) => _ask([TransferableTypedData.fromList([rgba]), width, height]);

  Future<FaceScan?> _ask(List<Object> payload) async {
    final id = _next++;
    final c = Completer<Object?>();
    _pending[id] = c;
    _send.send([id, ...payload]);
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
        final bytes = (l[1] as TransferableTypedData).materialize().asUint8List();
        final FaceResult? r;
        if (l.length >= 4) {
          // raw RGBA from the preview snapshot
          final w = l[2] as int, h = l[3] as int;
          final rgb = Float32List(w * h * 3);
          for (var i = 0, j = 0; i + 3 < bytes.length && j < rgb.length; i += 4, j += 3) {
            rgb[j] = bytes[i].toDouble();
            rgb[j + 1] = bytes[i + 1].toDouble();
            rgb[j + 2] = bytes[i + 2].toDouble();
          }
          r = core.analyzeRgb(rgb, w, h);
        } else {
          r = core.analyze(bytes);
        }
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
