import 'session_store.dart';

/// Returns saved sessions in a startup group once per endpoint, preserving the
/// user's saved-session order.
List<SessionRecord> sessionsForStartupGroup(
  Iterable<SessionRecord> sessions,
  String? group,
) {
  if (group == null || group.trim().isEmpty) return const [];
  final seenEndpoints = <String>{};
  return List.unmodifiable([
    for (final session in sessions)
      if (session.group == group && seenEndpoints.add(session.endpointKey))
        session,
  ]);
}

Future<void> startStartupSessionsInOrder(
  Iterable<SessionRecord> sessions,
  Future<void> Function(SessionRecord) startSession, {
  bool Function()? shouldContinue,
}) async {
  for (final session in sessions) {
    if (shouldContinue != null && !shouldContinue()) return;
    await startSession(session);
  }
}
