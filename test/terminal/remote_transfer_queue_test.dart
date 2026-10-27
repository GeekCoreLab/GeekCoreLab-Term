import 'dart:typed_data';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:geekcore_term/terminal/remote_file_transfer.dart';
import 'package:geekcore_term/terminal/remote_transfer_queue.dart';

void main() {
  group('RemoteTransferQueue', () {
    late RemoteTransferQueue queue;
    late Object connection;

    setUp(() {
      queue = RemoteTransferQueue();
      connection = Object();
    });

    RemoteFileSource source(String name) => RemoteFileSource(
      name: name,
      length: () async => 3,
      openRead: () => Stream.value(Uint8List.fromList([1, 2, 3])),
    );

    test('keeps FIFO order and allows only the active task to complete', () {
      final first = queue.enqueueUpload(
        connectionIdentity: connection,
        persistenceKey: 'session:test',
        remoteDirectory: '/tmp',
        source: source('one.txt'),
        protocol: RemoteTransferProtocol.sftp,
      );
      final second = queue.enqueueDownload(
        connectionIdentity: connection,
        persistenceKey: 'session:test',
        name: 'two.txt',
        remotePath: '/tmp/two.txt',
        protocol: RemoteTransferProtocol.sftp,
        expectedLength: 8,
      );

      expect(queue.takeNext(), same(first));
      expect(() => queue.complete(first), throwsStateError);
      queue.start(first, totalBytes: 3);
      expect(queue.takeNext(), same(second));
      queue.complete(first);
      expect(first.status, RemoteTransferStatus.completed);
      expect(queue.takeNext(), same(second));
      expect(queue.queuedCount, 1);
      expect(queue.activeCount, 0);
    });

    test('clamps progress so the visible byte count never moves backward', () {
      final task = queue.enqueueDownload(
        connectionIdentity: connection,
        persistenceKey: 'session:test',
        name: 'archive.tar',
        remotePath: '/tmp/archive.tar',
        protocol: RemoteTransferProtocol.scp,
      );
      queue.start(task);
      queue.updateProgress(task, 12, totalBytes: 20);
      queue.updateProgress(task, 4);

      expect(task.transferredBytes, 12);
      expect(task.totalBytes, 20);
      expect(() => queue.updateProgress(task, -1), throwsArgumentError);
      queue.skip(task, 'cancelled');
      expect(task.status, RemoteTransferStatus.skipped);
      expect(task.detail, 'cancelled');
      expect(task.isFinished, isTrue);
    });

    test('removes queued work and clears finished history only', () {
      final queued = queue.enqueueDownload(
        connectionIdentity: connection,
        persistenceKey: 'session:test',
        name: 'queued.txt',
        remotePath: '/tmp/queued.txt',
        protocol: RemoteTransferProtocol.sftp,
      );
      final active = queue.enqueueDownload(
        connectionIdentity: connection,
        persistenceKey: 'session:test',
        name: 'active.txt',
        remotePath: '/tmp/active.txt',
        protocol: RemoteTransferProtocol.sftp,
      );
      queue.start(active);

      expect(queue.removeQueued(queued.id), isTrue);
      expect(queue.removeQueued(active.id), isFalse);
      queue.fail(active, 'network error');
      queue.clearFinished();
      expect(queue.tasks, isEmpty);
    });

    test('rebinds queued and failed work for the same session only', () {
      final failed = queue.enqueueDownload(
        connectionIdentity: connection,
        persistenceKey: 'session:test',
        name: 'failed.txt',
        remotePath: '/tmp/failed.txt',
        protocol: RemoteTransferProtocol.sftp,
      );
      queue.start(failed);
      queue.fail(failed, 'disconnect');
      final queued = queue.enqueueDownload(
        connectionIdentity: connection,
        persistenceKey: 'session:test',
        name: 'queued.txt',
        remotePath: '/tmp/queued.txt',
        protocol: RemoteTransferProtocol.sftp,
      );
      final otherSession = queue.enqueueDownload(
        connectionIdentity: connection,
        persistenceKey: 'session:other',
        name: 'other.txt',
        remotePath: '/tmp/other.txt',
        protocol: RemoteTransferProtocol.sftp,
      );
      final replacement = Object();

      expect(queue.rebindConnection('session:test', replacement), 2);
      expect(failed.connectionIdentity, same(replacement));
      expect(queued.connectionIdentity, same(replacement));
      expect(otherSession.connectionIdentity, same(connection));
    });

    test(
      'cancels only an active task and records its terminal state',
      () async {
        final task = queue.enqueueDownload(
          connectionIdentity: connection,
          persistenceKey: 'session:test',
          name: 'large.bin',
          remotePath: '/tmp/large.bin',
          protocol: RemoteTransferProtocol.sftp,
        );
        final cancelled = Completer<void>();
        final subscription = task.cancellation.onCancel.listen((_) {
          if (!cancelled.isCompleted) cancelled.complete();
        });

        expect(queue.cancelActive(task.id), isFalse);
        queue.start(task);
        expect(queue.cancelActive(task.id), isTrue);
        await cancelled.future;
        expect(task.status, RemoteTransferStatus.cancelling);
        expect(task.cancellation.isCancelled, isTrue);
        expect(queue.activeCount, 1);

        queue.cancelled(task);
        await subscription.cancel();
        expect(task.status, RemoteTransferStatus.cancelled);
        expect(task.detail, '已取消');
        expect(task.isFinished, isTrue);
        expect(queue.activeCount, 0);
        expect(queue.cancelActive(task.id), isFalse);
      },
    );

    test('does not interrupt a task once its final commit begins', () {
      final task = queue.enqueueDownload(
        connectionIdentity: connection,
        persistenceKey: 'session:test',
        name: 'final.bin',
        remotePath: '/tmp/final.bin',
        protocol: RemoteTransferProtocol.sftp,
      );
      queue.start(task);
      task.cancellation.beginCommit();

      expect(task.cancellation.canCancel, isFalse);
      expect(queue.cancelActive(task.id), isFalse);
      expect(task.status, RemoteTransferStatus.transferring);
      queue.complete(task);
    });

    test('persists only reproducible sources and includes active tasks', () {
      final persistentUpload = queue.enqueueUpload(
        connectionIdentity: connection,
        persistenceKey: 'session:persist',
        remoteDirectory: '/tmp',
        source: RemoteFileSource(
          name: 'upload.bin',
          length: () async => 12,
          openRead: () => const Stream.empty(),
          openReadFromOffset: (_) => const Stream.empty(),
          localPath: '/home/user/upload.bin',
          localLength: 12,
          localModifiedAtMillis: 1234,
        ),
        protocol: RemoteTransferProtocol.sftp,
      );
      queue.enqueueUpload(
        connectionIdentity: connection,
        persistenceKey: 'session:persist',
        remoteDirectory: '/tmp',
        source: source('memory-only.bin'),
        protocol: RemoteTransferProtocol.sftp,
      );
      final activeDownload = queue.enqueueDownload(
        connectionIdentity: connection,
        persistenceKey: 'session:persist',
        name: 'download.bin',
        remotePath: '/tmp/download.bin',
        protocol: RemoteTransferProtocol.sftp,
        expectedLength: 20,
        localDirectory: '/home/user/Downloads',
      );
      queue.start(activeDownload);

      final snapshots = queue.pendingSnapshots('session:persist');
      expect(snapshots, hasLength(2));
      expect(snapshots.first.localSourcePath, '/home/user/upload.bin');
      expect(snapshots.first.localSourceLength, 12);
      expect(snapshots.first.localSourceModifiedAtMillis, 1234);
      expect(snapshots.last.remotePath, '/tmp/download.bin');
      expect(queue.pendingSnapshots('session:other'), isEmpty);

      queue.complete(activeDownload);
      expect(queue.pendingSnapshots('session:persist'), [snapshots.first]);
      queue.removeQueued(persistentUpload.id);
    });

    test('retries a failed upload with the same durable resume token', () {
      final task = queue.enqueueUpload(
        connectionIdentity: connection,
        persistenceKey: 'session:persist',
        remoteDirectory: '/tmp',
        source: RemoteFileSource(
          name: 'retry.bin',
          length: () async => 12,
          openRead: () => const Stream.empty(),
          openReadFromOffset: (_) => const Stream.empty(),
          localPath: '/home/user/retry.bin',
          localLength: 12,
          localModifiedAtMillis: 4567,
        ),
        protocol: RemoteTransferProtocol.sftp,
      );
      final resumeToken = task.uploadResumeToken;
      queue.start(task, totalBytes: 12);
      queue.fail(task, 'network disconnected');

      expect(
        queue.pendingSnapshots('session:persist').single.uploadResumeToken,
        resumeToken,
      );
      expect(queue.retryFailed(task.id), isTrue);
      expect(task.status, RemoteTransferStatus.queued);
      expect(task.uploadResumeToken, resumeToken);
      expect(task.cancellation.canCancel, isTrue);
      expect(queue.takeNext(), same(task));
    });

    test('retains only the most recent 100 finished tasks', () {
      for (var index = 0; index < 105; index++) {
        final task = queue.enqueueDownload(
          connectionIdentity: connection,
          persistenceKey: 'session:test',
          name: '$index.txt',
          remotePath: '/tmp/$index.txt',
          protocol: RemoteTransferProtocol.sftp,
        );
        queue.skip(task);
      }
      final resumableFailure = queue.enqueueUpload(
        connectionIdentity: connection,
        persistenceKey: 'session:test',
        remoteDirectory: '/tmp',
        source: RemoteFileSource(
          name: 'resumable.bin',
          length: () async => 3,
          openRead: () => Stream.value(Uint8List.fromList([1, 2, 3])),
          openReadFromOffset: (_) =>
              Stream.value(Uint8List.fromList([1, 2, 3])),
          localPath: '/tmp/resumable.bin',
          localLength: 3,
          localModifiedAtMillis: 1234,
        ),
        protocol: RemoteTransferProtocol.sftp,
      );
      queue.start(resumableFailure);
      queue.fail(resumableFailure, 'connection lost');

      expect(queue.tasks, hasLength(101));
      expect(queue.tasks.first.name, '5.txt');
      expect(queue.tasks.last, same(resumableFailure));
    });
  });
}
