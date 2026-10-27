Set<int> terminalInputTargetIds({
  required int sourceTabId,
  required Iterable<int> connectedTabIds,
  Iterable<int> splitTabIds = const [],
  Iterable<int> selectedTabIds = const [],
  bool broadcastSplitInput = false,
}) {
  final connected = connectedTabIds.toSet();
  final targets = <int>{};
  if (connected.contains(sourceTabId)) targets.add(sourceTabId);
  if (broadcastSplitInput) {
    targets.addAll(splitTabIds.where(connected.contains));
  }
  targets.addAll(selectedTabIds.where(connected.contains));
  return targets;
}
