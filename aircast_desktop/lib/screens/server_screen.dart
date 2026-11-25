import 'package:aircast_desktop/controller/server_controller.dart';
import 'package:aircast_desktop/screens/mic_monitor_screen.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:qr_flutter/qr_flutter.dart';

class ServerScreen extends StatelessWidget {
  const ServerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = Get.put(ServerController());

    return Scaffold(
      backgroundColor: const Color(0xFF0E0E10),
      appBar: AppBar(
        backgroundColor: const Color(0xFF16161A),
        title: const Text('AirCast Desktop — Phase 2A'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: FilledButton.icon(
              onPressed: () => Get.to(() => const MicMonitorScreen()),
              icon: const Icon(Icons.graphic_eq, size: 18),
              label: const Text('Mic Monitor'),
            ),
          ),
          IconButton(
            tooltip: 'Refresh Network IPs',
            icon: const Icon(Icons.refresh),
            onPressed: c.refreshNetworkInterfaces,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Row(
          children: [
            // Left Panel: QR Code & Connection Info
            Expanded(
              flex: 5,
              child: Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: const Color(0xFF16161A),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white12),
                ),
                child: Obx(() => Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _StatusBadge(
                      connected: c.isClientConnected.value,
                      label: c.isClientConnected.value
                          ? 'Connected: ${c.connectedDevice.value}'
                          : 'Waiting for phone...',
                    ),
                    const SizedBox(height: 24),
                    if (c.selectedIp.value.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: QrImageView(
                          data: c.qrData,
                          version: QrVersions.auto,
                          size: 210,
                        ),
                      )
                    else
                      const Text('No Wi-Fi IPv4 address detected.'),
                    const SizedBox(height: 20),
                    if (c.availableIps.length > 1)
                      DropdownButton<String>(
                        value: c.selectedIp.value,
                        dropdownColor: const Color(0xFF1F1F24),
                        items: c.availableIps
                            .map((ip) => DropdownMenuItem(
                          value: ip,
                          child: Text('Interface IP: $ip'),
                        ))
                            .toList(),
                        onChanged: (v) {
                          if (v != null) c.selectedIp.value = v;
                        },
                      )
                    else
                      Text(
                        'IP: ${c.selectedIp.value}',
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600),
                      ),
                    const SizedBox(height: 6),
                    Text(
                      'Port: ${c.port.value}   •   PIN: ${c.pairingToken.value}',
                      style: const TextStyle(
                          fontSize: 15, color: Colors.white70),
                    ),
                    if (c.isClientConnected.value) ...[
                      const SizedBox(height: 20),
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                            backgroundColor: Colors.redAccent),
                        onPressed: c.disconnectClient,
                        icon: const Icon(Icons.link_off),
                        label: const Text('Disconnect'),
                      ),
                    ],
                  ],
                )),
              ),
            ),
            const SizedBox(width: 24),
            // Right Panel: Live TCP Logs
            Expanded(
              flex: 6,
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF16161A),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Connection Log',
                      style:
                      TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    const Divider(color: Colors.white12, height: 24),
                    Expanded(
                      child: Obx(() => ListView.builder(
                        itemCount: c.logs.length,
                        itemBuilder: (_, i) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Text(
                            c.logs[i],
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 13,
                              color: Colors.white70,
                            ),
                          ),
                        ),
                      )),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final bool connected;
  final String label;

  const _StatusBadge({required this.connected, required this.label});

  @override
  Widget build(BuildContext context) {
    final color = connected ? Colors.greenAccent : Colors.amberAccent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, size: 10, color: color),
          const SizedBox(width: 8),
          Text(label,
              style: TextStyle(color: color, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}