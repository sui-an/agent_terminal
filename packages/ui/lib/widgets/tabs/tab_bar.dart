import 'package:flutter/material.dart';
import 'package:core/workspace/workspace_state.dart';
import 'package:ui/theme/app_theme.dart';
import '../common/smart_tooltip.dart';
import '../common/split_icon.dart';
import '../../agent_icon.dart';

class TabBarWidget extends StatefulWidget {
  final List<TabState> tabs;
  final String? selectedTabId;
  final String panelId;
  final ValueChanged<String> onTabSelected;
  final ValueChanged<String> onTabClosed;
  final VoidCallback? onNewTab;
  final ValueChanged<String>? onTabSplit;
  final VoidCallback? onClosePanel;
  final Function(String fromPanelId, String toPanelId, String tabId)? onTabMoved;
  final Function(String fromPanelId, String tabId, String direction)? onTabSplitByDrag;

  const TabBarWidget({
    super.key,
    required this.tabs,
    this.selectedTabId,
    required this.panelId,
    required this.onTabSelected,
    required this.onTabClosed,
    this.onNewTab,
    this.onTabSplit,
    this.onClosePanel,
    this.onTabMoved,
    this.onTabSplitByDrag,
  });

  @override
  State<TabBarWidget> createState() => _TabBarWidgetState();
}

class _TabBarWidgetState extends State<TabBarWidget> {
  static const double _tabWidth = 140;
  static const double _edgeRatio = 0.25;

  bool _dragging = false;
  String? _draggedTabId;
  String? _hoverZone;
  int? _hoverIdx;
  OverlayEntry? _overlay;
  Offset _overlayPos = Offset.zero;
  String _debugInfo = 'idle';

