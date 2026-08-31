import Foundation

/// A YouTube video referenced in an assistant reply.
///
/// The transcript renders Markdown, so a pasted YouTube URL was just a blue link — fine
/// for a terminal, weak on a phone. These are detected so the chat can show a proper
/// tappable thumbnail card instead. Detection only; the text keeps its link too, so
/// nothing the agent wrote is hidden.
public struct YouTubeLink: Equatable, Sendable, Identifiable, Hashable {
  /// The 11-character video id.
  public let videoID: String

  public init(videoID: String) {
    self.videoID = videoID
  }

  public var id: String { videoID }

  /// Canonical watch URL — what a tap opens (the YouTube app claims it when installed).
  public var watchURL: URL { URL(string: "https://www.youtube.com/watch?v=\(videoID)")! }

  /// Thumbnail JPEG. `hqdefault` exists for effectively every video, unlike the
  /// nicer `maxresdefault`, which 404s often enough to look broken.
  public var thumbnailURL: URL {
    URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg")!
  }

  /// Keyless oEmbed endpoint — the card fetches the real title from here, best-effort.
  public var oembedURL: URL {
    URL(string: "https://www.youtube.com/oembed?url=https://www.youtube.com/watch?v=\(videoID)&format=json")!
  }

  /// Extract every YouTube video referenced in `text`, de-duplicated in order.
  ///
  /// Covers the shapes people (and models) actually paste: `watch?v=`, `youtu.be/`,
  /// `shorts/`, `embed/`, with or without extra query parameters. The id alphabet is
  /// strict (11 URL-safe chars) so trailing punctuation never sticks to the id.
  public static func findAll(in text: String) -> [YouTubeLink] {
    guard text.localizedCaseInsensitiveContains("youtu") else { return [] }
    let pattern = #"(?:youtube\.com/(?:watch\?[^\s)\]]*?v=|shorts/|embed/|live/)|youtu\.be/)([A-Za-z0-9_-]{11})"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
      return []
    }
    let ns = text as NSString
    var seen = Set<String>()
    var out: [YouTubeLink] = []
    for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
      let id = ns.substring(with: match.range(at: 1))
      if seen.insert(id).inserted {
        out.append(YouTubeLink(videoID: id))
      }
    }
    return out
  }
}
