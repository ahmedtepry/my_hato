// The face engine runs on Windows through native code (ONNX Runtime). Browsers have no native code, so the web build
// gets a stand-in that always says "not available" and every face button stays hidden there.
export 'face_worker_stub.dart' if (dart.library.ffi) 'face_worker_io.dart';
