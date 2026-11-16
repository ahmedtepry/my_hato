// The face engine: find the face (YuNet), straighten it, turn it into a 128-number face print (SFace).
// Pure Dart + the ONNX Runtime binding, so it runs inside a background isolate and in plain `dart test`.
// Same maths as the reference in tool/face/pipe.py (checked against OpenCV's own YuNet/SFace).
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'ort_ffi.dart';

/// The model name stored with each print. A new model must get a new name (prints of different models never match).
export 'face_model_id.dart';

class FaceBox {
  FaceBox(this.score, this.x, this.y, this.w, this.h, this.kps);
  final double score, x, y, w, h;

  /// 5 landmarks in image pixels: right eye, left eye, nose tip, right mouth corner, left mouth corner (as seen in the picture: x grows to the right)
  final List<math.Point<double>> kps;

  /// How much the head is turned: nose offset from the eye midpoint, divided by the eye distance (about 0 when looking straight).
  double get yaw {
    final mid = (kps[0].x + kps[1].x) / 2;
    final d = (kps[1].x - kps[0].x).abs();
    return d < 1 ? 0 : (kps[2].x - mid) / d;
  }

  Map<String, Object> toMap() => {
        'score': score,
        'x': x,
        'y': y,
        'w': w,
        'h': h,
        'kps': [for (final p in kps) p.x, for (final p in kps) p.y],
      };
}

class FaceResult {
  FaceResult(this.box, this.print, this.imageW, this.imageH, this.faces);
  final FaceBox box;
  final Float32List print;
  final int imageW, imageH;

  /// how many faces were in the picture (more than one: the caller may refuse)
  final int faces;
}

class FaceCore {
  FaceCore._(this._ort, this._det, this._rec);
  final Ort _ort;
  final OrtSession _det, _rec;

  static FaceCore load(String dllPath, Uint8List detector, Uint8List recognizer) {
    final ort = Ort.open(dllPath);
    return FaceCore._(ort, ort.session(detector), ort.session(recognizer));
  }

  void dispose() {
    _det.dispose();
    _rec.dispose();
    _ort.dispose();
  }

  /// Decodes a camera picture (jpg/png/bmp) and returns the biggest face with its print, or null when there is none.
  FaceResult? analyze(Uint8List encoded, {double minScore = 0.8}) {
    final pic = img.decodeImage(encoded);
    if (pic == null) return null;
    final rgb = toRgb(pic);
    return analyzeRgb(rgb, pic.width, pic.height, minScore: minScore);
  }

  FaceResult? analyzeRgb(Float32List rgb, int w, int h, {double minScore = 0.8}) {
    final faces = detect(rgb, w, h, minScore: minScore);
    if (faces.isEmpty) return null;
    faces.sort((a, b) => (b.w * b.h).compareTo(a.w * a.h));
    final f = faces.first;
    return FaceResult(f, embed(rgb, w, h, f), w, h, faces.length);
  }

  // ------------------------------------------------------------------------------------------------ detection
  static const _size = 640;

  List<FaceBox> detect(Float32List rgb, int w, int h, {double minScore = 0.8}) {
    final s = _size / math.max(w, h);
    final nw = (w * s).round(), nh = (h * s).round();
    // BGR, CHW, values 0..255, letterboxed into the top-left corner
    final blob = Float32List(3 * _size * _size);
    const plane = _size * _size;
    final px = Float32List(3);
    for (var y = 0; y < nh; y++) {
      final sy = (y + 0.5) / s - 0.5;
      for (var x = 0; x < nw; x++) {
        bilinear(rgb, w, h, (x + 0.5) / s - 0.5, sy, px);
        final i = y * _size + x;
        blob[i] = px[2];
        blob[plane + i] = px[1];
        blob[2 * plane + i] = px[0];
      }
    }
    const strides = [8, 16, 32];
    final names = <String>[];
    final sizes = <int>[];
    for (final st in strides) {
      final n = (_size ~/ st) * (_size ~/ st);
      names.addAll(['cls_$st', 'obj_$st', 'bbox_$st', 'kps_$st']);
      sizes.addAll([n, n, n * 4, n * 10]);
    }
    final out = _det.run('input', blob, const [1, 3, _size, _size], names, sizes);
    final found = <FaceBox>[];
    for (var k = 0; k < strides.length; k++) {
      final st = strides[k];
      final cols = _size ~/ st;
      final cls = out[k * 4], obj = out[k * 4 + 1], bb = out[k * 4 + 2], kp = out[k * 4 + 3];
      for (var i = 0; i < cls.length; i++) {
        final sc = math.sqrt(cls[i].clamp(0.0, 1.0) * obj[i].clamp(0.0, 1.0));
        if (sc <= minScore) continue;
        final r = i ~/ cols, c = i % cols;
        final cx = (c + bb[i * 4]) * st, cy = (r + bb[i * 4 + 1]) * st;
        final bw = math.exp(bb[i * 4 + 2]) * st, bh = math.exp(bb[i * 4 + 3]) * st;
        found.add(FaceBox(sc, (cx - bw / 2) / s, (cy - bh / 2) / s, bw / s, bh / s, [
          for (var n = 0; n < 5; n++) math.Point((kp[i * 10 + 2 * n] + c) * st / s, (kp[i * 10 + 2 * n + 1] + r) * st / s),
        ]));
      }
    }
    found.sort((a, b) => b.score.compareTo(a.score));
    final keep = <FaceBox>[];
    for (final f in found) {
      if (keep.every((g) => _iou(f, g) < 0.3)) keep.add(f);
    }
    return keep;
  }

