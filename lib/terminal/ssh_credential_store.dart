import 'ssh_credential_store_io.dart'
    if (dart.library.js_interop) 'ssh_credential_store_web.dart'
    as platform;

class SshCredentials {
  const SshCredentials({
    required this.username,
    this.password,
    this.privateKeyPem,
    this.privateKeyPassphrase,
  });

  final String username;
  final String? password;
  final String? privateKeyPem;
  final String? privateKeyPassphrase;
}

class SshCredentialStore {
  final platform.SshCredentialStorePlatform _platform =
      platform.SshCredentialStorePlatform();

  Future<SshCredentials?> read(String endpointKey) async {
    final value = await _platform.read(endpointKey);
    if (value == null || value['username'] is! String) {
      return null;
    }
    return SshCredentials(
      username: value['username']! as String,
      password: value['password'] as String?,
      privateKeyPem: value['privateKeyPem'] as String?,
      privateKeyPassphrase: value['privateKeyPassphrase'] as String?,
    );
  }

  Future<void> write(String endpointKey, SshCredentials credentials) =>
      _platform.write(endpointKey, {
        'username': credentials.username,
        if (credentials.password != null && credentials.password!.isNotEmpty)
          'password': credentials.password!,
        if (credentials.privateKeyPem != null &&
            credentials.privateKeyPem!.isNotEmpty)
          'privateKeyPem': credentials.privateKeyPem!,
        if (credentials.privateKeyPassphrase != null &&
            credentials.privateKeyPassphrase!.isNotEmpty)
          'privateKeyPassphrase': credentials.privateKeyPassphrase!,
      });

  Future<void> delete(String endpointKey) => _platform.delete(endpointKey);
}
