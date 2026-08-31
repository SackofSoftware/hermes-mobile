import Foundation

/// Debug-only sign-in prefill, so a rebuild doesn't cost a hand-typed password.
///
/// Reinstalling onto a simulator clears the app's Keychain items, so every Debug build
/// landed on the sign-in screen — and the one thing you cannot reasonably retype twenty
/// times a day is a generated password. These values are baked into the Debug Info.plist
/// at `tuist generate` time from `TUIST_SERVER_URL` / `TUIST_DEBUG_USERNAME` /
/// `TUIST_DEBUG_PASSWORD`.
///
/// Why this can't leak into a shipped build:
///   * the keys are wired to build settings that are **empty in the Release config**, so a
///     Release archive carries empty strings even if the env vars happen to be set;
///   * every read here is inside `#if DEBUG`, so the lookup doesn't exist in Release at all;
///   * the generated `.xcodeproj` is gitignored (`Project.swift` is the source of truth),
///     so the values never reach the repository.
///
/// Treat it as a development convenience only — never a place to keep a real secret you
/// care about beyond a local test agent.
enum DebugAutoLogin {
  /// Server URL to prefill, e.g. `http://100.126.84.4:9119`.
  static var serverURL: String? { value(for: "HermesDefaultServerURL") }
  static var username: String? { value(for: "HermesDebugUsername") }
  static var password: String? { value(for: "HermesDebugPassword") }

  /// True when there's a complete set to sign in with, so the caller can prefill AND
  /// submit rather than leaving a half-filled form.
  static var hasCompleteCredentials: Bool {
    serverURL != nil && username != nil && password != nil
  }

  private static func value(for key: String) -> String? {
    #if DEBUG
    guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    // Unset build settings expand to the empty string, and an unexpanded `$(NAME)` means
    // the setting is missing entirely — neither is a usable value.
    guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
    return trimmed
    #else
    return nil
    #endif
  }
}
