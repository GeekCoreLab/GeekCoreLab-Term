enum DirectoryComparisonItemType { file, directory, symbolicLink, other }

enum DirectoryComparisonKind {
  onlyLocal,
  onlyRemote,
  typeDifferent,
  sizeDifferent,
  modifiedDifferent,
  metadataMatches,
  metadataUnavailable,
  symbolicLink,
  unsupportedType,
}

class DirectoryComparisonSnapshot {
  const DirectoryComparisonSnapshot({
    required this.type,
    this.size,
    this.modifiedAtMillis,
  });

  final DirectoryComparisonItemType type;
  final int? size;
  final int? modifiedAtMillis;
}

class DirectoryComparisonEntry {
  const DirectoryComparisonEntry({
    required this.relativePath,
    required this.kind,
    this.local,
    this.remote,
  });

  final String relativePath;
  final DirectoryComparisonKind kind;
  final DirectoryComparisonSnapshot? local;
  final DirectoryComparisonSnapshot? remote;
}

class DirectoryComparison {
  const DirectoryComparison({
    required this.entries,
    required this.localItemCount,
    required this.remoteItemCount,
    required this.isComplete,
    required this.isSnapshotStable,
  });

  final List<DirectoryComparisonEntry> entries;
  final int localItemCount;
  final int remoteItemCount;

  /// False when the scanner hit its depth, directory, or entry limit.
  final bool isComplete;

  /// False when one side could not verify directory timestamps while scanning.
  final bool isSnapshotStable;

  int count(DirectoryComparisonKind kind) =>
      entries.where((entry) => entry.kind == kind).length;

  bool get hasDifferences => entries.any(
    (entry) => entry.kind != DirectoryComparisonKind.metadataMatches,
  );
}

/// Compares directory trees by relative path and filesystem metadata only.
///
/// A matching size and modification time is not proof that file bytes match.
/// The caller owns traversal limits and must set [isComplete] accordingly.
DirectoryComparison compareDirectorySnapshots({
  required Map<String, DirectoryComparisonSnapshot> local,
  required Map<String, DirectoryComparisonSnapshot> remote,
  required bool isComplete,
  bool isSnapshotStable = true,
}) {
  final paths = {...local.keys, ...remote.keys}.toList()..sort();
  final entries = <DirectoryComparisonEntry>[];
  for (final path in paths) {
    final localItem = local[path];
    final remoteItem = remote[path];
    final kind = _compareItem(localItem, remoteItem);
    if (kind == null) continue;
    entries.add(
      DirectoryComparisonEntry(
        relativePath: path,
        kind: kind,
        local: localItem,
        remote: remoteItem,
      ),
    );
  }
  return DirectoryComparison(
    entries: List.unmodifiable(entries),
    localItemCount: local.length,
    remoteItemCount: remote.length,
    isComplete: isComplete,
    isSnapshotStable: isSnapshotStable,
  );
}

DirectoryComparisonKind? _compareItem(
  DirectoryComparisonSnapshot? local,
  DirectoryComparisonSnapshot? remote,
) {
  if (local == null) return DirectoryComparisonKind.onlyRemote;
  if (remote == null) return DirectoryComparisonKind.onlyLocal;
  if (local.type != remote.type) return DirectoryComparisonKind.typeDifferent;

  switch (local.type) {
    case DirectoryComparisonItemType.directory:
      return null;
    case DirectoryComparisonItemType.symbolicLink:
      return DirectoryComparisonKind.symbolicLink;
    case DirectoryComparisonItemType.other:
      return DirectoryComparisonKind.unsupportedType;
    case DirectoryComparisonItemType.file:
      if (local.size == null || remote.size == null) {
        return DirectoryComparisonKind.metadataUnavailable;
      }
      if (local.size != remote.size) {
        return DirectoryComparisonKind.sizeDifferent;
      }
      final localModified = local.modifiedAtMillis;
      final remoteModified = remote.modifiedAtMillis;
      if (localModified == null || remoteModified == null) {
        return DirectoryComparisonKind.metadataUnavailable;
      }
      // SFTP commonly exposes modification time only to whole seconds.
      if ((localModified - remoteModified).abs() > 2000) {
        return DirectoryComparisonKind.modifiedDifferent;
      }
      return DirectoryComparisonKind.metadataMatches;
  }
}
