import 'dart:async';

import 'package:flutter/material.dart';

import 'network_diagnostics.dart';

enum _NetworkDiagnosticMode { tcp, dns, scan }

class NetworkDiagnosticsDialog extends StatefulWidget {
  const NetworkDiagnosticsDialog({super.key});

  @override
  State<NetworkDiagnosticsDialog> createState() =>
      _NetworkDiagnosticsDialogState();
}

class _NetworkDiagnosticsDialogState extends State<NetworkDiagnosticsDialog> {
  final _hostController = TextEditingController();
  final _portController = TextEditingController(text: '443');
  final _scanStartController = TextEditingController(text: '1');
  final _scanEndController = TextEditingController(text: '1024');
  _NetworkDiagnosticMode _mode = _NetworkDiagnosticMode.tcp;
  Duration _timeout = const Duration(seconds: 5);
  Duration _scanTimeout = const Duration(milliseconds: 500);
  List<String>? _addresses;
  TcpProbeResult? _tcpResult;
  TcpPortScanResult? _scanResult;
  TcpPortScanCancellation? _scanCancellation;
  String? _error;
  String? _resultTitle;
  bool _busy = false;
  int _scanCompleted = 0;
  int _scanTotal = 0;

  @override
  void dispose() {
    _scanCancellation?.cancel();
    _hostController.dispose();
    _portController.dispose();
    _scanStartController.dispose();
    _scanEndController.dispose();
    super.dispose();
  }

  void _selectMode(_NetworkDiagnosticMode mode) {
    if (_busy || _mode == mode) return;
    setState(() {
      _mode = mode;
      _error = null;
      _addresses = null;
      _tcpResult = null;
      _scanResult = null;
      _resultTitle = null;
    });
  }

  Future<void> _run() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();
    final host = _hostController.text.trim();
    final cancellation = _mode == _NetworkDiagnosticMode.scan
        ? TcpPortScanCancellation()
        : null;
    setState(() {
      _busy = true;
      _error = null;
      _addresses = null;
      _tcpResult = null;
      _scanResult = null;
      _resultTitle = null;
      _scanCompleted = 0;
      _scanTotal = 0;
      _scanCancellation = cancellation;
    });

