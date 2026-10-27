import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geekcore_term/terminal/terminal_tab_order.dart';

void main() {
  test('moves a dragged tab forward using adjusted reorder indices', () {
    expect(
      reorderListItem(['ssh-a', 'ssh-b', 'ssh-c'], oldIndex: 0, newIndex: 2),
      ['ssh-b', 'ssh-c', 'ssh-a'],
    );
  });

  test('moves a dragged tab backward', () {
    expect(
      reorderListItem(['ssh-a', 'ssh-b', 'ssh-c'], oldIndex: 2, newIndex: 0),
      ['ssh-c', 'ssh-a', 'ssh-b'],
    );
  });

  test('drop at the same slot leaves the order unchanged', () {
    expect(reorderListItem(['ssh-a', 'ssh-b'], oldIndex: 1, newIndex: 1), [
      'ssh-a',
      'ssh-b',
    ]);
  });

  test('invalid indices fail instead of corrupting the session order', () {
    expect(
      () => reorderListItem(['ssh-a'], oldIndex: -1, newIndex: 0),
      throwsRangeError,
    );
    expect(
      () => reorderListItem(['ssh-a'], oldIndex: 0, newIndex: 1),
      throwsRangeError,
    );
  });

  testWidgets('horizontal drag handle reorders visible tab items', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(700, 100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final order = ['ssh-a', 'ssh-b', 'ssh-c'];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => SizedBox(
              height: 44,
              child: ReorderableListView.builder(
                scrollDirection: Axis.horizontal,
                buildDefaultDragHandles: false,
                itemCount: order.length,
                onReorderItem: (oldIndex, newIndex) {
                  setState(() {
                    final reordered = reorderListItem(
                      order,
                      oldIndex: oldIndex,
                      newIndex: newIndex,
                    );
                    order
                      ..clear()
                      ..addAll(reordered);
                  });
                },
                itemBuilder: (context, index) => KeyedSubtree(
                  key: ValueKey(order[index]),
                  child: SizedBox(
                    width: 200,
                    child: Row(
                      children: [
                        ReorderableDragStartListener(
                          index: index,
                          child: const Icon(Icons.drag_indicator),
                        ),
                        Text(order[index]),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.drag(
      find.byIcon(Icons.drag_indicator).first,
      const Offset(520, 0),
    );
    await tester.pumpAndSettle();

    expect(order, ['ssh-b', 'ssh-a', 'ssh-c']);
  });
}
