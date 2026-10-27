import 'dart:async' show unawaited;

import 'remote_file_transfer.dart';

enum RemoteTransferDirection { upload, download }

enum RemoteTransferStatus {
  queued,
  transferring,
  cancelling,
  completed,
  cancelled,
  skipped,
  failed,
}

class RemoteTransferTask {
  RemoteTransferTask._({
    required this.id,
    required this.connectionIdentity,
    required this.persistenceKey,
    required this.name,
    required this.remotePath,
    required this.direction,
    required this.protocol,
    this.uploadResumeToken,
    this.source,
    this.expectedLength,
    this.localDirectory,
  });

  final int id;
  Object connectionIdentity;
  final String persistenceKey;
  final String name;
  final String remotePath;
  final RemoteTransferDirection direction;
  final RemoteTransferProtocol protocol;
  final String? uploadResumeToken;
  final RemoteFileSource? source;
  final int? expectedLength;
  final String? localDirectory;
  RemoteTransferCancellation cancellation = RemoteTransferCancellation();

  RemoteTransferStatus _status = RemoteTransferStatus.queued;
  int _transferredBytes = 0;
  int? _totalBytes;
  String? _detail;

  RemoteTransferStatus get status => _status;
  int get transferredBytes => _transferredBytes;
  int? get totalBytes => _totalBytes;
  String? get detail => _detail;
  bool get isPersistable =>
      direction != RemoteTransferDirection.upload ||
      (source?.canResumeFromLocalPath == true &&
          uploadResumeToken != null &&
          uploadResumeToken!.isNotEmpty);
  bool get retainsRemoteUploadResume =>
      status == RemoteTransferStatus.failed &&
      direction == RemoteTransferDirection.upload &&
      protocol == RemoteTransferProtocol.sftp &&
      source?.canResumeFromLocalPath == true &&
      uploadResumeToken != null;

  PersistedRemoteTransferTask? toPersistenceSnapshot() {
    if (status == RemoteTransferStatus.completed ||
        status == RemoteTransferStatus.cancelled ||
        status == RemoteTransferStatus.skipped) {
      return null;
    }
    if (!isPersistable) return null;
    return PersistedRemoteTransferTask(
      direction: direction,
      protocol: protocol,
      name: name,
      remotePath: remotePath,
      uploadResumeToken: uploadResumeToken,
      expectedLength: expectedLength,
      localDirectory: localDirectory,
      localSourcePath: source?.localPath,
      localSourceLength: source?.localLength,
      localSourceModifiedAtMillis: source?.localModifiedAtMillis,
    );
  }

  bool get isFinished => switch (status) {
    RemoteTransferStatus.completed ||
    RemoteTransferStatus.cancelled ||
    RemoteTransferStatus.skipped ||
    RemoteTransferStatus.failed => true,
    RemoteTransferStatus.queued ||
    RemoteTransferStatus.transferring ||
    RemoteTransferStatus.cancelling => false,
  };
}

/// A session-scoped FIFO queue. Persistent task descriptors contain no secrets.
class RemoteTransferQueue {
  final List<RemoteTransferTask> _tasks = [];
  int _nextId = 1;

  List<RemoteTransferTask> get tasks => List.unmodifiable(_tasks);
  List<PersistedRemoteTransferTask> pendingSnapshots(String persistenceKey) => [
    for (final task in _tasks)
      if (task.persistenceKey == persistenceKey) ?task.toPersistenceSnapshot(),
  ];
  int get queuedCount =>
      _tasks.where((task) => task.status == RemoteTransferStatus.queued).length;
  int get activeCount => _tasks
      .where(
        (task) =>
            task.status == RemoteTransferStatus.transferring ||
            task.status == RemoteTransferStatus.cancelling,
      )
      .length;

  RemoteTransferTask enqueueUpload({
    required Object connectionIdentity,
    required String persistenceKey,
    required String remoteDirectory,
    required RemoteFileSource source,
    required RemoteTransferProtocol protocol,
    String? uploadResumeToken,
  }) {
    final task = RemoteTransferTask._(
      id: _nextId++,
      connectionIdentity: connectionIdentity,
      persistenceKey: persistenceKey,
      name: source.name,
      remotePath: _joinPath(remoteDirectory, source.name),
      direction: RemoteTransferDirection.upload,
      protocol: protocol,
      uploadResumeToken: uploadResumeToken ?? createRemoteTransferResumeToken(),
      source: source,
    );
    _tasks.add(task);
    _trimHistory();
    return task;
  }

  RemoteTransferTask enqueueDownload({
    required Object connectionIdentity,
    required String persistenceKey,
    required String name,
    required String remotePath,
    required RemoteTransferProtocol protocol,
    int? expectedLength,
    String? localDirectory,
  }) {
    final task = RemoteTransferTask._(
      id: _nextId++,
      connectionIdentity: connectionIdentity,
      persistenceKey: persistenceKey,
      name: name,
      remotePath: remotePath,
      direction: RemoteTransferDirection.download,
      protocol: protocol,
      expectedLength: expectedLength,
      localDirectory: localDirectory,
    );
    _tasks.add(task);
    _trimHistory();
    return task;
  }

