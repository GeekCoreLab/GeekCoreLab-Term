import 'ssh_terminal_environment_stub.dart'
    if (dart.library.io) 'ssh_terminal_environment_io.dart'
    as platform;

Map<String, String> sshTerminalEnvironment() =>
    platform.sshTerminalEnvironment();
