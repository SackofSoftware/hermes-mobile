import Testing

@testable import HermesKit

struct MarkdownSegmentTests {
  @Test func plainProseIsOneSegment() {
    #expect(MarkdownSegment.parse("hello world") == [.prose("hello world")])
  }

  @Test func fencedCodeSplitsFromProse() {
    let text = """
    Here is code:
    ```
    let x = 1
    print(x)
    ```
    Done.
    """
    #expect(MarkdownSegment.parse(text) == [
      .prose("Here is code:"),
      .code("let x = 1\nprint(x)"),
      .prose("Done."),
    ])
  }

  @Test func languageHintOnFenceIsDropped() {
    let text = "```swift\nlet x = 1\n```"
    #expect(MarkdownSegment.parse(text) == [.code("let x = 1")])
  }

  @Test func unterminatedFenceTreatsRemainderAsCode() {
    let text = "intro\n```\nstreaming code"
    #expect(MarkdownSegment.parse(text) == [.prose("intro"), .code("streaming code")])
  }

  @Test func emptyProseSegmentsAreOmitted() {
    // Blank lines around a fence shouldn't yield empty prose segments.
    let text = "\n\n```\ncode\n```\n\n"
    #expect(MarkdownSegment.parse(text) == [.code("code")])
  }
}
