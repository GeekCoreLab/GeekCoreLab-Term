import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:geekcore_term/terminal/remote_file_permissions.dart';
import 'package:geekcore_term/terminal/remote_file_search.dart';
import 'package:geekcore_term/terminal/remote_file_transfer.dart';
import 'package:geekcore_term/terminal/remote_transfer_queue.dart';
import 'package:geekcore_term/terminal/remote_transfer_queue_store.dart';
import 'package:geekcore_term/terminal/local_file_system.dart';
import 'package:geekcore_term/terminal/remote_file_manager_dialog.dart';

class RemoteFileBrowser extends StatefulWidget {
  const RemoteFileBrowser({
    required this.client,
    required this.sessionIdentity,
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
  final String sessionIdentity;
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
  static const _maxEditableFileBytes = 2 * 1024 * 1024;
  final TextEditingController _pathController = TextEditingController();
  final TextEditingController _filterController = TextEditingController();
  SftpClient? _sftp;
  List<SftpName> _entries = const [];
  SftpName? _selectedEntry;
  String? _currentPath;
  String? _error;
  bool _loading = true;
  bool _dragging = false;
  bool _transferring = false;
  bool _editing = false;
  bool _showNameFilter = false;
  bool _showTransferQueue = false;
  bool _queuePaused = false;
  String _nameFilter = '';
  final RemoteTransferQueue _transferQueue = RemoteTransferQueue();
  final RemoteTransferQueueStore _transferQueueStore =
      RemoteTransferQueueStore();
  final Set<String> _restoredQueueSessions = {};
  Future<void> _queuePersistence = Future<void>.value();
  Completer<void>? _queueIdle;
  int _generation = 0;

  List<SftpName> get _filteredEntries => _entries
      .where((entry) => matchesRemoteFileName(entry.filename, _nameFilter))
      .toList();

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
      await _restorePersistedQueue(generation);
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _restorePersistedQueue(int generation) async {
    final persistenceKey = widget.sessionIdentity;
    if (_restoredQueueSessions.contains(persistenceKey)) return;
    final snapshots = await _transferQueueStore.loadForSession(persistenceKey);
    if (!mounted || generation != _generation) return;
    if (!_restoredQueueSessions.add(persistenceKey)) return;

    var restored = 0;
    var unavailable = 0;
    for (final snapshot in snapshots) {
      try {
        validateRemoteFileName(snapshot.name, snapshot.protocol);
        if (snapshot.remotePath.split('/').last != snapshot.name) {
          throw const FormatException('远端路径与文件名不匹配');
        }
        if (snapshot.direction == RemoteTransferDirection.upload) {
          final path = snapshot.localSourcePath;
          if (path == null) throw const FormatException('缺少本地源文件路径');
          final source = await localFileSource(path);
          if (source.name != snapshot.name ||
              (snapshot.localSourceLength != null &&
                  source.localLength != snapshot.localSourceLength) ||
              (snapshot.localSourceModifiedAtMillis != null &&
                  source.localModifiedAtMillis !=
                      snapshot.localSourceModifiedAtMillis)) {
            throw const FormatException('本地源文件已变化');
          }
          _transferQueue.enqueueUpload(
            connectionIdentity: widget.client,
            persistenceKey: persistenceKey,
            remoteDirectory: _parentPath(snapshot.remotePath),
            source: source,
            protocol: snapshot.protocol,
          );
        } else {
          _transferQueue.enqueueDownload(
            connectionIdentity: widget.client,
            persistenceKey: persistenceKey,
            name: snapshot.name,
            remotePath: snapshot.remotePath,
            protocol: snapshot.protocol,
            expectedLength: snapshot.expectedLength,
            localDirectory: snapshot.localDirectory,
          );
        }
        restored++;
      } on Object catch (error) {
        unavailable++;
        widget.onMessage('未恢复传输“${snapshot.name}”：$error', isError: true);
      }
    }

    if (!mounted || generation != _generation) return;
    if (restored > 0) {
      setState(() {
        _showTransferQueue = true;
        _queuePaused = true;
      });
      widget.onMessage('已恢复 $restored 项待确认任务；检查队列后点击“恢复任务”开始传输');
    }
    if (snapshots.isNotEmpty || unavailable > 0) {
      _scheduleQueuePersistence();
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

  String _remoteVersion(SftpFileAttrs attrs) =>
      '${attrs.size}:${attrs.modifyTime}:${attrs.mode?.value}';

  Future<void> _chooseFiles() async {
    if (_editing) return;
    try {
      final files = await FilePicker.pickFiles(dialogTitle: '选择要上传的文件');
      if (!mounted) return;
      if (files.isEmpty) return;
      final sources = <RemoteFileSource>[];
      for (final file in files) {
        final path = file.path;
        if (!kIsWeb && path != null && path.isNotEmpty) {
          sources.add(await localFileSource(path));
        } else {
          sources.add(
            RemoteFileSource(
              name: file.name,
              length: () async => (await file.length()) ?? 0,
              openRead: file.readAsByteStream,
            ),
          );
        }
      }
      _enqueueUploads(sources);
    } catch (error) {
      if (!mounted) return;
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
    final sources = <RemoteFileSource>[];
    for (final file in files) {
      final path = file.path;
      if (!kIsWeb && !file.fromPromise && path.isNotEmpty) {
        try {
          sources.add(await localFileSource(path));
          continue;
        } on Object {
          // Use the drop stream if the platform cannot expose a local file.
        }
      }
      int? length;
      try {
        length = await file.length();
      } on Object {
        // The upload stream will report source errors in the regular queue.
      }
      final modifiedAt = await file.lastModified();
      sources.add(
        RemoteFileSource(
          name: file.name,
          length: () async => length ?? 0,
          openRead: file.openRead,
          localPath: null,
          localLength: length,
          localModifiedAtMillis: modifiedAt.millisecondsSinceEpoch,
        ),
      );
    }
    _enqueueUploads(sources);
  }

  void _enqueueUploads(
    List<RemoteFileSource> sources, {
    String? remoteDirectory,
    RemoteTransferProtocol? protocol,
  }) {
    final sftp = _sftp;
    final path = remoteDirectory ?? _currentPath;
    final transferProtocol = protocol ?? widget.protocol;
    if (!mounted || sftp == null || path == null || _editing) return;
    var added = false;
    for (final source in sources) {
      try {
        validateRemoteFileName(source.name, transferProtocol);
        _transferQueue.enqueueUpload(
          connectionIdentity: widget.client,
          persistenceKey: widget.sessionIdentity,
          remoteDirectory: path,
          source: source,
          protocol: transferProtocol,
        );
        added = true;
      } on ArgumentError catch (error) {
        widget.onMessage('跳过 ${source.name}：${error.message}', isError: true);
      }
    }
    if (!added) return;
    setState(() => _showTransferQueue = true);
    _scheduleQueuePersistence();
    unawaited(_runTransferQueue());
  }

  void _enqueueDownload(
    SftpName entry, {
    String? remotePath,
    RemoteTransferProtocol? protocol,
    String? localDirectory,
  }) {
    if (!mounted || _sftp == null || entry.attr.isDirectory || _editing) return;
    _transferQueue.enqueueDownload(
      connectionIdentity: widget.client,
      persistenceKey: widget.sessionIdentity,
      name: entry.filename,
      remotePath: remotePath ?? _remotePath(entry.filename),
      protocol: protocol ?? widget.protocol,
      expectedLength: entry.attr.size,
      localDirectory: localDirectory,
    );
    setState(() => _showTransferQueue = true);
    _scheduleQueuePersistence();
    unawaited(_runTransferQueue());
  }

  void _scheduleQueuePersistence() {
    final persistenceKey = widget.sessionIdentity;
    final snapshot = _transferQueue.pendingSnapshots(persistenceKey);
    _queuePersistence = _queuePersistence
        .then(
          (_) => _transferQueueStore.saveForSession(persistenceKey, snapshot),
        )
        .catchError((Object error) {
          if (mounted) {
            widget.onMessage('无法保存待处理传输队列：$error', isError: true);
          }
        });
  }

  void _resumePersistedQueue() {
    if (!_queuePaused) return;
    setState(() => _queuePaused = false);
    unawaited(_runTransferQueue());
  }

  Future<void> _runTransferQueue() async {
    if (!mounted || _editing || _queuePaused) return;
    if (_transferring) {
      final pending = _queueIdle;
      if (pending != null) await pending.future;
      if (mounted && _transferQueue.queuedCount > 0) {
        await _runTransferQueue();
      }
      return;
    }
    _queueIdle = Completer<void>();
    setState(() => _transferring = true);
    var completed = 0;
    var skipped = 0;
    var cancelled = 0;
    var failed = 0;
    var refreshCurrentDirectory = false;
    try {
      while (mounted) {
        final task = _transferQueue.takeNext();
        if (task == null) break;
        if (!identical(task.connectionIdentity, widget.client)) {
          _transferQueue.fail(task, 'SSH 会话已更换，任务未转移到新会话');
          failed++;
          _scheduleQueuePersistence();
          setState(() {});
          continue;
        }
        final sftp = _sftp;
        if (sftp == null) {
          _transferQueue.fail(task, 'SFTP 会话未就绪');
          failed++;
          _scheduleQueuePersistence();
          setState(() {});
          continue;
        }

        _transferQueue.start(task, totalBytes: task.expectedLength);
        setState(() {});
        try {
          if (task.direction == RemoteTransferDirection.upload) {
            final source = task.source!;
            final length = await source.length();
            _transferQueue.updateProgress(task, 0, totalBytes: length);
            final target = await _statRemoteFile(sftp, task.remotePath);
            if (target != null && !target.isFile) {
              throw StateError('远端同名目标不是普通文件');
            }
            if (target != null && !await _confirmOverwrite(task.name)) {
              _transferQueue.skip(task, '用户取消覆盖');
              skipped++;
              continue;
            }
            if (!mounted ||
                !identical(task.connectionIdentity, widget.client)) {
              throw StateError('SSH 会话已更换，任务已停止');
            }
            await uploadRemoteFile(
              client: widget.client,
              remoteDirectory: _parentPath(task.remotePath),
              source: source,
              protocol: task.protocol,
              sftpClient: sftp,
              overwriteConfirmed: target != null,
              cancellation: task.cancellation,
              onProgress: (bytes) {
                _transferQueue.updateProgress(task, bytes, totalBytes: length);
                if (mounted) setState(() {});
              },
            );
            refreshCurrentDirectory |=
                _currentPath == _parentPath(task.remotePath);
          } else {
            final localDirectory = task.localDirectory;
            if (localDirectory != null &&
                task.protocol == RemoteTransferProtocol.sftp) {
              final localPath = localJoinPath(localDirectory, task.name);
              final exists = await localFileExists(localPath);
              if (exists && !await _confirmLocalOverwrite(task.name)) {
                _transferQueue.skip(task, '用户取消覆盖');
                skipped++;
                continue;
              }
              final remoteFile = await sftp.open(
                task.remotePath,
                mode: SftpFileOpenMode.read,
              );
              Future<void>? cancellationClose;
              final cancellationSubscription = task.cancellation.onCancel
                  .listen((_) {
                    cancellationClose ??= remoteFile.close();
                  });
              if (task.cancellation.isCancelled) {
                cancellationClose ??= remoteFile.close();
              }
              try {
                task.cancellation.throwIfCancelled();
                final initialVersion = await remoteFile.stat();
                final totalLength = initialVersion.size;
                if (totalLength == null || totalLength < 0) {
                  throw StateError('远端未提供可验证的文件长度，无法安全续传');
                }
                if (initialVersion.modifyTime == null) {
                  final output = BytesBuilder(copy: false);
                  await for (final chunk in remoteFile.read(
                    length: totalLength,
                    onProgress: (received) {
                      _transferQueue.updateProgress(
                        task,
                        received,
                        totalBytes: totalLength,
                      );
                      if (mounted) setState(() {});
                    },
                  )) {
                    task.cancellation.throwIfCancelled();
                    output.add(chunk);
                  }
                  task.cancellation.throwIfCancelled();
                  final currentVersion = await remoteFile.stat();
                  if (!_sameRemoteVersion(initialVersion, currentVersion)) {
                    throw StateError('远端文件在下载期间发生变化');
                  }
                  task.cancellation.beginCommit();
                  await writeLocalFileAtomically(
                    localPath,
                    output.takeBytes(),
                    overwriteConfirmed: exists,
                  );
                } else {
                  await writeResumableLocalDownload(
                    path: localPath,
                    transferIdentity:
                        '${widget.sessionIdentity}\u0000${widget.client.username}\u0000${task.remotePath}',
                    sourceVersion: _remoteVersion(initialVersion),
                    expectedLength: totalLength,
                    openRead: (offset) => remoteFile.read(
                      offset: offset,
                      length: totalLength - offset,
                    ),
                    overwriteConfirmed: exists,
                    validateSource: () async {
                      task.cancellation.throwIfCancelled();
                      final currentVersion = await remoteFile.stat();
                      if (!_sameRemoteVersion(initialVersion, currentVersion)) {
                        throw StateError('远端文件在下载期间发生变化，部分数据已保留');
                      }
                    },
                    beforeCommit: task.cancellation.beginCommit,
                    onProgress: (received) {
                      _transferQueue.updateProgress(
                        task,
                        received,
                        totalBytes: totalLength,
                      );
                      if (mounted) setState(() {});
                    },
                  );
                }
              } finally {
                await cancellationSubscription.cancel();
                await cancellationClose;
                await remoteFile.close();
              }
            } else {
              final bytes = await downloadRemoteFile(
                client: widget.client,
                remotePath: task.remotePath,
                protocol: task.protocol,
                sftpClient: sftp,
                cancellation: task.cancellation,
                onProgress: (received) {
                  _transferQueue.updateProgress(task, received);
                  if (mounted) setState(() {});
                },
              );
              task.cancellation.throwIfCancelled();
              if (!mounted ||
                  !identical(task.connectionIdentity, widget.client)) {
                throw StateError('SSH 会话已更换，任务已停止');
              }
              if (localDirectory == null) {
                task.cancellation.beginCommit();
                final result = await FilePicker.saveFile(
                  fileName: task.name,
                  bytes: bytes,
                  dialogTitle: '下载 ${task.name}',
                );
                if (result == null) {
                  _transferQueue.skip(task, '用户取消保存');
                  skipped++;
                  continue;
                }
                task.cancellation.throwIfCancelled();
              } else {
                final localPath = localJoinPath(localDirectory, task.name);
                final exists = await localFileExists(localPath);
                if (exists && !await _confirmLocalOverwrite(task.name)) {
                  _transferQueue.skip(task, '用户取消覆盖');
                  skipped++;
                  continue;
                }
                task.cancellation.throwIfCancelled();
                task.cancellation.beginCommit();
                await writeLocalFileAtomically(
                  localPath,
                  bytes,
                  overwriteConfirmed: exists,
                );
              }
            }
          }
          _transferQueue.complete(task);
          completed++;
        } catch (error) {
          if (task.cancellation.isCancelled ||
              error is RemoteTransferCancelled) {
            _transferQueue.cancelled(task);
            cancelled++;
          } else {
            _transferQueue.fail(task, error.toString());
            failed++;
          }
        } finally {
          if (mounted) {
            _scheduleQueuePersistence();
            setState(() {});
          }
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _transferring = false;
        });
      }
      final idle = _queueIdle;
      _queueIdle = null;
      if (idle != null && !idle.isCompleted) idle.complete();
    }
    if (!mounted) return;
    if (refreshCurrentDirectory) await _refresh();
    if (completed + skipped + cancelled + failed > 0) {
      widget.onMessage(
        '传输队列完成：$completed 项成功，$skipped 项跳过，$cancelled 项取消，$failed 项失败',
        isError: failed > 0,
      );
    }
  }

  Future<SftpFileAttrs?> _statRemoteFile(SftpClient sftp, String path) async {
    try {
      return await sftp.stat(path, followLink: false);
    } on SftpStatusError catch (error) {
      if (error.code == SftpStatusCode.noSuchFile) return null;
      rethrow;
    }
  }

  String _parentPath(String path) {
    final separator = path.lastIndexOf('/');
    if (separator <= 0) return '/';
    return path.substring(0, separator);
  }

  void _removeQueuedTransfer(RemoteTransferTask task) {
    if (_transferQueue.removeQueued(task.id)) {
      _scheduleQueuePersistence();
      setState(() {});
    }
  }

  void _cancelActiveTransfer(RemoteTransferTask task) {
    if (_transferQueue.cancelActive(task.id)) setState(() {});
  }

  void _clearFinishedTransfers() {
    setState(_transferQueue.clearFinished);
    _scheduleQueuePersistence();
  }

  Future<void> _edit(SftpName entry) async {
    final sftp = _sftp;
    if (sftp == null || entry.attr.isDirectory || _transferring || _editing) {
      return;
    }
    final path = _remotePath(entry.filename);
    TextEditingController? controller;
    String? temporaryPath;
    setState(() => _editing = true);
    try {
      final originalAttrs = await sftp.stat(path);
      final length = originalAttrs.size;
      if (length == null) {
        throw const FormatException('无法读取文件大小，不能安全打开编辑器');
      }
      if (length > _maxEditableFileBytes) {
        throw const FormatException('在线编辑仅支持 2 MiB 以内的文本文件');
      }

      final remoteFile = await sftp.open(path);
      late final Uint8List bytes;
      try {
        bytes = await remoteFile.readBytes(length: length);
      } finally {
        await remoteFile.close();
      }
      if (bytes.contains(0)) {
        throw const FormatException('检测到二进制文件，请使用下载操作');
      }
      final originalText = utf8.decode(bytes);
      controller = TextEditingController(text: originalText);
      if (!mounted) return;
      final editedText = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => _RemoteTextEditorDialog(
          filename: entry.filename,
          controller: controller!,
        ),
      );
      if (!mounted || editedText == null || editedText == originalText) return;

      var expectedAttrs = originalAttrs;
      final beforeWriteAttrs = await sftp.stat(path);
      if (!_sameRemoteVersion(expectedAttrs, beforeWriteAttrs)) {
        if (!await _confirmRemoteConflict(entry.filename)) return;
        expectedAttrs = beforeWriteAttrs;
      }

      temporaryPath =
          '$path.geekcore-tmp-${DateTime.now().microsecondsSinceEpoch}';
      final temporaryFile = await sftp.open(
        temporaryPath,
        mode:
            SftpFileOpenMode.create |
            SftpFileOpenMode.truncate |
            SftpFileOpenMode.write,
      );
      try {
        final mode = expectedAttrs.mode;
        if (mode != null) {
          await temporaryFile.setStat(SftpFileAttrs(mode: mode));
        }
        final content = Uint8List.fromList(utf8.encode(editedText));
        await temporaryFile.write(Stream.value(content)).done;
      } finally {
        await temporaryFile.close();
      }

      final beforeRenameAttrs = await sftp.stat(path);
      if (!_sameRemoteVersion(expectedAttrs, beforeRenameAttrs)) {
        if (!await _confirmRemoteConflict(entry.filename)) return;
      }
      await sftp.rename(temporaryPath, path);
      temporaryPath = null;
      widget.onMessage('已保存 ${entry.filename}');
      await _refresh();
    } catch (error) {
      widget.onMessage('打开或保存文件失败：$error', isError: true);
    } finally {
      controller?.dispose();
      if (mounted) setState(() => _editing = false);
      final orphanedPath = temporaryPath;
      if (orphanedPath != null) {
        try {
          await sftp.remove(orphanedPath);
        } catch (_) {
          // Preserve the original editor error; the temporary file is harmless.
        }
      }
    }
  }

  Future<bool> _confirmRemoteConflict(String name) async => !mounted
      ? false
      : await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                icon: const Icon(Icons.sync_problem_rounded),
                title: const Text('远端文件已更改'),
                content: Text('“$name”在编辑期间被其他进程更新。仍要用当前编辑内容覆盖吗？'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('取消保存'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('覆盖并保存'),
                  ),
                ],
              ),
            ) ??
            false;

  bool _sameRemoteVersion(SftpFileAttrs first, SftpFileAttrs second) =>
      first.size == second.size &&
      first.modifyTime == second.modifyTime &&
      first.mode?.value == second.mode?.value;

  Future<void> _createDirectory() async {
    if (_transferring || _editing) return;
    final name = await _askForName(title: '新建远端文件夹', label: '文件夹名称');
    if (name == null || name.isEmpty) return;
    if (!_validateRemoteName(name)) return;
    try {
      await _sftp?.mkdir(_remotePath(name));
      await _refresh();
      widget.onMessage('已创建文件夹 $name');
    } catch (error) {
      widget.onMessage('创建文件夹失败：$error', isError: true);
    }
  }

  Future<void> _rename(SftpName entry) async {
    if (_transferring || _editing) return;
    final name = await _askForName(
      title: '重命名',
      label: '新名称',
      initialValue: entry.filename,
    );
    if (name == null || name.isEmpty || name == entry.filename) return;
    if (!_validateRemoteName(name)) return;
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

  bool _validateRemoteName(String name) {
    try {
      validateRemoteFileName(name, RemoteTransferProtocol.sftp);
      return true;
    } on ArgumentError catch (error) {
      widget.onMessage((error.message ?? '远端文件名无效').toString(), isError: true);
      return false;
    }
  }

  Future<void> _changePermissions(SftpName entry) async {
    final sftp = _sftp;
    if (sftp == null || _transferring || _editing) return;
    final originalMode = entry.attr.mode?.value;
    final initialMode = formatRemotePermissionMode(
      originalMode,
      isDirectory: entry.attr.isDirectory,
    );
    final permissions = await showDialog<int>(
      context: context,
      builder: (_) => _RemotePermissionDialog(initialMode: initialMode),
    );
    if (!mounted || permissions == null) return;

    setState(() => _editing = true);
    try {
      final fileTypeBits = (originalMode ?? 0) & ~0xFFF;
      await sftp.setStat(
        _remotePath(entry.filename),
        SftpFileAttrs(mode: SftpFileMode.value(fileTypeBits | permissions)),
      );
      widget.onMessage('已更新 ${entry.filename} 的权限');
      await _refresh();
    } catch (error) {
      widget.onMessage('修改权限失败：$error', isError: true);
    } finally {
      if (mounted) setState(() => _editing = false);
    }
  }

  Future<void> _delete(SftpName entry) async {
    if (_transferring || _editing) return;
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

  Future<bool> _confirmLocalOverwrite(String name) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('覆盖本地文件？'),
          content: Text('“$name”已存在于所选本地目录。继续会替换现有文件。'),
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

  Future<void> _queueLocalUploads(
    List<String> paths,
    String remoteDirectory,
    RemoteTransferProtocol protocol,
  ) async {
    final sources = <RemoteFileSource>[];
    for (final path in paths) {
      try {
        sources.add(await localFileSource(path));
      } on Object catch (error) {
        widget.onMessage('跳过 ${localFileName(path)}：$error', isError: true);
      }
    }
    _enqueueUploads(
      sources,
      remoteDirectory: remoteDirectory,
      protocol: protocol,
    );
    await _runTransferQueue();
  }

  Future<void> _queueLocalDownload(
    SftpName entry,
    String remotePath,
    RemoteTransferProtocol protocol,
    String localDirectory,
  ) async {
    _enqueueDownload(
      entry,
      remotePath: remotePath,
      protocol: protocol,
      localDirectory: localDirectory,
    );
    await _runTransferQueue();
  }

  Future<void> _openDualPaneManager() async {
    final path = _currentPath;
    if (path == null || !mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => RemoteFileManagerDialog(
        client: widget.client,
        sessionTitle: widget.sessionTitle,
        initialRemotePath: path,
        protocol: widget.protocol,
        onDirectoryChanged: (path) {
          _currentPath = path;
          _pathController.text = path;
          widget.onDirectoryChanged(path);
        },
        onProtocolChanged: widget.onProtocolChanged,
        onQueueUploads: _queueLocalUploads,
        onQueueDownload: _queueLocalDownload,
        onMessage: widget.onMessage,
      ),
    );
    if (mounted) await _refresh();
  }

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

  Widget _buildTransferQueuePanel(ColorScheme colors) {
    final tasks = _transferQueue.tasks;
    return Container(
      height: 154,
      margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      padding: const EdgeInsets.fromLTRB(10, 6, 6, 4),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _queuePaused
                      ? '恢复前请检查 · ${_transferQueue.queuedCount} 项待确认'
                      : '传输队列 · ${_transferQueue.queuedCount} 等待 · ${_transferQueue.activeCount} 进行中',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (_queuePaused)
                IconButton(
                  tooltip: '恢复任务',
                  visualDensity: VisualDensity.compact,
                  onPressed: _resumePersistedQueue,
                  icon: const Icon(Icons.play_arrow_rounded, size: 17),
                ),
              IconButton(
                tooltip: '清除已结束任务',
                visualDensity: VisualDensity.compact,
                onPressed: tasks.any((task) => task.isFinished)
                    ? _clearFinishedTransfers
                    : null,
                icon: const Icon(Icons.cleaning_services_outlined, size: 16),
              ),
              IconButton(
                tooltip: '隐藏传输队列',
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(() => _showTransferQueue = false),
                icon: const Icon(Icons.expand_less_rounded, size: 17),
              ),
            ],
          ),
          Expanded(
            child: ListView.separated(
              padding: EdgeInsets.zero,
              itemCount: tasks.length,
              separatorBuilder: (_, _) => Divider(
                height: 1,
                color: colors.outlineVariant.withValues(alpha: 0.6),
              ),
              itemBuilder: (context, index) {
                final task = tasks[index];
                final color = switch (task.status) {
                  RemoteTransferStatus.failed => colors.error,
                  RemoteTransferStatus.completed => colors.primary,
                  RemoteTransferStatus.queued ||
                  RemoteTransferStatus.transferring ||
                  RemoteTransferStatus.cancelling ||
                  RemoteTransferStatus.cancelled ||
                  RemoteTransferStatus.skipped => colors.onSurfaceVariant,
                };
                final icon = switch (task.direction) {
                  RemoteTransferDirection.upload => Icons.upload_rounded,
                  RemoteTransferDirection.download => Icons.download_rounded,
                };
                final statusText = switch (task.status) {
                  RemoteTransferStatus.queued =>
                    task.isPersistable ? '等待中' : '等待中 · 当前运行期间有效',
                  RemoteTransferStatus.transferring =>
                    !task.cancellation.canCancel
                        ? '正在提交文件…'
                        : task.totalBytes == null || task.totalBytes == 0
                        ? '传输中'
                        : '${_formatSize(task.transferredBytes)} / ${_formatSize(task.totalBytes!)}',
                  RemoteTransferStatus.cancelling => '正在取消…',
                  RemoteTransferStatus.completed => '已完成',
                  RemoteTransferStatus.cancelled => task.detail ?? '已取消',
                  RemoteTransferStatus.skipped => task.detail ?? '已跳过',
                  RemoteTransferStatus.failed => task.detail ?? '传输失败',
                };
                return SizedBox(
                  height: 46,
                  child: Row(
                    children: [
                      Icon(icon, size: 16, color: color),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              task.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 10),
                            ),
                            Text(
                              statusText,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 9, color: color),
                            ),
                            if (task.status ==
                                    RemoteTransferStatus.transferring ||
                                task.status == RemoteTransferStatus.cancelling)
                              LinearProgressIndicator(
                                minHeight: 2,
                                value:
                                    task.totalBytes == null ||
                                        task.totalBytes == 0
                                    ? null
                                    : (task.transferredBytes / task.totalBytes!)
                                          .clamp(0.0, 1.0),
                              ),
                          ],
                        ),
                      ),
                      if (task.status == RemoteTransferStatus.queued)
                        IconButton(
                          tooltip: '从队列移除',
                          visualDensity: VisualDensity.compact,
                          onPressed: () => _removeQueuedTransfer(task),
                          icon: const Icon(Icons.close_rounded, size: 15),
                        )
                      else if (task.status ==
                              RemoteTransferStatus.transferring &&
                          task.cancellation.canCancel)
                        IconButton(
                          tooltip: '取消当前传输',
                          visualDensity: VisualDensity.compact,
                          onPressed: () => _cancelActiveTransfer(task),
                          icon: const Icon(Icons.cancel_outlined, size: 15),
                        )
                      else if (task.status == RemoteTransferStatus.cancelling ||
                          task.status == RemoteTransferStatus.transferring)
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 8),
                          child: SizedBox.square(
                            dimension: 13,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      else
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Icon(
                            switch (task.status) {
                              RemoteTransferStatus.completed =>
                                Icons.check_circle_outline_rounded,
                              RemoteTransferStatus.skipped =>
                                Icons.remove_circle_outline_rounded,
                              RemoteTransferStatus.cancelled =>
                                Icons.cancel_outlined,
                              RemoteTransferStatus.failed =>
                                Icons.error_outline_rounded,
                              RemoteTransferStatus.queued ||
                              RemoteTransferStatus.transferring ||
                              RemoteTransferStatus.cancelling =>
                                Icons.circle_outlined,
                            },
                            size: 15,
                            color: color,
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _generation++;
    _scheduleQueuePersistence();
    _pathController.dispose();
    _filterController.dispose();
    final sftp = _sftp;
    if (sftp != null) unawaited(sftp.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final filteredEntries = _filteredEntries;
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
                IconButton(
                  tooltip: '打开本地 / 远端双栏文件管理',
                  visualDensity: VisualDensity.compact,
                  onPressed: _currentPath == null || _editing
                      ? null
                      : _openDualPaneManager,
                  icon: const Icon(Icons.folder_copy_rounded, size: 19),
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
                IconButton.filledTonal(
                  tooltip: _showNameFilter ? '关闭文件筛选' : '筛选文件名',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => setState(() {
                    _showNameFilter = !_showNameFilter;
                    if (!_showNameFilter) {
                      _nameFilter = '';
                      _filterController.clear();
                    }
                  }),
                  icon: Icon(
                    _showNameFilter
                        ? Icons.close_rounded
                        : Icons.search_rounded,
                    size: 17,
                  ),
                ),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _editing ? null : _chooseFiles,
                    icon: const Icon(Icons.upload_file_rounded, size: 17),
                    label: const Text('上传'),
                  ),
                ),
                const SizedBox(width: 6),
                IconButton.filledTonal(
                  tooltip: '传输队列',
                  visualDensity: VisualDensity.compact,
                  onPressed: _transferQueue.tasks.isEmpty
                      ? null
                      : () => setState(
                          () => _showTransferQueue = !_showTransferQueue,
                        ),
                  icon: Badge(
                    isLabelVisible:
                        _transferQueue.queuedCount +
                            _transferQueue.activeCount >
                        0,
                    label: Text(
                      '${_transferQueue.queuedCount + _transferQueue.activeCount}',
                    ),
                    child: const Icon(Icons.downloading_rounded, size: 18),
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
          if (_showNameFilter)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 2, 8, 6),
              child: TextField(
                controller: _filterController,
                autofocus: true,
                style: const TextStyle(fontSize: 11),
                decoration: InputDecoration(
                  hintText: '筛选当前目录的文件名',
                  prefixIcon: const Icon(Icons.search_rounded, size: 17),
                  suffixIcon: _nameFilter.isEmpty
                      ? null
                      : IconButton(
                          tooltip: '清除筛选',
                          onPressed: () {
                            _filterController.clear();
                            setState(() => _nameFilter = '');
                          },
                          icon: const Icon(Icons.close_rounded, size: 16),
                        ),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 8,
                  ),
                ),
                onChanged: (value) => setState(() => _nameFilter = value),
              ),
            ),
          if (_editing) const LinearProgressIndicator(minHeight: 2),
          if (_showTransferQueue && _transferQueue.tasks.isNotEmpty)
            _buildTransferQueuePanel(colors),
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
                child: filteredEntries.isEmpty && _entries.isNotEmpty
                    ? Center(
                        child: Text(
                          '没有匹配的文件',
                          style: TextStyle(
                            color: colors.onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(5, 0, 5, 8),
                        itemCount: filteredEntries.length,
                        itemBuilder: (context, index) =>
                            _buildEntry(filteredEntries[index], colors),
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
            unawaited(_edit(entry));
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
                    case 'edit':
                      unawaited(_edit(entry));
                      break;
                    case 'download':
                      _enqueueDownload(entry);
                      break;
                    case 'rename':
                      unawaited(_rename(entry));
                      break;
                    case 'delete':
                      unawaited(_delete(entry));
                      break;
                    case 'permissions':
                      unawaited(_changePermissions(entry));
                      break;
                  }
                },
                itemBuilder: (context) => [
                  if (!entry.attr.isDirectory)
                    const PopupMenuItem(value: 'edit', child: Text('编辑文本文件')),
                  if (!entry.attr.isDirectory)
                    const PopupMenuItem(value: 'download', child: Text('下载')),
                  const PopupMenuItem(value: 'rename', child: Text('重命名')),
                  const PopupMenuItem(
                    value: 'permissions',
                    child: Text('修改权限…'),
                  ),
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

class _RemotePermissionDialog extends StatefulWidget {
  const _RemotePermissionDialog({required this.initialMode});

  final String initialMode;

  @override
  State<_RemotePermissionDialog> createState() =>
      _RemotePermissionDialogState();
}

class _RemotePermissionDialogState extends State<_RemotePermissionDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _modeController = TextEditingController(
    text: widget.initialMode,
  );

  @override
  void dispose() {
    _modeController.dispose();
    super.dispose();
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.pop(context, parseRemotePermissionMode(_modeController.text));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('修改远端权限'),
    content: SizedBox(
      width: 360,
      child: Form(
        key: _formKey,
        child: TextFormField(
          controller: _modeController,
          autofocus: true,
          maxLength: 4,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp('[0-7]'))],
          decoration: const InputDecoration(
            labelText: '八进制模式',
            helperText: '例如 0644 或 0755；可包含特殊位，如 4755',
          ),
          validator: (value) => parseRemotePermissionMode(value ?? '') == null
              ? '请输入 3 或 4 位八进制权限'
              : null,
          onFieldSubmitted: (_) => _save(),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _save, child: const Text('保存')),
    ],
  );
}

class _RemoteTextEditorDialog extends StatefulWidget {
  const _RemoteTextEditorDialog({
    required this.filename,
    required this.controller,
  });

  final String filename;
  final TextEditingController controller;

  @override
  State<_RemoteTextEditorDialog> createState() =>
      _RemoteTextEditorDialogState();
}

class _RemoteTextEditorDialogState extends State<_RemoteTextEditorDialog> {
  late final String _originalText = widget.controller.text;
  bool _confirmingDiscard = false;

  bool get _dirty => widget.controller.text != _originalText;

  void _save() => Navigator.of(context).pop(widget.controller.text);

  Future<void> _confirmDiscard() async {
    if (_confirmingDiscard) return;
    _confirmingDiscard = true;
    try {
      final discard = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('放弃未保存的修改？'),
          content: const Text('当前编辑内容尚未保存到远端。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('继续编辑'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('放弃修改'),
            ),
          ],
        ),
      );
      if (mounted && discard == true) Navigator.of(context).pop();
    } finally {
      _confirmingDiscard = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return PopScope<String>(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _dirty) unawaited(_confirmDiscard());
      },
      child: AlertDialog(
        titlePadding: const EdgeInsets.fromLTRB(22, 18, 16, 10),
        contentPadding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        actionsPadding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        title: Row(
          children: [
            const Icon(Icons.description_outlined, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                widget.filename,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (_dirty)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text(
                  '未保存',
                  style: TextStyle(
                    color: colors.tertiary,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
          ],
        ),
        content: SizedBox(
          width: 920,
          height: MediaQuery.sizeOf(context).height * 0.64,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'UTF-8 文本 · 保存前检查远端版本 · 最大 2 MiB',
                  style: TextStyle(
                    fontSize: 11,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
              Expanded(
                child: TextField(
                  controller: widget.controller,
                  autofocus: true,
                  expands: true,
                  minLines: null,
                  maxLines: null,
                  textAlignVertical: TextAlignVertical.top,
                  keyboardType: TextInputType.multiline,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 13,
                    height: 1.4,
                  ),
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.all(12),
                    isDense: true,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _dirty ? _confirmDiscard : () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            onPressed: _dirty ? _save : null,
            icon: const Icon(Icons.save_outlined, size: 18),
            label: const Text('保存到远端'),
          ),
        ],
      ),
    );
  }
}
