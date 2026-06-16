import Foundation

extension String {
  /// `nil` when the string is empty, otherwise itself. Handy for collapsing empty
  /// server fields (titles, previews, tool results) to `nil`.
  var nonEmpty: String? { isEmpty ? nil : self }

  /// Whitespace/newline-trimmed, or `nil` when nothing is left. Collapses blank server
  /// fields (e.g. a title that's just spaces) to `nil`.
  var trimmedNonEmpty: String? {
    trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
  }
}
