import 'package:aircast_desktop/screens/server_screen.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';


void main() {
  runApp(const AirCastDesktopApp());
}

class AirCastDesktopApp extends StatelessWidget {
  const AirCastDesktopApp({super.key});

  @override
  Widget build(BuildContext context) {
    return GetMaterialApp(
      title: 'AirCast Desktop',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const ServerScreen(),
    );
  }
}