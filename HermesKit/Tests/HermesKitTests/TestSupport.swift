import Testing

/// Bounded busy-wait for cross-task spy flags (e.g. a socket stream's `onTermination`
/// firing on a cancelled effect): yields until `condition()` holds, FAILING the test —
/// instead of hanging the suite forever — if it never does.
@MainActor
func waitUntil(
  _ condition: () -> Bool,
  _ comment: Comment? = nil,
  sourceLocation: SourceLocation = #_sourceLocation
) async {
  for _ in 0..<100_000 {
    if condition() { return }
    await Task.yield()
  }
  #expect(condition(), comment ?? "Timed out waiting for condition", sourceLocation: sourceLocation)
}
