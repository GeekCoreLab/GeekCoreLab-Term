import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import 'terminal_search.dart';

class TerminalSearchDialog extends StatefulWidget {
  const TerminalSearchDialog({
    super.key,
    required this.terminal,
    required this.terminalController,
    required this.scrollController,
  });

  final Terminal terminal;
  final TerminalController terminalController;
  final ScrollController scrollController;

  @override
  State<TerminalSearchDialog> createState() => _TerminalSearchDialogState();
}

class _TerminalSearchDialogState extends State<TerminalSearchDialog> {
  final _queryController = TextEditingController();
  final _queryFocus = FocusNode();
  final List<_SearchHighlight> _highlights = [];
  List<TerminalSearchMatch> _matches = [];
  bool _caseSensitive = false;
  bool _truncated = false;
  int _activeIndex = -1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _queryFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _clearHighlights();
    _queryController.dispose();
    _queryFocus.dispose();
    super.dispose();
  }

  void _clearHighlights() {
    for (final highlight in _highlights) {
      highlight.highlight.dispose();
      highlight.start.dispose();
      highlight.end.dispose();
    }
    _highlights.clear();
  }

  void _search(String query) {
    _clearHighlights();
    if (query.isEmpty) {
      setState(() {
        _matches = [];
        _truncated = false;
        _activeIndex = -1;
      });
      return;
    }

    final result = findTerminalMatches(
      widget.terminal,
      query,
      caseSensitive: _caseSensitive,
    );
    setState(() {
      _matches = result.matches;
      _truncated = result.truncated;
      _activeIndex = result.matches.isEmpty ? -1 : 0;
    });
    _paintHighlights();
    if (_activeIndex >= 0) {
      _scrollToActiveMatch();
    }
  }

  void _paintHighlights() {
    _clearHighlights();
    if (_matches.isEmpty) return;
    final colors = Theme.of(context).colorScheme;
    final buffer = widget.terminal.buffer;
    for (var i = 0; i < _matches.length; i++) {
      final match = _matches[i];
      if (match.line >= buffer.height || match.endX > buffer.viewWidth) {
        continue;
      }
      final start = buffer.createAnchor(match.startX, match.line);
      final end = buffer.createAnchor(match.endX, match.line);
      final highlight = widget.terminalController.highlight(
        p1: start,
        p2: end,
        color: i == _activeIndex
            ? colors.primary.withValues(alpha: 0.42)
            : colors.tertiary.withValues(alpha: 0.22),
      );
      _highlights.add(_SearchHighlight(start, end, highlight));
    }
  }

  void _move(int delta) {
    if (_matches.isEmpty) return;
    setState(() {
      _activeIndex = (_activeIndex + delta) % _matches.length;
      if (_activeIndex < 0) _activeIndex += _matches.length;
    });
    _paintHighlights();
    _scrollToActiveMatch();
  }

  void _scrollToActiveMatch() {
    if (!widget.scrollController.hasClients || _activeIndex < 0) return;
    final position = widget.scrollController.position;
    final buffer = widget.terminal.buffer;
    final scrollBack = buffer.scrollBack;
    if (scrollBack <= 0) return;
    final match = _matches[_activeIndex];
    final centeredLine = (match.line - buffer.viewHeight / 2)
        .clamp(0, scrollBack)
        .toDouble();
    final target = position.maxScrollExtent * centeredLine / scrollBack;
    position.jumpTo(target.clamp(0.0, position.maxScrollExtent).toDouble());
  }

  String get _countLabel {
    if (_matches.isEmpty) return _queryController.text.isEmpty ? '' : '无匹配';
    final count = _truncated ? '${_matches.length}+' : '${_matches.length}';
    return '${_activeIndex + 1} / $count';
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('搜索终端输出'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _queryController,
              focusNode: _queryFocus,
              autofocus: true,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: '搜索当前终端及滚屏记录',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _queryController.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清除搜索',
                        onPressed: () {
                          _queryController.clear();
                          _search('');
                        },
                        icon: const Icon(Icons.close_rounded),
                      ),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: _search,
              onSubmitted: (_) => _move(1),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                IconButton(
                  tooltip: _caseSensitive ? '区分大小写：开' : '区分大小写：关',
                  onPressed: () {
                    setState(() => _caseSensitive = !_caseSensitive);
                    _search(_queryController.text);
                  },
                  color: _caseSensitive
                      ? Theme.of(context).colorScheme.primary
                      : null,
                  icon: const Text(
                    'Aa',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    _truncated ? '命中较多，仅显示前 2000 条' : _countLabel,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                IconButton(
                  tooltip: '上一个匹配项',
                  onPressed: _matches.isEmpty ? null : () => _move(-1),
                  icon: const Icon(Icons.keyboard_arrow_up_rounded),
                ),
                IconButton(
                  tooltip: '下一个匹配项',
                  onPressed: _matches.isEmpty ? null : () => _move(1),
                  icon: const Icon(Icons.keyboard_arrow_down_rounded),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

class _SearchHighlight {
  const _SearchHighlight(this.start, this.end, this.highlight);

  final CellAnchor start;
  final CellAnchor end;
  final TerminalHighlight highlight;
}
