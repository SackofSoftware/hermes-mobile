import Foundation

/// A file the agent sent, referenced from its reply as `![caption](hermes-media://<id>)`.
///
/// The agent registers a PATH with the `hermes-media` plugin and embeds the marker; the
/// app resolves it to an authenticated fetch. Bytes never travel through the message
/// itself, so a large file costs the transcript nothing.
public struct MediaMarker: Equatable, Sendable, Identifiable, Hashable {
  /// Opaque id issued by the plugin.
  public let id: String
  /// Alt text from the marker — the agent's caption, or the filename it fell back to.
  public let caption: String

  public init(id: String, caption: String) {
    self.id = id
    self.caption = caption
  }
}

public enum MediaMarkerParser {
  /// Matches `![alt](hermes-media://id)`. The id is restricted to the URL-safe alphabet
  /// `secrets.token_urlsafe` produces, so stray text after a valid id can't be swallowed.
  private static let pattern = try? NSRegularExpression(
    pattern: #"!\[([^\]]*)\]\(hermes-media://([A-Za-z0-9_-]+)\)"#
  )

  /// Split a reply into the text to render and the media it referenced.
  ///
  /// Markers are REMOVED from the text rather than left in place: a stock Markdown
  /// renderer would otherwise show a broken-image box for a scheme it can't fetch. The
  /// media renders as its own view beneath the message instead.
  ///
  /// Returns the original string untouched when there are no markers, so the overwhelming
  /// majority of messages pay nothing for this.
  public static func extract(from text: String) -> (text: String, media: [MediaMarker]) {
    guard let pattern, text.contains("hermes-media://") else { return (text, []) }

    let ns = text as NSString
    let matches = pattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
    guard !matches.isEmpty else { return (text, []) }

    var media: [MediaMarker] = []
    var seen = Set<String>()
    var stripped = ""
    var cursor = 0

    for m in matches {
      stripped += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
      cursor = m.range.location + m.range.length

      let caption = m.range(at: 1).location == NSNotFound ? "" : ns.substring(with: m.range(at: 1))
      let id = ns.substring(with: m.range(at: 2))
      // The same file referenced twice should render once.
      if seen.insert(id).inserted {
        media.append(MediaMarker(id: id, caption: caption))
      }
    }
    stripped += ns.substring(from: cursor)

    // Removing a marker can leave a blank line where it sat; collapse the gap so the
    // message doesn't render with a hole in it.
    let cleaned = stripped
      .replacingOccurrences(of: "\n\n\n", with: "\n\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return (cleaned, media)
  }
}
