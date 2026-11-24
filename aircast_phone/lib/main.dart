import 'package:aircast_phone/screens/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';


void main() {
  runApp(const AirCastPhoneApp());
}

class AirCastPhoneApp extends StatelessWidget {
  const AirCastPhoneApp({super.key});

  @override
  Widget build(BuildContext context) {
    return GetMaterialApp(
      title: 'AirCast Phone',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const HomeScreen(),
    );
  }
}