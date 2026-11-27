import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:shared_protocol/shared_protocol.dart';
import '../controller/camera_stream_controller.dart';
import '../controller/client_controller.dart';

class CameraScreen extends StatelessWidget {
  const CameraScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final client = Get.find<ClientController>();
    final cam = Get.put(CameraStreamController());

    return Obx(() {
      // 1-Tap OLED Blackout Mode (keeps camera alive while screen looks off)
      if (cam.isBlackoutMode.value) {
        return GestureDetector(
          onDoubleTap: () => cam.setBlackoutMode(false),
          child: Scaffold(
            backgroundColor: Colors.black,
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.nightlight_round, color: Colors.white12, size: 36),
                  const SizedBox(height: 10),
                  Text(
                    cam.isStreaming.value
                        ? 'AirCast Streaming (${cam.sentFps.value} FPS)'
                        : 'OLED Blackout Active',
                    style: const TextStyle(color: Colors.white24, fontSize: 13),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Double-tap anywhere to wake screen',
                    style: TextStyle(color: Colors.white12, fontSize: 11),
                  ),
                ],
              ),
            ),
          ),
        );
      }

      final connected = client.isConnected.value;
      final streaming = cam.isStreaming.value;
      final texId = cam.textureId.value;

      return Scaffold(
        backgroundColor: const Color(0xFF0E0E10),
        appBar: AppBar(
          backgroundColor: const Color(0xFF16161A),
          title: const Text('AirCast Camera — Phase 3C'),
          actions: [
            IconButton(
              tooltip: 'OLED Blackout Mode',
              icon: const Icon(Icons.brightness_2_outlined),
              onPressed: () => cam.setBlackoutMode(true),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Zero-Copy Native GPU Viewfinder (Tap-to-Focus enabled)
            AspectRatio(
              aspectRatio: 16 / 9,
              child: LayoutBuilder(
                builder: (ctx, constraints) {
                  return GestureDetector(
                    onTapDown: (details) {
                      final nx = (details.localPosition.dx / constraints.maxWidth).clamp(0.0, 1.0);
                      final ny = (details.localPosition.dy / constraints.maxHeight).clamp(0.0, 1.0);
                      cam.tapToFocus(nx, ny);
                    },
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.black,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: streaming
                              ? Colors.greenAccent.withValues(alpha: 0.6)
                              : Colors.white12,
                        ),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (texId >= 0)
                            Texture(textureId: texId)
                          else
                            Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    cam.statusText.value,
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(color: Colors.white60, fontSize: 13),
                                  ),
                                  const SizedBox(height: 10),
                                  FilledButton.tonal(
                                    onPressed: cam.initPreview,
                                    child: const Text('Retry Preview'),
                                  ),
                                ],
                              ),
                            ),

                          // Live Telemetry Overlay Badge
                          Positioned(
                            top: 10,
                            left: 10,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.65),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                streaming
                                    ? 'LIVE • ${cam.sentFps.value} FPS • ${cam.mbps.value.toStringAsFixed(1)} Mbps • Q${cam.effectiveQuality.value}'
                                    : 'PREVIEW • ${cam.preset.value.label}',
                                style: TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 11,
                                  color: streaming ? Colors.greenAccent : Colors.white70,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),

            const SizedBox(height: 10),
            Text(
              cam.statusText.value,
              style: TextStyle(
                fontSize: 12,
                color: streaming ? Colors.greenAccent : Colors.white60,
              ),
            ),

            const SizedBox(height: 14),

            // Start / Stop + Quick Action Buttons
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 15),
                      backgroundColor: streaming ? Colors.redAccent : Colors.deepOrangeAccent,
                    ),
                    onPressed: (!connected && !streaming) || !cam.isCameraReady.value
                        ? null
                        : () => streaming ? cam.stopStreaming() : cam.startStreaming(),
                    icon: Icon(streaming ? Icons.stop : Icons.videocam),
                    label: Text(streaming ? 'Stop Camera' : 'Start Camera'),
                  ),
                ),
                const SizedBox(width: 10),
                IconButton.filledTonal(
                  tooltip: 'Toggle Torch',
                  onPressed: cam.hasTorch.value ? cam.toggleTorch : null,
                  icon: Icon(
                    cam.torchEnabled.value ? Icons.flash_on : Icons.flash_off,
                    color: cam.torchEnabled.value ? Colors.amberAccent : null,
                  ),
                ),
                const SizedBox(width: 6),
                IconButton.filledTonal(
                  tooltip: 'Mirror Horizontal',
                  onPressed: cam.toggleMirror,
                  icon: Icon(
                    Icons.flip,
                    color: cam.mirrorHorizontal.value ? Colors.deepOrangeAccent : null,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 16),

            // Multi-Lens Selector (Back Main / Ultrawide / Front)
            if (cam.lensLabels.isNotEmpty) ...[
              const Text('Camera Lens', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: List.generate(cam.lensLabels.length, (i) {
                  final selected = cam.activeLensIndex.value == i;
                  return ChoiceChip(
                    label: Text(cam.lensLabels[i]),
                    selected: selected,
                    onSelected: (_) => cam.selectLens(i),
                  );
                }),
              ),
              const SizedBox(height: 16),
            ],

            // Resolution & FPS Presets
            const Text('Stream Preset', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            SegmentedButton<VideoPreset>(
              segments: const [
                ButtonSegment(value: VideoPreset.batterySaver, label: Text('480p 24')),
                ButtonSegment(value: VideoPreset.balanced, label: Text('720p 30')),
                ButtonSegment(value: VideoPreset.highQuality, label: Text('1080p 30')),
              ],
              selected: {cam.preset.value},
              onSelectionChanged: (s) => cam.selectPreset(s.first),
            ),

            const SizedBox(height: 16),

            // Zoom & JPEG Quality Sliders
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF16161A),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white12),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Zoom', style: TextStyle(fontWeight: FontWeight.w600)),
                      Text(
                        '${cam.zoomRatio.value.toStringAsFixed(1)}x',
                        style: const TextStyle(fontFamily: 'monospace', color: Colors.white70),
                      ),
                    ],
                  ),
                  Slider(
                    value: cam.zoomRatio.value.clamp(cam.minZoom.value, cam.maxZoom.value),
                    min: cam.minZoom.value,
                    max: cam.maxZoom.value > cam.minZoom.value ? cam.maxZoom.value : cam.minZoom.value + 1.0,
                    onChanged: cam.updateZoom,
                  ),
                  const Divider(color: Colors.white12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('JPEG Quality (Auto-Backoff)', style: TextStyle(fontWeight: FontWeight.w600)),
                      Text(
                        'Target ${cam.jpegQuality.value}% (Live ${cam.effectiveQuality.value}%)',
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Colors.greenAccent),
                      ),
                    ],
                  ),
                  Slider(
                    value: cam.jpegQuality.value.toDouble(),
                    min: 45,
                    max: 90,
                    divisions: 9,
                    onChanged: (v) => cam.updateQuality(v.round()),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    });
  }
}