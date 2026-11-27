import 'dart:ffi' as ffi;

typedef _GetIntNative = ffi.Int32 Function();
typedef _GetIntDart = int Function();

typedef _SetIntGetIntNative = ffi.Int32 Function(ffi.Int32 val);
typedef _SetIntGetIntDart = int Function(int val);

typedef _VoidNative = ffi.Void Function();
typedef _VoidDart = void Function();

class NativeVideoService {
  ffi.DynamicLibrary? _lib;

  late _GetIntDart _isVcamRegistered;
  late _SetIntGetIntDart _setVcamRegistration;
  late _GetIntDart _shmInit;
  late _GetIntDart _startTestPattern;
  late _VoidDart _stopTestPattern;
  late _GetIntDart _isTestRunning;
  late _GetIntDart _getFramesPublished;
  late _VoidDart _shutdown;

  bool get isLoaded => _lib != null;
  String? loadError;

  bool load() {
    if (_lib != null) return true;
    try {
      final lib = ffi.DynamicLibrary.open('aircast_video.dll');
      _isVcamRegistered = lib.lookupFunction<_GetIntNative, _GetIntDart>('video_is_vcam_registered');
      _setVcamRegistration = lib.lookupFunction<_SetIntGetIntNative, _SetIntGetIntDart>('video_set_vcam_registration');
      _shmInit = lib.lookupFunction<_GetIntNative, _GetIntDart>('video_shm_init');
      _startTestPattern = lib.lookupFunction<_GetIntNative, _GetIntDart>('video_start_test_pattern');
      _stopTestPattern = lib.lookupFunction<_VoidNative, _VoidDart>('video_stop_test_pattern');
      _isTestRunning = lib.lookupFunction<_GetIntNative, _GetIntDart>('video_is_test_running');
      _getFramesPublished = lib.lookupFunction<_GetIntNative, _GetIntDart>('video_get_frames_published');
      _shutdown = lib.lookupFunction<_VoidNative, _VoidDart>('video_shutdown');
      _lib = lib;
      loadError = null;
      return true;
    } catch (e) {
      loadError = e.toString();
      return false;
    }
  }

  bool get isVcamRegistered => load() && _isVcamRegistered() == 1;

  /// Returns: 1 = success, 0 = UAC cancelled, -1 = DLL missing, -2 = regsvr32 failed.
  int setVcamRegistration(bool register) {
    if (!load()) return -1;
    return _setVcamRegistration(register ? 1 : 0);
  }

  bool initShm() => load() && _shmInit() == 1;
  bool startTestPattern() => load() && _startTestPattern() == 1;
  void stopTestPattern() {
    if (_lib != null) _stopTestPattern();
  }

  bool get isTestRunning => _lib != null && _isTestRunning() == 1;
  int get framesPublished => _lib == null ? 0 : _getFramesPublished();

  void dispose() {
    if (_lib != null) {
      _shutdown();
      _lib = null;
    }
  }
}