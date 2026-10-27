import 'package:flutter_test/flutter_test.dart';
import 'package:geekcore_term/terminal/session_store.dart';
import 'package:geekcore_term/terminal/startup_session_group.dart';

void main() {
  test('selects saved group sessions once each in saved order', () {
    final sessions = [
      _session(id: 'first', name: 'Edge A', address: 'edge-a', group: 'ops'),
      _session(id: 'other', name: 'Build', address: 'build', group: 'dev'),
      _session(
        id: 'duplicate',
        name: 'Edge A copy',
        address: 'edge-a',
        group: 'ops',
      ),
      _session(id: 'last', name: 'Edge B', address: 'edge-b', group: 'ops'),
    ];

    expect(sessionsForStartupGroup(sessions, 'ops').map((item) => item.id), [
      'first',
      'last',
    ]);
  });

  test(
    'returns no sessions when startup is disabled or the group is empty',
    () {
      final sessions = [
        _session(id: 'first', name: 'Edge A', address: 'edge-a', group: 'ops'),
      ];

      expect(sessionsForStartupGroup(sessions, null), isEmpty);
      expect(sessionsForStartupGroup(sessions, 'missing'), isEmpty);
      expect(sessionsForStartupGroup(sessions, ' '), isEmpty);
    },
  );

  test('starts sessions serially and stops when cancelled', () async {
    final sessions = [
      _session(id: 'first', name: 'Edge A', address: 'edge-a', group: 'ops'),
      _session(id: 'second', name: 'Edge B', address: 'edge-b', group: 'ops'),
      _session(id: 'third', name: 'Edge C', address: 'edge-c', group: 'ops'),
    ];
    final started = <String>[];
    var active = false;
    var shouldContinue = true;

    await startStartupSessionsInOrder(sessions, (session) async {
      expect(active, isFalse);
      active = true;
      await Future<void>.delayed(Duration.zero);
      started.add(session.id);
      active = false;
      if (session.id == 'second') shouldContinue = false;
    }, shouldContinue: () => shouldContinue);

    expect(started, ['first', 'second']);
  });
}

SessionRecord _session({
  required String id,
  required String name,
  required String address,
  required String group,
}) => SessionRecord(
  id: id,
  name: name,
  protocol: SessionProtocol.ssh,
  address: address,
  port: 22,
  group: group,
  lastConnectedAt: DateTime.utc(2026),
);
