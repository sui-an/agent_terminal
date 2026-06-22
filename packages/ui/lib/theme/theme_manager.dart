import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ThemeManager extends StateNotifier<ThemeMode> {
  ThemeManager() : super(ThemeMode.system);

  void setThemeMode(ThemeMode mode) => state = mode;
}
