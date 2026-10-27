import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:geekcore_term/terminal/terminal_chart_coordinator.dart';
import 'package:geekcore_term/terminal/terminal_chart_models.dart';
import 'package:geekcore_term/terminal/terminal_chart_widgets.dart';
import 'package:xterm/xterm.dart';

/// Overlay widget placed directly on top of TerminalView
class TerminalChartOverlay extends StatefulWidget {
  const TerminalChartOverlay({
    required this.coordinator,
    required this.terminal,
    required this.scrollController,
    required this.textStyle,
    required this.padding,
    super.key,
  });

  final TerminalChartCoordinator coordinator;
  final Terminal terminal;
  final ScrollController scrollController;
  final TerminalStyle textStyle;
  final EdgeInsets padding;

  @override
  State<TerminalChartOverlay> createState() => _TerminalChartOverlayState();
}

class _TerminalChartOverlayState extends State<TerminalChartOverlay> {
  @override
  void initState() {
    super.initState();
    widget.coordinator.addListener(_onCoordinatorUpdate);
    widget.scrollController.addListener(_onScrollUpdate);
  }

  @override
  void didUpdateWidget(TerminalChartOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.coordinator != widget.coordinator) {
      oldWidget.coordinator.removeListener(_onCoordinatorUpdate);
      widget.coordinator.addListener(_onCoordinatorUpdate);
    }
    if (oldWidget.scrollController != widget.scrollController) {
      oldWidget.scrollController.removeListener(_onScrollUpdate);
      widget.scrollController.addListener(_onScrollUpdate);
    }
  }

  @override
  void dispose() {
    widget.coordinator.removeListener(_onCoordinatorUpdate);
    widget.scrollController.removeListener(_onScrollUpdate);
    super.dispose();
  }

  void _onCoordinatorUpdate() {
    if (mounted) setState(() {});
  }

  void _onScrollUpdate() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final blocks = widget.coordinator.blocks;
    if (blocks.isEmpty) return const SizedBox.shrink();

    final textScaler = MediaQuery.textScalerOf(context);
    final charSize = calcCharSize(widget.textStyle, textScaler);
    final lineHeight = charSize.height;

    final scrollOffset = widget.scrollController.hasClients
        ? widget.scrollController.offset
        : 0.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportHeight = constraints.maxHeight;
        final viewportWidth = constraints.maxWidth;

        final children = <Widget>[];

        for (final block in blocks) {
          final startY = block.startBufferLine * lineHeight + widget.padding.top - scrollOffset;
          final endY = (block.endBufferLine + 1) * lineHeight + widget.padding.top - scrollOffset;

          // Check if command block intersects visible viewport or nearby
          if (endY < -300 || startY > viewportHeight + 300) {
            continue;
          }

          // Calculate clamped floating position for toggle badge
          // The floating badge must remain within [startY, endY - badgeHeight]
          // and within viewport bounds [10, viewportHeight - 40]
          const badgeHeight = 28.0;
          final minBadgeY = startY;
          final maxBadgeY = math.max(startY, endY - badgeHeight);

          // Clamped to viewport
          final clampedY = minBadgeY.clamp(
            math.max(10.0, minBadgeY),
            math.min(viewportHeight - 38.0, maxBadgeY),
          ).toDouble();

          final badgeTop = (clampedY >= minBadgeY && clampedY <= maxBadgeY)
              ? clampedY
              : minBadgeY.clamp(0.0, viewportHeight - 38.0).toDouble();

          // 1. If in render mode, show the GUI chart card exactly where the output was
          if (block.isRenderMode) {
            final cardTop = startY + lineHeight;
            final blockPixelHeight = math.max(0.0, (block.endBufferLine - block.startBufferLine - 1) * lineHeight);
            children.add(
              Positioned(
                left: widget.padding.left,
                right: math.max(16.0, viewportWidth - 580),
                top: cardTop,
                height: blockPixelHeight > 60 ? blockPixelHeight : null,
                child: _buildChartCard(block),
              ),
            );
          }

          // 2. Floating toggle badge (Badge is always floating along [startY, endY])
          children.add(
            Positioned(
              right: 18,
              top: badgeTop,
              child: TerminalFloatingBadge(
                isRenderMode: block.isRenderMode,
                label: block.command,
                onToggle: () => widget.coordinator.toggleBlockMode(block),
              ),
            ),
          );
        }

        return Stack(
          fit: StackFit.expand,
          children: children,
        );
      },
    );
  }

  Widget _buildChartCard(CapturedCommandBlock block) {
    switch (block.type) {
      case CommandChartType.df:
        return TerminalDfChartWidget(
          entries: block.dfEntries,
          onClose: () => widget.coordinator.toggleBlockMode(block),
        );
      case CommandChartType.free:
        return TerminalFreeChartWidget(
          stats: block.freeStats!,
          onClose: () => widget.coordinator.toggleBlockMode(block),
        );
    }
  }
}
