import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:shared_protocol/shared_protocol.dart';
import 'package:window_manager/window_manager.dart';
import '../services/native_video_service.dart';
import 'server_controller.dart';

class VideoServerController extends GetxController {
  final ServerController server = Get.find<ServerController>();
  final NativeVideoService video = NativeVideoService();

  // Engine & Virtual Cam status
  final RxBool isEngineReady = false.obs;
  final RxBool isVcamRegistered = false.obs;
  final RxBool isTestPatternRunning = false.obs;
  final RxBool isVideoClientConnected = false.obs;
  final RxBool isReceivingVideo = false.obs;
  final RxString statusMessage = 'Initializing AirCast Video Engine...'.obs;

  // Controls
  final Rx<VideoFitMode> fitMode = VideoFitMode.fill.obs;
  final RxInt extraRotation = 0.obs;
  final RxBool mirrorHorizontal = false.obs;
  final RxBool privacyCut = false.obs;
  final RxBool previewEnabled = true.obs;
  final RxBool isPipMode = false.obs;

  // Live Telemetry
  final RxInt receivedFps = 0.obs;
  final RxInt decodedFps = 0.obs;
  final RxInt droppedFrames = 0.obs;
  final RxDouble mbps = 0.0.obs;
  final RxDouble avgFrameKb = 0.0.obs;
  final RxString resolutionLabel = '1280 × 720'.obs;

  // Decoded ui.Image for live Desktop preview & PiP
  final Rxn<ui.Image> previewImage = Rxn<ui.Image>();

  ServerSocket? _videoServer;
  Socket? _videoClient;
  final VideoStreamDecoder _decoder = VideoStreamDecoder();
  bool _clientAuthenticated = false;

  Timer? _statsTimer;
  Timer? _previewTimer;
  DateTime _lastVideoFrameAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _rxFramesWindow = 0;
  int _rxBytesWindow = 0;
  int _dartDropped = 0;
  int _lastNativeDecoded = 0;
  int _lastPreviewSeq = -1;
  bool _decodingPreviewImage = false;
  Rect? _savedNormalBounds;

  @override
  void onReady() {
    super.onReady();
    _initialize();
  }

