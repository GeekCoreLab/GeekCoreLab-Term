import 'dart:async';

import 'package:flutter/material.dart';

import 'network_diagnostics.dart';

enum _NetworkDiagnosticAction { dns, tcp }

class NetworkDiagnosticsDialog extends StatefulWidget {
  const NetworkDiagnosticsDialog({super.key});

  @override
  State<NetworkDiagnosticsDialog> createState() =>
      _NetworkDiagnosticsDialogState();
}

class _NetworkDiagnosticsDialogState extends State<NetworkDiagnosticsDialog> {
  final _hostController = TextEditingController();
  final _portController = TextEditingController(text: '443');
  Duration _timeout = const Duration(seconds: 5);
  List<String>? _addresses;
  TcpProbeResult? _tcpResult;
  String? _error;
  String? _resultTitle;
  bool _busy = false;

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    super.dispose();
  }

  Future<void> _run(_NetworkDiagnosticAction action) async {
    if (_busy) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
      _addresses = null;
      _tcpResult = null;
      _resultTitle = null;
    });
    try {
      final host = _hostController.text.trim();
      if (action == _NetworkDiagnosticAction.dns) {
        final stopwatch = Stopwatch()..start();
        final addresses = await lookupNetworkHost(host, timeout: _timeout);
        stopwatch.stop();
        if (!mounted) return;
        if (addresses.isEmpty) {
          setState(() => _error = '没有找到该主机的地址记录');
        } else {
          setState(() {
            _addresses = addresses;
            _resultTitle = 'DNS 查询完成 · ${stopwatch.elapsedMilliseconds} ms';
          });
        }
      } else {
        final port = int.tryParse(_portController.text.trim());
        if (port == null) throw const FormatException('请输入有效的 TCP 端口');
        final result = await probeTcpPort(host, port, timeout: _timeout);
        if (!mounted) return;
        setState(() {
          _tcpResult = result;
          _resultTitle = 'TCP ${result.elapsed.inMilliseconds} ms';
        });
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString().replaceFirst('Bad state: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.network_check_rounded),
          SizedBox(width: 10),
          Text('网络诊断'),
        ],
      ),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _hostController,
                autofocus: true,
                autocorrect: false,
                enableSuggestions: false,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(
                  labelText: '主机名或 IP 地址',
                  hintText: 'example.com 或 192.0.2.10',
                  prefixIcon: Icon(Icons.language_rounded),
                ),
                onSubmitted: (_) =>
                    unawaited(_run(_NetworkDiagnosticAction.dns)),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _portController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'TCP 端口',
                        prefixIcon: Icon(Icons.numbers_rounded),
                      ),
                      onSubmitted: (_) =>
                          unawaited(_run(_NetworkDiagnosticAction.tcp)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<int>(
                      initialValue: _timeout.inSeconds,
                      decoration: const InputDecoration(labelText: '超时'),
                      items: const [3, 5, 10, 15]
                          .map(
                            (seconds) => DropdownMenuItem(
                              value: seconds,
                              child: Text('$seconds 秒'),
                            ),
                          )
                          .toList(),
                      onChanged: _busy
                          ? null
                          : (seconds) {
                              if (seconds != null) {
                                setState(
                                  () => _timeout = Duration(seconds: seconds),
                                );
                              }
                            },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _busy
                        ? null
                        : () => unawaited(_run(_NetworkDiagnosticAction.dns)),
                    icon: const Icon(Icons.search_rounded, size: 18),
                    label: const Text('DNS 查询'),
                  ),
                  FilledButton.icon(
                    onPressed: _busy
                        ? null
                        : () => unawaited(_run(_NetworkDiagnosticAction.tcp)),
                    icon: const Icon(Icons.cable_rounded, size: 18),
                    label: const Text('测试 TCP 端口'),
                  ),
                ],
              ),
              if (_busy) ...[
                const SizedBox(height: 18),
                const LinearProgressIndicator(),
              ],
              if (_error != null) ...[
                const SizedBox(height: 16),
                _ResultCard(
                  color: colors.errorContainer,
                  foreground: colors.onErrorContainer,
                  icon: Icons.error_outline_rounded,
                  title: '诊断失败',
                  children: [Text(_error!)],
                ),
              ],
              if (_resultTitle != null) ...[
                const SizedBox(height: 16),
                _ResultCard(
                  color: colors.primaryContainer,
                  foreground: colors.onPrimaryContainer,
                  icon: Icons.check_circle_outline_rounded,
                  title: _resultTitle!,
                  children: [
                    if (_addresses != null)
                      for (final address in _addresses!)
                        SelectableText(
                          address,
                          style: const TextStyle(fontFamily: 'monospace'),
                        ),
                    if (_tcpResult != null)
                      SelectableText(
                        '已连接到 ${_tcpResult!.address}',
                        style: const TextStyle(fontFamily: 'monospace'),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 12),
              Text(
                'TCP 检查仅连接单个目标端口，握手后立即关闭，不发送应用数据。主机和端口不会保存。',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
              ),
            ],
          ),
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

class _ResultCard extends StatelessWidget {
  const _ResultCard({
    required this.color,
    required this.foreground,
    required this.icon,
    required this.title,
    required this.children,
  });

  final Color color;
  final Color foreground;
  final IconData icon;
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 18, color: foreground),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  color: foreground,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ...children,
      ],
    ),
  );
}
