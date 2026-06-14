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
}
