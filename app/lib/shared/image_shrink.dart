import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as img;

/// Re-encodes a photo as a smaller JPEG before it is uploaded (the free storage plan is 1 GB; a phone photo is 3-5 MB,
/// after this it is about 100-250 KB with no visible difference on screen).
/// Keeps the original when it cannot be decoded (e.g. HEIC) or when the result would not be smaller.
Future<Uint8List> shrinkImage(Uint8List bytes, {int maxSide = 1600, int quality = 74}) async {
  if (bytes.length < 180 * 1024) return bytes; // already small
  try {
    final out = await compute(_shrink, _Job(bytes, maxSide, quality));
    return (out != null && out.length < bytes.length) ? out : bytes;
  } catch (_) {
    return bytes;
  }
}

class _Job {
  const _Job(this.bytes, this.maxSide, this.quality);
  final Uint8List bytes;
  final int maxSide;
  final int quality;
}

Uint8List? _shrink(_Job j) {
  final decoded = img.decodeImage(j.bytes);
  if (decoded == null) return null;
  var im = img.bakeOrientation(decoded); // camera photos carry their rotation in EXIF
  final long = im.width > im.height ? im.width : im.height;
  if (long > j.maxSide) {
    im = im.width >= im.height
        ? img.copyResize(im, width: j.maxSide, interpolation: img.Interpolation.average)
        : img.copyResize(im, height: j.maxSide, interpolation: img.Interpolation.average);
  }
  return Uint8List.fromList(img.encodeJpg(im, quality: j.quality));
}

/// Size presets per kind of photo.
class Shrink {
  static Future<Uint8List> repair(Uint8List b) => shrinkImage(b, maxSide: 1600, quality: 72);
  static Future<Uint8List> proof(Uint8List b) => shrinkImage(b, maxSide: 1400, quality: 70);
  static Future<Uint8List> avatar(Uint8List b) => shrinkImage(b, maxSide: 512, quality: 80);
  static Future<Uint8List> product(Uint8List b) => shrinkImage(b, maxSide: 1400, quality: 82);
  static Future<Uint8List> banner(Uint8List b) => shrinkImage(b, maxSide: 1600, quality: 80);
}
