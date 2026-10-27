class LocalFileEntry {
  const LocalFileEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    this.isSymbolicLink = false,
    this.isOther = false,
    this.size,
    this.modified,
  });

  final String name;
  final String path;
  final bool isDirectory;
  final bool isSymbolicLink;
  final bool isOther;
  final int? size;
  final DateTime? modified;
}

void validateLocalFileName(String name) {
  if (name.isEmpty || name == '.' || name == '..') {
    throw ArgumentError.value(name, 'name', '无效的本地文件名');
  }
  if (name.contains('/') ||
      name.contains('\\') ||
      name.contains('\u0000') ||
      name.contains(RegExp(r'[\x00-\x1f<>:"|?*]'))) {
    throw ArgumentError.value(name, 'name', '文件名包含路径分隔符或控制字符');
  }
  if (name.endsWith('.') || name.endsWith(' ')) {
    throw ArgumentError.value(name, 'name', '文件名不能以点或空格结尾');
  }
  final stem = name.split('.').first.toUpperCase();
  if (RegExp(r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$').hasMatch(stem)) {
    throw ArgumentError.value(name, 'name', '文件名与 Windows 设备名称冲突');
  }
}
