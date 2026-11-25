import 'package:flutter/material.dart';

import 'home_screen.dart';

void main() => runApp(const DetourApp());

class DetourApp extends StatelessWidget {
  const DetourApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Detour',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const HomeScreen(),
    );
  }
}