  RemoteTransferTask? takeNext() {
    for (final task in _tasks) {
      if (task.status == RemoteTransferStatus.queued) return task;
    }
    return null;
  }

  void start(RemoteTransferTask task, {int? totalBytes}) {
    _requireOwned(task);
    if (task.status != RemoteTransferStatus.queued) {
      throw StateError('只有排队中的传输可以开始');
    }
    task
      .._status = RemoteTransferStatus.transferring
      .._totalBytes = totalBytes
      .._transferredBytes = 0
      .._detail = null;
  }

  void updateProgress(RemoteTransferTask task, int bytes, {int? totalBytes}) {
    _requireOwned(task);
    if (task.status != RemoteTransferStatus.transferring) {
      throw StateError('只有正在传输的任务可以更新进度');
    }
    if (bytes < 0 || (totalBytes != null && totalBytes < 0)) {
      throw ArgumentError('传输字节数不能为负数');
    }
    task
      .._transferredBytes = bytes < task._transferredBytes
          ? task._transferredBytes
          : bytes
      .._totalBytes = totalBytes ?? task._totalBytes;
  }

  void complete(RemoteTransferTask task) {
    _requireOwned(task);
    if (task.status != RemoteTransferStatus.transferring) {
      throw StateError('只有正在传输的任务可以完成');
    }
    _finish(task, RemoteTransferStatus.completed, null);
  }

  bool cancelActive(int id) {
    for (final task in _tasks) {
      if (task.id != id || task.status != RemoteTransferStatus.transferring) {
        continue;
      }
      if (!task.cancellation.cancel()) return false;
      task._status = RemoteTransferStatus.cancelling;
      return true;
    }
    return false;
  }

  void cancelled(RemoteTransferTask task) {
    _requireOwned(task);
    if (task.status != RemoteTransferStatus.transferring &&
        task.status != RemoteTransferStatus.cancelling) {
      throw StateError('只有正在传输的任务可以取消');
    }
    _finish(task, RemoteTransferStatus.cancelled, '已取消');
  }

  void skip(RemoteTransferTask task, [String? detail]) {
    _finish(task, RemoteTransferStatus.skipped, detail);
  }

  void fail(RemoteTransferTask task, String detail) {
    _finish(task, RemoteTransferStatus.failed, detail);
  }

  bool removeQueued(int id) {
    final index = _tasks.indexWhere(
      (task) => task.id == id && task.status == RemoteTransferStatus.queued,
    );
    if (index < 0) return false;
    _tasks.removeAt(index);
    return true;
  }

  bool retryFailed(int id) {
    for (final task in _tasks) {
      if (task.id != id || task.status != RemoteTransferStatus.failed) {
        continue;
      }
      unawaited(task.cancellation.dispose());
      task
        ..cancellation = RemoteTransferCancellation()
        .._status = RemoteTransferStatus.queued
        .._transferredBytes = 0
        .._totalBytes = null
        .._detail = null;
      return true;
    }
    return false;
  }

  int rebindConnection(String persistenceKey, Object connectionIdentity) {
    var rebound = 0;
    for (final task in _tasks) {
      if (task.persistenceKey != persistenceKey ||
          (task.status != RemoteTransferStatus.queued &&
              task.status != RemoteTransferStatus.failed)) {
        continue;
      }
      task.connectionIdentity = connectionIdentity;
      rebound++;
    }
    return rebound;
  }

  void clearFinished() {
    _tasks.removeWhere((task) => task.isFinished);
  }

  void _finish(
    RemoteTransferTask task,
    RemoteTransferStatus status,
    String? detail,
  ) {
    _requireOwned(task);
    if (task.status != RemoteTransferStatus.queued &&
        task.status != RemoteTransferStatus.transferring &&
        task.status != RemoteTransferStatus.cancelling) {
      throw StateError('传输任务已经结束');
    }
    task
      .._status = status
      .._detail = detail;
    unawaited(task.cancellation.dispose());
    _trimHistory();
  }

  void _requireOwned(RemoteTransferTask task) {
    if (!_tasks.contains(task)) throw StateError('传输任务不属于此队列');
  }

  void _trimHistory() {
    const maxFinished = 100;
    final finished = _tasks
        .where((task) => task.isFinished && !task.retainsRemoteUploadResume)
        .toList();
    final excess = finished.length - maxFinished;
    if (excess <= 0) return;
    var removed = 0;
    _tasks.removeWhere((task) {
      if (removed >= excess ||
          !task.isFinished ||
          task.retainsRemoteUploadResume) {
        return false;
      }
      removed++;
      return true;
    });
  }
}

