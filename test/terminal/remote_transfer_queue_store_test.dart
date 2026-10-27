import 'package:flutter_test/flutter_test.dart';
import 'package:geekcore_term/terminal/remote_file_transfer.dart';
import 'package:geekcore_term/terminal/remote_transfer_queue.dart';
import 'package:geekcore_term/terminal/remote_transfer_queue_store.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  tearDown(() {
    SharedPreferencesAsyncPlatform.instance = null;
  });

  test(
    'loads only the requested session and replaces its saved tasks',
    () async {
      final store = RemoteTransferQueueStore();
      const first = PersistedRemoteTransferTask(
        direction: RemoteTransferDirection.download,
        protocol: RemoteTransferProtocol.sftp,
        name: 'logs.tar',
        remotePath: '/var/logs.tar',
        expectedLength: 4096,
        localDirectory: '/tmp/downloads',
      );
      const second = PersistedRemoteTransferTask(
        direction: RemoteTransferDirection.download,
        protocol: RemoteTransferProtocol.scp,
        name: 'backup.bin',
        remotePath: '/srv/backup.bin',
      );

      await store.saveForSession('ssh:one', [first]);
      await store.saveForSession('ssh:two', [second]);
      expect(await store.loadForSession('ssh:one'), [first]);
      expect(await store.loadForSession('ssh:two'), [second]);

      await store.saveForSession('ssh:one', const []);
      expect(await store.loadForSession('ssh:one'), isEmpty);
      expect(await store.loadForSession('ssh:two'), [second]);
    },
  );

  test('clearAll removes pending task metadata', () async {
    final store = RemoteTransferQueueStore();
    const task = PersistedRemoteTransferTask(
      direction: RemoteTransferDirection.download,
      protocol: RemoteTransferProtocol.sftp,
      name: 'logs.tar',
      remotePath: '/var/logs.tar',
    );
    await store.saveForSession('ssh:one', [task]);

    await store.clearAll();

    expect(await store.loadForSession('ssh:one'), isEmpty);
  });

  test(
    'round-trips resumable upload identity without source contents',
    () async {
      final store = RemoteTransferQueueStore();
      const upload = PersistedRemoteTransferTask(
        direction: RemoteTransferDirection.upload,
        protocol: RemoteTransferProtocol.sftp,
        name: 'bundle.tar',
        remotePath: '/srv/bundle.tar',
        uploadResumeToken: '0123456789abcdef01234567',
        localSourcePath: '/home/user/bundle.tar',
        localSourceLength: 8192,
        localSourceModifiedAtMillis: 123456,
      );

      await store.saveForSession('ssh:one', [upload]);

      expect(await store.loadForSession('ssh:one'), [upload]);
    },
  );

  test('rejects upload descriptors without a local source path', () {
    expect(
      () => PersistedRemoteTransferTask.fromJson({
        'direction': 'upload',
        'protocol': 'sftp',
        'name': 'file.bin',
        'remotePath': '/tmp/file.bin',
      }),
      throwsFormatException,
    );
  });

  test('accepts older upload descriptors without a resume token', () {
    final descriptor = PersistedRemoteTransferTask.fromJson({
      'direction': 'upload',
      'protocol': 'sftp',
      'name': 'file.bin',
      'remotePath': '/tmp/file.bin',
      'localSourcePath': '/tmp/file.bin',
    });
    expect(descriptor.uploadResumeToken, isNull);
  });
}
