bool matchesRemoteFileName(String filename, String query) {
  final normalizedQuery = query.trim().toLowerCase();
  return normalizedQuery.isEmpty ||
      filename.toLowerCase().contains(normalizedQuery);
}
