import 'dart:async';
import 'dart:io';
import 'package:get/get.dart';
import 'package:jni/jni.dart';
import 'package:shared_protocol/shared_protocol.dart';
import '../native/camera_bridge.g.dart';
import 'client_controller.dart';

class CameraStreamController extends GetxController {
  final ClientController client = Get.find<ClientController>();

  final RxInt textureId = (-1).obs;
  final RxBool isCameraReady = false.obs;
  final RxBool isStreaming = false.obs;
  final RxBool isBlackoutMode = false.obs;

  final Rx<VideoPreset> preset = VideoPreset.balanced.obs;
  final RxInt jpegQuality = 75.obs;
  final RxInt effectiveQuality = 75.obs;
  final RxBool mirrorHorizontal = false.obs;
  final RxBool torchEnabled = false.obs;
  final RxBool hasTorch = false.obs;
  final RxDouble zoomRatio = 1.0.obs;
  final RxDouble minZoom = 1.0.obs;
  final RxDouble maxZoom = 4.0.obs;

  final RxList<String> lensLabels = <String>[].obs;
  final RxInt activeLensIndex = 0.obs;

  // Live Telemetry
  final RxInt captureFps = 0.obs;
  final RxInt sentFps = 0.obs;
  final RxInt droppedFrames = 0.obs;
  final RxDouble mbps = 0.0.obs;
  final RxString statusText = 'Starting native CameraX preview...'.obs;

  Timer? _statsTimer;
  Worker? _connWorker;
  int _lastCaptured = 0;
  int _lastSent = 0;
  int _lastBytes = 0;
  bool _wantedStreamingBeforeDrop = false;

  @override
  void onInit() {
    super.onInit();

    _connWorker = ever(client.isConnected, (bool connected) {
      if (!connected && isStreaming.value) {
        _wantedStreamingBeforeDrop = client.isReconnecting.value;
        stopStreaming(reason: 'Wi-Fi dropped — waiting to reconnect...');
      } else if (connected && _wantedStreamingBeforeDrop) {
        _wantedStreamingBeforeDrop = false;
        startStreaming();
      }
    });

    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!Platform.isAndroid || !isCameraReady.value) return;

      final cap = AirCastCameraBridge.readCapturedTotal();
      final sent = AirCastCameraBridge.readSentTotal();
      final bytes = AirCastCameraBridge.readBytesSentTotal();

      captureFps.value = cap >= _lastCaptured ? (cap - _lastCaptured) : 0;
      sentFps.value = sent >= _lastSent ? (sent - _lastSent) : 0;
      mbps.value = bytes >= _lastBytes ? ((bytes - _lastBytes) * 8.0) / 1000000.0 : 0.0;
      droppedFrames.value = AirCastCameraBridge.readDroppedTotal();
      effectiveQuality.value = AirCastCameraBridge.readEffectiveQuality();

      _lastCaptured = cap;
      _lastSent = sent;
      _lastBytes = bytes;

      // Refresh lens list & torch capabilities once CameraX finishes binding
      if (lensLabels.isEmpty) {
        _refreshCameraCapabilities();
      }

