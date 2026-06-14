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
}
