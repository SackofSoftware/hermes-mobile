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
