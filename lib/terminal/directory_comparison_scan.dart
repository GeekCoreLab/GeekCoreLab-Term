import 'package:dartssh2/dartssh2.dart';
import 'package:geekcore_term/terminal/directory_comparison.dart';
import 'package:geekcore_term/terminal/local_file_system.dart';
import 'package:geekcore_term/terminal/remote_file_transfer.dart';

const maxDirectoryComparisonItemsPerSide = 5000;
const maxDirectoryComparisonDirectories = 512;
const maxDirectoryComparisonDepth = 16;

class DirectoryTreeScan {
  const DirectoryTreeScan({
    required this.items,
    required this.isComplete,
    required this.directoriesScanned,
    required this.isSnapshotStable,
  });

  final Map<String, DirectoryComparisonSnapshot> items;
  final bool isComplete;
  final int directoriesScanned;
  final bool isSnapshotStable;
}

class _ScanNode {
  const _ScanNode(this.path, this.relativePath, this.depth);

  final String path;
  final String relativePath;
  final int depth;
}

Future<DirectoryTreeScan> scanLocalDirectoryTree(String rootPath) async {
  final items = <String, DirectoryComparisonSnapshot>{};
  final directoryVersions = <String, int>{};
  final pending = <_ScanNode>[_ScanNode(rootPath, '', 0)];
  var pendingIndex = 0;
  var directoriesScanned = 0;
  var isComplete = true;

  while (pendingIndex < pending.length) {
    if (directoriesScanned >= maxDirectoryComparisonDirectories) {
      isComplete = false;
      break;
    }
    final node = pending[pendingIndex++];
    final before = await localDirectoryModifiedAtMillis(node.path);
    final children = await listLocalDirectory(node.path);
    final after = await localDirectoryModifiedAtMillis(node.path);
    if (before != after) {
      throw StateError('本地目录在比较期间发生变化，请刷新后重试');
    }
    directoryVersions[node.path] = after;
    directoriesScanned++;

    children.sort((left, right) => left.name.compareTo(right.name));
    for (final child in children) {
      if (!_isSafeEntryName(child.name)) {
        throw StateError('本地目录包含无法安全比较的文件名');
      }
      if (child.name.startsWith('.geekcore-')) continue;
      if (items.length >= maxDirectoryComparisonItemsPerSide) {
        isComplete = false;
        break;
      }
      final relativePath = node.relativePath.isEmpty
          ? child.name
          : '${node.relativePath}/${child.name}';
      final type = child.isSymbolicLink
          ? DirectoryComparisonItemType.symbolicLink
          : child.isDirectory
          ? DirectoryComparisonItemType.directory
          : child.isOther
          ? DirectoryComparisonItemType.other
          : DirectoryComparisonItemType.file;
      items[relativePath] = DirectoryComparisonSnapshot(
        type: type,
        size: child.size,
        modifiedAtMillis: child.modified?.millisecondsSinceEpoch,
      );
      if (!child.isDirectory) continue;
      if (node.depth >= maxDirectoryComparisonDepth) {
        isComplete = false;
      } else {
        pending.add(_ScanNode(child.path, relativePath, node.depth + 1));
      }
    }
    if (!isComplete && items.length >= maxDirectoryComparisonItemsPerSide) {
      break;
    }
  }

  for (final entry in directoryVersions.entries) {
    if (await localDirectoryModifiedAtMillis(entry.key) != entry.value) {
      throw StateError('本地目录树在比较期间发生变化，请刷新后重试');
    }
  }
  return DirectoryTreeScan(
    items: Map.unmodifiable(items),
    isComplete: isComplete && pendingIndex == pending.length,
    directoriesScanned: directoriesScanned,
    isSnapshotStable: true,
  );
}

