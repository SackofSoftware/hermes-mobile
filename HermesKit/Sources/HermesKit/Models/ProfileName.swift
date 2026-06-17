import Foundation

/// Pure validation for a Hermes profile name. Mirrors the desktop's create-profile
/// dialog: a name must match `^[a-z0-9][a-z0-9_-]{0,63}$` — lowercase letters, digits,
/// hyphens, and underscores, starting with a letter or digit, up to 64 chars total.
///
/// Validation runs against the *trimmed* string, so surrounding whitespace is ignored.
public enum ProfileName {
  /// Verbatim desktop hint shown beneath the name field.
  public static let hint =
    "Lowercase letters, digits, hyphens, and underscores. Must start with a letter or digit."

  private static let pattern = "^[a-z0-9][a-z0-9_-]{0,63}$"

  /// Returns `true` when the trimmed name matches the profile-name pattern.
  public static func isValid(_ name: String) -> Bool {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.range(of: pattern, options: .regularExpression) != nil
  }
}
