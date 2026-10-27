import 'dart:convert';

enum SshProxyType { socks5, httpConnect }

class SshProxyConfig {
  const SshProxyConfig({
    required this.type,
    required this.address,
    required this.port,
    this.username = '',
  });

  final SshProxyType type;
  final String address;
  final int port;
  final String username;

  String get credentialKey =>
      'ssh-proxy:${type.name}:${address.trim().toLowerCase()}:$port:${base64Url.encode(utf8.encode(username))}';

  String? validate() {
    final host = address.trim();
    if (host.isEmpty ||
        host.contains(RegExp(r'[\s/\\?#@\u0000-\u001f]')) ||
        host.contains('://')) {
      return '请输入有效的代理主机名或 IP 地址';
    }
    if (port < 1 || port > 65535) return '代理端口范围为 1 到 65535';
    if (username.contains(RegExp(r'[\r\n\u0000]'))) {
      return '代理用户名包含无效字符';
    }
    if (type == SshProxyType.httpConnect && username.contains(':')) {
      return 'HTTP 代理用户名不能包含冒号';
    }
    return null;
  }

  Map<String, Object> toJson() => {
    'type': type.name,
    'address': address,
    'port': port,
    if (username.isNotEmpty) 'username': username,
  };

  factory SshProxyConfig.fromJson(Object? encoded) {
    if (encoded is! Map<String, dynamic>) {
      throw const FormatException('SSH 代理配置格式无效');
    }
    final type = SshProxyType.values.firstWhere(
      (item) => item.name == encoded['type'],
      orElse: () => throw const FormatException('SSH 代理类型无效'),
    );
    final address = encoded['address'];
    final port = encoded['port'];
    final username = encoded['username'] as String? ?? '';
    if (address is! String || port is! int) {
      throw const FormatException('SSH 代理主机或端口无效');
    }
    final config = SshProxyConfig(
      type: type,
      address: address,
      port: port,
      username: username,
    );
    final validationError = config.validate();
    if (validationError != null) throw FormatException(validationError);
    return config;
  }

  @override
  bool operator ==(Object other) =>
      other is SshProxyConfig &&
      other.type == type &&
      other.address.trim().toLowerCase() == address.trim().toLowerCase() &&
      other.port == port &&
      other.username == username;

  @override
  int get hashCode =>
      Object.hash(type, address.trim().toLowerCase(), port, username);
}
