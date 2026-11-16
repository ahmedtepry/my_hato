// Web stand-in for the face engine (see face_worker.dart): same API, never available.
import 'dart:typed_data';

class FaceScan {
  FaceScan(this.print, this.yaw, this.faces, this.sizeRatio, this.score);
  final List<double> print;
  final double yaw;
  final int faces;
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
  FaceWorker._();
  static Future<FaceWorker> get instance => Future.error(FaceUnavailable('not on the web'));
  Future<FaceScan?> analyze(Uint8List picture) async => null;
  Future<FaceScan?> analyzeRgba(Uint8List rgba, int width, int height) async => null;
  void dispose() {}
}
