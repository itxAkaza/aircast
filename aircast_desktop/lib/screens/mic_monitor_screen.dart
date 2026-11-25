import 'package:aircast_desktop/controller/mic_monitor_controller.dart';
import 'package:aircast_desktop/controller/server_controller.dart';
import 'package:aircast_desktop/services/native_audio_service.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class MicMonitorScreen extends StatelessWidget {
  const MicMonitorScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final server = Get.find<ServerController>();
    final mon = Get.put(MicMonitorController());

    return Scaffold(
      backgroundColor: const Color(0xFF0E0E10),
      appBar: AppBar(
        backgroundColor: const Color(0xFF16161A),
        title: const Text('AirCast Mic Monitor — Phase 2B'),
        actions: [
          TextButton.icon(
            onPressed: mon.initializeAudioHardware,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Re-check VB-Cable'),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: Obx(() {
        final cfg = server.remoteAudioConfig.value;
        final receiving = mon.isReceivingAudio.value;
        final deskMuted = mon.isDesktopMuted.value;
        final phoneMuted = cfg.isMuted;
        final cableStatus = mon.vbCableStatus.value;

        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
            // Top Status Pills + Emergency Mute
            Row(
              children: [
                _Pill(
                  label: server.isClientConnected.value
                      ? 'Phone: ${server.connectedDevice.value}'
                      : 'No Phone Connected',
                  color: server.isClientConnected.value
                      ? Colors.greenAccent
                      : Colors.white38,
                ),
                const SizedBox(width: 10),
                _Pill(
                  label: receiving ? 'Receiving Audio' : 'Stream Idle',
                  color: receiving ? Colors.cyanAccent : Colors.amberAccent,
                ),
                const SizedBox(width: 10),
                _Pill(
                  label: mon.isCableRouted.value
                      ? 'VB-Cable Active'
                      : 'VB-Cable Inactive',
                  color: mon.isCableRouted.value
                      ? Colors.greenAccent
                      : Colors.orangeAccent,
                ),
                if (phoneMuted) ...[
                  const SizedBox(width: 10),
                  const _Pill(label: 'Phone Muted', color: Colors.orangeAccent),
                ],
                const Spacer(),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor:
                    deskMuted ? Colors.redAccent : const Color(0xFF26262E),
                  ),
                  onPressed: mon.toggleDesktopMute,
                  icon: Icon(deskMuted ? Icons.volume_off : Icons.volume_up),
                  label: Text(deskMuted ? 'Desktop Muted' : 'Emergency Mute'),
                ),
              ],
            ),

            const SizedBox(height: 20),

            // VB-Cable Installation & Setup Card (Shown when missing or disabled)
            if (cableStatus != VbCableStatus.ready ||
                mon.audioRouterError.value.isNotEmpty) ...[
              _VbCableSetupCard(
                status: cableStatus,
                errorText: mon.audioRouterError.value,
                onOpenDownload: mon.openVbCableDownloadPage,
                onRecheck: mon.initializeAudioHardware,
              ),
              const SizedBox(height: 20),
            ],

            // 24-Bar Live VU / Beat Meter Card
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: const Color(0xFF16161A),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color:
                  mon.isClipping.value ? Colors.redAccent : Colors.white12,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Incoming Voice Level (48 kHz 16-bit PCM)',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      Text(
                        mon.isClipping.value
                            ? 'CLIPPING!'
                            : '${(mon.meterLevel.value * 100).round()}%',
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: mon.isClipping.value
                              ? Colors.redAccent
                              : Colors.greenAccent,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  _SegmentedBeatMeter(level: mon.meterLevel.value),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // Telemetry Cards
            Row(
              children: [
                Expanded(
                  child: _StatTile(
                    label: 'Throughput',
                    value: '${mon.kbps.value.toStringAsFixed(1)} KB/s',
                    hint: '${mon.packetsPerSec.value} pkt/s (20ms)',
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: _StatTile(
                    label: 'Jitter Buffer',
                    value: '${mon.bufferLatencyMs.value} ms',
                    hint: 'Underruns: ${mon.underrunCount.value}',
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: _StatTile(
                    label: 'Phone Gain',
                    value: '${cfg.gain.toStringAsFixed(2)}x',
                    hint: cfg.noiseSuppression
                        ? 'Noise Cancel: ON'
                        : 'Noise Cancel: OFF',
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: _StatTile(
                    label: 'Virtual Mic Output',
                    value: mon.isCableRouted.value ? 'CABLE Input' : 'Offline',
                    hint: 'Select CABLE Output in apps',
                  ),
                ),
              ],
            ),

            const SizedBox(height: 20),

            // Speaker Loopback Card (Material wrapper prevents ListTile warning)
            Material(
              color: const Color(0xFF16161A),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(
                  color: mon.isLoopbackEnabled.value
                      ? Colors.amberAccent.withValues(alpha: 0.5)
                      : Colors.white12,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: SwitchListTile(
                secondary: Icon(
                  Icons.headphones,
                  color: mon.isLoopbackEnabled.value
                      ? Colors.amberAccent
                      : Colors.white54,
                ),
                title: const Text(
                  'Speaker Loopback (Monitor Your Voice)',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: const Text(
                  'Use headphones — playing through PC speakers near your phone will cause loud feedback echo.',
                  style: TextStyle(fontSize: 12, color: Colors.white60),
                ),
                value: mon.isLoopbackEnabled.value,
                onChanged: mon.isCableRouted.value ? mon.toggleLoopback : null,
              ),
            ),
          ],
        );
      }),
    );
  }
}

