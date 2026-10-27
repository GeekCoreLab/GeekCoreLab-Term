import 'package:flutter_test/flutter_test.dart';
import 'package:geekcore_term/terminal/terminal_input_targets.dart';

void main() {
  test('routes input to its source tab by default', () {
    expect(terminalInputTargetIds(sourceTabId: 1, connectedTabIds: [1, 2, 3]), {
      1,
    });
  });

  test('combines split and selected targets without duplicates', () {
    expect(
      terminalInputTargetIds(
        sourceTabId: 1,
        connectedTabIds: [1, 2, 3, 4],
        splitTabIds: [1, 2],
        selectedTabIds: [2, 3],
        broadcastSplitInput: true,
      ),
      {1, 2, 3},
    );
  });

  test('never sends input to disconnected or stale tabs', () {
    expect(
      terminalInputTargetIds(
        sourceTabId: 1,
        connectedTabIds: [1, 3],
        splitTabIds: [1, 2],
        selectedTabIds: [2, 3, 99],
        broadcastSplitInput: true,
      ),
      {1, 3},
    );
  });
}
