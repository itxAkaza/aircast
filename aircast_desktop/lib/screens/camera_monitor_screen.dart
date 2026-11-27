import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:shared_protocol/shared_protocol.dart';
import 'package:window_manager/window_manager.dart';
import '../controller/video_server_controller.dart';

class CameraMonitorScreen extends StatelessWidget {
  const CameraMonitorScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = Get.isRegistered<VideoServerController>()
        ? Get.find<VideoServerController>()
        : Get.put(VideoServerController(), permanent: true);

    return Obx(() {
      if (c.isPipMode.value) {
        return _buildPipView(c);
      }
      return _buildFullDashboard(c);
    });
  }

  /// Compact, draggable, always-on-top 16:9 floating preview
  Widget _buildPipView(VideoServerController c) {
    final img = c.previewImage.value;
    final privacy = c.privacyCut.value;

    return Scaffold(
      backgroundColor: Colors.black,
      body: DragToMoveArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (privacy)
              const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.videocam_off, color: Colors.redAccent, size: 32),
                    SizedBox(height: 6),
                    Text('PRIVACY CUT', style: TextStyle(fontWeight: FontWeight.bold)),
                  ],
                ),
              )
            else if (img != null)
              RawImage(image: img, fit: BoxFit.contain)
            else
              const Center(
                child: Text(
                  'Waiting for video...',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ),

            // Top-right compact PiP controls
            Positioned(
              top: 8,
              right: 8,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.65),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: privacy ? 'Resume Camera' : 'Privacy Cut',
                      icon: Icon(
                        privacy ? Icons.videocam_off : Icons.videocam,
                        size: 18,
                        color: privacy ? Colors.redAccent : Colors.greenAccent,
                      ),
                      onPressed: c.togglePrivacyCut,
                    ),
                    IconButton(
                      tooltip: 'Expand to Full Window',
                      icon: const Icon(Icons.open_in_full, size: 18, color: Colors.white),
                      onPressed: c.togglePipMode,
                    ),
                  ],
                ),
              ),
            ),

            // Bottom-left FPS badge
            Positioned(
              bottom: 8,
              left: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.65),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  c.isReceivingVideo.value
                      ? '${c.decodedFps.value} FPS • ${c.mbps.value.toStringAsFixed(1)} Mbps'
                      : (c.isTestPatternRunning.value ? 'TEST 30 FPS' : 'STANDBY'),
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: Colors.white70,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFullDashboard(VideoServerController c) {
    final reg = c.isVcamRegistered.value;
    final live = c.isReceivingVideo.value;
    final testRunning = c.isTestPatternRunning.value;
    final privacy = c.privacyCut.value;
    final img = c.previewImage.value;

    return Scaffold(
      backgroundColor: const Color(0xFF0E0E10),
      appBar: AppBar(
        backgroundColor: const Color(0xFF16161A),
        title: const Text('AirCast Camera Monitor — Phase 3B'),
        actions: [
          FilledButton.tonalIcon(
            onPressed: c.togglePipMode,
            icon: const Icon(Icons.picture_in_picture_alt, size: 18),
            label: const Text('Pop-out PiP'),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: privacy ? Colors.redAccent : const Color(0xFF2B2B35),
            ),
            onPressed: c.togglePrivacyCut,
            icon: Icon(privacy ? Icons.videocam_off : Icons.shield_outlined, size: 18),
            label: Text(privacy ? 'Privacy Cut ON' : 'Privacy Cut'),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // Top Status Pills + Virtual Camera Registration
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF16161A),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: reg
                    ? Colors.greenAccent.withValues(alpha: 0.45)
                    : Colors.orangeAccent.withValues(alpha: 0.6),
              ),
            ),
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 10,
              runSpacing: 10,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      reg ? Icons.videocam : Icons.videocam_off,
                      color: reg ? Colors.greenAccent : Colors.orangeAccent,
                    ),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            reg ? 'AirCast Camera: Registered' : 'AirCast Camera: Not Registered',
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            c.statusMessage.value,
                            style: const TextStyle(fontSize: 12, color: Colors.white60),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                OutlinedButton.icon(
                  onPressed: c.isEngineReady.value ? c.toggleTestPattern : null,
                  icon: Icon(testRunning ? Icons.stop : Icons.tv, size: 18),
                  label: Text(testRunning ? 'Stop Test Bars' : 'Test Bars'),
                ),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: reg ? const Color(0xFF2B2B35) : Colors.deepOrangeAccent,
                  ),
                  onPressed: c.isEngineReady.value ? () => c.toggleRegistration(!reg) : null,
                  icon: Icon(reg ? Icons.delete_outline : Icons.admin_panel_settings, size: 18),
                  label: Text(reg ? 'Unregister' : 'Register VCam'),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // Live 16:9 Native Preview Canvas
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF111115),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: privacy
                      ? Colors.redAccent
                      : (live
                      ? Colors.greenAccent.withValues(alpha: 0.6)
                      : (testRunning ? Colors.cyanAccent.withValues(alpha: 0.6) : Colors.white12)),
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (privacy)
                    const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.videocam_off, color: Colors.redAccent, size: 48),
                          SizedBox(height: 8),
                          Text(
                            'Emergency Privacy Cut Active\nVirtual Camera is showing dark Standby slate',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white70),
                          ),
                        ],
                      ),
                    )
                  else if (!c.previewEnabled.value)
                    const Center(
                      child: Text(
                        'Preview Paused (Zero GPU overhead — Virtual Camera stays live)',
                        style: TextStyle(color: Colors.white54),
                      ),
                    )
                  else if (img != null)
                      RawImage(image: img, fit: BoxFit.contain)
                    else
                      const Center(
                        child: Text(
                          'Waiting for Phone Camera on Port 4821 — or click "Test Bars" to verify AirCast Camera',
                          style: TextStyle(color: Colors.white54),
                        ),
                      ),

                  // Preview Toggle overlay button
                  Positioned(
                    top: 10,
                    right: 10,
                    child: FilledButton.tonalIcon(
                      onPressed: c.togglePreviewEnabled,
                      icon: Icon(
                        c.previewEnabled.value ? Icons.visibility_off : Icons.visibility,
                        size: 16,
                      ),
                      label: Text(c.previewEnabled.value ? 'Hide Preview' : 'Show Preview'),
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Transform Controls Bar (Fit/Fill, Mirror, Rotate)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF16161A),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white12),
            ),
            child: Wrap(
              spacing: 12,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text('Framing:', style: TextStyle(fontWeight: FontWeight.w600)),
                SegmentedButton<VideoFitMode>(
                  segments: const [
                    ButtonSegment(value: VideoFitMode.fill, label: Text('Fill (Crop)')),
                    ButtonSegment(value: VideoFitMode.fit, label: Text('Fit (Full)')),
                  ],
                  selected: {c.fitMode.value},
                  onSelectionChanged: (s) => c.setFitMode(s.first),
                ),
                FilledButton.tonalIcon(
                  onPressed: c.toggleMirror,
                  icon: Icon(
                    Icons.flip,
                    color: c.mirrorHorizontal.value ? Colors.deepOrangeAccent : null,
                  ),
                  label: Text(c.mirrorHorizontal.value ? 'Mirrored' : 'Mirror'),
                ),
                FilledButton.tonalIcon(
                  onPressed: c.rotate90,
                  icon: const Icon(Icons.rotate_right),
                  label: Text('Rotate (${c.extraRotation.value}°)'),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // Telemetry Cards Row
          Row(
            children: [
              _statCard(
                'Video FPS',
                live ? '${c.decodedFps.value} / ${c.receivedFps.value}' : (testRunning ? '30 FPS' : '0'),
                'Decoded / Received',
              ),
              const SizedBox(width: 12),
              _statCard(
                'Bitrate',
                '${c.mbps.value.toStringAsFixed(2)} Mbps',
                'Avg ${c.avgFrameKb.value.toStringAsFixed(1)} KB/frame',
              ),
              const SizedBox(width: 12),
              _statCard(
                'Source',
                c.resolutionLabel.value,
                'Output locked 1280×720',
              ),
              const SizedBox(width: 12),
              _statCard(
                'Dropped',
                '${c.droppedFrames.value}',
                'Latest-frame-wins queue',
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _statCard(String title, String value, String sub) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF16161A),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontSize: 12, color: Colors.white54)),
            const SizedBox(height: 6),
            Text(
              value,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(sub, style: const TextStyle(fontSize: 11, color: Colors.white38)),
          ],
        ),
      ),
    );
  }
}