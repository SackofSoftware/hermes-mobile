import HermesKit
import SwiftUI

/// Renders assistant Markdown with support for fenced code blocks and lists.
///
/// SwiftUI's `Text` does not lay out block-level Markdown (lists collapse onto one
/// line, newlines vanish), so we render structure ourselves: split ``` fences via
/// `MarkdownSegment.parse`, then render prose line-by-line — list items get an explicit
/// bullet/number, and each line keeps inline Markdown (bold, code, links).
struct MarkdownText: View {
  let text: String

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(MarkdownSegment.parse(text).enumerated()), id: \.offset) { _, segment in
        switch segment {
        case let .prose(value):
          prose(value)
        case let .code(value):
          Text(value)
            .font(.callout.monospaced())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color(uiColor: .tertiarySystemBackground), in: .rect(cornerRadius: 8))
        }
      }
    }
  }

  private func prose(_ value: String) -> some View {
    let lines = value.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    return VStack(alignment: .leading, spacing: 3) {
      ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
        lineView(line)
      }
    }
  }

  @ViewBuilder
  private func lineView(_ line: String) -> some View {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty {
      // Paragraph break: a small gap, no empty Text (which would collapse).
      Spacer().frame(height: 2)
    } else if let bullet = Self.listMarker(trimmed) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(bullet.marker).foregroundStyle(.secondary)
        Text(inline(bullet.content)).frame(maxWidth: .infinity, alignment: .leading)
      }
    } else {
      Text(inline(trimmed)).frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  /// Inline-only Markdown so bold/code/links render but block layout (which `Text`
  /// can't show) is avoided; whitespace is preserved.
  private func inline(_ value: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    return (try? AttributedString(markdown: value, options: options)) ?? AttributedString(value)
  }

  /// Classify a line as a list item, returning the marker to show and the content
  /// after it. Handles `-`/`*`/`+` bullets and `N.` ordered items.
  static func listMarker(_ trimmed: String) -> (marker: String, content: String)? {
    for prefix in ["- ", "* ", "+ "] where trimmed.hasPrefix(prefix) {
      return ("•", String(trimmed.dropFirst(prefix.count)))
    }
    // Ordered list: leading digits followed by ". ".
    let digits = trimmed.prefix { $0.isNumber }
    if !digits.isEmpty {
      let rest = trimmed[digits.endIndex...]
      if rest.hasPrefix(". ") {
        return ("\(digits).", String(rest.dropFirst(2)))
      }
    }
    return nil
  }
}
