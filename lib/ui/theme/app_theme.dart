import 'package:flutter/material.dart';

class AppTheme {
  AppTheme._();

  static final darkTheme = ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    colorScheme: ColorScheme.dark(
      primary: Colors.blue,
      surface: const Color(0xFF1E1E1E),
    ),
    scaffoldBackgroundColor: const Color(0xFF121212),
  );

  static final lightTheme = ThemeData(
    brightness: Brightness.light,
    useMaterial3: true,
    colorScheme: ColorScheme.light(
      primary: Colors.blue,
      surface: Colors.white,
    ),
    scaffoldBackgroundColor: const Color(0xFFF5F5F5),
  );

  static const agentRunning = Color(0xFF007AFF);
  static const agentWaiting = Color(0xFFFF9500);
  static const agentError = Color(0xFFFF3B30);
  static const agentIdle = Color(0xFF8E8E93);
}
