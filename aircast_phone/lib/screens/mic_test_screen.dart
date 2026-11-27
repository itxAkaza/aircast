import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../controller/client_controller.dart';
import '../controller/mic_controller.dart';

class MicTestScreen extends StatelessWidget {
  const MicTestScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final client = Get.find<ClientController>();
    final mic = Get.isRegistered<MicController>()
        ? Get.find<MicController>()
        : Get.put(MicController(), permanent: true);

    return Scaffold(
      backgroundColor: const Color(0xFF0E0E10),
      appBar: AppBar(
        backgroundColor: const Color(0xFF16161A),
        title: const Text('AirCast Mic — Phase 2C'),
      ),
      body: Obx(() {
        final connected = client.isConnected.value;
        final reconnecting = client.isReconnecting.value;
        final streaming = mic.isStreaming.value;
        final muted = mic.isMuted.value;

        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            // Battery Optimization Banner (prevents Android from killing Wi-Fi on lock)
            if (!mic.isBatteryUnrestricted.value) ...[
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFF231A12),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: Colors.amberAccent.withValues(alpha: 0.5),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.battery_alert, color: Colors.amberAccent),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        'Allow unrestricted battery so Android does not pause Wi-Fi when the screen locks.',
                        style: TextStyle(fontSize: 12, color: Colors.white70),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.amberAccent,
                        foregroundColor: Colors.black,
                      ),
                      onPressed: mic.requestUnrestrictedBattery,
                      child: const Text('Allow'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Connection & Stream Header
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF16161A),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: reconnecting
                      ? Colors.amberAccent.withValues(alpha: 0.7)
                      : (streaming
                      ? Colors.greenAccent.withValues(alpha: 0.5)
                      : Colors.white12),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          connected
                              ? 'PC: ${client.serverName.value}'
                              : (reconnecting
                              ? 'Reconnecting (#${client.reconnectAttempt.value})...'
                              : 'PC Disconnected'),
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
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
                      color: reconnecting
                          ? Colors.amberAccent
                          : (streaming ? Colors.greenAccent : Colors.white60),
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 16),
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
                            color: mic.isClipping.value
                                ? Colors.redAccent
                                : Colors.white70,
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
                      backgroundColor:
                      streaming ? Colors.redAccent : Colors.green,
                    ),
                    onPressed: ((!connected && !streaming) || mic.isBusy.value)
                        ? null
                        : () => streaming
                        ? mic.stopStreaming()
                        : mic.startStreaming(),
                    icon: Icon(streaming ? Icons.stop : Icons.mic),
                    label: Text(streaming ? 'Stop Mic' : 'Start Mic'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.tonalIcon(
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      backgroundColor: muted
                          ? Colors.amber.withValues(alpha: 0.25)
                          : null,
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
                    'Keep around 1.0x for natural voice; higher values amplify room noise.',
                    style: TextStyle(fontSize: 12, color: Colors.white54),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // Hardware Audio Filters Card (Material wrapper prevents ListTile spam)
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
                      'Optional Android DSP filter (off = natural voice, restarts stream)',
                      style: TextStyle(fontSize: 12, color: Colors.white54),
                    ),
                    value: mic.noiseSuppression.value,
                    onChanged:
                    mic.isBusy.value ? null : mic.toggleNoiseSuppression,
                  ),
                  const Divider(height: 1, color: Colors.white12),
                  SwitchListTile(
                    title: const Text('Echo Cancellation'),
                    subtitle: const Text(
                      'Only enable if testing without headphones',
                      style: TextStyle(fontSize: 12, color: Colors.white54),
                    ),
                    value: mic.echoCancellation.value,
                    onChanged:
                    mic.isBusy.value ? null : mic.toggleEchoCancellation,
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