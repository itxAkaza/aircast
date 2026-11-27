import 'dart:async';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../services/native_video_service.dart';

class VcamTestController extends GetxController {
  final NativeVideoService video = NativeVideoService();

  final RxBool isLoaded = false.obs;
  final RxBool isRegistered = false.obs;
  final RxBool isPatternRunning = false.obs;
  final RxInt framesPublished = 0.obs;
  final RxInt approxFps = 0.obs;
  final RxString statusMessage = 'Checking AirCast Camera registration...'.obs;

  Timer? _pollTimer;
  int _lastFrames = 0;

  @override
  void onReady() {
    super.onReady();
    refreshStatus();
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!video.isLoaded) return;
      isPatternRunning.value = video.isTestRunning;
      final total = video.framesPublished;
      approxFps.value = total >= _lastFrames ? (total - _lastFrames) : 0;
      _lastFrames = total;
      framesPublished.value = total;
    });
  }

  void refreshStatus() {
    if (!video.load()) {
      isLoaded.value = false;
      statusMessage.value = 'Failed to load aircast_video.dll: ${video.loadError}';
      return;
    }
    isLoaded.value = true;
    isRegistered.value = video.isVcamRegistered;
    isPatternRunning.value = video.isTestRunning;
    statusMessage.value = isRegistered.value
        ? 'AirCast Camera is registered in Windows (1280x720 @ 30 FPS — YUY2 & RGB24).'
        : 'Virtual camera not registered yet. Click Register below (1-time UAC prompt).';
  }

  void toggleRegistration(bool register) {
    final res = video.setVcamRegistration(register);
    refreshStatus();
    if (res == 1) {
      statusMessage.value = register
          ? 'Registered! Restart OBS / Discord / Chrome if already open to detect "AirCast Camera".'
          : 'Unregistered cleanly.';
    } else if (res == 0) {
      statusMessage.value = 'UAC prompt was cancelled.';
    } else if (res == -1) {
      statusMessage.value = 'aircast_vcam.dll was not found beside aircast_desktop.exe.';
    } else {
      statusMessage.value = 'regsvr32 failed. Close OBS/Discord/Chrome first if the DLL is in use.';
    }
  }

  void toggleTestPattern() {
    if (isPatternRunning.value) {
      video.stopTestPattern();
      isPatternRunning.value = false;
      approxFps.value = 0;
      statusMessage.value = 'Test pattern stopped (AirCast Camera will hold 1s then show Standby slate).';
    } else {
      final ok = video.startTestPattern();
      isPatternRunning.value = ok;
      statusMessage.value = ok
          ? 'Streaming live 1280x720 @ 30 FPS moving SMPTE bars into Shared Memory!'
          : 'Failed to open Shared Memory.';
    }
  }

  @override
  void onClose() {
    _pollTimer?.cancel();
    video.dispose();
    super.onClose();
  }
}

class VcamTestScreen extends StatelessWidget {
  const VcamTestScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = Get.put(VcamTestController());

    return Scaffold(
      backgroundColor: const Color(0xFF0E0E10),
      appBar: AppBar(
        backgroundColor: const Color(0xFF16161A),
        title: const Text('AirCast Virtual Camera — Phase 3A Spike'),
        actions: [
          TextButton.icon(
            onPressed: c.refreshStatus,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Re-check'),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: Obx(() {
        final reg = c.isRegistered.value;
        final running = c.isPatternRunning.value;

        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFF16161A),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: reg
                      ? Colors.greenAccent.withValues(alpha: 0.5)
                      : Colors.orangeAccent.withValues(alpha: 0.6),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        reg ? Icons.videocam : Icons.videocam_off,
                        color: reg ? Colors.greenAccent : Colors.orangeAccent,
                        size: 28,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          reg ? 'AirCast Camera: Registered' : 'AirCast Camera: Not Registered',
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                      ),
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: reg ? const Color(0xFF2B2B35) : Colors.deepOrangeAccent,
                        ),
                        onPressed: c.isLoaded.value ? () => c.toggleRegistration(!reg) : null,
                        icon: Icon(reg ? Icons.delete_outline : Icons.admin_panel_settings),
                        label: Text(reg ? 'Unregister' : 'Register Virtual Camera'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    c.statusMessage.value,
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFF16161A),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: running ? Colors.cyanAccent.withValues(alpha: 0.6) : Colors.white12,
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Triple-Buffer Shared Memory Feeder',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          running
                              ? 'Live: ${c.approxFps.value} FPS  •  Total frames: ${c.framesPublished.value}'
                              : 'Idle — Virtual Camera outputs dark Standby Slate',
                          style: TextStyle(
                            fontFamily: 'monospace',
                            color: running ? Colors.cyanAccent : Colors.white54,
                          ),
                        ),
                      ],
                    ),
                  ),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                      backgroundColor: running ? Colors.redAccent : Colors.green,
                    ),
                    onPressed: c.isLoaded.value ? c.toggleTestPattern : null,
                    icon: Icon(running ? Icons.stop : Icons.play_arrow),
                    label: Text(running ? 'Stop Test Bars' : 'Start 30 FPS Test Bars'),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: const Color(0xFF16161A),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white12),
              ),
              child: const Text(
                'Phase 3A Verification Steps:\n'
                    '1. Click "Register Virtual Camera" and accept the Windows UAC prompt.\n'
                    '2. Click "Start 30 FPS Test Bars".\n'
                    '3. Open OBS Studio (Add -> Video Capture Device), Discord (Settings -> Voice & Video), '
                    'or Chrome (webcamtests.com) and select "AirCast Camera".\n'
                    '4. Verify smooth moving SMPTE color bars + orange bouncing box, then click "Stop Test Bars" '
                    'and confirm it cleanly switches to the dark Standby slate without freezing the app.',
                style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.5),
              ),
            ),
          ],
        );
      }),
    );
  }
}