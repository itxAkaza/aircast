import 'dart:ffi' as ffi;
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

typedef _CheckVbCableNative = ffi.Int32 Function();
typedef _CheckVbCableDart = int Function();

typedef _InitNative = ffi.Int32 Function();
typedef _InitDart = int Function();

typedef _PushNative = ffi.Void Function(ffi.Pointer<ffi.Uint8> data, ffi.Int32 length);
typedef _PushDart = void Function(ffi.Pointer<ffi.Uint8> data, int length);

typedef _FlushNative = ffi.Void Function();
typedef _FlushDart = void Function();

typedef _SetLoopbackNative = ffi.Void Function(ffi.Int32 enabled);
typedef _SetLoopbackDart = void Function(int enabled);

typedef _GetIntNative = ffi.Int32 Function();
typedef _GetIntDart = int Function();

typedef _StopNative = ffi.Void Function();
typedef _StopDart = void Function();

enum VbCableStatus {
  notInstalled,   // 0
  ready,          // 1
  outputDisabled, // 2 (CABLE Input exists, CABLE Output disabled in Windows Sound settings)
}

class NativeAudioService {
  static const int _maxPushChunkBytes = 8192;

  ffi.DynamicLibrary? _lib;
  ffi.Pointer<ffi.Uint8>? _nativeBuffer;

  late _CheckVbCableDart _checkVbCable;
  late _InitDart _init;
  late _PushDart _push;
  late _FlushDart _flush;
  late _SetLoopbackDart _setLoopback;
  late _GetIntDart _isCableActive;
  late _GetIntDart _isLoopbackActive;
  late _GetIntDart _getBufferedMs;
  late _GetIntDart _getUnderruns;
  late _StopDart _stop;

  bool get isLoaded => _lib != null;
  String? loadError;

  bool load() {
    if (_lib != null) return true;
    try {
      final lib = ffi.DynamicLibrary.open('aircast_audio.dll');
      _checkVbCable = lib.lookupFunction<_CheckVbCableNative, _CheckVbCableDart>('audio_check_vbcable');
      _init = lib.lookupFunction<_InitNative, _InitDart>('audio_init');
      _push = lib.lookupFunction<_PushNative, _PushDart>('audio_push');
      _flush = lib.lookupFunction<_FlushNative, _FlushDart>('audio_flush');
      _setLoopback = lib.lookupFunction<_SetLoopbackNative, _SetLoopbackDart>('audio_set_loopback');
      _isCableActive = lib.lookupFunction<_GetIntNative, _GetIntDart>('audio_is_cable_active');
      _isLoopbackActive = lib.lookupFunction<_GetIntNative, _GetIntDart>('audio_is_loopback_active');
      _getBufferedMs = lib.lookupFunction<_GetIntNative, _GetIntDart>('audio_get_buffered_ms');
      _getUnderruns = lib.lookupFunction<_GetIntNative, _GetIntDart>('audio_get_underruns');
      _stop = lib.lookupFunction<_StopNative, _StopDart>('audio_stop');

      _nativeBuffer = malloc.allocate<ffi.Uint8>(_maxPushChunkBytes);
      _lib = lib;
      loadError = null;
      return true;
    } catch (e) {
      loadError = e.toString();
      return false;
    }
  }

  VbCableStatus checkVbCable() {
    if (!load()) return VbCableStatus.notInstalled;
    switch (_checkVbCable()) {
      case 1:
        return VbCableStatus.ready;
      case 2:
        return VbCableStatus.outputDisabled;
      default:
        return VbCableStatus.notInstalled;
    }
  }

  /// Returns 1 on success, 0 if VB-Cable missing, -1 on Windows audio device error.
  int initRouter() {
    if (!load()) return -1;
    return _init();
  }

  /// Non-blocking copy into the C++ jitter ring buffer using a single pre-allocated buffer.
  void pushPcm(Uint8List bytes) {
    final buf = _nativeBuffer;
    if (_lib == null || buf == null || bytes.isEmpty) return;

    var offset = 0;
    while (offset < bytes.length) {
      final remaining = bytes.length - offset;
      final chunkLen = remaining > _maxPushChunkBytes ? _maxPushChunkBytes : remaining;
      buf.asTypedList(chunkLen).setRange(0, chunkLen, bytes, offset);
      _push(buf, chunkLen);
      offset += chunkLen;
    }
  }

  void flush() {
    if (_lib == null) return;
    _flush();
  }

  void setLoopback(bool enabled) {
    if (_lib == null) return;
    _setLoopback(enabled ? 1 : 0);
  }

  bool get isCableActive => _lib != null && _isCableActive() == 1;
  bool get isLoopbackActive => _lib != null && _isLoopbackActive() == 1;
  int get bufferedMs => _lib == null ? 0 : _getBufferedMs();
  int get underruns => _lib == null ? 0 : _getUnderruns();

  void dispose() {
    if (_lib != null) {
      _stop();
    }
    if (_nativeBuffer != null) {
      malloc.free(_nativeBuffer!);
      _nativeBuffer = null;
    }
    _lib = null;
  }
}