import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AppTheme {
  AppTheme._();

  // ── Dark Colors ──
  static const Color bg = Color(0xFF1E1E1E);
  static const Color surface = Color(0xFF2C2C2E);
  static const Color surfaceVariant = Color(0xFF3A3A3C);
  static const Color border = Color(0xFF48484A);
  static const Color text = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xFF8E8E93);
  static const Color accent = Color(0xFF0A84FF);
  static const Color success = Color(0xFF30D158);
  static const Color warning = Color(0xFFFF9F0A);
  static const Color error = Color(0xFFFF453A);

  // ── Light Colors ──
  static const Color lightBg = Color(0xFFF2F2F7);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightBorder = Color(0xFFD1D1D6);
  static const Color lightText = Color(0xFF1C1C1E);
  static const Color lightTextSecondary = Color(0xFF8E8E93);

  static ThemeData dark() {
    return ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      scaffoldBackgroundColor: bg,
      appBarTheme: const AppBarTheme(
        backgroundColor: surface,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        systemOverlayStyle: SystemUiOverlayStyle.light,
        iconTheme: IconThemeData(color: textSecondary),
        titleTextStyle: TextStyle(color: text, fontSize: 14, fontWeight: FontWeight.w500),
      ),
      dividerTheme: const DividerThemeData(color: border, thickness: 0.5, space: 0),
      iconTheme: const IconThemeData(color: textSecondary, size: 18),
      textTheme: const TextTheme(
        bodyLarge: TextStyle(color: text, fontSize: 14),
        bodyMedium: TextStyle(color: text, fontSize: 13),
        bodySmall: TextStyle(color: textSecondary, fontSize: 12),
        titleLarge: TextStyle(color: text, fontSize: 16, fontWeight: FontWeight.w600),
        titleMedium: TextStyle(color: text, fontSize: 14, fontWeight: FontWeight.w500),
        titleSmall: TextStyle(color: text, fontSize: 13, fontWeight: FontWeight.w500),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceVariant,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: border)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: border)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: accent, width: 2)),
      ),
      dialogTheme: DialogThemeData(backgroundColor: surface, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
      popupMenuTheme: PopupMenuThemeData(color: surface, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
    );
  }

  static ThemeData light() {
    return ThemeData(
      brightness: Brightness.light,
      useMaterial3: true,
      scaffoldBackgroundColor: lightBg,
      appBarTheme: const AppBarTheme(
        backgroundColor: lightSurface,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        systemOverlayStyle: SystemUiOverlayStyle.dark,
        iconTheme: IconThemeData(color: lightTextSecondary),
        titleTextStyle: TextStyle(color: lightText, fontSize: 14, fontWeight: FontWeight.w500),
      ),
      dividerTheme: const DividerThemeData(color: lightBorder, thickness: 0.5, space: 0),
      iconTheme: const IconThemeData(color: lightTextSecondary, size: 18),
      textTheme: const TextTheme(
        bodyLarge: TextStyle(color: lightText, fontSize: 14),
        bodyMedium: TextStyle(color: lightText, fontSize: 13),
        bodySmall: TextStyle(color: lightTextSecondary, fontSize: 12),
        titleLarge: TextStyle(color: lightText, fontSize: 16, fontWeight: FontWeight.w600),
        titleMedium: TextStyle(color: lightText, fontSize: 14, fontWeight: FontWeight.w500),
        titleSmall: TextStyle(color: lightText, fontSize: 13, fontWeight: FontWeight.w500),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: lightBorder)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: lightBorder)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: accent, width: 2)),
      ),
      dialogTheme: DialogThemeData(backgroundColor: lightSurface, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
      popupMenuTheme: PopupMenuThemeData(color: lightSurface, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
    );
  }

  static const agentRunning = accent;
  static const agentWaiting = warning;
  static const agentError = error;
  static const agentIdle = textSecondary;
  static const agentSuccess = success;
}
