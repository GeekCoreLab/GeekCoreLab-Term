import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:geekcore_term/terminal/local_file_system.dart';
import 'package:geekcore_term/terminal/remote_file_transfer.dart';

void main() {
  group('local file system', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('geekcore-local-files-');
    });

    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    test(
      'lists ordinary files and directories in a stable type order',
      () async {
        await File('${root.path}/zeta.txt').writeAsString('z');
        await Directory('${root.path}/Alpha').create();
        await File('${root.path}/beta.txt').writeAsString('b');

        final entries = await listLocalDirectory(root.path);

        expect(entries.map((entry) => entry.name), [
          'Alpha',
          'beta.txt',
          'zeta.txt',
        ]);
        expect(entries.first.isDirectory, isTrue);
        expect(entries[1].size, 1);
        expect(localParentDirectory(root.path), root.parent.path);
        expect(localJoinPath(root.path, 'file.txt'), '${root.path}/file.txt');
      },
    );

    test('local upload sources can seek and reject changed files', () async {
      final path = '${root.path}/source.bin';
      final file = File(path);
      await file.writeAsBytes([1, 2, 3, 4]);
      final source = await localFileSource(path);

      expect(source.canResumeFromLocalPath, isTrue);
      expect(
        await source.openReadFromOffset!(2).expand((chunk) => chunk).toList(),
        [3, 4],
      );

      await file.writeAsBytes([9, 8, 7, 6, 5]);
      await expectLater(
        source.length(),
        throwsA(isA<RemoteFileSourceChanged>()),
      );
    });

    test('writes a new file and refuses implicit overwrite', () async {
      final destination = '${root.path}/download.txt';
      final bytes = Uint8List.fromList([1, 2, 3, 4]);

      await writeLocalFileAtomically(
        destination,
        bytes,
        overwriteConfirmed: false,
      );
      expect(await File(destination).readAsBytes(), bytes);
      expect(await localFileExists(destination), isTrue);
      await expectLater(
        writeLocalFileAtomically(
          destination,
          Uint8List.fromList([9]),
          overwriteConfirmed: false,
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(await File(destination).readAsBytes(), bytes);
    });

    test(
      'replaces only after confirmation and removes temporary siblings',
      () async {
        final destination = '${root.path}/download.txt';
        await File(destination).writeAsString('original');

        await writeLocalFileAtomically(
          destination,
          Uint8List.fromList('replacement'.codeUnits),
          overwriteConfirmed: true,
        );

        expect(await File(destination).readAsString(), 'replacement');
        final names = Directory(
          root.path,
        ).listSync().map((entity) => localFileName(entity.path));
        expect(names, ['download.txt']);
      },
    );

    test(
      'resumes a matching SFTP partial file after an interrupted stream',
      () async {
        final destination = '${root.path}/resumed.bin';
        Stream<Uint8List> interrupted(int offset) async* {
          expect(offset, 0);
          yield Uint8List.fromList([1, 2]);
          throw StateError('connection dropped');
        }

        await expectLater(
          writeResumableLocalDownload(
            path: destination,
            transferIdentity: 'server:user:/remote/resumed.bin',
            sourceVersion: 'size=4;mtime=1234',
            expectedLength: 4,
            openRead: interrupted,
            overwriteConfirmed: false,
            validateSource: () async {},
          ),
          throwsStateError,
        );

        final progress = <int>[];
        Stream<Uint8List> resumed(int offset) async* {
          expect(offset, 2);
          yield Uint8List.fromList([3, 4]);
        }

        await writeResumableLocalDownload(
          path: destination,
          transferIdentity: 'server:user:/remote/resumed.bin',
          sourceVersion: 'size=4;mtime=1234',
          expectedLength: 4,
          openRead: resumed,
          overwriteConfirmed: false,
          validateSource: () async {},
          onProgress: progress.add,
        );

        expect(await File(destination).readAsBytes(), [1, 2, 3, 4]);
        expect(progress, [2, 4]);
        expect(
          Directory(
            root.path,
          ).listSync().map((entity) => localFileName(entity.path)),
          ['resumed.bin'],
        );
      },
    );

    test('restarts a partial file when the remote version changes', () async {
      final destination = '${root.path}/changed.bin';
      Future<void> interruptVersion(String version) async {
        Stream<Uint8List> interrupted(int offset) async* {
          expect(offset, 0);
          yield Uint8List.fromList([1]);
          throw StateError('connection dropped');
        }

        await expectLater(
          writeResumableLocalDownload(
            path: destination,
            transferIdentity: 'server:user:/remote/changed.bin',
            sourceVersion: version,
            expectedLength: 2,
            openRead: interrupted,
            overwriteConfirmed: false,
            validateSource: () async {},
          ),
          throwsStateError,
        );
      }

      await interruptVersion('mtime=1');
      Stream<Uint8List> updatedSource(int offset) async* {
        expect(offset, 0);
        yield Uint8List.fromList([8, 9]);
      }

      await writeResumableLocalDownload(
        path: destination,
        transferIdentity: 'server:user:/remote/changed.bin',
        sourceVersion: 'mtime=2',
        expectedLength: 2,
        openRead: updatedSource,
        overwriteConfirmed: false,
        validateSource: () async {},
      );

      expect(await File(destination).readAsBytes(), [8, 9]);
    });

    test('rejects path components and Windows device names', () {
      for (final name in [
        '../escape',
        r'folder\escape',
        'CON.txt',
        'bad:name',
      ]) {
        expect(() => validateLocalFileName(name), throwsArgumentError);
      }
      expect(() => validateLocalFileName('normal file.txt'), returnsNormally);
    });
  });
}
