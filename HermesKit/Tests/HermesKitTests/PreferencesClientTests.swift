import Foundation
import Testing

@testable import HermesKit

struct PreferencesClientTests {
  @Test func inMemoryRoundTripAndClear() {
    let prefs = PreferencesClient.inMemory()
    #expect(prefs.loadServerURL() == nil)

    prefs.saveServerURL("http://mac.tailnet:9119")
    #expect(prefs.loadServerURL() == "http://mac.tailnet:9119")

    prefs.clearServerURL()
    #expect(prefs.loadServerURL() == nil)
  }

  @Test func liveBacksOntoProvidedDefaults() {
    let suite = UserDefaults(suiteName: "hermes.prefs.test")!
    suite.removePersistentDomain(forName: "hermes.prefs.test")
    let prefs = PreferencesClient.live(defaults: suite)

    prefs.saveServerURL("http://example:9119")
    #expect(suite.string(forKey: "hermes.server-url") == "http://example:9119")
    #expect(prefs.loadServerURL() == "http://example:9119")

    prefs.clearServerURL()
    #expect(prefs.loadServerURL() == nil)
  }

  @Test func inMemoryPinnedIDsRoundTrip() {
    let prefs = PreferencesClient.inMemory()
    #expect(prefs.loadPinnedIDs() == [])

    prefs.savePinnedIDs(["s1", "s2"])
    #expect(prefs.loadPinnedIDs() == ["s1", "s2"]) // order preserved

    prefs.savePinnedIDs([])
    #expect(prefs.loadPinnedIDs() == [])
  }

  @Test func livePinnedIDsBacksOntoProvidedDefaults() {
    let suite = UserDefaults(suiteName: "hermes.prefs.test.pinned")!
    suite.removePersistentDomain(forName: "hermes.prefs.test.pinned")
    let prefs = PreferencesClient.live(defaults: suite)

    #expect(prefs.loadPinnedIDs() == [])
    prefs.savePinnedIDs(["a", "b"])
    #expect(suite.array(forKey: "hermes.pinned-session-ids") as? [String] == ["a", "b"])
    #expect(prefs.loadPinnedIDs() == ["a", "b"])
  }

  @Test func inMemoryDefaultSwipeActionRoundTripAndDefault() {
    let prefs = PreferencesClient.inMemory()
    #expect(prefs.loadDefaultSessionSwipeAction() == .archive) // default when unset

    prefs.saveDefaultSessionSwipeAction(.delete)
    #expect(prefs.loadDefaultSessionSwipeAction() == .delete)

    prefs.saveDefaultSessionSwipeAction(.archive)
    #expect(prefs.loadDefaultSessionSwipeAction() == .archive)
  }

  @Test func liveDefaultSwipeActionBacksOntoProvidedDefaults() {
    let suite = UserDefaults(suiteName: "hermes.prefs.test.swipe")!
    suite.removePersistentDomain(forName: "hermes.prefs.test.swipe")
    let prefs = PreferencesClient.live(defaults: suite)

    #expect(prefs.loadDefaultSessionSwipeAction() == .archive) // default when unset
    prefs.saveDefaultSessionSwipeAction(.delete)
    #expect(suite.string(forKey: "hermes.default-session-swipe-action") == "delete")
    #expect(prefs.loadDefaultSessionSwipeAction() == .delete)
  }

  @Test func liveDefaultSwipeActionDefaultsWhenValueIsGarbage() {
    let suite = UserDefaults(suiteName: "hermes.prefs.test.swipe.garbage")!
    suite.removePersistentDomain(forName: "hermes.prefs.test.swipe.garbage")
    suite.set("shred", forKey: "hermes.default-session-swipe-action")
    let prefs = PreferencesClient.live(defaults: suite)
    #expect(prefs.loadDefaultSessionSwipeAction() == .archive) // unknown raw value → default
  }

  @Test func inMemoryCronSectionCollapsedRoundTripAndDefault() {
    let prefs = PreferencesClient.inMemory()
    #expect(prefs.loadCronSectionCollapsed() == false) // default when unset: expanded

    prefs.saveCronSectionCollapsed(true)
    #expect(prefs.loadCronSectionCollapsed() == true)

    prefs.saveCronSectionCollapsed(false)
    #expect(prefs.loadCronSectionCollapsed() == false)
  }

