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
      .code(text: "let x = 1\nprint(x)", language: nil),
      .prose("Done."),
    ])
  }

  @Test func languageHintOnFenceIsCaptured() {
    let text = "```swift\nlet x = 1\n```"
    #expect(MarkdownSegment.parse(text) == [.code(text: "let x = 1", language: "swift")])
  }

  @Test func unterminatedFenceTreatsRemainderAsCode() {
    let text = "intro\n```\nstreaming code"
    #expect(MarkdownSegment.parse(text) == [
      .prose("intro"),
      .code(text: "streaming code", language: nil),
    ])
  }

  @Test func emptyProseSegmentsAreOmitted() {
    // Blank lines around a fence shouldn't yield empty prose segments.
    let text = "\n\n```\ncode\n```\n\n"
    #expect(MarkdownSegment.parse(text) == [.code(text: "code", language: nil)])
  }

  @Test func multipleCodeBlocksKeepRawTextAndLanguages() {
    let text = """
    one
    ```bash
    echo hi
    ```
    two
    ```
    plain
    ```
    """
    #expect(MarkdownSegment.parse(text) == [
      .prose("one"),
      .code(text: "echo hi", language: "bash"),
      .prose("two"),
      .code(text: "plain", language: nil),
    ])
  }

  @Test func codeWhitespaceIsPreservedExactly() {
    // Indentation and blank lines inside a fence must round-trip for copy fidelity.
    let text = "```\n  indented\n\n    deeper\n```"
    #expect(MarkdownSegment.parse(text) == [
      .code(text: "  indented\n\n    deeper", language: nil),
    ])
  }
}
