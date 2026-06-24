import Foundation

/// Pure helpers for the push-notification onboarding flow: the canonical plugin name, the
/// install prompt seeded into a new chat composer, the readiness signal derived from the
/// agent's plugin hub, and the Fibonacci snooze schedule for the "Later" backoff.
///
/// Everything here is platform-free and unit-tested — the views/reducers consume these
/// constants and functions rather than redefining copy or math.
public enum PushSetup {
  /// The plugin we look for in the agent's plugin hub (entry-point name on the agent).
  public static let pluginName = "hermes-push"

  /// Public repo for the plugin users install on their own agent.
  public static let pluginURLString = "https://github.com/goncharik/hermes-mobile-push-plugin"

  /// Defined ONCE here so the reducer can seed a new chat's composer with it (and the info
  /// sheet no longer renders it). A plain, ready-to-send instruction the user reviews before
  /// sending — it asks the agent to pip-install the standard Hermes plugin and restart so its
  /// REST routes mount.
  public static let installPrompt = """
    Please install the hermes-push plugin so I can receive push notifications on my phone. \
    Run: pip install git+https://github.com/goncharik/hermes-mobile-push-plugin.git — it's a \
    standard Hermes plugin (entry-point group "hermes_agent.plugins"). Then restart yourself \
    so the plugin loads and its REST routes mount.
    """
}

/// Readiness of the `hermes-push` plugin on the connected agent, derived from
/// `GET /api/dashboard/plugins/hub`.
public enum PushPluginStatus: Equatable, Sendable {
  /// Present AND `runtime_status == "enabled"` → request permission + register.
  case ready
  /// Present but not enabled (disabled/inactive), OR absent from the list → present the info
  /// sheet (unless snoozed).
  case notReady
  /// The endpoint 404'd or the request failed — we can't tell, so don't nag (leave the
  /// capability flag as-is).
  case unknown
}

/// Days to snooze the push info sheet after the N-th "Later" tap (1-indexed). A Fibonacci
/// backoff capped at ~60 days so the nag spaces out quickly but never disappears entirely.
///
/// `1→1, 2→2, 3→3, 4→5, 5→8, 6→13, 7→21, 8→34, 9→55, 10+→60`. A `laterCount` below 1 is
/// treated as 1 (first snooze).
public func pushPromptSnoozeDays(laterCount: Int) -> Int {
  let n = max(1, laterCount)
  // Fibonacci sequence indexed so 1→1, 2→2, 3→3, 4→5, … (i.e. Fib(2), Fib(3), Fib(4), …).
  var a = 1 // Fib(1)
  var b = 1 // Fib(2)
  for _ in 0..<n {
    (a, b) = (b, a + b)
  }
  // After `n` steps `a` is Fib(n+1): n=1→1, 2→2, 3→3, 4→5, 5→8, 6→13, 7→21, 8→34, 9→55.
  return min(a, 60)
}
