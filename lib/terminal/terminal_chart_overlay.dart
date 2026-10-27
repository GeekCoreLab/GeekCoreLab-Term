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
    widget.terminal.addListener(_onTerminalUpdate);
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
    if (oldWidget.terminal != widget.terminal) {
      oldWidget.terminal.removeListener(_onTerminalUpdate);
      widget.terminal.addListener(_onTerminalUpdate);
    }
  }

  @override
  void dispose() {
    widget.coordinator.removeListener(_onCoordinatorUpdate);
    widget.scrollController.removeListener(_onScrollUpdate);
    widget.terminal.removeListener(_onTerminalUpdate);
    super.dispose();
  }

  void _onCoordinatorUpdate() {
    if (mounted) setState(() {});
  }

  void _onScrollUpdate() {
    if (mounted) setState(() {});
  }

  void _onTerminalUpdate() {
    if (mounted && widget.coordinator.blocks.isNotEmpty) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final blocks = widget.coordinator.blocks;
    if (blocks.isEmpty) return const SizedBox.shrink();

    final textScaler = MediaQuery.textScalerOf(context);
    final charSize = calcCharSize(widget.textStyle, textScaler);
    final lineHeight = charSize.height;

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportHeight = constraints.maxHeight;
        final viewportWidth = constraints.maxWidth;

        // Match RenderTerminal's exact scrollOffset calculation so there is zero frame lag
        // when commands execute near the bottom of the terminal or after `clear`.
        final innerViewportHeight = math.max(0.0, viewportHeight - widget.padding.vertical);
        final terminalHeight = widget.terminal.buffer.lines.length * lineHeight;
        final currentMaxScrollExtent = math.max(0.0, terminalHeight - innerViewportHeight);

        double scrollOffset;
        if (!widget.scrollController.hasClients) {
          scrollOffset = currentMaxScrollExtent;
        } else {
          final pos = widget.scrollController.position;
          final wasAtBottom = pos.pixels >= pos.maxScrollExtent - 1.0;
          if (wasAtBottom || pos.pixels > currentMaxScrollExtent) {
            scrollOffset = currentMaxScrollExtent;
          } else {
            scrollOffset = pos.pixels.clamp(0.0, currentMaxScrollExtent);
          }
        }

        final children = <Widget>[];

        for (final block in blocks) {
          final startLine = block.currentStartLine;
          final endLine = block.currentEndLine;
          // startLine is the command line; endLine - 1 is the last line of output
          // (since endLine is the line where the next prompt is located)
          final lastOutputLine = math.max(startLine, endLine - 1);
          final startY = startLine * lineHeight + widget.padding.top - scrollOffset;
          final endY = (lastOutputLine + 1) * lineHeight + widget.padding.top - scrollOffset;

          final outputLinesCount = math.max(1, endLine - startLine - 1);
          final outputPixelHeight = outputLinesCount * lineHeight;
          final minChartHeight = _estimateMinChartHeight(block);
          final fullChartHeight = _estimateFullChartHeight(block);

          // Auto-fullscreen when the output or full chart content occupies most of or exceeds the screen
          final autoFullscreen = block.type != CommandChartType.free &&
              (fullChartHeight >= viewportHeight * 0.72 ||
                  outputPixelHeight >= viewportHeight * 0.72);
          final isFullscreen = block.isFullscreenOverride ?? autoFullscreen;
          final fitsInOutputSpace = outputPixelHeight >= minChartHeight;

          // Check if command block intersects visible viewport or nearby (never cull active fullscreen chart)
          if (!(block.isRenderMode && isFullscreen) &&
              (endY < -300 || startY > viewportHeight + 300)) {
            continue;
          }

          // Calculate clamped floating position for toggle badge:
          // The floating badge stays within [startY, endY - badgeHeight]
          // while sticking to the viewport top/bottom [8.0, viewportHeight - 36.0] when scrolling
          const badgeHeight = 26.0;
          final minBadgeY = startY;
          final maxBadgeY = math.max(startY, endY - badgeHeight);
          final targetViewportY = startY.clamp(8.0, math.max(8.0, viewportHeight - badgeHeight - 8.0));
          final badgeTop = (block.isRenderMode && isFullscreen)
              ? 8.0
              : targetViewportY.clamp(minBadgeY, maxBadgeY).clamp(8.0, math.max(8.0, viewportHeight - badgeHeight - 8.0)).toDouble();

          // 1. If in render mode, show the GUI chart card
          if (block.isRenderMode) {
            if (isFullscreen) {
              // Fullscreen mode: fill the available terminal viewport (leaving space on the right for the floating badge)
              final maxAllowedHeight = math.max(120.0, viewportHeight - 16.0);
              final rightMargin = viewportWidth > 260 ? 116.0 : 12.0;

              children.add(
                Positioned(
                  left: math.max(8.0, widget.padding.left),
                  right: rightMargin,
                  top: 8.0,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: maxAllowedHeight),
                    child: _buildChartCard(
                      block,
                      maxHeight: maxAllowedHeight,
                      isFullscreen: true,
                    ),
                  ),
                ),
              );
            } else if (fitsInOutputSpace) {
              // Output space is tall enough: render in-place occupying at most the output space,
              // clamped so it never overflows the bottom of the terminal viewport.
              final desiredTop = startY + lineHeight;
              final maxAllowedHeight = math.min(
                outputPixelHeight,
                math.max(96.0, viewportHeight - 16.0),
              );
              final cardTop = desiredTop.clamp(
                8.0,
                math.max(8.0, viewportHeight - maxAllowedHeight - 8.0),
              ).toDouble();
              final cardWidth = math.min(760.0, math.max(260.0, viewportWidth - 130.0));

              children.add(
                Positioned(
                  left: widget.padding.left,
                  width: cardWidth,
                  top: cardTop,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: maxAllowedHeight),
                    child: _buildChartCard(
                      block,
                      maxHeight: maxAllowedHeight,
                      isFullscreen: false,
                    ),
                  ),
                ),
              );
            } else {
              // Output space does NOT meet minimum chart height (e.g. `free -h` is only 3 lines):
              // Place the chart on the RIGHT side so it does not cover the left-side command/prompt,
              // and shift `top` up if needed so the card never overflows the bottom of the terminal viewport.
              final maxAllowedHeight = math.min(
                math.max(minChartHeight + 24.0, fullChartHeight),
                math.max(110.0, viewportHeight - 24.0),
              );
              final desiredTop = startY + lineHeight;
              final cardTop = desiredTop.clamp(
                8.0,
                math.max(8.0, viewportHeight - maxAllowedHeight - 8.0),
              ).toDouble();
              final cardWidth = math.min(460.0, math.max(250.0, viewportWidth * 0.55));

              children.add(
                Positioned(
                  right: 116,
                  width: cardWidth,
                  top: cardTop,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: maxAllowedHeight),
                    child: _buildChartCard(
                      block,
                      maxHeight: maxAllowedHeight,
                      isFullscreen: false,
                    ),
                  ),
                ),
              );
            }
          }

          // 2. Floating toggle badge (Badge floats within [startY, endY])
          children.add(
            Positioned(
              right: 14,
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
          clipBehavior: Clip.hardEdge,
          children: children,
        );
      },
    );
  }

  double _estimateMinChartHeight(CapturedCommandBlock block) {
    switch (block.type) {
      case CommandChartType.free:
        final hasSwap = block.freeStats != null &&
            block.freeStats!.totalSwap.isNotEmpty &&
            block.freeStats!.totalSwap != '0B' &&
            block.freeStats!.totalSwap != '0';
        return hasSwap ? 132.0 : 88.0;
      case CommandChartType.df:
        final rows = math.min(block.dfEntries.length, 4);
        return 46.0 + rows * 38.0;
      case CommandChartType.dockerPs:
        if (block.dockerEntries.isEmpty) return 76.0;
        final rows = math.min(block.dockerEntries.length, 3);
        return 46.0 + rows * 52.0;
    }
  }

  double _estimateFullChartHeight(CapturedCommandBlock block) {
    switch (block.type) {
      case CommandChartType.free:
        return _estimateMinChartHeight(block);
      case CommandChartType.df:
        return 52.0 + block.dfEntries.length * 42.0;
      case CommandChartType.dockerPs:
        if (block.dockerEntries.isEmpty) return 80.0;
        return 52.0 + block.dockerEntries.length * 68.0;
    }
  }

  Widget _buildChartCard(
    CapturedCommandBlock block, {
    required bool isFullscreen,
    double? maxHeight,
  }) {
    final onToggleFullscreen = () => widget.coordinator.toggleBlockFullscreen(
          block,
          currentlyFullscreen: isFullscreen,
        );

    switch (block.type) {
      case CommandChartType.df:
        return TerminalDfChartWidget(
          entries: block.dfEntries,
          maxHeight: maxHeight,
          isFullscreen: isFullscreen,
          onToggleFullscreen: onToggleFullscreen,
          onClose: () => widget.coordinator.toggleBlockMode(block),
        );
      case CommandChartType.free:
        return TerminalFreeChartWidget(
          stats: block.freeStats!,
          maxHeight: maxHeight,
          isFullscreen: isFullscreen,
          onToggleFullscreen: onToggleFullscreen,
          onClose: () => widget.coordinator.toggleBlockMode(block),
        );
      case CommandChartType.dockerPs:
        return TerminalDockerPsChartWidget(
          entries: block.dockerEntries,
          maxHeight: maxHeight,
          isFullscreen: isFullscreen,
          onToggleFullscreen: onToggleFullscreen,
          onClose: () => widget.coordinator.toggleBlockMode(block),
        );
    }
  }
}
