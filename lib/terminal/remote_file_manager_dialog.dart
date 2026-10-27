import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:geekcore_term/terminal/local_file_system.dart';
import 'package:geekcore_term/terminal/file_comparison.dart';
import 'package:geekcore_term/terminal/file_comparison_dialog.dart';
import 'package:geekcore_term/terminal/remote_file_transfer.dart';

class RemoteFileManagerDialog extends StatefulWidget {
  const RemoteFileManagerDialog({
    required this.client,
    required this.sessionTitle,
    required this.initialRemotePath,
    required this.protocol,
    required this.onDirectoryChanged,
    required this.onProtocolChanged,
    required this.onQueueUploads,
    required this.onQueueDownload,
    required this.onMessage,
    super.key,
  });

  final SSHClient client;
  final String sessionTitle;
  final String? initialRemotePath;
  final RemoteTransferProtocol protocol;
  final ValueChanged<String> onDirectoryChanged;
  final ValueChanged<RemoteTransferProtocol> onProtocolChanged;
  final Future<void> Function(
    List<String> paths,
    String remoteDirectory,
    RemoteTransferProtocol protocol,
  )
  onQueueUploads;
  final Future<void> Function(
    SftpName entry,
    String remotePath,
    RemoteTransferProtocol protocol,
    String localDirectory,
  )
  onQueueDownload;
  final void Function(String message, {bool? isError}) onMessage;

  @override
  State<RemoteFileManagerDialog> createState() =>
      _RemoteFileManagerDialogState();
}

class _RemoteFileManagerDialogState extends State<RemoteFileManagerDialog> {
  final TextEditingController _localPathController = TextEditingController();
  final TextEditingController _remotePathController = TextEditingController();
  SftpClient? _sftp;
  List<LocalFileEntry> _localEntries = const [];
  List<SftpName> _remoteEntries = const [];
  final Set<String> _selectedLocalPaths = {};
  final Set<String> _selectedRemotePaths = {};
  String? _localPath;
  String? _remotePath;
  String? _localError;
  String? _remoteError;
  RemoteTransferProtocol _protocol = RemoteTransferProtocol.sftp;
  bool _localLoading = false;
  bool _remoteLoading = true;
  bool _transferring = false;
  bool _comparing = false;
  bool _showRemoteOnCompact = true;
  int _generation = 0;
  int _remoteNavigationGeneration = 0;
  int _localNavigationGeneration = 0;

  @override
  void initState() {
    super.initState();
    _protocol = widget.protocol;
    unawaited(_connectRemote());
    if (localFileSystemSupported) unawaited(_openDefaultLocalDirectory());
  }

  @override
  void dispose() {
    _generation++;
    _remoteNavigationGeneration++;
    _localNavigationGeneration++;
    _localPathController.dispose();
    _remotePathController.dispose();
    unawaited(_sftp?.close());
    super.dispose();
  }

