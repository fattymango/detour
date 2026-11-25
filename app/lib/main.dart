import 'package:flutter/material.dart';

import 'home_screen.dart';
import 'theme.dart';

void main() => runApp(const DetourApp());

class DetourApp extends StatelessWidget {
  const DetourApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Detour',
      theme: detourTheme(Brightness.light),
      darkTheme: detourTheme(Brightness.dark),
      home: const HomeScreen(),
    );
  }
}
