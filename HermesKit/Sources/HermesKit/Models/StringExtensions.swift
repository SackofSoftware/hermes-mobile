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

  /// This string with ANSI/VT100 escape sequences removed. The agent formats slash-command
  /// output for a terminal (SGR colors, cursor moves, box-drawing color runs); on mobile
  /// those render as literal garbage (`[1;31m`, `[0m`, `[38;2;255;215;0m`, …) because the
  /// introducing ESC byte (`0x1B`) is invisible. Applied to every slash-pipeline string
  /// before it becomes a `commandOutput` row or is set into the composer (#36 follow-up).
  ///
  /// ONLY ESC-introduced sequences are stripped — normal text is left byte-for-byte intact,
  /// including box-drawing (`+---+`, `|`), the `(^_^)?` mascot, multibyte characters, and a
  /// literal `[abc]` that has no ESC prefix. Handled: CSI (`ESC [` params `[0-9;:<>=?]*`
  /// intermediates `[ -/]*` final `[@-~]` — covers SGR `m`, cursor moves), OSC
  /// (`ESC ] … BEL|ST`), and any other two-byte `ESC <byte>` sequence, plus a lone trailing
  /// ESC. Pure and platform-agnostic (outside any UIKit guard) so it is unit-tested on macOS.
  var strippingANSI: String {
    // Fast path: no ESC byte means no escape sequences — return the original untouched.
    guard contains("\u{1B}") else { return self }

    let scalars = Array(unicodeScalars)
    var result = String.UnicodeScalarView()
    result.reserveCapacity(scalars.count)
    var i = 0
    while i < scalars.count {
      guard scalars[i] == "\u{1B}" else {
        result.append(scalars[i])
        i += 1
        continue
      }
      // ESC: consume the whole escape sequence.
      let next = i + 1 < scalars.count ? scalars[i + 1] : nil
      switch next {
      case "["?: // CSI: ESC [ <params> <intermediates> <final>
        i += 2
        while i < scalars.count, (0x30...0x3F).contains(scalars[i].value) { i += 1 } // params
        while i < scalars.count, (0x20...0x2F).contains(scalars[i].value) { i += 1 } // intermediates
        if i < scalars.count, (0x40...0x7E).contains(scalars[i].value) { i += 1 }    // final byte
      case "]"?: // OSC: ESC ] ... terminated by BEL (0x07) or ST (ESC \)
        i += 2
        while i < scalars.count {
          if scalars[i] == "\u{07}" { i += 1; break } // BEL
          if scalars[i] == "\u{1B}", i + 1 < scalars.count, scalars[i + 1] == "\\" { i += 2; break } // ST
          i += 1
        }
      case .some: // any other two-byte ESC sequence (drop ESC + the following byte)
        i += 2
      case nil: // a lone trailing ESC
        i += 1
      }
    }
    return String(result)
  }
}