  static double _iou(FaceBox a, FaceBox b) {
    final x1 = math.max(a.x, b.x), y1 = math.max(a.y, b.y);
    final x2 = math.min(a.x + a.w, b.x + b.w), y2 = math.min(a.y + a.h, b.y + b.h);
    final inter = math.max(0.0, x2 - x1) * math.max(0.0, y2 - y1);
    return inter / (a.w * a.h + b.w * b.h - inter);
  }

  // ------------------------------------------------------------------------------------------------ recognition
  static const _dst = [38.2946, 51.6963, 73.5318, 51.5014, 56.0252, 71.7366, 41.5493, 92.3655, 70.7299, 92.2041];

  /// 128 numbers, length 1 (cosine similarity = dot product)
  Float32List embed(Float32List rgb, int w, int h, FaceBox f) {
    final m = similarity(f.kps, _dst); // [a, -b, tx; b, a, ty]
    final a = m[0], b = m[1], tx = m[2], ty = m[3];
    final det = a * a + b * b;
    // inverse of [[a,-b],[b,a]] is [[a,b],[-b,a]] / det
    final crop = Float32List(3 * 112 * 112);
    const plane = 112 * 112;
    final px = Float32List(3);
    for (var y = 0; y < 112; y++) {
      for (var x = 0; x < 112; x++) {
        final dx = x - tx, dy = y - ty;
        final sx = (a * dx + b * dy) / det, sy = (-b * dx + a * dy) / det;
        bilinear(rgb, w, h, sx, sy, px);
        final i = y * 112 + x;
        crop[i] = px[0];
        crop[plane + i] = px[1];
        crop[2 * plane + i] = px[2];
      }
    }
    final v = _rec.run('data', crop, const [1, 3, 112, 112], const ['fc1'], const [128])[0];
    var n = 0.0;
    for (final e in v) {
      n += e * e;
    }
    n = math.sqrt(n);
    for (var i = 0; i < v.length; i++) {
      v[i] = v[i] / n;
    }
    return v;
  }

  /// Least-squares similarity (rotation + uniform scale + shift, no mirror) taking the 5 points onto [dst]
  /// (Umeyama). Returns [a, b, tx, ty] for x' = a*x - b*y + tx, y' = b*x + a*y + ty.
  static List<double> similarity(List<math.Point<double>> src, List<double> dst) {
    const n = 5;
    var msx = 0.0, msy = 0.0, mdx = 0.0, mdy = 0.0;
    for (var i = 0; i < n; i++) {
      msx += src[i].x;
      msy += src[i].y;
      mdx += dst[2 * i];
      mdy += dst[2 * i + 1];
    }
    msx /= n;
    msy /= n;
    mdx /= n;
    mdy /= n;
    var sxx = 0.0, sxy = 0.0, var0 = 0.0;
    for (var i = 0; i < n; i++) {
      final px = src[i].x - msx, py = src[i].y - msy;
      final qx = dst[2 * i] - mdx, qy = dst[2 * i + 1] - mdy;
      sxx += px * qx + py * qy; // dot
      sxy += px * qy - py * qx; // cross
      var0 += px * px + py * py;
    }
    final a = sxx / var0, b = sxy / var0;
    return [a, b, mdx - (a * msx - b * msy), mdy - (b * msx + a * msy)];
  }

  // ------------------------------------------------------------------------------------------------ pixels
  /// RGB floats, row-major, 3 per pixel
  static Float32List toRgb(img.Image pic) {
    final out = Float32List(pic.width * pic.height * 3);
    var i = 0;
    for (final p in pic) {
      out[i++] = p.r.toDouble();
      out[i++] = p.g.toDouble();
      out[i++] = p.b.toDouble();
    }
    return out;
  }

  /// Bilinear sample at (x, y); outside the picture counts as black (same as the reference).
  static void bilinear(Float32List rgb, int w, int h, double x, double y, Float32List out) {
    final x0 = x.floor(), y0 = y.floor();
    final fx = x - x0, fy = y - y0;
    out[0] = 0;
    out[1] = 0;
    out[2] = 0;
    void add(int xx, int yy, double wgt) {
      if (wgt == 0 || xx < 0 || yy < 0 || xx >= w || yy >= h) return;
      final i = (yy * w + xx) * 3;
      out[0] += rgb[i] * wgt;
      out[1] += rgb[i + 1] * wgt;
      out[2] += rgb[i + 2] * wgt;
    }

    add(x0, y0, (1 - fx) * (1 - fy));
    add(x0 + 1, y0, fx * (1 - fy));
    add(x0, y0 + 1, (1 - fx) * fy);
    add(x0 + 1, y0 + 1, fx * fy);
  }
}
