class SshConfigHost {
  const SshConfigHost({
    required this.alias,
    required this.hostName,
    required this.port,
    this.username = '',
    this.identityFile,
  });

  final String alias;
  final String hostName;
  final int port;
  final String username;
  final String? identityFile;
}

class SshConfigParseResult {
  const SshConfigParseResult({required this.hosts, required this.warnings});

  final List<SshConfigHost> hosts;
  final List<String> warnings;
}

SshConfigParseResult parseOpenSshConfig(String source) {
  final warnings = <String>{};
  final blocks = <_ConfigBlock>[];
  _ConfigBlock? activeBlock;
  var ignoreUntilHost = false;

  for (final line in _logicalLines(source)) {
    final cleaned = _stripComment(line).trim();
    if (cleaned.isEmpty) continue;
    final tokens = _tokenize(cleaned);
    if (tokens.isEmpty) continue;
    final firstToken = tokens.first;
    final equalsIndex = firstToken.indexOf('=');
    final keyword =
        (equalsIndex < 0 ? firstToken : firstToken.substring(0, equalsIndex))
            .toLowerCase();
    final values = <String>[
      if (equalsIndex >= 0) firstToken.substring(equalsIndex + 1),
      ...tokens.skip(1),
    ];
    if (equalsIndex < 0 && values.isNotEmpty && values.first.startsWith('=')) {
      final inlineValue = values.removeAt(0).substring(1);
      if (inlineValue.isNotEmpty) values.insert(0, inlineValue);
      if (inlineValue.isEmpty && values.isNotEmpty && values.first == '=') {
        values.removeAt(0);
      }
    }

    if (keyword == 'host') {
      if (values.isEmpty) {
        warnings.add('发现没有主机名的 Host 声明');
        activeBlock = null;
        ignoreUntilHost = false;
        continue;
      }
      activeBlock = _ConfigBlock(values);
      blocks.add(activeBlock);
      ignoreUntilHost = false;
      continue;
    }
    if (keyword == 'match') {
      warnings.add('Match 条件未导入；其中的配置被跳过');
      activeBlock = null;
      ignoreUntilHost = true;
      continue;
    }
    if (ignoreUntilHost) continue;
    if (keyword == 'include') {
      warnings.add('Include 文件未展开；请单独选择被引用的配置文件');
      continue;
    }
    if (values.isEmpty || values.first.isEmpty) {
      warnings.add('忽略缺少值的配置项：${tokens.first}');
      continue;
    }
    if (keyword == 'proxyjump' || keyword == 'proxycommand') {
      warnings.add('ProxyJump / ProxyCommand 未导入');
    }
    activeBlock ??= _ConfigBlock(null)..isGlobal = true;
    if (!blocks.contains(activeBlock)) blocks.insert(0, activeBlock);
    activeBlock.directives.add(_ConfigDirective(keyword, values));
  }

  final aliases = <String, String>{};
  for (final block in blocks) {
    if (block.isGlobal) continue;
    for (final pattern in block.patterns ?? const <String>[]) {
      if (pattern.startsWith('!') || _hasWildcard(pattern)) continue;
      aliases.putIfAbsent(pattern.toLowerCase(), () => pattern);
    }
  }

  final hosts = <SshConfigHost>[];
  for (final alias in aliases.values) {
    final values = <String, String>{};
    final identityFiles = <String>[];
    for (final block in blocks) {
      if (!_blockMatches(block, alias)) continue;
      for (final directive in block.directives) {
        switch (directive.name) {
          case 'hostname':
          case 'user':
          case 'port':
            values.putIfAbsent(directive.name, () => directive.values.first);
            break;
          case 'identityfile':
            for (final path in directive.values) {
              if (path.toLowerCase() != 'none' &&
                  !identityFiles.contains(path)) {
                identityFiles.add(path);
              }
            }
            break;
        }
      }
    }

    final portValue = values['port'];
    final port = portValue == null ? 22 : int.tryParse(portValue);
    if (port == null || port < 1 || port > 65535) {
      warnings.add('忽略端口无效的主机配置：$alias');
      continue;
    }
    final username = values['user'] ?? '';
    final rawHostName = values['hostname'] ?? alias;
    final hostName = _expandTokens(
      rawHostName,
      alias: alias,
      hostName: rawHostName,
      port: port,
      username: username,
    );
    final identityFile = identityFiles.isEmpty
        ? null
        : _expandTokens(
            identityFiles.first,
            alias: alias,
            hostName: hostName,
            port: port,
            username: username,
          );
    hosts.add(
      SshConfigHost(
        alias: alias,
        hostName: hostName,
        port: port,
        username: username,
        identityFile: identityFile,
      ),
    );
    if (identityFiles.length > 1) {
      warnings.add('$alias 配置了多个 IdentityFile；导入了第一个');
    }
  }

  return SshConfigParseResult(hosts: hosts, warnings: warnings.toList());
}

