import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:shared_protocol/shared_protocol.dart';

import '../controller/client_controller.dart';
import 'mic_test_screen.dart';
import 'qr_scanner_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _ipCtrl = TextEditingController();
  final _portCtrl =
  TextEditingController(text: AirCastConstants.defaultPort.toString());
  final _pinCtrl = TextEditingController();

  @override
  void dispose() {
    _ipCtrl.dispose();
    _portCtrl.dispose();
    _pinCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = Get.put(ClientController());

    return Scaffold(
      backgroundColor: const Color(0xFF0E0E10),
      appBar: AppBar(
        backgroundColor: const Color(0xFF16161A),
        title: const Text('AirCast Phone — Phase 2A'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Obx(() => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Connection Status Card
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF16161A),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white12),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        c.isConnected.value
                            ? 'Connected to ${c.serverName.value}'
                            : 'Not Connected',
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600),
                      ),
                      if (c.lastPingMs.value != null)
                        Text(
                          'Wi-Fi Latency: ${c.lastPingMs.value} ms',
                          style: const TextStyle(color: Colors.greenAccent),
                        ),
                    ],
                  ),
                  Icon(
                    c.isConnected.value ? Icons.wifi : Icons.wifi_off,
                    color: c.isConnected.value
                        ? Colors.greenAccent
                        : Colors.white38,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            if (!c.isConnected.value) ...[
              FilledButton.icon(
                onPressed: c.isConnecting.value
                    ? null
                    : () async {
                  final result = await Get.to<PairingPayload?>(
                        () => const QrScannerScreen(),
                  );
                  if (result != null) {
                    _ipCtrl.text = result.host;
                    _portCtrl.text = result.port.toString();
                    _pinCtrl.text = result.token;
                    c.connect(
                      host: result.host,
                      port: result.port,
                      token: result.token,
                    );
                  }
                },
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('Scan Desktop QR Code'),
              ),
              const SizedBox(height: 16),
              const Text(
                'Or Connect Manually:',
                style: TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _ipCtrl,
                decoration: const InputDecoration(
                  labelText: 'PC IP Address (e.g. 192.168.1.5)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _portCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Port',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _pinCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '6-Digit PIN',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: c.isConnecting.value
                    ? null
                    : () => c.connect(
                  host: _ipCtrl.text.trim(),
                  port: int.tryParse(_portCtrl.text.trim()) ??
                      AirCastConstants.defaultPort,
                  token: _pinCtrl.text.trim(),
                ),
                child: Text(
                  c.isConnecting.value
                      ? 'Connecting...'
                      : 'Connect Manually',
                ),
              ),
            ] else ...[
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: c.sendPing,
                      icon: const Icon(Icons.speed),
                      label: const Text('Test Ping'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.redAccent,
                      ),
                      onPressed: c.disconnect,
                      icon: const Icon(Icons.link_off),
                      label: const Text('Disconnect'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              const Text(
                'Select Stream Mode',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => Get.to(() => const MicTestScreen()),
                      icon: const Icon(Icons.mic),
                      label: const Text('Mic Only'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: OutlinedButton(
                      onPressed: null,
                      child: Text('Cam (Ph 3)'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: OutlinedButton(
                      onPressed: null,
                      child: Text('Both (Ph 3)'),
                    ),
                  ),
                ],
              ),
            ],

            const SizedBox(height: 16),
            const Text(
              'Logs',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF16161A),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white12),
                ),
                child: ListView.builder(
                  itemCount: c.logs.length,
                  itemBuilder: (_, i) => Text(
                    c.logs[i],
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: Colors.white70,
                    ),
                  ),
                ),
              ),
            ),
          ],
        )),
      ),
    );
  }
}