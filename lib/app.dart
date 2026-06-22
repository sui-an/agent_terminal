import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ui/theme/app_theme.dart';
import 'package:ui/theme/theme_provider.dart';
import 'package:ui/screens/home_screen.dart';

class AgentTerminalApp extends ConsumerWidget {
  const AgentTerminalApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeManagerProvider);

    return MaterialApp(
      title: 'AgentTerminal',
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,
      home: const HomeScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}
