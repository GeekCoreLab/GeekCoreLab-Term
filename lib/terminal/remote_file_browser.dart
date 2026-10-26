import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'package:geekcore_term/terminal/remote_file_transfer.dart';

class RemoteFileBrowser extends StatefulWidget {
  const RemoteFileBrowser({
    required this.client,
    required this.sessionTitle,
    required this.initialPath,
    required this.refreshToken,
    required this.protocol,
    required this.onDirectoryChanged,
    required this.onProtocolChanged,
    required this.onMessage,
    super.key,
  });

  final SSHClient client;
  final String sessionTitle;
  final String? initialPath;
  final int refreshToken;
  final RemoteTransferProtocol protocol;
  final ValueChanged<String> onDirectoryChanged;
  final ValueChanged<RemoteTransferProtocol> onProtocolChanged;
  final void Function(String message, {bool? isError}) onMessage;

  @override
  State<RemoteFileBrowser> createState() => _RemoteFileBrowserState();
}

class _RemoteFileBrowserState extends State<RemoteFileBrowser> {
  final TextEditingController _pathController = TextEditingController();
  SftpClient? _sftp;
  List<SftpName> _entries = const [];
  SftpName? _selectedEntry;
  String? _currentPath;
  String? _error;
  bool _loading = true;
  bool _dragging = false;
  bool _transferring = false;
  int? _transferProgress;
  int? _transferLength;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_connect());
  }

  @override
  void didUpdateWidget(covariant RemoteFileBrowser oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.client, oldWidget.client)) {
      unawaited(_connect());
    } else if (widget.refreshToken != oldWidget.refreshToken) {
      unawaited(_refresh());
    }
  }

  Future<void> _connect() async {
    final generation = ++_generation;
    final oldSftp = _sftp;
    _sftp = null;
    if (oldSftp != null) await oldSftp.close();
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
      _entries = const [];
      _currentPath = null;
      _selectedEntry = null;
    });

    try {
      final sftp = await widget.client.sftp();
      if (!mounted || generation != _generation) {
        await sftp.close();
        return;
      }
      _sftp = sftp;
      await _navigate(widget.initialPath ?? '.');
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _navigate(String path) async {
    final sftp = _sftp;
    if (sftp == null) return;
    final generation = _generation;
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final absolutePath = await sftp.absolute(path);
      final entries = await sftp.listdir(absolutePath);
      entries.removeWhere(
        (entry) => entry.filename == '.' || entry.filename == '..',
      );
      entries.sort((a, b) {
        final directoryOrder =
            (b.attr.isDirectory ? 1 : 0) - (a.attr.isDirectory ? 1 : 0);
        return directoryOrder != 0
            ? directoryOrder
            : a.filename.toLowerCase().compareTo(b.filename.toLowerCase());
      });
      if (!mounted || generation != _generation) return;
      setState(() {
        _currentPath = absolutePath;
        _pathController.text = absolutePath;
        _entries = entries;
        _selectedEntry = null;
        _loading = false;
      });
      widget.onDirectoryChanged(absolutePath);
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _refresh() async {
    final path = _currentPath;
    if (path == null) {
      await _connect();
    } else {
      await _navigate(path);
    }
  }

  Future<void> _goUp() async {
    final path = _currentPath;
    if (path == null || path == '/') return;
    final trimmed = path.endsWith('/')
        ? path.substring(0, path.length - 1)
        : path;
    final slash = trimmed.lastIndexOf('/');
    await _navigate(slash <= 0 ? '/' : trimmed.substring(0, slash));
  }

  String _remotePath(String name) {
    final directory = _currentPath ?? '/';
    return directory.endsWith('/') ? '$directory$name' : '$directory/$name';
  }

  Future<void> _chooseFiles() async {
    if (_transferring) return;
    try {
      final files = await FilePicker.pickFiles(dialogTitle: '选择要上传的文件');
      if (files.isEmpty) return;
      await _uploadSources([
        for (final file in files)
          RemoteFileSource(
            name: file.name,
            length: () async => (await file.length()) ?? 0,
            openRead: file.readAsByteStream,
          ),
      ]);
    } catch (error) {
      widget.onMessage('选择文件失败：$error', isError: true);
    }
  }

  Future<void> _uploadDropped(List<DropItem> dropped) async {
    final files = dropped.whereType<DropItemFile>().toList();
    final hasDirectories = dropped.any((item) => item is DropItemDirectory);
    if (files.isEmpty) {
      if (hasDirectories) widget.onMessage('当前支持拖拽文件上传，暂不支持目录');
      return;
    }
    if (hasDirectories) widget.onMessage('目录已跳过；其余文件继续上传');
    await _uploadSources([
      for (final file in files)
        RemoteFileSource(
          name: file.name,
          length: file.length,
          openRead: file.openRead,
        ),
    ]);
  }

  Future<void> _uploadSources(List<RemoteFileSource> sources) async {
    final sftp = _sftp;
    final path = _currentPath;
    if (sftp == null || path == null || _transferring) return;
    setState(() {
      _transferring = true;
      _transferProgress = 0;
      _transferLength = null;
    });
    try {
      var completed = 0;
      for (final source in sources) {
        final exists = _entries.any((entry) => entry.filename == source.name);
        if (exists && !await _confirmOverwrite(source.name)) continue;
        final length = await source.length();
        if (mounted) {
          setState(() {
            _transferLength = length;
            _transferProgress = 0;
          });
        }
        await uploadRemoteFile(
          client: widget.client,
          remoteDirectory: path,
          source: source,
          protocol: widget.protocol,
          sftpClient: sftp,
          onProgress: (bytes) {
            if (mounted) setState(() => _transferProgress = bytes);
          },
        );
        completed++;
      }
      widget.onMessage(completed == 0 ? '没有上传文件' : '已上传 $completed 个文件');
      await _refresh();
    } catch (error) {
      widget.onMessage('上传失败：$error', isError: true);
    } finally {
      if (mounted) {
        setState(() {
          _transferring = false;
          _transferProgress = null;
          _transferLength = null;
        });
      }
    }
  }

  Future<void> _download(SftpName entry) async {
    final sftp = _sftp;
    if (sftp == null || entry.attr.isDirectory || _transferring) return;
    final remotePath = _remotePath(entry.filename);
    setState(() {
      _transferring = true;
      _transferProgress = 0;
      _transferLength = entry.attr.size;
    });
    try {
      final bytes = await downloadRemoteFile(
        client: widget.client,
        remotePath: remotePath,
        protocol: widget.protocol,
        sftpClient: sftp,
        onProgress: (received) {
          if (mounted) setState(() => _transferProgress = received);
        },
      );
      final result = await FilePicker.saveFile(
        fileName: entry.filename,
        bytes: bytes,
        dialogTitle: '下载 ${entry.filename}',
      );
      if (result != null) widget.onMessage('已下载 ${entry.filename}');
    } catch (error) {
      widget.onMessage('下载失败：$error', isError: true);
    } finally {
      if (mounted) {
        setState(() {
          _transferring = false;
          _transferProgress = null;
          _transferLength = null;
        });
      }
    }
  }

  Future<void> _createDirectory() async {
    final name = await _askForName(title: '新建远端文件夹', label: '文件夹名称');
    if (name == null || name.isEmpty) return;
    try {
      await _sftp?.mkdir(_remotePath(name));
      await _refresh();
      widget.onMessage('已创建文件夹 $name');
    } catch (error) {
      widget.onMessage('创建文件夹失败：$error', isError: true);
    }
  }

  Future<void> _rename(SftpName entry) async {
    final name = await _askForName(
      title: '重命名',
      label: '新名称',
      initialValue: entry.filename,
    );
    if (name == null || name.isEmpty || name == entry.filename) return;
    if (name.contains('/')) {
      widget.onMessage('名称不能包含路径分隔符', isError: true);
      return;
    }
    if (_entries.any((item) => item.filename == name) &&
        !await _confirmOverwrite(name)) {
      return;
    }
    try {
      await _sftp?.rename(_remotePath(entry.filename), _remotePath(name));
      await _refresh();
      widget.onMessage('已重命名为 $name');
    } catch (error) {
      widget.onMessage('重命名失败：$error', isError: true);
    }
  }

  Future<void> _delete(SftpName entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除远端项目？'),
        content: Text('将删除“${entry.filename}”。此操作无法撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      if (entry.attr.isDirectory) {
        await _sftp?.rmdir(_remotePath(entry.filename));
      } else {
        await _sftp?.remove(_remotePath(entry.filename));
      }
      await _refresh();
      widget.onMessage('已删除 ${entry.filename}');
    } catch (error) {
      widget.onMessage('删除失败：$error', isError: true);
    }
  }

  Future<bool> _confirmOverwrite(String name) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('覆盖远端项目？'),
          content: Text('“$name”已存在。继续会替换现有项目。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('覆盖'),
            ),
          ],
        ),
      ) ??
      false;

  Future<String?> _askForName({
    required String title,
    required String label,
    String initialValue = '',
  }) async {
    final controller = TextEditingController(text: initialValue);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: label),
          onSubmitted: (value) => Navigator.pop(context, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  @override
  void dispose() {
    _generation++;
    _pathController.dispose();
    final sftp = _sftp;
    if (sftp != null) unawaited(sftp.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: 260,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '远端文件',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        widget.sessionTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<RemoteTransferProtocol>(
                  tooltip: '传输协议',
                  initialValue: widget.protocol,
                  onSelected: widget.onProtocolChanged,
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                      value: RemoteTransferProtocol.sftp,
                      child: Text('SFTP 传输'),
                    ),
                    PopupMenuItem(
                      value: RemoteTransferProtocol.scp,
                      child: Text('SCP 传输'),
                    ),
                  ],
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      border: Border.all(color: colors.outlineVariant),
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: Text(
                      widget.protocol.name.toUpperCase(),
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              children: [
                IconButton(
                  tooltip: '上级目录',
                  visualDensity: VisualDensity.compact,
                  onPressed: _currentPath == null || _currentPath == '/'
                      ? null
                      : _goUp,
                  icon: const Icon(Icons.arrow_upward_rounded, size: 18),
                ),
                IconButton(
                  tooltip: '刷新',
                  visualDensity: VisualDensity.compact,
                  onPressed: _loading ? null : _refresh,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                ),
                Expanded(
                  child: TextField(
                    controller: _pathController,
                    enabled: !_loading,
                    style: const TextStyle(fontSize: 11),
                    decoration: const InputDecoration(
                      isDense: true,
                      hintText: '远端绝对路径',
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 8,
                      ),
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (path) => unawaited(_navigate(path.trim())),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _transferring ? null : _chooseFiles,
                    icon: const Icon(Icons.upload_file_rounded, size: 17),
                    label: const Text('上传'),
                  ),
                ),
                const SizedBox(width: 6),
                IconButton.filledTonal(
                  tooltip: '新建文件夹',
                  onPressed: _createDirectory,
                  icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
          if (_transferring)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(
                    value: _transferLength == null || _transferLength == 0
                        ? null
                        : ((_transferProgress ?? 0) / _transferLength!).clamp(
                            0,
                            1,
                          ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _transferLength == null || _transferLength == 0
                        ? '正在传输…'
                        : '${_formatSize(_transferProgress ?? 0)} / ${_formatSize(_transferLength!)}',
                    style: TextStyle(
                      fontSize: 10,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                '无法读取目录：$_error',
                style: TextStyle(color: colors.error, fontSize: 12),
              ),
            ),
          if (!_loading && _error == null && _entries.isEmpty)
            Padding(
              padding: const EdgeInsets.all(14),
              child: Text(
                '此目录为空。可将本地文件拖到这里上传。',
                style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
              ),
            ),
          Expanded(
            child: DropTarget(
              onDragEntered: (_) => setState(() => _dragging = true),
              onDragExited: (_) => setState(() => _dragging = false),
              onDragDone: (details) => unawaited(_uploadDropped(details.files)),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: _dragging
                      ? colors.primary.withValues(alpha: 0.08)
                      : null,
                  border: _dragging
                      ? Border.all(color: colors.primary.withValues(alpha: 0.5))
                      : null,
                ),
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(5, 0, 5, 8),
                  itemCount: _entries.length,
                  itemBuilder: (context, index) =>
                      _buildEntry(_entries[index], colors),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 5, 12, 10),
            child: Text(
              '拖动远端文件到终端可插入路径',
              style: TextStyle(fontSize: 10, color: colors.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEntry(SftpName entry, ColorScheme colors) {
    final isDirectory = entry.attr.isDirectory;
    final path = _remotePath(entry.filename);
    final selected = identical(_selectedEntry, entry);
    final icon = isDirectory
        ? Icons.folder_rounded
        : entry.attr.isSymbolicLink
        ? Icons.link_rounded
        : Icons.insert_drive_file_outlined;
    return Draggable<String>(
      data: path,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Material(
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
        elevation: 5,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: colors.primary),
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 180),
                child: Text(entry.filename, overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
        ),
      ),
      childWhenDragging: Opacity(
        opacity: 0.4,
        child: _entryTile(entry, selected, icon, colors),
      ),
      child: _entryTile(entry, selected, icon, colors),
    );
  }

  Widget _entryTile(
    SftpName entry,
    bool selected,
    IconData icon,
    ColorScheme colors,
  ) {
    return Material(
      color: selected
          ? colors.primary.withValues(alpha: 0.12)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(7),
      child: InkWell(
        borderRadius: BorderRadius.circular(7),
        onTap: () => setState(() => _selectedEntry = entry),
        onDoubleTap: () {
          if (entry.attr.isDirectory) {
            unawaited(_navigate(_remotePath(entry.filename)));
          } else {
            unawaited(_download(entry));
          }
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(9, 7, 2, 7),
          child: Row(
            children: [
              Icon(
                icon,
                size: 18,
                color: entry.attr.isDirectory
                    ? colors.primary
                    : colors.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.filename,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                    Text(
                      entry.attr.isDirectory
                          ? '文件夹'
                          : _formatSize(entry.attr.size ?? 0),
                      style: TextStyle(
                        fontSize: 10,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: '文件操作',
                onSelected: (action) {
                  switch (action) {
                    case 'download':
                      unawaited(_download(entry));
                      break;
                    case 'rename':
                      unawaited(_rename(entry));
                      break;
                    case 'delete':
                      unawaited(_delete(entry));
                      break;
                  }
                },
                itemBuilder: (context) => [
                  if (!entry.attr.isDirectory)
                    const PopupMenuItem(value: 'download', child: Text('下载')),
                  const PopupMenuItem(value: 'rename', child: Text('重命名')),
                  const PopupMenuItem(value: 'delete', child: Text('删除')),
                ],
                icon: const Icon(Icons.more_vert_rounded, size: 17),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _formatSize(int value) {
  if (value < 1024) return '$value B';
  if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(1)} KB';
  if (value < 1024 * 1024 * 1024) {
    return '${(value / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(value / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}
