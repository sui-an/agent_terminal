import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core/agent/agent_config_manager.dart';
import '../theme/theme_provider.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});
  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  String _font = 'JetBrains Mono';
  double _fontSize = 14;

  @override
  Widget build(BuildContext context) {
    final currentTheme = ref.watch(themeManagerProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings', style: TextStyle(fontSize: 14)),
        leading: IconButton(icon: const Icon(Icons.arrow_back_ios_new, size: 18), onPressed: () => Navigator.pop(context)),
      ),
      body: ListView(
        children: [
          _section('Appearance'),
          ListTile(
            leading: const Icon(Icons.palette, size: 18),
            title: const Text('Theme', style: TextStyle(fontSize: 13)),
            subtitle: Text(_themeName(currentTheme), style: TextStyle(fontSize: 12)),
            trailing: const Icon(Icons.chevron_right, size: 16),
            onTap: () => _pickTheme(currentTheme),
          ),
          ListTile(
            leading: const Icon(Icons.text_fields, size: 18),
            title: const Text('Font', style: TextStyle(fontSize: 13)),
            subtitle: Text('$_font (${_fontSize.round()}px)', style: TextStyle(fontSize: 12)),
            trailing: const Icon(Icons.chevron_right, size: 16),
            onTap: _pickFont,
          ),
          const Divider(),
          _section('Terminal'),
          SwitchListTile(
            secondary: const Icon(Icons.keyboard, size: 18),
            title: const Text('Keyboard Hints', style: TextStyle(fontSize: 13)),
            value: true,
            onChanged: (_) {},
          ),
          SwitchListTile(
            secondary: const Icon(Icons.history, size: 18),
            title: const Text('Scrollback (10k lines)', style: TextStyle(fontSize: 13)),
            value: true,
            onChanged: (_) {},
          ),
          const Divider(),
          _section('Agents'),
          ListTile(
            leading: const Icon(Icons.smart_toy, size: 18),
            title: const Text('Agent Configuration', style: TextStyle(fontSize: 13)),
            subtitle: Text('${AgentConfigManager().agents.length} agents configured', style: TextStyle(fontSize: 12)),
            trailing: const Icon(Icons.chevron_right, size: 16),
            onTap: _showAgents,
          ),
          const Divider(),
          _section('About'),
          const ListTile(
            leading: Icon(Icons.info_outline, size: 18),
            title: Text('Version', style: TextStyle(fontSize: 13)),
            subtitle: Text('1.0.0', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  String _themeName(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.system: return 'System';
      case ThemeMode.light: return 'Light';
      case ThemeMode.dark: return 'Dark';
    }
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
        child: Text(title.toUpperCase(), style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Theme.of(context).textTheme.bodySmall?.color, letterSpacing: 0.5)),
      );

  void _pickTheme(ThemeMode current) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Theme'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RadioListTile<ThemeMode>(
              title: const Text('System'),
              value: ThemeMode.system,
              groupValue: current,
              onChanged: (v) { ref.read(themeManagerProvider.notifier).state = v!; Navigator.pop(ctx); },
            ),
            RadioListTile<ThemeMode>(
              title: const Text('Light'),
              value: ThemeMode.light,
              groupValue: current,
              onChanged: (v) { ref.read(themeManagerProvider.notifier).state = v!; Navigator.pop(ctx); },
            ),
            RadioListTile<ThemeMode>(
              title: const Text('Dark'),
              value: ThemeMode.dark,
              groupValue: current,
              onChanged: (v) { ref.read(themeManagerProvider.notifier).state = v!; Navigator.pop(ctx); },
            ),
          ],
        ),
      ),
    );
  }

  void _pickFont() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Font'),
        content: StatefulBuilder(
          builder: (ctx, set) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButton<String>(
                value: _font,
                isExpanded: true,
                items: ['JetBrains Mono', 'Fira Code', 'Source Code Pro', 'Menlo', 'Monaco']
                    .map((f) => DropdownMenuItem(value: f, child: Text(f)))
                    .toList(),
                onChanged: (v) => set(() => _font = v!),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Text('Size: ', style: TextStyle(fontSize: 13)),
                  Expanded(
                    child: Slider(value: _fontSize, min: 10, max: 24, divisions: 14, label: '${_fontSize.round()}', onChanged: (v) => set(() => _fontSize = v)),
                  ),
                  Text('${_fontSize.round()}px', style: const TextStyle(fontSize: 13)),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done')),
        ],
      ),
    );
  }

  void _showAgents() {
    final agents = AgentConfigManager().agents;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Agents'),
        content: SizedBox(
          width: 360,
          height: 280,
          child: ListView.separated(
            itemCount: agents.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final a = agents[i];
              return ListTile(
                dense: true,
                leading: Icon(Icons.smart_toy, size: 18, color: Theme.of(context).colorScheme.primary),
                title: Text(a.name, style: const TextStyle(fontSize: 13)),
                subtitle: Text(a.command, style: TextStyle(fontSize: 11, color: Theme.of(context).textTheme.bodySmall?.color)),
              );
            },
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done'))],
      ),
    );
  }
}
