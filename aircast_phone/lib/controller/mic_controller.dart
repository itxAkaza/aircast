import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:get/get.dart';
import 'package:record/record.dart';
import 'package:shared_protocol/shared_protocol.dart';
import '../services/foreground_mic_service.dart';
import 'client_controller.dart';

class MicController extends GetxController {
  final ClientController client = Get.find<ClientController>();
  final AudioRecorder _recorder = AudioRecorder();

  final RxBool isStreaming = false.obs;
  final RxBool isBusy = false.obs;
  final RxBool isMuted = false.obs;
  final RxBool noiseSuppression = false.obs;
  final RxBool echoCancellation = false.obs;
  final RxDouble gain = 1.0.obs;

  final RxBool isBatteryUnrestricted = true.obs;

  /// Smoothed 0.0..1.0 level updated at ~25 FPS for the UI meter.
  final RxDouble meterLevel = 0.0.obs;
  final RxBool isClipping = false.obs;
  final RxInt packetsSentPerSec = 0.obs;
  final RxString statusText = 'Idle — tap Start Mic to stream'.obs;

  StreamSubscription<Uint8List>? _audioSub;
  Worker? _connectionWorker;
  Worker? _reconnectingWorker;
  Timer? _uiMeterTimer;
  Timer? _statsTimer;

  // Fixed 20 ms chunk accumulator (48 kHz * 1 ch * 2 bytes * 0.02s = 1920 bytes)
  final BytesBuilder _pcmAccumulator = BytesBuilder(copy: false);
  final Uint8List _silenceFrame = Uint8List(AudioConfig.frameBytes20ms);

  double _pendingRawLevel = 0.0;
  bool _pendingClipping = false;
  int _packetsCounter = 0;

  AudioConfig get currentConfig => AudioConfig(
    sampleRate: AudioConfig.defaultSampleRate,
    numChannels: AudioConfig.defaultChannels,
    gain: gain.value,
    isMuted: isMuted.value,
    noiseSuppression: noiseSuppression.value,
    echoCancellation: echoCancellation.value,
    mode: StreamMode.mic,
  );