String _joinPath(String directory, String name) =>
    directory.endsWith('/') ? '$directory$name' : '$directory/$name';

class PersistedRemoteTransferTask {
  const PersistedRemoteTransferTask({
    required this.direction,
    required this.protocol,
    required this.name,
    required this.remotePath,
    this.expectedLength,
    this.localDirectory,
    this.uploadResumeToken,
    this.localSourcePath,
    this.localSourceLength,
    this.localSourceModifiedAtMillis,
  });

  final RemoteTransferDirection direction;
  final RemoteTransferProtocol protocol;
  final String name;
  final String remotePath;
  final int? expectedLength;
  final String? localDirectory;
  final String? uploadResumeToken;
  final String? localSourcePath;
  final int? localSourceLength;
  final int? localSourceModifiedAtMillis;

  Map<String, Object> toJson() {
    final result = <String, Object>{
      'direction': direction.name,
      'protocol': protocol.name,
      'name': name,
      'remotePath': remotePath,
    };
    void addIfPresent(String key, Object? value) {
      if (value != null) result[key] = value;
    }

    addIfPresent('expectedLength', expectedLength);
    addIfPresent('localDirectory', localDirectory);
    addIfPresent('uploadResumeToken', uploadResumeToken);
    addIfPresent('localSourcePath', localSourcePath);
    addIfPresent('localSourceLength', localSourceLength);
    addIfPresent('localSourceModifiedAtMillis', localSourceModifiedAtMillis);
    return result;
  }

  factory PersistedRemoteTransferTask.fromJson(Object? encoded) {
    if (encoded is! Map<String, dynamic>) {
      throw const FormatException('传输任务记录格式无效');
    }
    final direction = RemoteTransferDirection.values.firstWhere(
      (value) => value.name == encoded['direction'],
      orElse: () => throw const FormatException('传输方向无效'),
    );
    final protocol = RemoteTransferProtocol.values.firstWhere(
      (value) => value.name == encoded['protocol'],
      orElse: () => throw const FormatException('传输协议无效'),
    );
    final name = encoded['name'];
    final remotePath = encoded['remotePath'];
    final expectedLength = encoded['expectedLength'];
    final localDirectory = encoded['localDirectory'];
    final uploadResumeToken = encoded['uploadResumeToken'];
    final localSourcePath = encoded['localSourcePath'];
    final localSourceLength = encoded['localSourceLength'];
    final localSourceModifiedAtMillis = encoded['localSourceModifiedAtMillis'];
    if (name is! String ||
        name.isEmpty ||
        remotePath is! String ||
        remotePath.isEmpty ||
        (expectedLength != null && expectedLength is! int) ||
        (localDirectory != null && localDirectory is! String) ||
        (uploadResumeToken != null && uploadResumeToken is! String) ||
        (localSourcePath != null && localSourcePath is! String) ||
        (localSourceLength != null && localSourceLength is! int) ||
        (localSourceModifiedAtMillis != null &&
            localSourceModifiedAtMillis is! int)) {
      throw const FormatException('传输任务字段无效');
    }
    if (direction == RemoteTransferDirection.upload &&
        (localSourcePath == null || localSourcePath.isEmpty)) {
      throw const FormatException('上传任务缺少本地源文件路径');
    }
    if (uploadResumeToken != null &&
        !RegExp(r'^[a-f0-9]{24}$').hasMatch(uploadResumeToken as String)) {
      throw const FormatException('上传任务续传标识无效');
    }
    if ((expectedLength is int && expectedLength < 0) ||
        (localSourceLength is int && localSourceLength < 0)) {
      throw const FormatException('传输任务长度不能为负数');
    }
    return PersistedRemoteTransferTask(
      direction: direction,
      protocol: protocol,
      name: name,
      remotePath: remotePath,
      uploadResumeToken: uploadResumeToken as String?,
      expectedLength: expectedLength as int?,
      localDirectory: localDirectory as String?,
      localSourcePath: localSourcePath as String?,
      localSourceLength: localSourceLength as int?,
      localSourceModifiedAtMillis: localSourceModifiedAtMillis as int?,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PersistedRemoteTransferTask &&
      other.direction == direction &&
      other.protocol == protocol &&
      other.name == name &&
      other.remotePath == remotePath &&
      other.uploadResumeToken == uploadResumeToken &&
      other.expectedLength == expectedLength &&
      other.localDirectory == localDirectory &&
      other.localSourcePath == localSourcePath &&
      other.localSourceLength == localSourceLength &&
      other.localSourceModifiedAtMillis == localSourceModifiedAtMillis;

  @override
  int get hashCode => Object.hash(
    direction,
    protocol,
    name,
    remotePath,
    uploadResumeToken,
    expectedLength,
    localDirectory,
    localSourcePath,
    localSourceLength,
    localSourceModifiedAtMillis,
  );
}
