import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:window_manager/window_manager.dart';
import 'screens/server_screen.dart'; // adjust if your path differs

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  const windowOptions = WindowOptions(
    size: Size(1060, 720),
    minimumSize: Size(320, 180),
    center: true,
    title: 'AirCast Desktop',
  );
  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(const AirCastDesktopApp());
}

class AirCastDesktopApp extends StatelessWidget {
  const AirCastDesktopApp({super.key});

  @override
  Widget build(BuildContext context) {
    return GetMaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'AirCast Desktop',
      theme: ThemeData.dark(useMaterial3: true),
      home: const ServerScreen(),
    );
  }
}