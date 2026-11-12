// A tiny binding to the ONNX Runtime C API (onnxruntime.dll, version 1.20.x) - only the calls the face engine needs.
// Windows team app only: the DLL ships next to myhato.exe (build-windows.yml copies it), so the customer APK carries nothing.
// Indexes are the positions of the functions in `struct OrtApi` of onnxruntime_c_api.h (ORT_API_VERSION 20).
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

const _apiVersion = 20;

// OrtApi slots
const _getErrorMessage = 2, _createEnv = 3, _createSessionFromArray = 8, _run = 9, _createSessionOptions = 10;
const _setGraphOptLevel = 23, _setIntraOpThreads = 24, _createTensorWithData = 49, _getTensorMutableData = 51;
const _createCpuMemoryInfo = 69, _releaseEnv = 92, _releaseStatus = 93, _releaseMemoryInfo = 94, _releaseSession = 95;
const _releaseValue = 96, _releaseSessionOptions = 100;

typedef _GetApiBaseN = Pointer<Pointer<Void>> Function();
typedef _GetApiN = Pointer<Pointer<Void>> Function(Uint32);
typedef _GetApiD = Pointer<Pointer<Void>> Function(int);
typedef _ErrMsgN = Pointer<Utf8> Function(Pointer<Void>);
typedef _ErrMsgD = Pointer<Utf8> Function(Pointer<Void>);
typedef _CreateEnvN = Pointer<Void> Function(Int32, Pointer<Utf8>, Pointer<Pointer<Void>>);
typedef _CreateEnvD = Pointer<Void> Function(int, Pointer<Utf8>, Pointer<Pointer<Void>>);
typedef _OutN = Pointer<Void> Function(Pointer<Pointer<Void>>);
typedef _OutD = Pointer<Void> Function(Pointer<Pointer<Void>>);
typedef _SetIntN = Pointer<Void> Function(Pointer<Void>, Int32);
typedef _SetIntD = Pointer<Void> Function(Pointer<Void>, int);
typedef _FromArrayN = Pointer<Void> Function(Pointer<Void>, Pointer<Void>, Size, Pointer<Void>, Pointer<Pointer<Void>>);
typedef _FromArrayD = Pointer<Void> Function(Pointer<Void>, Pointer<Void>, int, Pointer<Void>, Pointer<Pointer<Void>>);
typedef _MemInfoN = Pointer<Void> Function(Int32, Int32, Pointer<Pointer<Void>>);
typedef _MemInfoD = Pointer<Void> Function(int, int, Pointer<Pointer<Void>>);
typedef _TensorN = Pointer<Void> Function(Pointer<Void>, Pointer<Void>, Size, Pointer<Int64>, Size, Int32, Pointer<Pointer<Void>>);
typedef _TensorD = Pointer<Void> Function(Pointer<Void>, Pointer<Void>, int, Pointer<Int64>, int, int, Pointer<Pointer<Void>>);
typedef _RunN = Pointer<Void> Function(Pointer<Void>, Pointer<Void>, Pointer<Pointer<Utf8>>, Pointer<Pointer<Void>>, Size, Pointer<Pointer<Utf8>>,
    Size, Pointer<Pointer<Void>>);
typedef _RunD = Pointer<Void> Function(Pointer<Void>, Pointer<Void>, Pointer<Pointer<Utf8>>, Pointer<Pointer<Void>>, int, Pointer<Pointer<Utf8>>,
    int, Pointer<Pointer<Void>>);
typedef _DataN = Pointer<Void> Function(Pointer<Void>, Pointer<Pointer<Void>>);
typedef _DataD = Pointer<Void> Function(Pointer<Void>, Pointer<Pointer<Void>>);
typedef _RelN = Void Function(Pointer<Void>);
typedef _RelD = void Function(Pointer<Void>);

class OrtException implements Exception {
  OrtException(this.message);
  final String message;
  @override
  String toString() => 'OrtException: $message';
}

/// The loaded runtime: one environment shared by every session.
class Ort {
  Ort._(this._api);
  final Pointer<Pointer<Void>> _api;
  late final Pointer<Void> _env;
  late final Pointer<Void> _mem;

  static Ort open(String dllPath) {
    final lib = DynamicLibrary.open(dllPath);
    final base = lib.lookupFunction<_GetApiBaseN, _GetApiBaseN>('OrtGetApiBase')();
    // struct OrtApiBase { const OrtApi* (*GetApi)(uint32_t); const char* (*GetVersionString)(void); }
    final getApi = base[0].cast<NativeFunction<_GetApiN>>().asFunction<_GetApiD>();
    final api = getApi(_apiVersion);
    if (api == nullptr) throw OrtException('onnxruntime.dll does not offer API version $_apiVersion');
    final o = Ort._(api);
    o._env = o._out((p) => o._fn<_CreateEnvN, _CreateEnvD>(_createEnv)(3 /* ERROR */, 'myhato'.toNativeUtf8(), p));
    o._mem = o._out((p) => o._fn<_MemInfoN, _MemInfoD>(_createCpuMemoryInfo)(0 /* device allocator */, 0 /* default mem */, p));
    return o;
  }

