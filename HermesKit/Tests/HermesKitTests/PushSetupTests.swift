import Foundation
import Testing

@testable import HermesKit

struct PushSetupTests {
  // The Fibonacci backoff schedule (1-indexed by the Later count), capped at ~60 days.
  @Test func snoozeDaysFollowFibonacciSequenceAndCap() {
    #expect(pushPromptSnoozeDays(laterCount: 1) == 1)
    #expect(pushPromptSnoozeDays(laterCount: 2) == 2)
    #expect(pushPromptSnoozeDays(laterCount: 3) == 3)
    #expect(pushPromptSnoozeDays(laterCount: 4) == 5)
    #expect(pushPromptSnoozeDays(laterCount: 5) == 8)
    #expect(pushPromptSnoozeDays(laterCount: 6) == 13)
    #expect(pushPromptSnoozeDays(laterCount: 7) == 21)
    #expect(pushPromptSnoozeDays(laterCount: 8) == 34)
    #expect(pushPromptSnoozeDays(laterCount: 9) == 55)
    // 10+ caps at ~60.
    #expect(pushPromptSnoozeDays(laterCount: 10) == 60)
    #expect(pushPromptSnoozeDays(laterCount: 11) == 60)
    #expect(pushPromptSnoozeDays(laterCount: 50) == 60)
  }

  // A non-positive count is treated as the first snooze (1 day) — defensive, never negative.
  @Test func snoozeDaysClampsNonPositiveCountToFirst() {
    #expect(pushPromptSnoozeDays(laterCount: 0) == 1)
    #expect(pushPromptSnoozeDays(laterCount: -5) == 1)
  }

  // The install prompt asks the agent to install the plugin as a DIRECTORY plugin (clone into
  // ~/.hermes/plugins/) and enable it — a plain pip install won't mount the registration route.
  @Test func installPromptDescribesDirectoryInstall() {
    #expect(PushSetup.installPrompt.contains("git clone"))
    #expect(PushSetup.installPrompt.contains("~/.hermes/plugins/hermes-push"))
    #expect(PushSetup.installPrompt.contains("plugins.enabled") || PushSetup.installPrompt.contains("plugins enable"))
    #expect(PushSetup.installPrompt.contains("hermes-push"))
  }
}
