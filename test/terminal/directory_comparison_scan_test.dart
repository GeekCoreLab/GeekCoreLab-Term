import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geekcore_term/terminal/directory_comparison.dart';
import 'package:geekcore_term/terminal/directory_comparison_scan.dart';

void main() {
  test(
    'scans local trees without following symbolic links',
    () async {
      final root = await Directory.systemTemp.createTemp('geekcore-tree-');
      final outside = await Directory.systemTemp.createTemp(
        'geekcore-outside-',
      );
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
        if (await outside.exists()) await outside.delete(recursive: true);
      });
      await Directory('${root.path}/nested').create();
      await File('${root.path}/nested/source.txt').writeAsString('read only');
      await File('${outside.path}/secret.txt').writeAsString('outside');
      await Link('${root.path}/linked').create(outside.path);

      final scan = await scanLocalDirectoryTree(root.path);

      expect(scan.isComplete, isTrue);
      expect(
        scan.items['nested/source.txt']?.type,
        DirectoryComparisonItemType.file,
      );
      expect(
        scan.items['linked']?.type,
        DirectoryComparisonItemType.symbolicLink,
      );
      expect(scan.items.containsKey('linked/secret.txt'), isFalse);
    },
    skip: Platform.isWindows ? 'Requires symlink creation privileges' : false,
  );

  test('scans remote trees without traversing symbolic links', () async {
    final sftp = _FakeSftpClient(
      directories: {
        '/root': [_name('folder', 0x41ed), _name('linked', 0xa1ff)],
        '/root/folder': [_name('data.bin', 0x81a4, size: 3, modifiedAt: 10)],
      },
    );

    final scan = await scanRemoteDirectoryTree(sftp, '/root');

    expect(scan.isComplete, isTrue);
    expect(scan.items['folder/data.bin']?.size, 3);
    expect(
      scan.items['linked']?.type,
      DirectoryComparisonItemType.symbolicLink,
    );
    expect(scan.items.keys, isNot(contains('linked/data.bin')));
  });

  test(
    'marks remote scan unstable when directory timestamps are unavailable',
    () async {
      final sftp = _FakeSftpClient(
        directories: const {'/root': []},
        provideDirectoryMtime: false,
      );

      final scan = await scanRemoteDirectoryTree(sftp, '/root');

      expect(scan.isComplete, isTrue);
      expect(scan.isSnapshotStable, isFalse);
    },
  );

  test('rejects remote entry names that could escape the tree', () async {
    final sftp = _FakeSftpClient(
      directories: {
        '/root': [_name('../outside', 0x81a4, size: 1, modifiedAt: 100)],
      },
    );

    await expectLater(
      scanRemoteDirectoryTree(sftp, '/root'),
      throwsA(isA<StateError>()),
    );
  });

  test(
    'marks a directory-tree scan incomplete at the directory limit',
    () async {
      final children = <SftpName>[];
      final directories = <String, List<SftpName>>{'/root': children};
      for (var index = 0; index < maxDirectoryComparisonDirectories; index++) {
        final name = 'dir-$index';
        children.add(_name(name, 0x41ed));
        directories['/root/$name'] = const [];
      }
      final sftp = _FakeSftpClient(directories: directories);

      final scan = await scanRemoteDirectoryTree(sftp, '/root');

      expect(scan.isComplete, isFalse);
      expect(scan.directoriesScanned, maxDirectoryComparisonDirectories);
    },
  );

  test('cancels when a remote directory changes during its listing', () async {
    final sftp = _FakeSftpClient(
      directories: const {'/root': []},
      changeRootOnList: true,
    );

    await expectLater(
      scanRemoteDirectoryTree(sftp, '/root'),
      throwsA(isA<StateError>()),
    );
  });
}

SftpName _name(String name, int mode, {int? size, int? modifiedAt}) => SftpName(
  filename: name,
  longname: name,
  attr: SftpFileAttrs(
    mode: SftpFileMode.value(mode),
    size: size,
    modifyTime: modifiedAt,
  ),
);

class _FakeSftpClient extends Fake implements SftpClient {
  _FakeSftpClient({
    required this.directories,
    this.provideDirectoryMtime = true,
    this.changeRootOnList = false,
  });

  final Map<String, List<SftpName>> directories;
  final bool provideDirectoryMtime;
  final bool changeRootOnList;
  bool _rootListed = false;

  @override
  Future<String> absolute(String path) async => path;

  @override
  Future<List<SftpName>> listdir(String path) async {
    if (path == '/root') _rootListed = true;
    return directories[path] ?? const [];
  }

  @override
  Future<SftpFileAttrs> stat(String path, {bool followLink = true}) async {
    if (directories.containsKey(path)) {
      return SftpFileAttrs(
        mode: SftpFileMode.value(0x41ed),
        modifyTime: !provideDirectoryMtime
            ? null
            : changeRootOnList && path == '/root' && _rootListed
            ? 101
            : 100,
      );
    }
    if (path == '/root/linked') {
      return SftpFileAttrs(mode: SftpFileMode.value(0xa1ff));
    }
    throw StateError('Unexpected remote stat: $path');
  }
}