Future<DirectoryTreeScan> scanRemoteDirectoryTree(
  SftpClient sftp,
  String rootPath,
) async {
  final root = await sftp.absolute(rootPath);
  final items = <String, DirectoryComparisonSnapshot>{};
  final directoryVersions = <String, int?>{};
  final pending = <_ScanNode>[_ScanNode(root, '', 0)];
  var pendingIndex = 0;
  var directoriesScanned = 0;
  var isComplete = true;
  var isSnapshotStable = true;

  while (pendingIndex < pending.length) {
    if (directoriesScanned >= maxDirectoryComparisonDirectories) {
      isComplete = false;
      break;
    }
    final node = pending[pendingIndex++];
    final before = await sftp.stat(node.path, followLink: false);
    if (!before.isDirectory) {
      throw StateError('远端目录在比较期间被替换或移除');
    }
    final children = (await sftp.listdir(node.path)).toList();
    final after = await sftp.stat(node.path, followLink: false);
    if (!_sameRemoteDirectoryVersion(before, after)) {
      throw StateError('远端目录在比较期间发生变化，请刷新后重试');
    }
    directoryVersions[node.path] = after.modifyTime;
    if (before.modifyTime == null || after.modifyTime == null) {
      isSnapshotStable = false;
    }
    directoriesScanned++;

    children.sort((left, right) => left.filename.compareTo(right.filename));
    for (final child in children) {
      final name = child.filename;
      if (name == '.' ||
          name == '..' ||
          isRemoteTransferTemporaryFileName(name)) {
        continue;
      }
      if (!_isSafeEntryName(name)) {
        throw StateError('远端目录包含无法安全比较的文件名');
      }
      if (items.length >= maxDirectoryComparisonItemsPerSide) {
        isComplete = false;
        break;
      }
      final relativePath = node.relativePath.isEmpty
          ? name
          : '${node.relativePath}/$name';
      final attrs = child.attr;
      final type = attrs.isDirectory
          ? DirectoryComparisonItemType.directory
          : attrs.isFile
          ? DirectoryComparisonItemType.file
          : attrs.isSymbolicLink
          ? DirectoryComparisonItemType.symbolicLink
          : DirectoryComparisonItemType.other;
      items[relativePath] = DirectoryComparisonSnapshot(
        type: type,
        size: attrs.size,
        modifiedAtMillis: attrs.modifyTime == null
            ? null
            : attrs.modifyTime! * 1000,
      );
      if (!attrs.isDirectory) continue;
      if (node.depth >= maxDirectoryComparisonDepth) {
        isComplete = false;
      } else {
        final path = node.path.endsWith('/')
            ? '${node.path}$name'
            : '${node.path}/$name';
        pending.add(_ScanNode(path, relativePath, node.depth + 1));
      }
    }
    if (!isComplete && items.length >= maxDirectoryComparisonItemsPerSide) {
      break;
    }
  }

  final versions = directoryVersions.entries.toList();
  for (var offset = 0; offset < versions.length; offset += 16) {
    final batch = versions.skip(offset).take(16);
    await Future.wait(
      batch.map((entry) async {
        final current = await sftp.stat(entry.key, followLink: false);
        if (!current.isDirectory ||
            (entry.value != null && current.modifyTime != entry.value)) {
          throw StateError('远端目录树在比较期间发生变化，请刷新后重试');
        }
      }),
    );
  }
  return DirectoryTreeScan(
    items: Map.unmodifiable(items),
    isComplete: isComplete && pendingIndex == pending.length,
    directoriesScanned: directoriesScanned,
    isSnapshotStable: isSnapshotStable,
  );
}

bool _sameRemoteDirectoryVersion(SftpFileAttrs before, SftpFileAttrs after) =>
    after.isDirectory &&
    (before.modifyTime == null ||
        after.modifyTime == null ||
        before.modifyTime == after.modifyTime);

bool _isSafeEntryName(String name) =>
    name.isNotEmpty &&
    name != '.' &&
    name != '..' &&
    !name.contains('/') &&
    !name.contains('\u0000') &&
    !RegExp(r'[\x01-\x1f\x7f]').hasMatch(name);
