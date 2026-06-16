import Foundation
import Testing

@testable import HermesKit

/// `Session.displayName` is the single fallback rule for the list rows, search, and the
/// chat header: a real title → first-message preview → raw id (last resort). A regular
/// session must never surface its bare id as a name (#13).
struct SessionDisplayNameTests {
  private func session(title: String? = nil, preview: String? = nil) -> Session {
    Session(id: "20260610_120231_afcca6", title: title, preview: preview)
  }

  @Test func prefersRealTitle() {
    let s = session(title: "Refactor the parser", preview: "first message")
    #expect(s.resolvedTitle == "Refactor the parser")
    #expect(s.displayName == "Refactor the parser")
  }

  @Test func untitledPlaceholderIsNotATitle() {
    // The server sends "Untitled" for auto-named/cron sessions before a real title exists.
    let s = session(title: "Untitled", preview: "Run the nightly backup")
    #expect(s.resolvedTitle == nil)
    #expect(s.displayName == "Run the nightly backup")
  }

  @Test func blankTitleIsNotATitle() {
    let s = session(title: "   ", preview: "Plan the iOS MVP")
    #expect(s.resolvedTitle == nil)
    #expect(s.displayName == "Plan the iOS MVP")
  }

  @Test func fallsBackToPreviewWhenNoTitle() {
    let s = session(title: nil, preview: "Can you help me refactor the parser?")
    #expect(s.displayName == "Can you help me refactor the parser?")
  }

  @Test func previewIsTrimmed() {
    let s = session(title: nil, preview: "  hello there  ")
    #expect(s.resolvedPreview == "hello there")
    #expect(s.displayName == "hello there")
  }

  @Test func idIsTheLastResort() {
    // No title and no (or blank) preview — only then does the raw id show.
    #expect(session(title: nil, preview: nil).displayName == "20260610_120231_afcca6")
    #expect(session(title: "Untitled", preview: "   ").displayName == "20260610_120231_afcca6")
  }
}
