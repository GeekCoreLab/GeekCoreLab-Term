import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:geekcore_term/terminal/file_comparison.dart';

Uint8List _bytes(String value) => Uint8List.fromList(utf8.encode(value));

void main() {
  test('reports byte-identical content without calculating line diffs', () {
    final result = compareFileContents(_bytes('same\n'), _bytes('same\n'));

    expect(result.status, FileComparisonStatus.identical);
    expect(result.rows, isEmpty);
  });

  test('aligns changed lines while preserving insertions and deletions', () {
    final result = compareFileContents(
      _bytes('alpha\nbeta\nomega\n'),
      _bytes('alpha\ngamma\nomega\n'),
    );

    expect(result.status, FileComparisonStatus.textDifferent);
    expect(result.rows, hasLength(5));
    expect(result.rows[0].leftLine, 'alpha');
    expect(result.rows[1].leftLine, 'beta');
    expect(result.rows[1].rightLine, isNull);
    expect(result.rows[2].leftLine, isNull);
    expect(result.rows[2].rightLine, 'gamma');
    expect(result.rows.last.leftLine, '');
    expect(result.rows.last.rightLine, '');
  });

  test('distinguishes newline-only changes from text changes', () {
    final result = compareFileContents(
      _bytes('alpha\r\nbeta\r\n'),
      _bytes('alpha\nbeta\n'),
    );

    expect(result.status, FileComparisonStatus.formattingOnly);
  });

  test('labels invalid UTF-8 or NUL-containing content as binary', () {
    final invalidUtf8 = compareFileContents(
      Uint8List.fromList([0xff, 0xfe]),
      _bytes('text'),
    );
    final nulText = compareFileContents(
      Uint8List.fromList([0x61, 0x00]),
      Uint8List.fromList([0x62, 0x00]),
    );

    expect(invalidUtf8.status, FileComparisonStatus.binaryDifferent);
    expect(nulText.status, FileComparisonStatus.binaryDifferent);
  });

  test('bounds line alignment work for very large text files', () {
    final manyLines = _bytes(List.filled(1201, 'line').join('\n'));
    final result = compareFileContents(manyLines, _bytes('different'));

    expect(result.status, FileComparisonStatus.tooComplex);
    expect(result.rows, isEmpty);
  });
}
