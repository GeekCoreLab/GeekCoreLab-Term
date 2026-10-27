import 'remote_file_transfer.dart';

enum RemoteTransferDirection { upload, download }

enum RemoteTransferStatus { queued, transferring, completed, skipped, failed }

class RemoteTransferTask {
  RemoteTransferTask._({
    required this.id,
    required this.connectionIdentity,
    required this.name,
    required this.remotePath,
    required this.direction,
    required this.protocol,
    this.source,
    this.expectedLength,
    this.localDirectory,
  });

  final int id;
  final Object connectionIdentity;
  final String name;
  final String remotePath;
  final RemoteTransferDirection direction;
  final RemoteTransferProtocol protocol;
  final RemoteFileSource? source;
  final int? expectedLength;
  final String? localDirectory;

  RemoteTransferStatus _status = RemoteTransferStatus.queued;
  int _transferredBytes = 0;
  int? _totalBytes;
  String? _detail;

  RemoteTransferStatus get status => _status;
  int get transferredBytes => _transferredBytes;
  int? get totalBytes => _totalBytes;
  String? get detail => _detail;

  bool get isFinished => switch (status) {
    RemoteTransferStatus.completed ||
    RemoteTransferStatus.skipped ||
    RemoteTransferStatus.failed => true,
    RemoteTransferStatus.queued || RemoteTransferStatus.transferring => false,
  };
}

/// A session-scoped FIFO queue. Tasks are intentionally not persisted.
class RemoteTransferQueue {
  final List<RemoteTransferTask> _tasks = [];
  int _nextId = 1;

  List<RemoteTransferTask> get tasks => List.unmodifiable(_tasks);
  int get queuedCount =>
      _tasks.where((task) => task.status == RemoteTransferStatus.queued).length;
  int get activeCount => _tasks
      .where((task) => task.status == RemoteTransferStatus.transferring)
      .length;

  RemoteTransferTask enqueueUpload({
    required Object connectionIdentity,
    required String remoteDirectory,
    required RemoteFileSource source,
    required RemoteTransferProtocol protocol,
  }) {
    final task = RemoteTransferTask._(
      id: _nextId++,
      connectionIdentity: connectionIdentity,
      name: source.name,
      remotePath: _joinPath(remoteDirectory, source.name),
      direction: RemoteTransferDirection.upload,
      protocol: protocol,
      source: source,
    );
    _tasks.add(task);
    _trimHistory();
    return task;
  }

  RemoteTransferTask enqueueDownload({
    required Object connectionIdentity,
    required String name,
    required String remotePath,
    required RemoteTransferProtocol protocol,
    int? expectedLength,
    String? localDirectory,
  }) {
    final task = RemoteTransferTask._(
      id: _nextId++,
      connectionIdentity: connectionIdentity,
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
        task.status != RemoteTransferStatus.transferring) {
      throw StateError('传输任务已经结束');
    }
    task
      .._status = status
      .._detail = detail;
    _trimHistory();
  }

  void _requireOwned(RemoteTransferTask task) {
    if (!_tasks.contains(task)) throw StateError('传输任务不属于此队列');
  }

  void _trimHistory() {
    const maxFinished = 100;
    final finished = _tasks.where((task) => task.isFinished).toList();
    final excess = finished.length - maxFinished;
    if (excess <= 0) return;
    var removed = 0;
    _tasks.removeWhere((task) {
      if (removed >= excess || !task.isFinished) return false;
      removed++;
      return true;
    });
  }
}

String _joinPath(String directory, String name) =>
    directory.endsWith('/') ? '$directory$name' : '$directory/$name';
