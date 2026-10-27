import 'package:flutter_test/flutter_test.dart';
import 'package:geekcore_term/terminal/directory_comparison.dart';

void main() {
  test('compares relative paths, type, size and rounded modification time', () {
    final result = compareDirectorySnapshots(
      local: {
        'same.txt': const DirectoryComparisonSnapshot(
          type: DirectoryComparisonItemType.file,
          size: 12,
          modifiedAtMillis: 1000,
        ),
        'size.txt': const DirectoryComparisonSnapshot(
          type: DirectoryComparisonItemType.file,
          size: 2,
          modifiedAtMillis: 1000,
        ),
        'time.txt': const DirectoryComparisonSnapshot(
          type: DirectoryComparisonItemType.file,
          size: 4,
          modifiedAtMillis: 1000,
        ),
        'folder': const DirectoryComparisonSnapshot(
          type: DirectoryComparisonItemType.directory,
        ),
        'link': const DirectoryComparisonSnapshot(
          type: DirectoryComparisonItemType.symbolicLink,
        ),
      },
      remote: {
        'same.txt': const DirectoryComparisonSnapshot(
          type: DirectoryComparisonItemType.file,
          size: 12,
          modifiedAtMillis: 3000,
        ),
        'size.txt': const DirectoryComparisonSnapshot(
          type: DirectoryComparisonItemType.file,
          size: 3,
          modifiedAtMillis: 1000,
        ),
        'time.txt': const DirectoryComparisonSnapshot(
          type: DirectoryComparisonItemType.file,
          size: 4,
          modifiedAtMillis: 5000,
        ),
        'folder': const DirectoryComparisonSnapshot(
          type: DirectoryComparisonItemType.file,
          size: 0,
          modifiedAtMillis: 1000,
        ),
        'link': const DirectoryComparisonSnapshot(
          type: DirectoryComparisonItemType.symbolicLink,
        ),
        'only-remote.txt': const DirectoryComparisonSnapshot(
          type: DirectoryComparisonItemType.file,
          size: 1,
          modifiedAtMillis: 1000,
        ),
      },
      isComplete: true,
    );

    final kinds = {
      for (final entry in result.entries) entry.relativePath: entry.kind,
    };
    expect(kinds['same.txt'], DirectoryComparisonKind.metadataMatches);
    expect(kinds['size.txt'], DirectoryComparisonKind.sizeDifferent);
    expect(kinds['time.txt'], DirectoryComparisonKind.modifiedDifferent);
    expect(kinds['folder'], DirectoryComparisonKind.typeDifferent);
    expect(kinds['link'], DirectoryComparisonKind.symbolicLink);
    expect(kinds['only-remote.txt'], DirectoryComparisonKind.onlyRemote);
    expect(result.localItemCount, 5);
    expect(result.remoteItemCount, 6);
    expect(result.hasDifferences, isTrue);
  });

  test('keeps incomplete scan status visible and labels missing metadata', () {
    final result = compareDirectorySnapshots(
      local: {
        'unknown.txt': const DirectoryComparisonSnapshot(
          type: DirectoryComparisonItemType.file,
          size: 1,
        ),
      },
      remote: {
        'unknown.txt': const DirectoryComparisonSnapshot(
          type: DirectoryComparisonItemType.file,
          size: 1,
        ),
      },
      isComplete: false,
    );

    expect(result.isComplete, isFalse);
    expect(
      result.entries.single.kind,
      DirectoryComparisonKind.metadataUnavailable,
    );
  });
}
