import 'package:flutter/material.dart';
import 'package:core/workspace/workspace_state.dart';
import 'package:ui/theme/app_theme.dart';
import '../common/smart_tooltip.dart';

class TabBarWidget extends StatelessWidget {
  final List<TabState> tabs;
  final String? selectedTabId;
  final ValueChanged<String> onTabSelected;
  final ValueChanged<String> onTabClosed;
  final VoidCallback? onNewTab;

  const TabBarWidget({
    super.key,
    required this.tabs,
    this.selectedTabId,
    required this.onTabSelected,
    required this.onTabClosed,
    this.onNewTab,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 36,
      decoration: BoxDecoration(
        color: AppTheme.surface,
        border: Border(bottom: BorderSide(color: AppTheme.border, width: 0.5)),
      ),
      child: Row(
        children: [
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: tabs.length,
              separatorBuilder: (_, __) => Container(width: 1, color: AppTheme.border),
              itemBuilder: (_, i) {
                final tab = tabs[i];
                final sel = tab.id == selectedTabId;
                return GestureDetector(
                  onTap: () => onTabSelected(tab.id),
                  child: Container(
                    width: 140,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: sel ? AppTheme.bg : Colors.transparent,
                      border: Border(bottom: BorderSide(color: sel ? AppTheme.accent : Colors.transparent, width: 2)),
                    ),
                    alignment: Alignment.centerLeft,
                    child: Row(
                      children: [
                        Icon(Icons.terminal, size: 12, color: sel ? AppTheme.accent : AppTheme.textSecondary),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(tab.title, style: TextStyle(fontSize: 12, color: sel ? AppTheme.text : AppTheme.textSecondary), overflow: TextOverflow.ellipsis),
                        ),
                        GestureDetector(
                          onTap: () => onTabClosed(tab.id),
                          child: Icon(Icons.close, size: 12, color: AppTheme.textSecondary.withOpacity(0.5)),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          if (onNewTab != null)
            Container(
              width: 36,
              decoration: BoxDecoration(border: Border(left: BorderSide(color: AppTheme.border, width: 0.5))),
              child: SmartTooltip(
                message: 'New Tab',
                preferBelow: true,
                child: IconButton(
                  icon: const Icon(Icons.add, size: 16, color: AppTheme.textSecondary),
                  onPressed: onNewTab,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
