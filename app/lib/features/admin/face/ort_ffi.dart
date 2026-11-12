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
    o._env = o._out((p) => o._createEnvF(3 /* ERROR */, 'myhato'.toNativeUtf8(), p));
    o._mem = o._out((p) => o._memInfoF(0 /* device allocator */, 0 /* default mem */, p));
    return o;
  }

  Pointer<NativeFunction<T>> _p<T extends Function>(int slot) => _api[slot].cast<NativeFunction<T>>();
  late final _errMsg = _p<_ErrMsgN>(_getErrorMessage).asFunction<_ErrMsgD>();
  late final _createEnvF = _p<_CreateEnvN>(_createEnv).asFunction<_CreateEnvD>();
  late final _createOptsF = _p<_OutN>(_createSessionOptions).asFunction<_OutD>();
  late final _setThreadsF = _p<_SetIntN>(_setIntraOpThreads).asFunction<_SetIntD>();
  late final _setOptLevelF = _p<_SetIntN>(_setGraphOptLevel).asFunction<_SetIntD>();
  late final _fromArrayF = _p<_FromArrayN>(_createSessionFromArray).asFunction<_FromArrayD>();
  late final _memInfoF = _p<_MemInfoN>(_createCpuMemoryInfo).asFunction<_MemInfoD>();
  late final _tensorF = _p<_TensorN>(_createTensorWithData).asFunction<_TensorD>();
  late final _runF = _p<_RunN>(_run).asFunction<_RunD>();
  late final _dataF = _p<_DataN>(_getTensorMutableData).asFunction<_DataD>();
  late final _relStatus = _p<_RelN>(_releaseStatus).asFunction<_RelD>();
  late final _relEnv = _p<_RelN>(_releaseEnv).asFunction<_RelD>();
  late final _relMem = _p<_RelN>(_releaseMemoryInfo).asFunction<_RelD>();
  late final _relSession = _p<_RelN>(_releaseSession).asFunction<_RelD>();
  late final _relValue = _p<_RelN>(_releaseValue).asFunction<_RelD>();
  late final _relOpts = _p<_RelN>(_releaseSessionOptions).asFunction<_RelD>();

  void _check(Pointer<Void> status) {
    if (status == nullptr) return;
    final msg = _errMsg(status).toDartString();
    _relStatus(status);
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
    final opts = _out((p) => _createOptsF(p));
    final buf = calloc<Uint8>(model.length);
    try {
      _check(_setThreadsF(opts, threads));
      _check(_setOptLevelF(opts, 99 /* ORT_ENABLE_ALL */));
      buf.asTypedList(model.length).setAll(0, model);
      final s = _out((p) => _fromArrayF(_env, buf.cast(), model.length, opts, p));
      return OrtSession._(this, s);
    } finally {
      calloc.free(buf);
      _relOpts(opts);
    }
  }

  void dispose() {
    _relMem(_mem);
    _relEnv(_env);
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
      inVal.value = o._out((p) => o._tensorF(o._mem, data.cast(), input.length * 4, dims, shape.length, 1 /* float */, p));
      inName.value = inputName.toNativeUtf8();
      names.add(inName.value);
      for (var i = 0; i < outputs.length; i++) {
        outNames[i] = outputs[i].toNativeUtf8();
        names.add(outNames[i]);
      }
      o._check(o._runF(_s, nullptr, inName, inVal, 1, outNames, outputs.length, outVals));
      final res = <Float32List>[];
      for (var i = 0; i < outputs.length; i++) {
        final p = calloc<Pointer<Void>>();
        try {
          o._check(o._dataF(outVals[i], p));
          res.add(Float32List.fromList(p.value.cast<Float>().asTypedList(outputSizes[i])));
        } finally {
          calloc.free(p);
          o._relValue(outVals[i]);
        }
      }
      return res;
    } finally {
      if (inVal.value != nullptr) o._relValue(inVal.value);
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

  void dispose() => _ort._relSession(_s);
}
