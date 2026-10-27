import 'package:flutter_test/flutter_test.dart';
import 'package:geekcore_term/terminal/remote_file_search.dart';

void main() {
  group('matchesRemoteFileName', () {
    test('matches substrings without case sensitivity', () {
      expect(matchesRemoteFileName('Router-Backup.conf', 'backup'), isTrue);
      expect(matchesRemoteFileName('Router-Backup.conf', 'ROUTER'), isTrue);
    });

    test('trims query whitespace and accepts an empty filter', () {
      expect(matchesRemoteFileName('known_hosts', '  hosts  '), isTrue);
      expect(matchesRemoteFileName('known_hosts', '   '), isTrue);
    });

    test('does not match absent text', () {
      expect(matchesRemoteFileName('known_hosts', 'private'), isFalse);
    });
  });
}
