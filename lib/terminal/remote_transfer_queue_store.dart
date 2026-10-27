import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'remote_transfer_queue.dart';

/// Stores resumable task descriptors, never connection credentials or bytes.
class RemoteTransferQueueStore {
  RemoteTransferQueueStore({SharedPreferencesAsync? preferences})
    : _preferences = preferences ?? SharedPreferencesAsync();

  static const storageKey = 'geekcore_term.remote_transfer_queue.v1';
  static Future<void> _writeQueue = Future<void>.value();

  final SharedPreferencesAsync _preferences;

  Future<List<PersistedRemoteTransferTask>> loadForSession(
    String sessionIdentity,
  ) async {
    await _writeQueue;
    final encodedTasks =
        await _preferences.getStringList(storageKey) ?? const [];
    final tasks = <PersistedRemoteTransferTask>[];
    for (final encoded in encodedTasks) {
      try {
        final value = jsonDecode(encoded);
        if (value is! Map<String, dynamic> ||
            value['sessionIdentity'] != sessionIdentity) {
          continue;
        }
        tasks.add(PersistedRemoteTransferTask.fromJson(value['task']));
      } on Object {
        // Ignore one malformed task without losing the rest of the queue.
      }
    }
    return tasks;
  }

  Future<void> saveForSession(
    String sessionIdentity,
    List<PersistedRemoteTransferTask> tasks,
  ) => _enqueueWrite(() async {
    final encodedTasks =
        await _preferences.getStringList(storageKey) ?? const [];
    final retained = <String>[];
    for (final encoded in encodedTasks) {
      try {
        final value = jsonDecode(encoded);
        if (value is Map<String, dynamic> &&
            value['sessionIdentity'] == sessionIdentity) {
          continue;
        }
      } on Object {
        // Preserve unrelated/corrupt records until their session is loaded.
      }
      retained.add(encoded);
    }
    retained.addAll(
      tasks.map(
        (task) => jsonEncode({
          'sessionIdentity': sessionIdentity,
          'task': task.toJson(),
        }),
      ),
    );
    await _preferences.setStringList(storageKey, retained);
  });

  Future<void> clearAll() =>
      _enqueueWrite(() => _preferences.remove(storageKey));

  Future<void> _enqueueWrite(Future<void> Function() operation) {
    final next = _writeQueue.then((_) => operation());
    _writeQueue = next.catchError((Object _) {});
    return next;
  }
}