  @override
  void onInit() {
    super.onInit();

    ForegroundMicService.init();
    FlutterForegroundTask.addTaskDataCallback(_onForegroundTaskData);

    // Handle connection drops & seamless auto-resume when Wi-Fi recovers
    _connectionWorker = ever(client.isConnected, (bool connected) {
      if (!isStreaming.value) return;

      if (connected) {
        // Socket recovered while mic & foreground service stayed alive!
        _pcmAccumulator.clear();
        _syncConfigToDesktop();
        client.sendControl({'cmd': 'audio_state', 'streaming': true});
        statusText.value = 'Streaming 48 kHz Mono PCM (Lock-safe)';
        _refreshNotification();
      } else if (client.isReconnecting.value) {
        // Keep mic & FGS alive so Android 14+ lets us resume while locked
        statusText.value = 'Connection lost — auto-reconnecting...';
        ForegroundMicService.updateStatus(
          title: 'AirCast Reconnecting...',
          text: 'Waiting for PC (${client.lastHost.value})',
          isMuted: isMuted.value,
        );
      } else {
        stopStreaming(reason: 'Disconnected from PC');
      }
    });

    // If auto-reconnect gives up completely, cleanly release the mic & FGS
    _reconnectingWorker = ever(client.isReconnecting, (bool reconnecting) {
      if (!reconnecting && !client.isConnected.value && isStreaming.value) {
        stopStreaming(reason: 'Disconnected (reconnect timed out)');
      }
    });

    // Smooth UI meter updates at ~25 FPS
    _uiMeterTimer = Timer.periodic(const Duration(milliseconds: 40), (_) {
      if (!isStreaming.value || !client.isConnected.value) {
        if (meterLevel.value > 0.001) meterLevel.value = 0.0;
        if (isClipping.value) isClipping.value = false;
        return;
      }

      final target = isMuted.value ? 0.0 : _pendingRawLevel;
      final current = meterLevel.value;
      final factor = target > current ? 0.65 : 0.22;
      meterLevel.value = current + (target - current) * factor;
      isClipping.value = !isMuted.value && _pendingClipping;
      _pendingClipping = false;
    });

    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      packetsSentPerSec.value = _packetsCounter;
      _packetsCounter = 0;
    });
  }

  @override
  void onReady() {
    super.onReady();
    refreshBatteryStatus();
  }

  Future<void> refreshBatteryStatus() async {
    isBatteryUnrestricted.value =
    await ForegroundMicService.isIgnoringBatteryOptimizations();
  }

  Future<void> requestUnrestrictedBattery() async {
    await ForegroundMicService.requestIgnoreBatteryOptimization();
    await Future.delayed(const Duration(milliseconds: 400));
    await refreshBatteryStatus();
  }

  void _onForegroundTaskData(Object data) {
    if (data is! Map) return;
    final action = data['action'] as String?;
    if (action == 'toggle_mute') {
      toggleMute();
    } else if (action == 'stop_mic') {
      stopStreaming(reason: 'Stopped from notification');
    }
  }

  Future<void> startStreaming({bool keepServiceAlive = false}) async {
    if (isBusy.value || isStreaming.value) return;
    if (!client.isConnected.value) {
      statusText.value = 'Connect to PC first';
      return;
    }

    isBusy.value = true;
    statusText.value = 'Checking microphone permission...';

    try {
      // 1. Must verify RECORD_AUDIO BEFORE starting a microphone FGS on Android 14+
      final permitted = await _recorder.hasPermission();
      if (!permitted) {
        statusText.value = 'Microphone permission denied';
        Get.snackbar(
          'Permission Required',
          'Allow Microphone access in Android settings to stream audio.',
          snackPosition: SnackPosition.BOTTOM,
        );
        return;
      }

      // 2. Start lock-screen Foreground Service (WakeLock + Wi-Fi Lock)
      if (!keepServiceAlive) {
        final fgsStarted = await ForegroundMicService.start(
          serverName: client.serverName.value,
          isMuted: isMuted.value,
        );
        if (!fgsStarted) {
          client.log('Warning: Foreground service did not start cleanly');
        }
      }

      _pcmAccumulator.clear();
      _syncConfigToDesktop();

      // 3. Start raw 48 kHz PCM capture on the primary bottom microphone
      final stream = await _recorder.startStream(
        RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: AudioConfig.defaultSampleRate,
          numChannels: AudioConfig.defaultChannels,
          noiseSuppress: noiseSuppression.value,
          echoCancel: echoCancellation.value,
          autoGain: false,
          androidConfig: const AndroidRecordConfig(
            audioSource: AndroidAudioSource.mic,
          ),
        ),
      );

      _audioSub = stream.listen(
        _onRawPcmChunk,
        onError: (e) {
          client.log('Mic stream error: $e');
          stopStreaming(reason: 'Mic interrupted ($e)');
        },
        onDone: () {
          if (isStreaming.value) {
            stopStreaming(reason: 'Mic stream closed by system');
          }
        },
        cancelOnError: true,
      );

      isStreaming.value = true;
      statusText.value = 'Streaming 48 kHz Mono PCM (Lock-safe)';
      client.sendControl({'cmd': 'audio_state', 'streaming': true});
      client.log('Mic streaming started (Foreground Service active)');
      await refreshBatteryStatus();
    } catch (e) {
      client.log('Failed to start mic: $e');
      statusText.value = 'Error: $e';
      await _cleanupRecorder();
      if (!keepServiceAlive) {
        await ForegroundMicService.stop();
      }
    } finally {
      isBusy.value = false;
    }
  }

  void _onRawPcmChunk(Uint8List rawChunk) {
    if (!isStreaming.value) return;

    // While auto-reconnecting, keep recorder warm and drop stale frames cleanly
    if (!client.isConnected.value) {
      _pcmAccumulator.clear();
      return;
    }

    _pcmAccumulator.add(rawChunk);
    if (_pcmAccumulator.length < AudioConfig.frameBytes20ms) return;

    final allBytes = _pcmAccumulator.takeBytes();
    var offset = 0;
    const frameSize = AudioConfig.frameBytes20ms;

    while (allBytes.length - offset >= frameSize) {
      if (isMuted.value) {
        _pendingRawLevel = 0.0;
        _pendingClipping = false;
        if (client.sendAudioFrame(_silenceFrame)) {
          _packetsCounter++;
        }
      } else {
        final frame = Uint8List.fromList(
          Uint8List.sublistView(allBytes, offset, offset + frameSize),
        );
        PcmUtils.applyGainInPlace(frame, gain.value);

        final stats = PcmUtils.analyze(frame);
        _pendingRawLevel = stats.level;
        if (stats.isClipping) _pendingClipping = true;

        if (client.sendAudioFrame(frame)) {
          _packetsCounter++;
        }
      }
      offset += frameSize;
    }

    if (offset < allBytes.length) {
      _pcmAccumulator.add(Uint8List.sublistView(allBytes, offset));
    }
  }

  Future<void> stopStreaming({
    String reason = 'Stopped',
    bool keepServiceAlive = false,
  }) async {
    if (isBusy.value && !isStreaming.value) return;
    isBusy.value = true;
    try {
      await _cleanupRecorder();
      if (!keepServiceAlive) {
        await ForegroundMicService.stop();
      }
      isStreaming.value = false;
      _pendingRawLevel = 0.0;
      meterLevel.value = 0.0;
      statusText.value = reason;
      if (client.isConnected.value) {
        client.sendControl({'cmd': 'audio_state', 'streaming': false});
      }
      client.log('Mic streaming stopped ($reason)');
    } finally {
      isBusy.value = false;
    }
  }

  void toggleMute() {
    isMuted.value = !isMuted.value;
    _syncConfigToDesktop();
    if (isStreaming.value) {
      _refreshNotification();
    }
  }

  void updateGain(double value) {
    gain.value = value.clamp(0.0, 2.0);
  }

  void commitGain() {
    _syncConfigToDesktop();
  }

  Future<void> toggleNoiseSuppression(bool enabled) async {
    if (isBusy.value) return;
    noiseSuppression.value = enabled;
    await _restartIfStreaming();
  }

  Future<void> toggleEchoCancellation(bool enabled) async {
    if (isBusy.value) return;
    echoCancellation.value = enabled;
    await _restartIfStreaming();
  }

  Future<void> _restartIfStreaming() async {
    _syncConfigToDesktop();
    if (!isStreaming.value) return;

    client.sendControl({'cmd': 'audio_reconfig'});
    await stopStreaming(
      reason: 'Applying audio filter...',
      keepServiceAlive: true,
    );
    await startStreaming(keepServiceAlive: true);
  }

  void _refreshNotification() {
    ForegroundMicService.updateStatus(
      title: isMuted.value ? 'AirCast Mic (Muted)' : 'AirCast Mic Active',
      text: 'Streaming 48 kHz PCM to ${client.serverName.value}',
      isMuted: isMuted.value,
    );
  }

  void _syncConfigToDesktop() {
    if (!client.isConnected.value) return;
    client.sendControl({
      'cmd': 'audio_config',
      'config': currentConfig.toJson(),
    });
  }

  Future<void> _cleanupRecorder() async {
    await _audioSub?.cancel();
    _audioSub = null;
    _pcmAccumulator.clear();
    try {
      if (await _recorder.isRecording()) {
        await _recorder.stop();
      }
    } catch (_) {}
  }

  @override
  void onClose() {
    FlutterForegroundTask.removeTaskDataCallback(_onForegroundTaskData);
    _connectionWorker?.dispose();
    _reconnectingWorker?.dispose();
    _uiMeterTimer?.cancel();
    _statsTimer?.cancel();
    _cleanupRecorder();
    ForegroundMicService.stop();
    _recorder.dispose();
    super.onClose();
  }
}