    try {
      switch (_mode) {
        case _NetworkDiagnosticMode.dns:
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
        case _NetworkDiagnosticMode.tcp:
          final port = int.tryParse(_portController.text.trim());
          if (port == null) throw const FormatException('请输入有效的 TCP 端口');
          final result = await probeTcpPort(host, port, timeout: _timeout);
          if (!mounted) return;
          setState(() {
            _tcpResult = result;
            _resultTitle = 'TCP ${result.elapsed.inMilliseconds} ms';
          });
        case _NetworkDiagnosticMode.scan:
          final startPort = int.tryParse(_scanStartController.text.trim());
          final endPort = int.tryParse(_scanEndController.text.trim());
          if (startPort == null || endPort == null) {
            throw const FormatException('请输入有效的起止端口');
          }
          final result = await scanTcpPorts(
            host,
            startPort: startPort,
            endPort: endPort,
            timeout: _scanTimeout,
            cancellation: cancellation,
            onProgress: (completed, total) {
              if (!mounted || cancellation?.isRequested == true) return;
              if (completed != total && completed % 8 != 0) return;
              setState(() {
                _scanCompleted = completed;
                _scanTotal = total;
              });
            },
          );
          if (!mounted) return;
          setState(() {
            _scanResult = result;
            _scanCompleted = result.scannedPorts;
            _scanTotal = result.totalPorts;
            _resultTitle =
                '${result.cancelled ? '扫描已停止' : '扫描完成'} · '
                '${result.scannedPorts}/${result.totalPorts} · '
                '${result.elapsed.inMilliseconds} ms';
          });
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error is FormatException
            ? error.message
            : error.toString().replaceFirst('Bad state: ', '');
      });
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _scanCancellation = null;
        });
      }
    }
  }

  void _cancelScan() {
    final cancellation = _scanCancellation;
    if (cancellation == null || cancellation.isRequested) return;
    setState(cancellation.cancel);
  }

  Duration get _activeTimeout =>
      _mode == _NetworkDiagnosticMode.scan ? _scanTimeout : _timeout;

  List<Duration> get _timeoutOptions => _mode == _NetworkDiagnosticMode.scan
      ? const [
          Duration(milliseconds: 250),
          Duration(milliseconds: 500),
          Duration(seconds: 1),
          Duration(seconds: 2),
          Duration(seconds: 5),
        ]
      : const [
          Duration(seconds: 3),
          Duration(seconds: 5),
          Duration(seconds: 10),
          Duration(seconds: 15),
        ];

  void _setTimeout(Duration timeout) {
    setState(() {
      if (_mode == _NetworkDiagnosticMode.scan) {
        _scanTimeout = timeout;
      } else {
        _timeout = timeout;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final selectedTimeout = _timeoutOptions.contains(_activeTimeout)
        ? _activeTimeout
        : _timeoutOptions.first;
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
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  _modeChip(_NetworkDiagnosticMode.tcp, '单端口'),
                  _modeChip(_NetworkDiagnosticMode.scan, '端口扫描'),
                  _modeChip(_NetworkDiagnosticMode.dns, 'DNS 查询'),
                ],
              ),
              const SizedBox(height: 12),
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
                onSubmitted: (_) => unawaited(_run()),
              ),
              if (_mode == _NetworkDiagnosticMode.tcp) ...[
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
                        onSubmitted: (_) => unawaited(_run()),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: _timeoutField(selectedTimeout)),
                  ],
                ),
              ],
              if (_mode == _NetworkDiagnosticMode.scan) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _scanStartController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: '起始端口'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: _scanEndController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: '结束端口'),
                        onSubmitted: (_) => unawaited(_run()),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _timeoutField(selectedTimeout),
              ],
              if (_mode == _NetworkDiagnosticMode.dns) ...[
                const SizedBox(height: 12),
                _timeoutField(selectedTimeout),
              ],
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: _busy ? null : () => unawaited(_run()),
                icon: Icon(switch (_mode) {
                  _NetworkDiagnosticMode.dns => Icons.search_rounded,
                  _NetworkDiagnosticMode.tcp => Icons.cable_rounded,
                  _NetworkDiagnosticMode.scan => Icons.radar_rounded,
                }, size: 18),
                label: Text(switch (_mode) {
                  _NetworkDiagnosticMode.dns => '查询 DNS',
                  _NetworkDiagnosticMode.tcp => '测试 TCP 端口',
                  _NetworkDiagnosticMode.scan => '开始扫描',
                }),
              ),
              if (_busy) ...[
                const SizedBox(height: 14),
                LinearProgressIndicator(
                  value: _mode == _NetworkDiagnosticMode.scan && _scanTotal > 0
                      ? _scanCompleted / _scanTotal
                      : null,
                ),
                if (_mode == _NetworkDiagnosticMode.scan) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _scanCancellation?.isRequested == true
                              ? '正在停止，等待已开始的连接结束…'
                              : _scanTotal == 0
                              ? '正在解析主机…'
                              : '已完成 $_scanCompleted / $_scanTotal',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      TextButton(
                        onPressed: _scanCancellation?.isRequested == true
                            ? null
                            : _cancelScan,
                        child: const Text('停止'),
                      ),
                    ],
                  ),
                ],
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
                  icon: _scanResult?.cancelled == true
                      ? Icons.stop_circle_outlined
                      : Icons.check_circle_outline_rounded,
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
                    if (_scanResult != null) _scanResultContent(_scanResult!),
                  ],
                ),
              ],
              const SizedBox(height: 12),
              Text(
                _helpText,
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

  Widget _modeChip(_NetworkDiagnosticMode mode, String label) => ChoiceChip(
    label: Text(label),
    selected: _mode == mode,
    onSelected: _busy ? null : (_) => _selectMode(mode),
  );

  Widget _timeoutField(Duration selectedTimeout) =>
      DropdownButtonFormField<Duration>(
        initialValue: selectedTimeout,
        decoration: const InputDecoration(labelText: '超时'),
        items: _timeoutOptions
            .map(
              (duration) => DropdownMenuItem(
                value: duration,
                child: Text(_formatDuration(duration)),
              ),
            )
            .toList(),
        onChanged: _busy
            ? null
            : (duration) {
                if (duration != null) _setTimeout(duration);
              },
      );

  String get _helpText => switch (_mode) {
    _NetworkDiagnosticMode.dns => 'DNS 查询不会保存主机记录。',
    _NetworkDiagnosticMode.tcp => 'TCP 检查握手后立即关闭，不发送应用数据。主机和端口不会保存。',
    _NetworkDiagnosticMode.scan =>
      '只扫描单个主机解析出的首个地址，每次最多 1024 个连续端口、24 个并发连接。仅列出已建立连接的端口；拒绝、过滤和超时都不会列为开放。',
  };

  Widget _scanResultContent(TcpPortScanResult result) {
    if (result.openPorts.isEmpty) {
      return Text('目标地址：${result.targetAddress}\n未发现开放端口');
    }
    final lines = result.openPorts
        .map((port) {
          final service = _commonServices[port];
          return service == null ? '$port/tcp' : '$port/tcp  $service';
        })
        .join('\n');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('目标地址：${result.targetAddress} · 开放 ${result.openPorts.length} 个'),
        const SizedBox(height: 6),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 160),
          child: SingleChildScrollView(
            child: SelectableText(
              lines,
              style: const TextStyle(fontFamily: 'monospace'),
            ),
          ),
        ),
      ],
    );
  }

  static String _formatDuration(Duration duration) =>
      duration.inMilliseconds < 1000
      ? '${duration.inMilliseconds} ms'
      : '${duration.inSeconds} 秒';

  static const _commonServices = <int, String>{
    21: 'FTP',
    22: 'SSH',
    23: 'Telnet',
    25: 'SMTP',
    53: 'DNS',
    80: 'HTTP',
    110: 'POP3',
    143: 'IMAP',
    443: 'HTTPS',
    445: 'SMB',
    3389: 'RDP',
  };
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
