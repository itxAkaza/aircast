import 'dart:async';
import 'dart:typed_data';
import 'package:aircast_desktop/controller/server_controller.dart';
import 'package:aircast_desktop/services/native_audio_service.dart';
import 'package:get/get.dart';
import 'package:shared_protocol/shared_protocol.dart';
import 'package:url_launcher/url_launcher.dart';

class MicMonitorController extends GetxController {
  static final Uri vbCableOfficialUrl = Uri.parse('https://vb-audio.com/Cable/');

  final ServerController server = Get.find<ServerController>();
  final NativeAudioService nativeAudio = NativeAudioService();

  /// VB-Cable installation & hardware status
  final Rx<VbCableStatus> vbCableStatus = VbCableStatus.notInstalled.obs;
  final RxBool isCableRouted = false.obs;
  final RxString audioRouterError = ''.obs;

  /// Controls (Loopback defaults OFF to prevent speaker feedback)
  final RxBool isDesktopMuted = false.obs;
  final RxBool isLoopbackEnabled = false.obs;
  final RxBool isLoopbackActive = false.obs;

  /// Live VU/Beat meter (0.0 .. 1.0), throttled to ~25 FPS
  final RxDouble meterLevel = 0.0.obs;
  final RxBool isClipping = false.obs;
  final RxBool isReceivingAudio = false.obs;

  /// Telemetry
  final RxDouble kbps = 0.0.obs;
  final RxInt packetsPerSec = 0.obs;
  final RxInt bufferLatencyMs = 0.obs;
  final RxInt underrunCount = 0.obs;

  double _pendingRawLevel = 0.0;
  bool _pendingClipping = false;
  int _bytesInWindow = 0;
  int _packetsInWindow = 0;
  DateTime _lastPacketAt = DateTime.fromMillisecondsSinceEpoch(0);

  Timer? _uiMeterTimer;
  Timer? _statsTimer;

  @override
  void onInit() {
    super.onInit();

    server.onAudioPacket = _handleAudioPacket;
    server.onAudioReconfig = () {
      _pendingRawLevel = 0.0;
      _pendingClipping = false;
      nativeAudio.flush();
    };

    // Smooth 25 FPS UI meter + C++ ring-buffer telemetry polling
    _uiMeterTimer = Timer.periodic(const Duration(milliseconds: 40), (_) {
      final stale = DateTime.now().difference(_lastPacketAt).inMilliseconds > 500;
      if (stale) {
        if (isReceivingAudio.value) isReceivingAudio.value = false;
        _pendingRawLevel = 0.0;
      }

      final target = (isDesktopMuted.value || stale) ? 0.0 : _pendingRawLevel;
      final current = meterLevel.value;
      final factor = target > current ? 0.65 : 0.20;
      meterLevel.value = current + (target - current) * factor;
      isClipping.value = !isDesktopMuted.value && !stale && _pendingClipping;
      _pendingClipping = false;

      isCableRouted.value = nativeAudio.isCableActive;
      isLoopbackActive.value = nativeAudio.isLoopbackActive;
      bufferLatencyMs.value = nativeAudio.bufferedMs;
      underrunCount.value = nativeAudio.underruns;
    });

    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      kbps.value = _bytesInWindow / 1024.0;
      packetsPerSec.value = _packetsInWindow;
      _bytesInWindow = 0;
      _packetsInWindow = 0;
    });
  }

  @override
  void onReady() {
    super.onReady();
    initializeAudioHardware();
  }

  void initializeAudioHardware() {
    audioRouterError.value = '';

    if (!nativeAudio.load()) {
      audioRouterError.value =
      'Native audio DLL failed to load: ${nativeAudio.loadError}';
      server.log(audioRouterError.value);
      return;
    }

    final status = nativeAudio.checkVbCable();
    vbCableStatus.value = status;

    if (status == VbCableStatus.notInstalled) {
      isCableRouted.value = false;
      server.log('VB-Cable not detected on this PC.');
      return;
    }

    final initRes = nativeAudio.initRouter();
    if (initRes == 1) {
      isCableRouted.value = true;
      nativeAudio.setLoopback(isLoopbackEnabled.value);
      server.log('VB-Cable audio router active (48 kHz Mono PCM -> CABLE Input)');
    } else {
      isCableRouted.value = false;
      audioRouterError.value =
      'CABLE Input was detected, but Windows failed to open it (code $initRes). Check Windows Sound settings.';
      server.log(audioRouterError.value);
    }
  }

  void _handleAudioPacket(Uint8List pcmBytes) {
    _lastPacketAt = DateTime.now();
    if (!isReceivingAudio.value) isReceivingAudio.value = true;

    _bytesInWindow += pcmBytes.length;
    _packetsInWindow++;

    if (isDesktopMuted.value) {
      return;
    }

    // Non-blocking push into C++ jitter ring buffer -> VB-Cable + optional Loopback
    nativeAudio.pushPcm(pcmBytes);

    final stats = PcmUtils.analyze(pcmBytes);
    _pendingRawLevel = stats.level;
    if (stats.isClipping) _pendingClipping = true;
  }

  void toggleDesktopMute() {
    isDesktopMuted.value = !isDesktopMuted.value;
    if (isDesktopMuted.value) {
      nativeAudio.flush();
    }
    server.log(
      isDesktopMuted.value
          ? 'Desktop Emergency Mute ENABLED (ring buffer flushed)'
          : 'Desktop Emergency Mute DISABLED',
    );
  }

  void toggleLoopback(bool enabled) {
    isLoopbackEnabled.value = enabled;
    nativeAudio.setLoopback(enabled);
    server.log(enabled ? 'Speaker Loopback ENABLED' : 'Speaker Loopback DISABLED');
  }

  Future<void> openVbCableDownloadPage() async {
    await launchUrl(vbCableOfficialUrl, mode: LaunchMode.externalApplication);
  }

  @override
  void onClose() {
    if (server.onAudioPacket == _handleAudioPacket) {
      server.onAudioPacket = null;
    }
    server.onAudioReconfig = null;
    _uiMeterTimer?.cancel();
    _statsTimer?.cancel();
    nativeAudio.dispose();
    super.onClose();
  }
}