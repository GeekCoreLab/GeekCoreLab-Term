import 'ssh_identity_file_stub.dart'
    if (dart.library.io) 'ssh_identity_file_io.dart'
    as platform;

Future<String> readSshIdentityFile(String configuredPath) =>
    platform.readSshIdentityFile(configuredPath);
