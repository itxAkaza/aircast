import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../controller/client_controller.dart';
import '../controller/mic_controller.dart';

class MicTestScreen extends StatelessWidget {
  const MicTestScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final client = Get.find<ClientController>();
    final mic = Get.put(MicController());

    return Scaffold(
      backgroundColor: const Color(0xFF0E0E10),
      appBar: AppBar(
        backgroundColor: const Color(0xFF16161A),
        title: const Text('Mic Stream Test (Phase 2A)'),
      ),
      body: Obx(() {
        final connected = client.isConnected.value;
        final streaming = mic.isStreaming.value;
        final muted = mic.isMuted.value;

        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            // Connection & Stream Header
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF16161A),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: streaming ? Colors.greenAccent.withValues(alpha: 0.5) : Colors.white12,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        connected ? 'PC: ${client.serverName.value}' : 'PC Disconnected',
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                      ),
                      Text(
                        '${mic.packetsSentPerSec.value} pkt/s',
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          color: Colors.white70,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    mic.statusText.value,
                    style: TextStyle(
                      color: streaming ? Colors.greenAccent : Colors.white60,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 16),
                  // Live Local Input Meter
                  Row(
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: LinearProgressIndicator(
                            value: mic.meterLevel.value,
                            minHeight: 14,
                            backgroundColor: Colors.white10,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              mic.isClipping.value
                                  ? Colors.redAccent
                                  : (mic.meterLevel.value > 0.78
                                  ? Colors.amberAccent
                                  : Colors.greenAccent),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      SizedBox(
                        width: 46,
                        child: Text(
                          mic.isClipping.value
                              ? 'CLIP!'
                              : '${(mic.meterLevel.value * 100).round()}%',
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontWeight: FontWeight.bold,
                            color: mic.isClipping.value ? Colors.redAccent : Colors.white70,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // Start / Stop + Mute Controls
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      backgroundColor: streaming ? Colors.redAccent : Colors.green,
                    ),
                    onPressed: (!connected || mic.isBusy.value)
                        ? null
                        : () => streaming ? mic.stopStreaming() : mic.startStreaming(),
                    icon: Icon(streaming ? Icons.stop : Icons.mic),
                    label: Text(streaming ? 'Stop Mic' : 'Start Mic'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.tonalIcon(
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      backgroundColor: muted ? Colors.amber.withValues(alpha: 0.25) : null,
                    ),
                    onPressed: mic.toggleMute,
                    icon: Icon(
                      muted ? Icons.mic_off : Icons.mic_none,
                      color: muted ? Colors.amberAccent : null,
                    ),
                    label: Text(muted ? 'Muted' : 'Mute'),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 20),

            // Gain Slider Card
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF16161A),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Digital Mic Gain (16-bit PCM)',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        '${mic.gain.value.toStringAsFixed(2)}x',
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.bold,
                          color: Colors.greenAccent,
                        ),
                      ),
                    ],
                  ),
                  Slider(
                    value: mic.gain.value,
                    min: 0.0,
                    max: 2.0,
                    divisions: 40,
                    onChanged: mic.updateGain,
                    onChangeEnd: (_) => mic.commitGain(),
                  ),
                  const Text(
                    'Values above 1.0x boost voice and room noise; clamping protects against harsh wrap-around.',
                    style: TextStyle(fontSize: 12, color: Colors.white54),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // Hardware Audio Filters Card
            // Hardware Audio Filters Card
            Material(
              color: const Color(0xFF16161A),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: const BorderSide(color: Colors.white12),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  SwitchListTile(
                    title: const Text('Noise Cancellation'),
                    subtitle: const Text(
                      'Best-effort Android hardware NoiseSuppressor (restarts stream)',
                      style: TextStyle(fontSize: 12, color: Colors.white54),
                    ),
                    value: mic.noiseSuppression.value,
                    onChanged: mic.isBusy.value ? null : mic.toggleNoiseSuppression,
                  ),
                  const Divider(height: 1, color: Colors.white12),
                  SwitchListTile(
                    title: const Text('Echo Cancellation'),
                    subtitle: const Text(
                      'Helps reduce speaker bleed when testing near PC',
                      style: TextStyle(fontSize: 12, color: Colors.white54),
                    ),
                    value: mic.echoCancellation.value,
                    onChanged: mic.isBusy.value ? null : mic.toggleEchoCancellation,
                  ),
                ],
              ),
            ),
          ],
        );
      }),
    );
  }
}