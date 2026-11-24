import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shared_protocol/shared_protocol.dart';

class QrScannerScreen extends StatefulWidget {
  const QrScannerScreen({super.key});

  @override
  State<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<QrScannerScreen> {
  bool _handled = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: const Text('Scan Desktop QR')),
      body: MobileScanner(
        onDetect: (BarcodeCapture capture) {
          if (_handled) return;
          final raw = capture.barcodes.firstOrNull?.rawValue;
          if (raw == null) return;

          final payload = PairingPayload.tryParse(raw);
          if (payload != null) {
            _handled = true;
            Get.back(result: payload);
          }
        },
      ),
    );
  }
}