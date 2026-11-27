import 'dart:ffi' as ffi;
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

typedef _GetIntNative = ffi.Int32 Function();
typedef _GetIntDart = int Function();

typedef _GetInt64Native = ffi.Int64 Function();
typedef _GetInt64Dart = int Function();

typedef _SetIntGetIntNative = ffi.Int32 Function(ffi.Int32 val);
typedef _SetIntGetIntDart = int Function(int val);

typedef _SetIntVoidNative = ffi.Void Function(ffi.Int32 val);
typedef _SetIntVoidDart = void Function(int val);

typedef _VoidNative = ffi.Void Function();
typedef _VoidDart = void Function();

typedef _PushJpegNative = ffi.Void Function(
    ffi.Pointer<ffi.Uint8> data,
    ffi.Int32 length,
    ffi.Int32 rotation,
    ffi.Int32 mirror,
    ffi.Int64 timestampMs,
    );
typedef _PushJpegDart = void Function(
    ffi.Pointer<ffi.Uint8> data,
    int length,
    int rotation,
    int mirror,
    int timestampMs,
    );

typedef _SetTransformsNative = ffi.Void Function(
    ffi.Int32 fitMode,
    ffi.Int32 extraRotation,
    ffi.Int32 extraMirror,
    );
typedef _SetTransformsDart = void Function(
    int fitMode,
    int extraRotation,
    int extraMirror,
    );

typedef _CopyPreviewNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Uint8> dst,
    ffi.Int32 maxBytes,
    );
typedef _CopyPreviewDart = int Function(
    ffi.Pointer<ffi.Uint8> dst,
    int maxBytes,
    );

class NativeVideoService {
  static const int previewWidth = 640;
  static const int previewHeight = 360;
  static const int previewBytes = previewWidth * previewHeight * 4;
  static const int _initialJpegBufSize = 512 * 1024; // 512 KB, grows up to 4 MB if needed

  ffi.DynamicLibrary? _lib;
  ffi.Pointer<ffi.Uint8>? _jpegBuf;
  int _jpegBufCapacity = 0;
  ffi.Pointer<ffi.Uint8>? _previewBuf;

  late _GetIntDart _isVcamRegistered;
  late _SetIntGetIntDart _setVcamRegistration;
  late _GetIntDart _shmInit;
  late _GetIntDart _startTestPattern;
  late _VoidDart _stopTestPattern;
  late _GetIntDart _isTestRunning;
  late _GetIntDart _getFramesPublished;
  late _PushJpegDart _pushJpeg;
  late _SetTransformsDart _setTransforms;
  late _SetIntVoidDart _setPrivacyCut;
  late _VoidDart _markIdle;
  late _GetIntDart _getFramesDecoded;
  late _GetIntDart _getFramesDropped;
  late _GetIntDart _getSourceWidth;
  late _GetIntDart _getSourceHeight;
  late _GetInt64Dart _getPreviewSeq;
  late _CopyPreviewDart _copyPreviewRgba;
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
      _pushJpeg = lib.lookupFunction<_PushJpegNative, _PushJpegDart>('video_push_jpeg');
      _setTransforms = lib.lookupFunction<_SetTransformsNative, _SetTransformsDart>('video_set_transforms');
      _setPrivacyCut = lib.lookupFunction<_SetIntVoidNative, _SetIntVoidDart>('video_set_privacy_cut');
      _markIdle = lib.lookupFunction<_VoidNative, _VoidDart>('video_mark_idle');
      _getFramesDecoded = lib.lookupFunction<_GetIntNative, _GetIntDart>('video_get_frames_decoded');
      _getFramesDropped = lib.lookupFunction<_GetIntNative, _GetIntDart>('video_get_frames_dropped');
      _getSourceWidth = lib.lookupFunction<_GetIntNative, _GetIntDart>('video_get_source_width');
      _getSourceHeight = lib.lookupFunction<_GetIntNative, _GetIntDart>('video_get_source_height');
      _getPreviewSeq = lib.lookupFunction<_GetInt64Native, _GetInt64Dart>('video_get_preview_seq');
      _copyPreviewRgba = lib.lookupFunction<_CopyPreviewNative, _CopyPreviewDart>('video_copy_preview_rgba');
      _shutdown = lib.lookupFunction<_VoidNative, _VoidDart>('video_shutdown');

      _jpegBuf = malloc.allocate<ffi.Uint8>(_initialJpegBufSize);
      _jpegBufCapacity = _initialJpegBufSize;
      _previewBuf = malloc.allocate<ffi.Uint8>(previewBytes);

      _lib = lib;
      loadError = null;
      return true;
    } catch (e) {
      loadError = e.toString();
      return false;
    }
  }

  bool get isVcamRegistered => load() && _isVcamRegistered() == 1;

  int setVcamRegistration(bool register) {
    if (!load()) return -1;
    return _setVcamRegistration(register ? 1 : 0);
  }

  bool initEngine() => load() && _shmInit() == 1;
  bool startTestPattern() => load() && _startTestPattern() == 1;
  void stopTestPattern() {
    if (_lib != null) _stopTestPattern();
  }

  void pushJpeg(
      Uint8List jpegBytes, {
        required int rotation,
        required bool mirror,
        required int timestampMs,
      }) {
    if (_lib == null || jpegBytes.isEmpty) return;

    if (jpegBytes.length > _jpegBufCapacity) {
      if (_jpegBuf != null) malloc.free(_jpegBuf!);
      _jpegBufCapacity = jpegBytes.length;
      _jpegBuf = malloc.allocate<ffi.Uint8>(_jpegBufCapacity);
    }

    final buf = _jpegBuf!;
    buf.asTypedList(jpegBytes.length).setAll(0, jpegBytes);
    _pushJpeg(buf, jpegBytes.length, rotation, mirror ? 1 : 0, timestampMs);
  }

  void setTransforms({
    required bool fitLetterbox,
    required int extraRotation,
    required bool extraMirror,
  }) {
    if (_lib == null) return;
    _setTransforms(fitLetterbox ? 1 : 0, extraRotation, extraMirror ? 1 : 0);
  }

  void setPrivacyCut(bool enabled) {
    if (_lib == null) return;
    _setPrivacyCut(enabled ? 1 : 0);
  }

  void markIdle() {
    if (_lib == null) return;
    _markIdle();
  }

  /// Copies latest 640x360 RGBA32 frame into a Dart Uint8List if available.
  Uint8List? copyPreviewRgba() {
    if (_lib == null || _previewBuf == null) return null;
    if (_copyPreviewRgba(_previewBuf!, previewBytes) != 1) return null;
    return Uint8List.fromList(_previewBuf!.asTypedList(previewBytes));
  }

  bool get isTestRunning => _lib != null && _isTestRunning() == 1;
  int get framesPublished => _lib == null ? 0 : _getFramesPublished();
  int get framesDecoded => _lib == null ? 0 : _getFramesDecoded();
  int get framesDropped => _lib == null ? 0 : _getFramesDropped();
  int get sourceWidth => _lib == null ? 0 : _getSourceWidth();
  int get sourceHeight => _lib == null ? 0 : _getSourceHeight();
  int get previewSeq => _lib == null ? 0 : _getPreviewSeq();

  void dispose() {
    if (_lib != null) {
      _shutdown();
      _lib = null;
    }
    if (_jpegBuf != null) {
      malloc.free(_jpegBuf!);
      _jpegBuf = null;
      _jpegBufCapacity = 0;
    }
    if (_previewBuf != null) {
      malloc.free(_previewBuf!);
      _previewBuf = null;
    }
  }
}