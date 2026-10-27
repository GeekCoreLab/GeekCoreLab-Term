import 'package:flutter_test/flutter_test.dart';
import 'package:geekcore_term/terminal/remote_file_permissions.dart';

void main() {
  group('remote file permission mode', () {
    test('parses three and four digit octal modes', () {
      expect(parseRemotePermissionMode('644'), 0x1A4);
      expect(parseRemotePermissionMode('0755'), 0x1ED);
      expect(parseRemotePermissionMode('4755'), 0x9ED);
    });

    test('rejects malformed and out-of-range modes', () {
      expect(parseRemotePermissionMode('77'), isNull);
      expect(parseRemotePermissionMode('0888'), isNull);
      expect(parseRemotePermissionMode('17777'), isNull);
      expect(parseRemotePermissionMode('0644 '), 0x1A4);
    });

    test('formats a sensible default when the server omits mode', () {
      expect(formatRemotePermissionMode(null, isDirectory: false), '0644');
      expect(formatRemotePermissionMode(null, isDirectory: true), '0755');
    });
  });
}
