import 'package:flutter_test/flutter_test.dart';
import 'package:geekcore_term/terminal/remote_file_transfer.dart';

void main() {
  group('validateRemoteFileName', () {
    test('accepts ordinary names and SFTP names containing newlines', () {
      expect(
        () => validateRemoteFileName(
          'release #1.txt',
          RemoteTransferProtocol.sftp,
        ),
        returnsNormally,
      );
      expect(
        () =>
            validateRemoteFileName('line\nbreak', RemoteTransferProtocol.sftp),
        returnsNormally,
      );
    });

    test('rejects empty names, path traversal, and NUL bytes', () {
      for (final name in [
        '',
        '.',
        '..',
        '../private',
        'dir/file',
        'nul\u0000name',
      ]) {
        expect(
          () => validateRemoteFileName(name, RemoteTransferProtocol.sftp),
          throwsArgumentError,
          reason: 'rejected: $name',
        );
      }
    });

    test('rejects line breaks in legacy SCP protocol headers', () {
      expect(
        () => validateRemoteFileName('bad\nname', RemoteTransferProtocol.scp),
        throwsArgumentError,
      );
      expect(
        () => validateRemoteFileName('bad\rname', RemoteTransferProtocol.scp),
        throwsArgumentError,
      );
    });
  });
}