  Future<void> _connectRemote() async {
    final generation = ++_generation;
    final previous = _sftp;
    _sftp = null;
    if (previous != null) await previous.close();
    if (!mounted) return;
    setState(() {
      _remoteLoading = true;
      _remoteError = null;
      _remoteEntries = const [];
    });
    try {
      final sftp = await widget.client.sftp();
      if (!mounted || generation != _generation) {
        await sftp.close();
        return;
      }
      _sftp = sftp;
      await _navigateRemote(widget.initialRemotePath ?? '.');
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _remoteLoading = false;
        _remoteError = error.toString();
      });
    }
  }

  Future<void> _navigateRemote(String path) async {
    final sftp = _sftp;
    if (sftp == null || !mounted) return;
    final connectionGeneration = _generation;
    final navigationGeneration = ++_remoteNavigationGeneration;
    setState(() {
      _remoteLoading = true;
      _remoteError = null;
    });
    try {
      final absolutePath = await sftp.absolute(path);
      final entries = await sftp.listdir(absolutePath);
      entries.removeWhere(
        (entry) =>
            entry.filename == '.' ||
            entry.filename == '..' ||
            isRemoteTransferTemporaryFileName(entry.filename),
      );
      entries.sort((left, right) {
        final typeOrder =
            (right.attr.isDirectory ? 1 : 0) - (left.attr.isDirectory ? 1 : 0);
        if (typeOrder != 0) return typeOrder;
        return left.filename.toLowerCase().compareTo(
          right.filename.toLowerCase(),
        );
      });
      if (!mounted ||
          connectionGeneration != _generation ||
          navigationGeneration != _remoteNavigationGeneration) {
        return;
      }
      setState(() {
        _remotePath = absolutePath;
        _remotePathController.text = absolutePath;
        _remoteEntries = entries;
        _selectedRemotePaths.clear();
        _remoteLoading = false;
      });
      widget.onDirectoryChanged(absolutePath);
    } catch (error) {
      if (!mounted ||
          connectionGeneration != _generation ||
          navigationGeneration != _remoteNavigationGeneration) {
        return;
      }
      setState(() {
        _remoteLoading = false;
        _remoteError = error.toString();
      });
    }
  }

  Future<void> _openDefaultLocalDirectory() async {
    try {
      final path = await defaultLocalDirectory();
      if (path != null && mounted) await _navigateLocal(path);
    } catch (error) {
      if (!mounted) return;
      setState(() => _localError = error.toString());
    }
  }

  Future<void> _navigateLocal(String path) async {
    if (!localFileSystemSupported || !mounted) return;
    final navigationGeneration = ++_localNavigationGeneration;
    setState(() {
      _localLoading = true;
      _localError = null;
    });
    try {
      final entries = await listLocalDirectory(path);
      if (!mounted || navigationGeneration != _localNavigationGeneration) {
        return;
      }
      setState(() {
        _localPath = path;
        _localPathController.text = path;
        _localEntries = entries;
        _selectedLocalPaths.clear();
        _localLoading = false;
      });
    } catch (error) {
      if (!mounted || navigationGeneration != _localNavigationGeneration) {
        return;
      }
      setState(() {
        _localLoading = false;
        _localError = error.toString();
      });
    }
  }

  Future<void> _chooseLocalDirectory() async {
    if (!localFileSystemSupported) return;
    try {
      final path = await FilePicker.getDirectoryPath(
        dialogTitle: '选择本地目录',
        initialDirectory: _localPath,
      );
      if (path != null && mounted) await _navigateLocal(path);
    } catch (error) {
      if (!mounted) return;
      setState(() => _localError = '无法选择本地目录：$error');
    }
  }

  Future<void> _queueUploads() async {
    final path = _remotePath;
    if (_selectedLocalPaths.isEmpty || path == null || _transferring) return;
    setState(() => _transferring = true);
    try {
      await widget.onQueueUploads(
        _selectedLocalPaths.toList()..sort(),
        path,
        _protocol,
      );
      if (!mounted) return;
      await _navigateRemote(path);
    } catch (error) {
      if (mounted) widget.onMessage('上传队列失败：$error', isError: true);
    } finally {
      if (mounted) setState(() => _transferring = false);
    }
  }

  Future<void> _queueDownloads() async {
    final localPath = _localPath;
    final remotePath = _remotePath;
    if (_selectedRemotePaths.isEmpty ||
        localPath == null ||
        remotePath == null ||
        _transferring) {
      return;
    }
    final entries = _remoteEntries
        .where(
          (entry) =>
              _selectedRemotePaths.contains(entry.filename) &&
              !entry.attr.isDirectory,
        )
        .toList();
    if (entries.isEmpty) {
      widget.onMessage('请选择一个或多个远端文件', isError: true);
      return;
    }
    setState(() => _transferring = true);
    try {
      for (final entry in entries) {
        final path = remotePath.endsWith('/')
            ? '$remotePath${entry.filename}'
            : '$remotePath/${entry.filename}';
        await widget.onQueueDownload(entry, path, _protocol, localPath);
      }
      if (!mounted) return;
      await _navigateLocal(localPath);
    } catch (error) {
      if (mounted) widget.onMessage('下载队列失败：$error', isError: true);
    } finally {
      if (mounted) setState(() => _transferring = false);
    }
  }

  bool get _canCompareFiles {
    if (!localFileSystemSupported ||
        _selectedLocalPaths.length != 1 ||
        _selectedRemotePaths.length != 1) {
      return false;
    }
    final localPath = _selectedLocalPaths.single;
    final remoteName = _selectedRemotePaths.single;
    final local = _localEntries.where((entry) => entry.path == localPath);
    final remote = _remoteEntries.where(
      (entry) => entry.filename == remoteName,
    );
    return local.length == 1 &&
        remote.length == 1 &&
        !local.single.isDirectory &&
        remote.single.attr.isFile;
  }

  Future<Uint8List> _readLocalForComparison(String path) async {
    final source = await localFileSource(path);
    final length = await source.length();
    if (length > maxComparableFileBytes) {
      throw StateError('本地文件超过 2 MiB 比较上限');
    }
    final output = BytesBuilder(copy: false);
    var received = 0;
    await for (final chunk in source.openRead()) {
      received += chunk.length;
      if (received > maxComparableFileBytes) {
        throw StateError('本地文件读取长度超过 2 MiB 比较上限');
      }
      output.add(chunk);
    }
    final bytes = output.takeBytes();
    if (bytes.length != length) {
      throw StateError('本地文件在比较期间发生变化');
    }
    return bytes;
  }

  Future<Uint8List> _readRemoteForComparison(
    SftpClient sftp,
    String path,
  ) async {
    final pathVersion = await sftp.stat(path, followLink: false);
    if (!pathVersion.isFile) {
      throw StateError('仅支持比较远端普通文件，不跟随符号链接');
    }
    final remoteFile = await sftp.open(path, mode: SftpFileOpenMode.read);
    try {
      final initial = await remoteFile.stat();
      if (!initial.isFile || !_sameRemoteFileVersion(pathVersion, initial)) {
        throw StateError('远端文件在打开前发生变化');
      }
      final length = initial.size;
      if (length == null || length < 0) {
        throw StateError('远端未提供可读取的文件长度');
      }
      if (length > maxComparableFileBytes) {
        throw StateError('远端文件超过 2 MiB 比较上限');
      }
      final bytes = await remoteFile.readBytes(length: length);
      if (bytes.length != length) {
        throw StateError('远端文件读取不完整');
      }
      final currentHandleVersion = await remoteFile.stat();
      final currentPathVersion = await sftp.stat(path, followLink: false);
      if (!_sameRemoteFileVersion(initial, currentHandleVersion) ||
          !_sameRemoteFileVersion(pathVersion, currentPathVersion) ||
          !currentPathVersion.isFile) {
        throw StateError('远端文件在比较期间发生变化');
      }
      return bytes;
    } finally {
      await remoteFile.close();
    }
  }

  bool _sameRemoteFileVersion(SftpFileAttrs left, SftpFileAttrs right) =>
      left.size == right.size && left.modifyTime == right.modifyTime;

  Future<void> _compareSelectedFiles() async {
    if (!_canCompareFiles || _comparing || _transferring) return;
    final localPath = _selectedLocalPaths.single;
    final remoteName = _selectedRemotePaths.single;
    final remotePath = _remotePath;
    final sftp = _sftp;
    if (remotePath == null || sftp == null) return;
    final localEntry = _localEntries.singleWhere(
      (entry) => entry.path == localPath,
    );
    final remoteEntry = _remoteEntries.singleWhere(
      (entry) => entry.filename == remoteName,
    );
    final fullRemotePath = remotePath.endsWith('/')
        ? '$remotePath$remoteName'
        : '$remotePath/$remoteName';
    setState(() => _comparing = true);
    try {
      final localBytes = await _readLocalForComparison(localPath);
      final remoteBytes = await _readRemoteForComparison(sftp, fullRemotePath);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => FileComparisonDialog(
          leftName: localEntry.name,
          leftPath: localEntry.path,
          rightName: remoteEntry.filename,
          rightPath: fullRemotePath,
          comparison: compareFileContents(localBytes, remoteBytes),
        ),
      );
    } catch (error) {
      if (mounted) widget.onMessage('比较文件失败：$error', isError: true);
    } finally {
      if (mounted) setState(() => _comparing = false);
    }
  }

  void _setProtocol(RemoteTransferProtocol? value) {
    if (value == null) return;
    setState(() => _protocol = value);
    widget.onProtocolChanged(value);
  }

  String _remoteParent(String path) {
    if (path == '/') return path;
    final trimmed = path.endsWith('/')
        ? path.substring(0, path.length - 1)
        : path;
    final slash = trimmed.lastIndexOf('/');
    return slash <= 0 ? '/' : trimmed.substring(0, slash);
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final compact = screen.width < 820;
    final width = (screen.width - (compact ? 0 : 48)).clamp(360.0, 1320.0);
    final height = (screen.height - (compact ? 0 : 48)).clamp(420.0, 900.0);
    final colors = Theme.of(context).colorScheme;
    final localPane = _buildLocalPane(colors);
    final remotePane = _buildRemotePane(colors);

    return Dialog(
      insetPadding: EdgeInsets.all(compact ? 0 : 24),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: width,
        height: height,
        child: Column(
          children: [
            _buildHeader(colors, compact),
            if (_transferring) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: compact
                  ? Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                          child: SegmentedButton<bool>(
                            segments: const [
                              ButtonSegment(
                                value: false,
                                icon: Icon(Icons.computer_rounded),
                                label: Text('本地'),
                              ),
                              ButtonSegment(
                                value: true,
                                icon: Icon(Icons.dns_rounded),
                                label: Text('远端'),
                              ),
                            ],
                            selected: {_showRemoteOnCompact},
                            onSelectionChanged: (selection) => setState(
                              () => _showRemoteOnCompact = selection.first,
                            ),
                          ),
                        ),
                        Expanded(
                          child: _showRemoteOnCompact ? remotePane : localPane,
                        ),
                      ],
                    )
                  : Row(
                      children: [
                        Expanded(child: localPane),
                        VerticalDivider(width: 1, color: colors.outlineVariant),
                        Expanded(child: remotePane),
                      ],
                    ),
            ),
            _buildFooter(colors),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ColorScheme colors, bool compact) => Padding(
    padding: EdgeInsets.fromLTRB(compact ? 12 : 20, 12, 8, 8),
    child: Row(
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: colors.primaryContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(Icons.folder_copy_rounded, color: colors.primary),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '双栏文件管理',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
              ),
              Text(
                widget.sessionTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
              ),
            ],
          ),
        ),
        DropdownButton<RemoteTransferProtocol>(
          value: _protocol,
          underline: const SizedBox.shrink(),
          borderRadius: BorderRadius.circular(12),
          items: const [
            DropdownMenuItem(
              value: RemoteTransferProtocol.sftp,
              child: Text('SFTP'),
            ),
            DropdownMenuItem(
              value: RemoteTransferProtocol.scp,
              child: Text('SCP'),
            ),
          ],
          onChanged: _setProtocol,
        ),
        IconButton(
          tooltip: '关闭',
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.close_rounded),
        ),
      ],
    ),
  );

  Widget _buildLocalPane(ColorScheme colors) => Padding(
    padding: const EdgeInsets.all(12),
    child: Column(
      children: [
        _paneTitle(colors, Icons.computer_rounded, '本地文件'),
        const SizedBox(height: 8),
        _pathBar(
          controller: _localPathController,
          onUp: _localPath == null
              ? null
              : () => _navigateLocal(localParentDirectory(_localPath!)),
          onRefresh: _localPath == null
              ? null
              : () => _navigateLocal(_localPath!),
          onChoose: localFileSystemSupported ? _chooseLocalDirectory : null,
          chooseTooltip: '选择本地目录',
          colors: colors,
        ),
        if (!localFileSystemSupported)
          Expanded(child: _emptyState(Icons.web_rounded, 'Web 环境不提供本地目录浏览'))
        else
          Expanded(child: _buildLocalList(colors)),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed:
                _selectedLocalPaths.isEmpty ||
                    _remotePath == null ||
                    _transferring ||
                    _comparing
                ? null
                : _queueUploads,
            icon: const Icon(Icons.upload_rounded, size: 18),
            label: Text('上传所选 (${_selectedLocalPaths.length})'),
          ),
        ),
      ],
    ),
  );

  Widget _buildRemotePane(ColorScheme colors) => Padding(
    padding: const EdgeInsets.all(12),
    child: Column(
      children: [
        _paneTitle(colors, Icons.dns_rounded, '远端文件'),
        const SizedBox(height: 8),
        _pathBar(
          controller: _remotePathController,
          onUp: _remotePath == null || _remotePath == '/'
              ? null
              : () => _navigateRemote(_remoteParent(_remotePath!)),
          onRefresh: _remotePath == null
              ? null
              : () => _navigateRemote(_remotePath!),
          onChoose: null,
          chooseTooltip: '',
          colors: colors,
          onSubmitted: _navigateRemote,
        ),
        Expanded(child: _buildRemoteList(colors)),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed:
                _selectedRemotePaths.isEmpty ||
                    _localPath == null ||
                    _transferring ||
                    _comparing
                ? null
                : _queueDownloads,
            icon: const Icon(Icons.download_rounded, size: 18),
            label: Text('下载所选 (${_selectedRemotePaths.length})'),
          ),
        ),
      ],
    ),
  );

  Widget _paneTitle(ColorScheme colors, IconData icon, String title) => Row(
    children: [
      Icon(icon, size: 18, color: colors.primary),
      const SizedBox(width: 8),
      Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      const Spacer(),
      if (title == '本地文件')
        Text(
          _localPath == null ? '' : '${_selectedLocalPaths.length} 项已选',
          style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
        )
      else
        Text(
          _remotePath == null ? '' : '${_selectedRemotePaths.length} 项已选',
          style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
        ),
    ],
  );

  Widget _pathBar({
    required TextEditingController controller,
    required VoidCallback? onUp,
    required VoidCallback? onRefresh,
    required VoidCallback? onChoose,
    required String chooseTooltip,
    required ColorScheme colors,
    ValueChanged<String>? onSubmitted,
  }) => Row(
    children: [
      IconButton(
        tooltip: '上级目录',
        visualDensity: VisualDensity.compact,
        onPressed: onUp,
        icon: const Icon(Icons.arrow_upward_rounded, size: 18),
      ),
      Expanded(
        child: TextField(
          controller: controller,
          readOnly: onSubmitted == null,
          onSubmitted: onSubmitted,
          maxLines: 1,
          style: const TextStyle(fontSize: 12),
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: colors.surfaceContainerLow,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 10,
              vertical: 9,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide.none,
            ),
          ),
        ),
      ),
      IconButton(
        tooltip: '刷新目录',
        visualDensity: VisualDensity.compact,
        onPressed: onRefresh,
        icon: const Icon(Icons.refresh_rounded, size: 18),
      ),
      if (onChoose != null)
        IconButton(
          tooltip: chooseTooltip,
          visualDensity: VisualDensity.compact,
          onPressed: onChoose,
          icon: const Icon(Icons.folder_open_rounded, size: 18),
        ),
    ],
  );

  Widget _buildLocalList(ColorScheme colors) {
    if (_localLoading) return const Center(child: CircularProgressIndicator());
    if (_localError != null) {
      return _errorState(_localError!, () {
        final path = _localPath;
        if (path != null) unawaited(_navigateLocal(path));
      });
    }
    if (_localPath == null) {
      return _emptyState(Icons.folder_open_rounded, '选择一个本地目录开始');
    }
    if (_localEntries.isEmpty) {
      return _emptyState(Icons.inbox_rounded, '此目录为空');
    }
    return ListView.builder(
      itemCount: _localEntries.length,
      itemBuilder: (context, index) {
        final entry = _localEntries[index];
        final selected = _selectedLocalPaths.contains(entry.path);
        return _fileTile(
          colors: colors,
          name: entry.name,
          isDirectory: entry.isDirectory,
          selected: selected,
          detail: entry.isDirectory ? '文件夹' : _formatBytes(entry.size ?? 0),
          onTap: () => setState(() {
            if (selected) {
              _selectedLocalPaths.remove(entry.path);
            } else {
              _selectedLocalPaths.add(entry.path);
            }
          }),
          onDoubleTap: entry.isDirectory
              ? () => _navigateLocal(entry.path)
              : null,
        );
      },
    );
  }

  Widget _buildRemoteList(ColorScheme colors) {
    if (_remoteLoading) return const Center(child: CircularProgressIndicator());
    if (_remoteError != null) {
      return _errorState(_remoteError!, () {
        final path = _remotePath ?? widget.initialRemotePath ?? '.';
        unawaited(_navigateRemote(path));
      });
    }
    if (_remoteEntries.isEmpty) {
      return _emptyState(Icons.inbox_rounded, '此目录为空');
    }
    return ListView.builder(
      itemCount: _remoteEntries.length,
      itemBuilder: (context, index) {
        final entry = _remoteEntries[index];
        final path = _remotePath == null
            ? entry.filename
            : _remotePath!.endsWith('/')
            ? '$_remotePath${entry.filename}'
            : '$_remotePath/${entry.filename}';
        final selected = _selectedRemotePaths.contains(entry.filename);
        return _fileTile(
          colors: colors,
          name: entry.filename,
          isDirectory: entry.attr.isDirectory,
          selected: selected,
          detail: entry.attr.isDirectory
              ? '文件夹'
              : _formatBytes(entry.attr.size ?? 0),
          onTap: () => setState(() {
            if (selected) {
              _selectedRemotePaths.remove(entry.filename);
            } else {
              _selectedRemotePaths.add(entry.filename);
            }
          }),
          onDoubleTap: entry.attr.isDirectory
              ? () => _navigateRemote(path)
              : null,
        );
      },
    );
  }

  Widget _fileTile({
    required ColorScheme colors,
    required String name,
    required bool isDirectory,
    required bool selected,
    required String detail,
    required VoidCallback onTap,
    required VoidCallback? onDoubleTap,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 3),
    child: Material(
      color: selected
          ? colors.primaryContainer.withValues(alpha: 0.65)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        onDoubleTap: onDoubleTap,
        child: SizedBox(
          height: 42,
          child: Row(
            children: [
              const SizedBox(width: 10),
              Icon(
                isDirectory
                    ? Icons.folder_rounded
                    : Icons.insert_drive_file_outlined,
                size: 19,
                color: isDirectory ? colors.tertiary : colors.onSurfaceVariant,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5),
                ),
              ),
              Text(
                detail,
                style: TextStyle(fontSize: 10, color: colors.onSurfaceVariant),
              ),
              const SizedBox(width: 10),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _emptyState(IconData icon, String message) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 34, color: Theme.of(context).colorScheme.outline),
        const SizedBox(height: 8),
        Text(
          message,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    ),
  );

  Widget _errorState(String message, VoidCallback retry) => Center(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline_rounded),
          const SizedBox(height: 8),
          Text(
            message,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: retry,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('重试'),
          ),
        ],
      ),
    ),
  );

  Widget _buildFooter(ColorScheme colors) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
    child: Row(
      children: [
        Icon(
          Icons.swap_horiz_rounded,
          size: 17,
          color: colors.onSurfaceVariant,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            localFileSystemSupported
                ? '双击目录进入；单击选择文件，传输任务进入会话队列。'
                : 'Web 版本可浏览远端目录；本地目录操作需要桌面或移动客户端。',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
          ),
        ),
        TextButton(
          onPressed: _canCompareFiles && !_comparing && !_transferring
              ? _compareSelectedFiles
              : null,
          child: _comparing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.compare_arrows_rounded, size: 17),
                    SizedBox(width: 5),
                    Text('比较'),
                  ],
                ),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('完成'),
        ),
      ],
    ),
  );

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
