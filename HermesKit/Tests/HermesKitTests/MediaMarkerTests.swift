import Testing
@testable import HermesKit

@Suite struct MediaMarkerTests {
  @Test func extractsMarkerAndStripsItFromText() {
    let (text, media) = MediaMarkerParser.extract(
      from: "Here's the door schedule.\n\n![door schedule](hermes-media://AbC123_-x)\n\nLet me know."
    )
    #expect(media.count == 1)
    #expect(media[0].id == "AbC123_-x")
    #expect(media[0].caption == "door schedule")
    // The marker must NOT survive into the rendered text — a Markdown renderer would
    // show a broken-image box for a scheme it can't fetch.
    #expect(!text.contains("hermes-media"))
    #expect(text.contains("Here's the door schedule."))
    #expect(text.contains("Let me know."))
  }

  @Test func messagesWithoutMarkersAreUntouched() {
    let original = "Just a normal reply with a ![real image](https://example.com/x.png)."
    let (text, media) = MediaMarkerParser.extract(from: original)
    #expect(media.isEmpty)
    #expect(text == original) // byte-identical: no marker, no cost
  }

  @Test func handlesMultipleAndDeduplicates() {
    let (_, media) = MediaMarkerParser.extract(
      from: "![a](hermes-media://one) ![b](hermes-media://two) ![again](hermes-media://one)"
    )
    #expect(media.map(\.id) == ["one", "two"])
  }

  @Test func emptyCaptionIsAllowed() {
    let (_, media) = MediaMarkerParser.extract(from: "![](hermes-media://xyz)")
    #expect(media.count == 1)
    #expect(media[0].caption.isEmpty)
  }

  @Test func idAlphabetIsRestrictedSoTrailingTextIsNotSwallowed() {
    // Only the token-urlsafe alphabet is valid; a bad id shouldn't match at all.
    let (text, media) = MediaMarkerParser.extract(from: "![x](hermes-media://has spaces)")
    #expect(media.isEmpty)
    #expect(text.contains("hermes-media"))
  }
}

@Suite struct YouTubeLinkTests {
  @Test func findsTheShapesPeopleActuallyPaste() {
    let text = """
    Try https://www.youtube.com/watch?v=dQw4w9WgXcQ or the short form
    https://youtu.be/abc123DEF-_ — and a short https://youtube.com/shorts/AAAAAAAAAAA.
    """
    #expect(YouTubeLink.findAll(in: text).map(\.videoID)
      == ["dQw4w9WgXcQ", "abc123DEF-_", "AAAAAAAAAAA"])
  }

  @Test func trailingPunctuationDoesNotStickToTheID() {
    let links = YouTubeLink.findAll(in: "watch this: https://youtu.be/dQw4w9WgXcQ, great video")
    #expect(links.map(\.videoID) == ["dQw4w9WgXcQ"])
  }

  @Test func duplicatesCollapseAndNonYouTubeIsIgnored() {
    let text = "https://youtu.be/dQw4w9WgXcQ and again https://www.youtube.com/watch?v=dQw4w9WgXcQ plus https://vimeo.com/12345"
    #expect(YouTubeLink.findAll(in: text).count == 1)
    #expect(YouTubeLink.findAll(in: "no links here").isEmpty)
  }

  @Test func extraQueryParamsBeforeVAreHandled() {
    let links = YouTubeLink.findAll(in: "https://www.youtube.com/watch?app=desktop&v=dQw4w9WgXcQ&t=42")
    #expect(links.map(\.videoID) == ["dQw4w9WgXcQ"])
  }
}
