int? parseRemotePermissionMode(String value) {
  final normalized = value.trim();
  if (!RegExp(r'^[0-7]{3,4}$').hasMatch(normalized)) return null;
  final mode = int.tryParse(normalized, radix: 8);
  if (mode == null || mode > 0xFFF) return null;
  return mode;
}

String formatRemotePermissionMode(int? mode, {required bool isDirectory}) {
  final permissions = (mode ?? (isDirectory ? 0x1ED : 0x1A4)) & 0xFFF;
  return permissions.toRadixString(8).padLeft(4, '0');
}