  int? _tabAt(Offset globalPos) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) { _debugInfo = 'no box'; return null; }
    final local = box.globalToLocal(globalPos);
    final x = local.dx;
    _debugInfo = 'x=${x.toStringAsFixed(0)} w=${box.size.width.toStringAsFixed(0)}';
    if (x < 0) return null;
    final idx = x ~/ _tabWidth;
    if (idx < 0 || idx >= widget.tabs.length) return null;
    return idx;
  }

  String _zoneAt(Offset globalPos, int tabIndex) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return 'center';
    final local = box.globalToLocal(globalPos);
    final x = local.dx - tabIndex * _tabWidth;
    if (x < _tabWidth * _edgeRatio) return 'left';
    if (x > _tabWidth * (1 - _edgeRatio)) return 'right';
    return 'center';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onLongPressStart: (d) {
            final idx = _tabAt(d.globalPosition);
            _debugInfo += ' | START idx=$idx';
            if (idx == null) { setState(() {}); return; }
            _draggedTabId = widget.tabs[idx].id;
            _dragging = true;
            _overlayPos = d.globalPosition;
            _showOverlay();
            setState(() {});
          },
          onLongPressMoveUpdate: (d) {
            if (!_dragging) { _debugInfo = 'move but not dragging'; setState(() {}); return; }
            _overlayPos = d.globalPosition;
            _overlay?.markNeedsBuild();
            final idx = _tabAt(d.globalPosition);
            _debugInfo += ' | MOVE idx=$idx';
            if (idx != null && _draggedTabId != null && widget.tabs[idx].id != _draggedTabId) {
              final z = _zoneAt(d.globalPosition, idx);
              _debugInfo += ' z=$z';
              if (z != _hoverZone || idx != _hoverIdx) {
                setState(() { _hoverZone = z; _hoverIdx = idx; });
                return;
              }
            } else if (_hoverZone != null) {
              setState(() { _hoverZone = null; _hoverIdx = null; });
              return;
            }
            setState(() {});
          },
          onLongPressEnd: (d) {
            if (!_dragging) return;
            final z = _hoverZone;
            final ti = _hoverIdx;
            _removeOverlay();
            _dragging = false;
            _hoverZone = null;
            _hoverIdx = null;
            _debugInfo = 'END z=$z ti=$ti';
            setState(() {});
            if (ti == null || _draggedTabId == null) return;
            if (z == 'left' || z == 'right') {
              widget.onTabSplitByDrag?.call(widget.panelId, _draggedTabId!, 'horizontal');
            } else if (z == 'center') {
              widget.onTabMoved?.call(widget.panelId, widget.panelId, _draggedTabId!);
            }
          },
          onLongPressCancel: () {
            _removeOverlay();
            _dragging = false;
            _hoverZone = null;
            _hoverIdx = null;
            _draggedTabId = null;
            _debugInfo = 'CANCEL';
            if (mounted) setState(() {});
          },
          onTap: () {
            _debugInfo = 'TAP';
            setState(() {});
          },
          onSecondaryTapUp: (d) {
            final idx = _tabAt(d.globalPosition);
            _debugInfo = 'RIGHT CLICK idx=$idx';
            setState(() {});
            if (idx != null) _showContextMenu(widget.tabs[idx], d.globalPosition);
          },
          child: Container(
            height: 36,
            decoration: BoxDecoration(
              color: AppTheme.surface,
              border: Border(bottom: BorderSide(color: AppTheme.border, width: 0.5)),
            ),
            child: Row(
              children: [
                for (int i = 0; i < widget.tabs.length; i++) ...[
                  if (i > 0) Container(width: 1, color: AppTheme.border),
                  _buildTab(i),
                ],
                if (widget.onNewTab != null)
                  Container(
                    width: 36,
                    decoration: BoxDecoration(border: Border(left: BorderSide(color: AppTheme.border, width: 0.5))),
                    child: SmartTooltip(
                      message: 'New Tab', preferBelow: true,
                      child: SizedBox(
                        width: 36, height: 36,
                        child: Icon(Icons.add, size: 16, color: AppTheme.textSecondary),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        Container(
          height: 18,
          color: Colors.black87,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          alignment: Alignment.centerLeft,
          child: Text(_debugInfo, style: const TextStyle(fontSize: 10, color: Colors.yellow, fontFamily: 'monospace')),
        ),
      ],
    );
  }

  void _showContextMenu(TabState tab, Offset pos) {
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx + 1, pos.dy + 1),
      items: [
        if (widget.onTabSplit != null) ...[
          PopupMenuItem(value: 'sr', height: 32, child: Row(children: [const SplitIcon(horizontal: true, size: 14), const SizedBox(width: 8), Text('Split Right', style: TextStyle(fontSize: 12, color: AppTheme.text))])),
          PopupMenuItem(value: 'sd', height: 32, child: Row(children: [const SplitIcon(horizontal: false, size: 14), const SizedBox(width: 8), Text('Split Down', style: TextStyle(fontSize: 12, color: AppTheme.text))])),
          const PopupMenuDivider(height: 1),
        ],
        if (widget.onClosePanel != null)
          PopupMenuItem(value: 'cp', height: 32, child: Row(children: [Icon(Icons.close, size: 14, color: AppTheme.textSecondary), const SizedBox(width: 8), Text('Close Panel', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))])),
      ],
    ).then((v) {
      if (v == null) return;
      if (v == 'sr') widget.onTabSplit?.call('${widget.panelId},horizontal');
      if (v == 'sd') widget.onTabSplit?.call('${widget.panelId},vertical');
      if (v == 'cp') widget.onClosePanel?.call();
    });
  }

  void _showOverlay() {
    _removeOverlay();
    _overlay = OverlayEntry(builder: (ctx) {
      final title = _draggedTabId != null
          ? widget.tabs.firstWhere((t) => t.id == _draggedTabId, orElse: () => widget.tabs.first).title
          : '';
      return Positioned(
        left: _overlayPos.dx - _tabWidth / 2,
        top: _overlayPos.dy - 18,
        child: IgnorePointer(
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: _tabWidth, height: 36,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: AppTheme.surface,
                border: Border.all(color: AppTheme.accent),
                borderRadius: BorderRadius.circular(4),
                boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 8)],
              ),
              alignment: Alignment.centerLeft,
              child: Text(title, style: TextStyle(fontSize: 12, color: AppTheme.text), overflow: TextOverflow.ellipsis),
            ),
          ),
        ),
      );
    });
    Overlay.of(context).insert(_overlay!);
  }

  void _removeOverlay() {
    _overlay?.remove();
    _overlay = null;
  }

  @override
  void dispose() {
    _removeOverlay();
    super.dispose();
  }

  Widget _buildTab(int i) {
    final tab = widget.tabs[i];
    final sel = tab.id == widget.selectedTabId;
    final drop = _dragging && _hoverIdx == i && _draggedTabId != tab.id;
    return Container(
      width: _tabWidth, height: 36,
      decoration: BoxDecoration(
        color: sel ? AppTheme.bg : (drop && _hoverZone == 'center' ? AppTheme.accent.withOpacity(0.1) : Colors.transparent),
        border: Border(
          bottom: BorderSide(color: sel ? AppTheme.accent : Colors.transparent, width: 2),
          left: drop && _hoverZone == 'left' ? BorderSide(color: AppTheme.accent, width: 3) : BorderSide.none,
          right: drop && _hoverZone == 'right' ? BorderSide(color: AppTheme.accent, width: 3) : BorderSide.none,
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      alignment: Alignment.centerLeft,
      child: Row(
        children: [
          AgentIcon.getIcon(tab.agentId, size: 12, color: sel ? AppTheme.accent : AppTheme.textSecondary),
          const SizedBox(width: 6),
          Expanded(child: Text(tab.title, style: TextStyle(fontSize: 12, color: sel ? AppTheme.text : AppTheme.textSecondary), overflow: TextOverflow.ellipsis)),
          Icon(Icons.close, size: 12, color: AppTheme.textSecondary.withOpacity(0.5)),
        ],
      ),
    );
  }
}
