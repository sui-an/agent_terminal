import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';
import 'theme_manager.dart';

final themeManagerProvider = StateNotifierProvider<ThemeManager, ThemeMode>((ref) {
  return ThemeManager();
});