  F _fn<T extends Function, F extends Function>(int slot) => _api[slot].cast<NativeFunction<T>>().asFunction<F>();

  void _check(Pointer<Void> status) {
    if (status == nullptr) return;
    final msg = _fn<_ErrMsgN, _ErrMsgD>(_getErrorMessage)(status).toDartString();
    _fn<_RelN, _RelD>(_releaseStatus)(status);
    throw OrtException(msg);
  }

  Pointer<Void> _out(Pointer<Void> Function(Pointer<Pointer<Void>>) call) {
    final p = calloc<Pointer<Void>>();
    try {
      _check(call(p));
      return p.value;
    } finally {
      calloc.free(p);
    }
  }

  OrtSession session(Uint8List model, {int threads = 2}) {
    final opts = _out((p) => _fn<_OutN, _OutD>(_createSessionOptions)(p));
    final buf = calloc<Uint8>(model.length);
    try {
      _check(_fn<_SetIntN, _SetIntD>(_setIntraOpThreads)(opts, threads));
      _check(_fn<_SetIntN, _SetIntD>(_setGraphOptLevel)(opts, 99 /* ORT_ENABLE_ALL */));
      buf.asTypedList(model.length).setAll(0, model);
      final s = _out((p) => _fn<_FromArrayN, _FromArrayD>(_createSessionFromArray)(_env, buf.cast(), model.length, opts, p));
      return OrtSession._(this, s);
    } finally {
      calloc.free(buf);
      _fn<_RelN, _RelD>(_releaseSessionOptions)(opts);
    }
  }

  void dispose() {
    _fn<_RelN, _RelD>(_releaseMemoryInfo)(_mem);
    _fn<_RelN, _RelD>(_releaseEnv)(_env);
  }
}

class OrtSession {
  OrtSession._(this._ort, this._s);
  final Ort _ort;
  final Pointer<Void> _s;

  /// Runs one float input; returns each requested output as a flat Float32List of [outputSizes[i]] values.
  List<Float32List> run(String inputName, Float32List input, List<int> shape, List<String> outputs, List<int> outputSizes) {
    final o = _ort;
    final data = calloc<Float>(input.length);
    final dims = calloc<Int64>(shape.length);
    final inName = calloc<Pointer<Utf8>>();
    final outNames = calloc<Pointer<Utf8>>(outputs.length);
    final outVals = calloc<Pointer<Void>>(outputs.length);
    final inVal = calloc<Pointer<Void>>();
    final names = <Pointer<Utf8>>[];
    try {
      data.asTypedList(input.length).setAll(0, input);
      for (var i = 0; i < shape.length; i++) {
        dims[i] = shape[i];
      }
      inVal.value = o._out((p) => o._fn<_TensorN, _TensorD>(_createTensorWithData)(o._mem, data.cast(), input.length * 4, dims, shape.length, 1 /* float */, p));
      inName.value = inputName.toNativeUtf8();
      names.add(inName.value);
      for (var i = 0; i < outputs.length; i++) {
        outNames[i] = outputs[i].toNativeUtf8();
        names.add(outNames[i]);
      }
      o._check(o._fn<_RunN, _RunD>(_run)(_s, nullptr, inName, inVal, 1, outNames, outputs.length, outVals));
      final res = <Float32List>[];
      for (var i = 0; i < outputs.length; i++) {
        final p = calloc<Pointer<Void>>();
        try {
          o._check(o._fn<_DataN, _DataD>(_getTensorMutableData)(outVals[i], p));
          res.add(Float32List.fromList(p.value.cast<Float>().asTypedList(outputSizes[i])));
        } finally {
          calloc.free(p);
          o._fn<_RelN, _RelD>(_releaseValue)(outVals[i]);
        }
      }
      return res;
    } finally {
      if (inVal.value != nullptr) o._fn<_RelN, _RelD>(_releaseValue)(inVal.value);
      for (final n in names) {
        calloc.free(n);
      }
      calloc.free(data);
      calloc.free(dims);
      calloc.free(inName);
      calloc.free(outNames);
      calloc.free(outVals);
      calloc.free(inVal);
    }
  }

  void dispose() => _ort._fn<_RelN, _RelD>(_releaseSession)(_s);
}
