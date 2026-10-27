/// Returns a copy of [items] reordered with indices from `onReorderItem`.
List<T> reorderListItem<T>(
  List<T> items, {
  required int oldIndex,
  required int newIndex,
}) {
  if (oldIndex < 0 || oldIndex >= items.length) {
    throw RangeError.index(oldIndex, items, 'oldIndex');
  }
  if (newIndex < 0 || newIndex >= items.length) {
    throw RangeError.range(newIndex, 0, items.length - 1, 'newIndex');
  }

  final reordered = List<T>.of(items);
  if (newIndex == oldIndex) return reordered;

  final item = reordered.removeAt(oldIndex);
  reordered.insert(newIndex, item);
  return reordered;
}
