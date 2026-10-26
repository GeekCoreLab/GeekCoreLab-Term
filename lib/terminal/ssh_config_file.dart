import 'ssh_config_file_data.dart';
import 'ssh_config_file_stub.dart'
    if (dart.library.io) 'ssh_config_file_io.dart'
    as platform;

export 'ssh_config_file_data.dart';

Future<SshConfigFileData?> readDefaultSshConfig() =>
    platform.readDefaultSshConfig();
