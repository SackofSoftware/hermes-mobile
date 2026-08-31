import Foundation
import IdentifiedCollections
import Testing
@testable import HermesKit

@Suite struct ToolDisplayTests {
  @Test func mapsKnownToolsToPlainEnglish() {
    #expect(ToolDisplay.forTool("terminal").verb == "Ran a command")
    #expect(ToolDisplay.forTool("browser_navigate").verb == "Opened a page")
    #expect(ToolDisplay.forTool("session_search").verb == "Searched past chats")
    #expect(ToolDisplay.forTool("skill_view").verb == "Opened a skill")
    #expect(ToolDisplay.forTool("search_files").verb == "Searched files")
  }

  @Test func stripsMCPNamespace() {
    #expect(ToolDisplay.forTool("mcp__somebody__read_file").verb == "Read a file")
  }

  @Test func unknownToolsAreHumanizedNotRaw() {
    // Never show a bare identifier: worst case it reads as a sentence.
    #expect(ToolDisplay.forTool("some_new_tool").verb == "Some new tool")
  }

  @Test func familyFallbackCatchesUnlistedVariants() {
    #expect(ToolDisplay.forTool("browser_scroll").symbol == "globe")
    #expect(ToolDisplay.forTool("grep_search").verb == "Searched")
  }

  @Test func headlineCombinesVerbAndObject() {
    #expect(ToolDisplay.headline(name: "browser_navigate", title: "example.com/menu")
      == "Opened a page · example.com/menu")
  }

  @Test func headlineDropsUninformativeObjects() {
    // The reducer falls back to title == name; repeating it helps nobody.
    #expect(ToolDisplay.headline(name: "terminal", title: "terminal") == "Ran a command")
    // A bare wildcard was a real row in the transcript screenshots.
    #expect(ToolDisplay.headline(name: "search_files", title: "*") == "Searched files")
    #expect(ToolDisplay.headline(name: "terminal", title: "") == "Ran a command")
    #expect(ToolDisplay.headline(name: "terminal", title: nil) == "Ran a command")
  }

  @Test func longObjectsKeepTheirTail() {
    // A URL or path is identifiable at the END, so trimming happens at the front.
    let long = String(repeating: "a", count: 40) + "/the-important-bit"
    let out = ToolDisplay.shorten(long, limit: 20)
    #expect(out.hasSuffix("the-important-bit"))
    #expect(out.hasPrefix("…"))
  }
}

@Suite struct ProfilePillVisibilityTests {
  private func state(profiles: [String], selected: String?, supported: Bool = true)
    -> SessionListFeature.State
  {
    var s = SessionListFeature.State(
      connection: ServerConnection(baseURL: URL(string: "http://x")!, auth: .token("t")),
      profilesSupported: supported
    )
    s.profiles = IdentifiedArray(uniqueElements: profiles.map { Profile(name: $0) })
    if let selected { s.selectedProfileName = selected }
    return s
  }

  @Test func hiddenWhenOnlyTheDefaultProfileExists() {
    // The case that prompted this: a switcher with one destination is pure chrome.
    #expect(state(profiles: ["default"], selected: "default").showsProfilePill == false)
    #expect(state(profiles: ["default"], selected: nil).showsProfilePill == false)
  }

  @Test func shownOnceThereIsSomewhereToSwitchTo() {
    #expect(state(profiles: ["default", "work"], selected: "default").showsProfilePill)
  }

  @Test func shownWhenAScopedProfileIsSelectedEvenIfAlone() {
    // A scoped list must always say which profile it's showing.
    #expect(state(profiles: ["work"], selected: "work").showsProfilePill)
  }

  @Test func hiddenWhenTheAgentHasNoProfilesAPI() {
    #expect(state(profiles: ["default", "work"], selected: "default", supported: false)
      .showsProfilePill == false)
  }
}
