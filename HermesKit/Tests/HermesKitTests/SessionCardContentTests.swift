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

  @Test func messageCountTextIsPluralizedAndHiddenWhenUnknownOrZero() {
    #expect(SessionCardContent(session: Session(id: "s", messageCount: 1)).messageCountText == "1 message")
    #expect(SessionCardContent(session: Session(id: "s", messageCount: 12)).messageCountText == "12 messages")
    #expect(SessionCardContent(session: Session(id: "s", messageCount: 0)).messageCountText == nil)
    #expect(SessionCardContent(session: Session(id: "s")).messageCountText == nil)
  }

  @Test func footerRendersWhenEitherModelOrCountIsPresent() {
    #expect(SessionCardContent(session: Session(id: "s", model: "gpt-5")).hasFooter)
    #expect(SessionCardContent(session: Session(id: "s", messageCount: 3)).hasFooter)
    #expect(!SessionCardContent(session: Session(id: "s", messageCount: 0)).hasFooter)
  }

  // MARK: - Accessibility

  @Test func accessibilityLabelReadsInVisualOrderThenStatusAndPin() {
    let content = SessionCardContent(session: Session(
      id: "s", title: "Fix the build", preview: "it fails on CI", cwd: "/w/app",
      messageCount: 4, model: "gpt-5"
    ))
    #expect(
      content.accessibilityLabel(age: "2 hours ago", status: .working, isPinned: true)
        == "app, Fix the build, it fails on CI, gpt-5, 4 messages, 2 hours ago, Working, Pinned"
    )
  }

  @Test func accessibilityLabelSkipsAbsentParts() {
    let content = SessionCardContent(session: Session(id: "s", preview: "snippet"), showsWorkspace: false)
    #expect(content.accessibilityLabel(age: nil, status: .idle, isPinned: false) == "snippet")
  }

  // MARK: - Status dot

  @Test func statusResolvesNeedsInputOverWorkingOverUnread() {
    #expect(SessionStatus(needsInput: true, isWorking: true, isUnread: true) == .needsInput)
    #expect(SessionStatus(needsInput: false, isWorking: true, isUnread: true) == .working)
    #expect(SessionStatus(needsInput: false, isWorking: false, isUnread: true) == .unread)
    #expect(SessionStatus(needsInput: false, isWorking: false, isUnread: false) == .idle)
  }

  @Test func statusAccessibilityTextIsSilentWhenIdle() {
    #expect(SessionStatus.needsInput.accessibilityText == "Needs input")
    #expect(SessionStatus.unread.accessibilityText == "Unread")
    #expect(SessionStatus.idle.accessibilityText == nil)
  }
}
