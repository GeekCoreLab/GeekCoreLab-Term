import 'dart:typed_data';

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
        remoteDirectory: '/tmp',
        source: source('one.txt'),
        protocol: RemoteTransferProtocol.sftp,
      );
      final second = queue.enqueueDownload(
        connectionIdentity: connection,
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
        name: 'queued.txt',
        remotePath: '/tmp/queued.txt',
        protocol: RemoteTransferProtocol.sftp,
      );
      final active = queue.enqueueDownload(
        connectionIdentity: connection,
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

    test('retains only the most recent 100 finished tasks', () {
      for (var index = 0; index < 105; index++) {
        final task = queue.enqueueDownload(
          connectionIdentity: connection,
          name: '$index.txt',
          remotePath: '/tmp/$index.txt',
          protocol: RemoteTransferProtocol.sftp,
        );
        queue.skip(task);
      }

      expect(queue.tasks, hasLength(100));
      expect(queue.tasks.first.name, '5.txt');
    });
  });
}
