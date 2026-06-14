import Foundation

extension String {
  /// `nil` when the string is empty, otherwise itself. Handy for collapsing empty
  /// server fields (titles, previews, tool results) to `nil`.
  var nonEmpty: String? { isEmpty ? nil : self }
}
