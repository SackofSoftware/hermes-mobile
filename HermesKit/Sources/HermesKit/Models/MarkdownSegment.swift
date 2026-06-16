import Foundation

/// A chunk of assistant Markdown: either prose or a fenced code block. Splitting on
/// ``` fences lets the UI render code in a monospaced box (Task 11) — pure and
/// testable, kept out of the view layer.
public enum MarkdownSegment: Equatable, Sendable {
  case prose(String)
  /// A fenced code block: the fence-stripped raw text (whitespace preserved) plus the
  /// optional language hint from the opening fence (e.g. ```` ```swift ````). The raw
  /// `text` is what the per-block copy button (#9) puts on the pasteboard.
  case code(text: String, language: String?)

  /// Split `text` into prose and fenced-code segments. The fence lines themselves are
  /// dropped, but the opening fence's language hint is retained on the code segment.
  /// An unterminated fence (as seen mid-stream) leaves its remainder as code.
  /// Empty/whitespace-only prose segments are omitted.
  public static func parse(_ text: String) -> [MarkdownSegment] {
    var result: [MarkdownSegment] = []
    var inCode = false
    var buffer: [Substring] = []
    var language: String?

    func flush() {
      let joined = buffer.joined(separator: "\n")
      buffer.removeAll()
      if inCode {
        result.append(.code(text: joined, language: language))
      } else {
        let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { result.append(.prose(trimmed)) }
      }
    }

    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let trimmedLine = line.trimmingCharacters(in: .whitespaces)
      if trimmedLine.hasPrefix("```") {
        let opening = !inCode
        flush()           // close the current segment
        inCode.toggle()   // the fence line itself is dropped
        if opening {
          // Carry the opening fence's language hint onto the code segment.
          let hint = trimmedLine.dropFirst(3).trimmingCharacters(in: .whitespaces)
          language = hint.isEmpty ? nil : hint
        } else {
          language = nil
        }
        continue
      }
      buffer.append(line)
    }
    flush()
    return result
  }
}