      final errStr = _readAndReleaseString(AirCastCameraBridge.readLastError());
      if (errStr.isNotEmpty) {
        statusText.value = errStr;
      }
    });
  }

  @override
  void onReady() {
    super.onReady();
    initPreview();
  }

  Future<void> initPreview() async {
    if (!Platform.isAndroid) return;

    if (!AirCastCameraBridge.hasCameraPermission()) {
      AirCastCameraBridge.requestCameraPermission();
      statusText.value = 'Grant Camera permission, then tap Retry Preview.';
      return;
    }

    final p = preset.value;
    final id = AirCastCameraBridge.startCamera(
      p.width,
      p.height,
      p.fps,
      jpegQuality.value,
      activeLensIndex.value,
    );

    if (id < 0) {
      final err = _readAndReleaseString(AirCastCameraBridge.readLastError());
      statusText.value = err.isEmpty ? 'Failed to start CameraX' : err;
      return;
    }

    textureId.value = id;
    isCameraReady.value = true;
    statusText.value = 'Preview ready (${p.label}) — tap Start Camera to stream';

    // Give CameraX a brief moment to bind lenses asynchronously
    await Future.delayed(const Duration(milliseconds: 500));
    _refreshCameraCapabilities();
  }

  void _refreshCameraCapabilities() {
    final count = AirCastCameraBridge.readLensCount();
    if (count > 0) {
      final labels = <String>[];
      for (var i = 0; i < count; i++) {
        labels.add(_readAndReleaseString(AirCastCameraBridge.readLensLabel(i)));
      }
      lensLabels.assignAll(labels);
      activeLensIndex.value = AirCastCameraBridge.readActiveLensIndex();
    }
    hasTorch.value = AirCastCameraBridge.hasTorch();
    minZoom.value = AirCastCameraBridge.readMinZoom();
    maxZoom.value = AirCastCameraBridge.readMaxZoom().clamp(1.0, 8.0);
    zoomRatio.value = zoomRatio.value.clamp(minZoom.value, maxZoom.value);
  }

  void startStreaming() {
    if (!isCameraReady.value) return;
    if (!client.isConnected.value || client.sessionToken.value.isEmpty) {
      statusText.value = 'Connect to PC first (missing session token)';
      return;
    }

    final hostJ = client.lastHost.value.toJString();
    final tokenJ = client.sessionToken.value.toJString();
    try {
      final ok = AirCastCameraBridge.startStreaming(
        hostJ,
        client.videoPort.value,
        tokenJ,
      );
      isStreaming.value = ok;
      if (ok) {
        _lastCaptured = 0;
        _lastSent = 0;
        _lastBytes = 0;
        statusText.value = 'Streaming ${preset.value.label} to ${client.serverName.value}';
        client.log('Camera streaming started on port ${client.videoPort.value}');
      } else {
        final err = _readAndReleaseString(AirCastCameraBridge.readLastError());
        statusText.value = err.isEmpty ? 'Failed to start video stream' : err;
      }
    } finally {
      hostJ.release();
      tokenJ.release();
    }
  }

  void stopStreaming({String reason = 'Camera stopped'}) {
    AirCastCameraBridge.stopStreaming();
    isStreaming.value = false;
    captureFps.value = 0;
    sentFps.value = 0;
    mbps.value = 0.0;
    statusText.value = reason;
  }

  Future<void> selectLens(int index) async {
    if (index < 0 || index >= lensLabels.length) return;
    activeLensIndex.value = index;
    AirCastCameraBridge.switchLens(index);
    final isFront = lensLabels[index].toLowerCase().contains('front');
    mirrorHorizontal.value = isFront;
    if (isFront) torchEnabled.value = false;
    zoomRatio.value = 1.0;

    await Future.delayed(const Duration(milliseconds: 350));
    _refreshCameraCapabilities();
  }

  void selectPreset(VideoPreset next) {
    preset.value = next;
    jpegQuality.value = next.quality;
    effectiveQuality.value = next.quality;
    AirCastCameraBridge.applyPreset(next.width, next.height, next.fps, next.quality);
    if (isStreaming.value) {
      statusText.value = 'Streaming ${next.label} to ${client.serverName.value}';
    }
  }

  void updateQuality(int q) {
    jpegQuality.value = q;
    effectiveQuality.value = q;
    AirCastCameraBridge.applyJpegQuality(q);
  }

  void toggleMirror() {
    mirrorHorizontal.value = !mirrorHorizontal.value;
    AirCastCameraBridge.applyMirror(mirrorHorizontal.value);
  }

  void toggleTorch() {
    if (!hasTorch.value) return;
    final next = !torchEnabled.value;
    if (AirCastCameraBridge.applyTorch(next)) {
      torchEnabled.value = next;
    }
  }

  void updateZoom(double value) {
    zoomRatio.value = value.clamp(minZoom.value, maxZoom.value);
    AirCastCameraBridge.applyZoomRatio(zoomRatio.value);
  }

  void tapToFocus(double normX, double normY) {
    AirCastCameraBridge.focusAt(normX, normY);
  }

  void setBlackoutMode(bool enabled) {
    isBlackoutMode.value = enabled;
  }

  String _readAndReleaseString(JString? jStr) {
    if (jStr == null) return '';
    try {
      return jStr.toDartString();
    } finally {
      jStr.release();
    }
  }

  @override
  void onClose() {
    _statsTimer?.cancel();
    _connWorker?.dispose();
    if (Platform.isAndroid) {
      AirCastCameraBridge.stopCamera();
    }
    super.onClose();
  }
}