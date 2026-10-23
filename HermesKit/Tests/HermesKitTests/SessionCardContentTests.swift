import Testing

@testable import HermesKit

struct SessionCardContentTests {
  // MARK: - workspaceLabel

  @Test func workspaceLabelIsTheFolderBasename() {
    #expect(Session(id: "s", cwd: "/Users/me/proj").workspaceLabel == "proj")
    #expect(Session(id: "s", cwd: "/Users/me/proj/").workspaceLabel == "proj")
  }

  @Test func rootPathIsShownVerbatim() {
    #expect(Session(id: "s", cwd: "/").workspaceLabel == "/")
  }

  @Test func missingOrBlankCwdIsNoWorkspace() {
    #expect(Session(id: "s").workspaceLabel == "No workspace")
    #expect(Session(id: "s", cwd: "").workspaceLabel == "No workspace")
    #expect(Session(id: "s", cwd: "   ").workspaceLabel == "No workspace")
  }

  // MARK: - Content

  @Test func titledSessionShowsItsPreviewUnderTheTitle() {
    let content = SessionCardContent(
      session: Session(id: "s", title: "Fix the build", preview: "it fails on CI", cwd: "/w/app")
    )
    #expect(content.workspace == "app")
    #expect(content.title == "Fix the build")
    #expect(content.preview == "it fails on CI")
  }

  @Test func untitledSessionPromotesThePreviewAndDropsTheLine() {
    let content = SessionCardContent(
      session: Session(id: "s", title: "Untitled", preview: "it fails on CI")
    )
    #expect(content.title == "it fails on CI")
    #expect(content.preview == nil)
  }

  @Test func searchHitLeavesTheWorkspaceOutButKeepsTheSnippet() {
    // Search hits carry only id, snippet (as preview) and start time.
    let content = SessionCardContent(
      session: Session(id: "s", preview: "matched keyword"), showsWorkspace: false
    )
    #expect(content.workspace == nil)
    #expect(content.title == "matched keyword")
  }

  @Test func messageCountIsInflectedAndHiddenWhenUnknownOrZero() {
    #expect(SessionCardContent(session: Session(id: "s", messageCount: 1)).messageCount == "1 message")
    #expect(SessionCardContent(session: Session(id: "s", messageCount: 12)).messageCount == "12 messages")
    #expect(SessionCardContent(session: Session(id: "s", messageCount: 0)).messageCount == nil)
    #expect(SessionCardContent(session: Session(id: "s")).messageCount == nil)
  }

  @Test func footerRendersWhenEitherModelOrCountIsPresent() {
    #expect(SessionCardContent(session: Session(id: "s", model: "gpt-5")).hasFooter)
    #expect(SessionCardContent(session: Session(id: "s", messageCount: 3)).hasFooter)
    #expect(!SessionCardContent(session: Session(id: "s", messageCount: 0)).hasFooter)
  }

  // MARK: - Accessibility

  @Test func accessibilityLabelReadsInVisualOrderThenFlags() {
    let content = SessionCardContent(session: Session(
      id: "s", title: "Fix the build", preview: "it fails on CI", cwd: "/w/app",
      messageCount: 4, model: "gpt-5"
    ))
    #expect(
      content.accessibilityLabel(age: "2 hours ago", isUnread: true, isPinned: true, isActive: true)
        == "app, Fix the build, it fails on CI, gpt-5, 4 messages, 2 hours ago, Unread, Pinned, Working"
    )
  }

  @Test func accessibilityLabelSkipsAbsentParts() {
    let content = SessionCardContent(session: Session(id: "s", preview: "snippet"), showsWorkspace: false)
    #expect(
      content.accessibilityLabel(age: nil, isUnread: false, isPinned: false, isActive: false)
        == "snippet"
    )
  }
}