class _VbCableSetupCard extends StatelessWidget {
  final VbCableStatus status;
  final String errorText;
  final VoidCallback onOpenDownload;
  final VoidCallback onRecheck;

  const _VbCableSetupCard({
    required this.status,
    required this.errorText,
    required this.onOpenDownload,
    required this.onRecheck,
  });

  @override
  Widget build(BuildContext context) {
    final isDisabledOutput = status == VbCableStatus.outputDisabled;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF231A12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.orangeAccent.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.warning_amber_rounded,
                  color: Colors.orangeAccent, size: 26),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  isDisabledOutput
                      ? 'VB-Cable Recording Endpoint Disabled'
                      : 'VB-Audio Virtual Cable Not Installed',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.orangeAccent,
                  ),
                ),
              ),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                    backgroundColor: Colors.orangeAccent,
                    foregroundColor: Colors.black),
                onPressed: onOpenDownload,
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Text('Download VB-Cable'),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: onRecheck,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Re-check Device'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (errorText.isNotEmpty) ...[
            Text(errorText,
                style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
            const SizedBox(height: 8),
          ],
          Text(
            isDisabledOutput
                ? 'CABLE Input was found, but CABLE Output is disabled in Windows:\n'
                '1. Press Win + R, type mmsys.cpl, and press Enter.\n'
                '2. Open the Recording tab, right-click "CABLE Output", and click Enable.\n'
                '3. Click Re-check Device above.'
                : 'AirCast routes your phone mic into VB-Cable so Discord, games, and Zoom recognize it as a standard Windows microphone:\n'
                '1. Click "Download VB-Cable" to open the official VB-Audio website and download the Windows VBCABLE Driver Pack.\n'
                '2. Extract the downloaded ZIP file into a folder.\n'
                '3. Right-click the Windows x64 Setup installer inside the extracted folder -> Run as administrator -> Install Driver.\n'
                '4. Restart Windows if prompted, then click "Re-check Device".',
            style: const TextStyle(
                color: Colors.white70, fontSize: 13, height: 1.45),
          ),
        ],
      ),
    );
  }
}

class _SegmentedBeatMeter extends StatelessWidget {
  final double level;
  const _SegmentedBeatMeter({required this.level});

  @override
  Widget build(BuildContext context) {
    const barCount = 24;
    final activeBars = (level * barCount).round().clamp(0, barCount);

    return SizedBox(
      height: 54,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: List.generate(barCount, (i) {
          final isLit = i < activeBars;
          Color barColor;
          if (i >= 20) {
            barColor = Colors.redAccent;
          } else if (i >= 15) {
            barColor = Colors.amberAccent;
          } else {
            barColor = Colors.greenAccent;
          }

          return Expanded(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 2),
              height: 24 + (i * 1.25),
              decoration: BoxDecoration(
                color: isLit ? barColor : Colors.white10,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          );
        }),
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  final String label;
  final String value;
  final String hint;

  const _StatTile({
    required this.label,
    required this.value,
    required this.hint,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF16161A),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(color: Colors.white54, fontSize: 12)),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(hint,
              style: const TextStyle(color: Colors.white38, fontSize: 11)),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String label;
  final Color color;

  const _Pill({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        label,
        style:
        TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 13),
      ),
    );
  }
}