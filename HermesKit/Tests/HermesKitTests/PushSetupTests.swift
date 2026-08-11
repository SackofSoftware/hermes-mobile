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

  // The prompt has to work for someone who ALREADY has the plugin: `git clone` into an
  // existing non-empty directory fails outright, so the pull branch must be spelled out.
  @Test func installPromptCoversUpdatingAnExistingCheckout() {
    #expect(PushSetup.installPrompt.contains("git -C ~/.hermes/plugins/hermes-push pull"))
    // …and it must say why a restart is still needed after a pull, or the user updates the
    // files and keeps getting pushes from the code still loaded in the running process.
    #expect(PushSetup.installPrompt.uppercased().contains("RESTART"))
  }

  // MARK: Version comparison (drives the Settings update prompt)

  @Test func olderVersionIsDetectedAsOutdated() {
    #expect(PushSetup.isVersion("0.1.0", olderThan: "0.2.0"))
    #expect(PushSetup.isVersion("0.1.9", olderThan: "0.2.0"))
    #expect(PushSetup.isVersion("0.0.1", olderThan: "0.2.0"))
    // Multi-digit components compare numerically, not lexicographically ("10" > "9").
    #expect(PushSetup.isVersion("0.9.0", olderThan: "0.10.0"))
  }

  @Test func equalOrNewerVersionIsNotOutdated() {
    #expect(!PushSetup.isVersion("0.2.0", olderThan: "0.2.0"))
    #expect(!PushSetup.isVersion("0.2.1", olderThan: "0.2.0"))
    #expect(!PushSetup.isVersion("1.0.0", olderThan: "0.2.0"))
    #expect(!PushSetup.isVersion("0.10.0", olderThan: "0.9.0"))
  }

  // Shorter/longer forms pad with zeros, so "0.2" and "0.2.0" are the same version.
  @Test func versionComparisonPadsMissingComponents() {
    #expect(!PushSetup.isVersion("0.2", olderThan: "0.2.0"))
    #expect(!PushSetup.isVersion("0.2.0", olderThan: "0.2"))
    #expect(PushSetup.isVersion("0.1", olderThan: "0.2.0"))
    #expect(PushSetup.isVersion("0.2.0", olderThan: "0.2.1"))
  }

  // A leading `v` is tolerated — release tags commonly carry one.
  @Test func versionComparisonToleratesLeadingV() {
    #expect(PushSetup.isVersion("v0.1.0", olderThan: "0.2.0"))
    #expect(!PushSetup.isVersion("v0.2.0", olderThan: "0.2.0"))
  }

  // Anything unparseable stays SILENT (not outdated). A wrong `true` nags a current user with
  // an update that does nothing; a wrong `false` costs a prompt they can still reach from the
  // guide sheet. Missing/garbage versions therefore must never trigger the update row.
  @Test func unparseableVersionIsNeverOutdated() {
    #expect(!PushSetup.isVersion(nil, olderThan: "0.2.0"))
    #expect(!PushSetup.isVersion("", olderThan: "0.2.0"))
    #expect(!PushSetup.isVersion("   ", olderThan: "0.2.0"))
    #expect(!PushSetup.isVersion("unknown", olderThan: "0.2.0"))
    #expect(!PushSetup.isVersion("main", olderThan: "0.2.0"))
    #expect(!PushSetup.isVersion("0.1.0-rc1", olderThan: "0.2.0")) // pre-release unsupported
    #expect(!PushSetup.isVersion("0.-1.0", olderThan: "0.2.0"))
    #expect(!PushSetup.isVersion("0..1", olderThan: "0.2.0"))
  }

  // `PushPluginInfo.isOutdated` reads the shipped minimum, so it moves with the constant.
  @Test func pluginInfoOutdatedReflectsTheShippedMinimum() {
    #expect(PushPluginInfo(status: .ready, version: "0.1.0").isOutdated)
    #expect(!PushPluginInfo(status: .ready, version: PushSetup.minimumPluginVersion).isOutdated)
    #expect(!PushPluginInfo(status: .ready, version: nil).isOutdated)
    // An absent/unknown plugin carries no version, so it never reads as outdated.
    #expect(!PushPluginInfo(status: .unknown).isOutdated)
    #expect(!PushPluginInfo(status: .notReady).isOutdated)
  }
}
