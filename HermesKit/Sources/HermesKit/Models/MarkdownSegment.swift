import Foundation

/// A chunk of assistant Markdown: either prose or a fenced code block. Splitting on
/// ``` fences lets the UI render code in a monospaced box (Task 11) — pure and
/// testable, kept out of the view layer.
public enum MarkdownSegment: Equatable, Sendable {
  case prose(String)
  case code(String)

  /// Split `text` into prose and fenced-code segments. The fence lines themselves are
  /// dropped. An unterminated fence (as seen mid-stream) leaves its remainder as code.
  /// Empty/whitespace-only prose segments are omitted.
  public static func parse(_ text: String) -> [MarkdownSegment] {
    var result: [MarkdownSegment] = []
    var inCode = false
    var buffer: [Substring] = []

    func flush() {
      let joined = buffer.joined(separator: "\n")
      buffer.removeAll()
      if inCode {
        result.append(.code(joined))
      } else {
        let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { result.append(.prose(trimmed)) }
      }
    }

    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
        flush()           // close the current segment
        inCode.toggle()   // the fence line itself is dropped
        continue
      }
      buffer.append(line)
    }
    flush()
    return result
  }
}