  @Test func liveCronSectionCollapsedBacksOntoProvidedDefaults() {
    let suite = UserDefaults(suiteName: "hermes.prefs.test.croncollapsed")!
    suite.removePersistentDomain(forName: "hermes.prefs.test.croncollapsed")
    let prefs = PreferencesClient.live(defaults: suite)

    #expect(prefs.loadCronSectionCollapsed() == false) // default when unset: expanded
    prefs.saveCronSectionCollapsed(true)
    #expect(suite.bool(forKey: "hermes.cron-section-collapsed") == true)
    #expect(prefs.loadCronSectionCollapsed() == true)
  }

  @Test func liveClientDropsStaleShowCronSectionKey() {
    // A build that persisted the old hide pref leaves `hermes.show-cron-section` behind;
    // building the live client clears it and does NOT translate it — the section starts
    // expanded.
    let suite = UserDefaults(suiteName: "hermes.prefs.test.croncollapsed.legacy")!
    suite.removePersistentDomain(forName: "hermes.prefs.test.croncollapsed.legacy")
    suite.set(false, forKey: "hermes.show-cron-section")
    let prefs = PreferencesClient.live(defaults: suite)

    #expect(suite.object(forKey: "hermes.show-cron-section") == nil)
    #expect(prefs.loadCronSectionCollapsed() == false)
  }

  @Test func liveClientDropsStaleGroupingModeKey() {
    // The workspace/chronological grouping pref is retired (the list is always
    // date-sectioned); a build that persisted it leaves the key behind, and building the
    // live client clears it so an upgrade leaves no orphaned default.
    let suite = UserDefaults(suiteName: "hermes.prefs.test.grouping.legacy")!
    suite.removePersistentDomain(forName: "hermes.prefs.test.grouping.legacy")
    suite.set("chronological", forKey: "hermes.session-grouping-mode")
    suite.set(true, forKey: "hermes.cron-section-collapsed")
    let prefs = PreferencesClient.live(defaults: suite)

    #expect(suite.object(forKey: "hermes.session-grouping-mode") == nil)
    #expect(prefs.loadCronSectionCollapsed() == true) // the live pref is untouched
  }

  @Test func inMemorySelectedProfileRoundTripAndClear() {
    let prefs = PreferencesClient.inMemory()
    #expect(prefs.loadSelectedProfileID() == nil)

    prefs.saveSelectedProfileID("work")
    #expect(prefs.loadSelectedProfileID() == "work")

    prefs.clearSelectedProfileID()
    #expect(prefs.loadSelectedProfileID() == nil)
  }

  @Test func liveSelectedProfileBacksOntoProvidedDefaults() {
    let suite = UserDefaults(suiteName: "hermes.prefs.test.profile")!
    suite.removePersistentDomain(forName: "hermes.prefs.test.profile")
    let prefs = PreferencesClient.live(defaults: suite)

    #expect(prefs.loadSelectedProfileID() == nil)
    prefs.saveSelectedProfileID("work")
    #expect(suite.string(forKey: "hermes.selected-profile-id") == "work")
    #expect(prefs.loadSelectedProfileID() == "work")

    prefs.clearSelectedProfileID()
    #expect(suite.string(forKey: "hermes.selected-profile-id") == nil)
    #expect(prefs.loadSelectedProfileID() == nil)
  }

  // MARK: Push prompt snooze

  @Test func inMemoryPushPromptSnoozeRoundTripAndClear() {
    let prefs = PreferencesClient.inMemory()
    #expect(prefs.loadPushPromptSnooze() == nil) // never snoozed

    let until = Date(timeIntervalSince1970: 1_750_000_000)
    prefs.savePushPromptSnooze(3, until)
    let snooze = prefs.loadPushPromptSnooze()
    #expect(snooze?.count == 3)
    #expect(snooze?.until == until)

    prefs.clearPushPromptSnooze()
    #expect(prefs.loadPushPromptSnooze() == nil)
  }

  @Test func livePushPromptSnoozeBacksOntoProvidedDefaults() {
    let suite = UserDefaults(suiteName: "hermes.prefs.test.pushsnooze")!
    suite.removePersistentDomain(forName: "hermes.prefs.test.pushsnooze")
    let prefs = PreferencesClient.live(defaults: suite)

    #expect(prefs.loadPushPromptSnooze() == nil) // no `until` persisted yet
    let until = Date(timeIntervalSince1970: 1_750_000_000)
    prefs.savePushPromptSnooze(2, until)
    #expect(suite.integer(forKey: "hermes.push-prompt-snooze-count") == 2)
    let snooze = prefs.loadPushPromptSnooze()
    #expect(snooze?.count == 2)
    #expect(snooze?.until == until)

    prefs.clearPushPromptSnooze()
    #expect(prefs.loadPushPromptSnooze() == nil)
  }
}