class _ConfigBlock {
  _ConfigBlock(this.patterns);

  final List<String>? patterns;
  final List<_ConfigDirective> directives = [];
  bool isGlobal = false;
}

class _ConfigDirective {
  const _ConfigDirective(this.name, this.values);

  final String name;
  final List<String> values;
}

bool _blockMatches(_ConfigBlock block, String alias) {
  if (block.isGlobal) return true;
  final patterns = block.patterns;
  if (patterns == null) return false;
  final positive = patterns.where((pattern) => !pattern.startsWith('!'));
  final negative = patterns.where((pattern) => pattern.startsWith('!'));
  final matchesPositive = positive.any(
    (pattern) => _matchesPattern(alias, pattern),
  );
  final matchesNegative = negative.any(
    (pattern) => _matchesPattern(alias, pattern.substring(1)),
  );
  return matchesPositive && !matchesNegative;
}

bool _matchesPattern(String value, String pattern) {
  final expression = StringBuffer('^');
  for (final rune in pattern.runes) {
    final character = String.fromCharCode(rune);
    if (character == '*') {
      expression.write('.*');
    } else if (character == '?') {
      expression.write('.');
    } else {
      expression.write(RegExp.escape(character));
    }
  }
  expression.write(r'$');
  return RegExp(expression.toString(), caseSensitive: false).hasMatch(value);
}

bool _hasWildcard(String pattern) =>
    pattern.contains('*') || pattern.contains('?');

String _expandTokens(
  String value, {
  required String alias,
  required String hostName,
  required int port,
  required String username,
}) {
  return value
      .replaceAll('%%', '\u0000')
      .replaceAll('%h', hostName)
      .replaceAll('%n', alias)
      .replaceAll('%p', '$port')
      .replaceAll('%r', username)
      .replaceAll('\u0000', '%');
}

List<String> _logicalLines(String source) {
  final lines = <String>[];
  final pending = StringBuffer();
  for (final line
      in source.replaceFirst('\uFEFF', '').split(RegExp(r'\r?\n'))) {
    final trimmed = line.trimRight();
    if (trimmed.endsWith('\\')) {
      pending.write(trimmed.substring(0, trimmed.length - 1));
      pending.write(' ');
    } else {
      pending.write(line);
      lines.add(pending.toString());
      pending.clear();
    }
  }
  if (pending.isNotEmpty) lines.add(pending.toString());
  return lines;
}

String _stripComment(String line) {
  var quote = '';
  var escaped = false;
  for (var index = 0; index < line.length; index++) {
    final character = line[index];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (character == '\\' && quote != "'") {
      escaped = true;
      continue;
    }
    if ((character == '"' || character == "'") &&
        (quote.isEmpty || quote == character)) {
      quote = quote.isEmpty ? character : '';
      continue;
    }
    if (character == '#' &&
        quote.isEmpty &&
        (index == 0 || line[index - 1].trim().isEmpty)) {
      return line.substring(0, index);
    }
  }
  return line;
}

List<String> _tokenize(String line) {
  final tokens = <String>[];
  final token = StringBuffer();
  var quote = '';
  var escaped = false;
  var hasToken = false;
  for (var index = 0; index < line.length; index++) {
    final character = line[index];
    if (escaped) {
      token.write(character);
      hasToken = true;
      escaped = false;
      continue;
    }
    if (character == '\\' && quote != "'") {
      final next = index + 1 < line.length ? line[index + 1] : '';
      if (next.isEmpty || next.trim().isEmpty || next == '"' || next == "'") {
        escaped = true;
      } else {
        token.write(character);
        hasToken = true;
      }
      continue;
    }
    if ((character == '"' || character == "'") &&
        (quote.isEmpty || quote == character)) {
      quote = quote.isEmpty ? character : '';
      hasToken = true;
      continue;
    }
    if (character.trim().isEmpty && quote.isEmpty) {
      if (hasToken) {
        tokens.add(token.toString());
        token.clear();
        hasToken = false;
      }
      continue;
    }
    token.write(character);
    hasToken = true;
  }
  if (escaped) token.write('\\');
  if (hasToken) tokens.add(token.toString());
  return tokens;
}