  Future<void> _initialize() async {
    if (!video.load()) {
      statusMessage.value = 'Failed to load aircast_video.dll: ${video.loadError}';
      return;
    }

    isEngineReady.value = video.initEngine();
    refreshRegistrationStatus();
    _applyTransforms();
    await _startVideoServer();

    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final stale = DateTime.now().difference(_lastVideoFrameAt).inMilliseconds > 1500;
      if (stale && isReceivingVideo.value) {
        isReceivingVideo.value = false;
        if (!isTestPatternRunning.value) video.markIdle();
      }

      receivedFps.value = _rxFramesWindow;
      mbps.value = (_rxBytesWindow * 8.0) / 1000000.0;
      avgFrameKb.value = _rxFramesWindow > 0 ? (_rxBytesWindow / _rxFramesWindow) / 1024.0 : 0.0;
      _rxFramesWindow = 0;
      _rxBytesWindow = 0;

      if (video.isLoaded) {
        final curDecoded = video.framesDecoded;
        decodedFps.value = curDecoded >= _lastNativeDecoded ? (curDecoded - _lastNativeDecoded) : 0;
        _lastNativeDecoded = curDecoded;
        droppedFrames.value = _dartDropped + video.framesDropped;

        final sw = video.sourceWidth;
        final sh = video.sourceHeight;
        if (sw > 0 && sh > 0 && isReceivingVideo.value) {
          resolutionLabel.value = '$sw × $sh';
        } else if (isTestPatternRunning.value) {
          resolutionLabel.value = '1280 × 720 (Test)';
        }
      }
    });

    // ~20 FPS lightweight native RGBA preview pump (zero JPEG decode on UI thread)
    _previewTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (!video.isLoaded || !previewEnabled.value || privacyCut.value) return;
      if (!isReceivingVideo.value && !isTestPatternRunning.value) return;
      if (_decodingPreviewImage) return;

      final seq = video.previewSeq;
      if (seq == _lastPreviewSeq) return;
      _lastPreviewSeq = seq;

      final rgba = video.copyPreviewRgba();
      if (rgba == null) return;

      _decodingPreviewImage = true;
      ui.decodeImageFromPixels(
        rgba,
        NativeVideoService.previewWidth,
        NativeVideoService.previewHeight,
        ui.PixelFormat.rgba8888,
            (ui.Image img) {
          final old = previewImage.value;
          previewImage.value = img;
          old?.dispose();
          _decodingPreviewImage = false;
        },
      );
    });
  }

  Future<void> _startVideoServer() async {
    try {
      await _videoServer?.close();
      _videoServer = await ServerSocket.bind(
        InternetAddress.anyIPv4,
        AirCastConstants.defaultVideoPort,
      );
      server.log('Video TCP server listening on port ${AirCastConstants.defaultVideoPort}');
      _videoServer!.listen(_handleVideoConnection);
    } catch (e) {
      statusMessage.value = 'Port ${AirCastConstants.defaultVideoPort} bind failed: $e';
      server.log('Video server error: $e');
    }
  }

  void _handleVideoConnection(Socket socket) {
    final old = _videoClient;
    _videoClient = socket;
    _clientAuthenticated = false;
    _decoder.reset();
    old?.destroy();

    socket.setOption(SocketOption.tcpNoDelay, true);
    server.log('Incoming video connection from ${socket.remoteAddress.address}');

    socket.listen(
          (chunk) {
        if (_videoClient != socket) return;
        try {
          final packets = _decoder.addChunk(chunk);
          if (packets.isEmpty) return;

          // Process auth packets first; for JPEG frames, drain-to-latest
          VideoFramePacket? latestFrame;
          int skipped = 0;

          for (final pkt in packets) {
            if (pkt.type == VideoFramePacket.typeAuth) {
              final token = utf8.decode(pkt.payload, allowMalformed: true).trim();
              final expected = server.activeSessionToken.value;
              if (expected.isEmpty || token != expected) {
                server.log('Rejected unauthorized video stream');
                socket.destroy();
                return;
              }
              _clientAuthenticated = true;
              isVideoClientConnected.value = true;
              if (isTestPatternRunning.value) toggleTestPattern();
              server.log('Video stream authenticated on port ${AirCastConstants.defaultVideoPort}');
            } else if (pkt.type == VideoFramePacket.typeJpegFrame) {
              if (!_clientAuthenticated) {
                socket.destroy();
                return;
              }
              if (latestFrame != null) skipped++;
              latestFrame = pkt;
            }
          }

          if (skipped > 0) _dartDropped += skipped;
          if (latestFrame != null) {
            _rxFramesWindow++;
            _rxBytesWindow += latestFrame.payload.length;
            _lastVideoFrameAt = DateTime.now();
            if (!isReceivingVideo.value) isReceivingVideo.value = true;

            video.pushJpeg(
              latestFrame.payload,
              rotation: latestFrame.rotation,
              mirror: latestFrame.isMirrored,
              timestampMs: latestFrame.timestampMs,
            );
          }
        } on FormatException catch (e) {
          server.log('Dropped corrupt video stream: $e');
          socket.destroy();
        }
      },
      onError: (_) {
        if (_videoClient == socket) _resetVideoClient();
      },
      onDone: () {
        if (_videoClient == socket) _resetVideoClient();
      },
    );
  }

  void _resetVideoClient() {
    _videoClient = null;
    _clientAuthenticated = false;
    _decoder.reset();
    isVideoClientConnected.value = false;
    isReceivingVideo.value = false;
    if (!isTestPatternRunning.value) {
      video.markIdle();
    }
  }

  void refreshRegistrationStatus() {
    if (!video.load()) return;
    isVcamRegistered.value = video.isVcamRegistered;
    statusMessage.value = isVcamRegistered.value
        ? 'AirCast Camera registered (1280×720 @ 30 FPS — YUY2 & RGB24)'
        : 'Virtual camera not registered yet. Click Register (1-time UAC prompt).';
  }

  void toggleRegistration(bool register) {
    final res = video.setVcamRegistration(register);
    refreshRegistrationStatus();
    if (res == 1) {
      statusMessage.value = register
          ? 'Registered! Restart OBS / Discord / Chrome if already open to detect "AirCast Camera".'
          : 'Unregistered cleanly.';
    } else if (res == 0) {
      statusMessage.value = 'UAC prompt cancelled.';
    } else if (res == -1) {
      statusMessage.value = 'aircast_vcam.dll missing beside aircast_desktop.exe.';
    } else {
      statusMessage.value = 'regsvr32 failed. Close OBS/Discord/Chrome first if the DLL is locked.';
    }
  }

  void toggleTestPattern() {
    if (isTestPatternRunning.value) {
      video.stopTestPattern();
      isTestPatternRunning.value = false;
      statusMessage.value = 'Test bars stopped (AirCast Camera shows dark Standby slate).';
    } else {
      if (video.startTestPattern()) {
        isTestPatternRunning.value = true;
        statusMessage.value = 'Streaming live 1280×720 @ 30 FPS SMPTE bars to AirCast Camera.';
      }
    }
  }

  void setFitMode(VideoFitMode mode) {
    fitMode.value = mode;
    _applyTransforms();
  }

  void rotate90() {
    extraRotation.value = (extraRotation.value + 90) % 360;
    _applyTransforms();
  }

  void toggleMirror() {
    mirrorHorizontal.value = !mirrorHorizontal.value;
    _applyTransforms();
  }

  void togglePrivacyCut() {
    privacyCut.value = !privacyCut.value;
    video.setPrivacyCut(privacyCut.value);
    if (privacyCut.value) {
      previewImage.value?.dispose();
      previewImage.value = null;
    }
  }

  void togglePreviewEnabled() {
    previewEnabled.value = !previewEnabled.value;
    if (!previewEnabled.value) {
      previewImage.value?.dispose();
      previewImage.value = null;
    }
  }

  Future<void> togglePipMode() async {
    if (!isPipMode.value) {
      _savedNormalBounds = await windowManager.getBounds();
      isPipMode.value = true;
      previewEnabled.value = true;
      await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
      await windowManager.setAlwaysOnTop(true);
      await windowManager.setSize(const Size(368, 207));
    } else {
      isPipMode.value = false;
      await windowManager.setAlwaysOnTop(false);
      await windowManager.setTitleBarStyle(TitleBarStyle.normal);
      if (_savedNormalBounds != null) {
        await windowManager.setBounds(_savedNormalBounds!);
      } else {
        await windowManager.setSize(const Size(1060, 720));
      }
    }
  }

  void _applyTransforms() {
    video.setTransforms(
      fitLetterbox: fitMode.value == VideoFitMode.fit,
      extraRotation: extraRotation.value,
      extraMirror: mirrorHorizontal.value,
    );
  }

  @override
  void onClose() {
    if (isPipMode.value) {
      windowManager.setAlwaysOnTop(false);
      windowManager.setTitleBarStyle(TitleBarStyle.normal);
    }
    _statsTimer?.cancel();
    _previewTimer?.cancel();
    previewImage.value?.dispose();
    _videoClient?.destroy();
    _videoServer?.close();
    video.dispose();
    super.onClose();
  }
}