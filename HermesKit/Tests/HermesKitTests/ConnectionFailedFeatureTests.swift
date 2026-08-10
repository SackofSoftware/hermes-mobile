import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

@MainActor
struct ConnectionFailedFeatureTests {
  private let url = URL(string: "http://mac.tailnet:9119")!

  private var connection: ServerConnection {
    ServerConnection(baseURL: url, token: "tok")
  }

  private func state(
    reason: RESTError = .unreachable, isRetrying: Bool = false
  ) -> ConnectionFailedFeature.State {
    ConnectionFailedFeature.State(connection: connection, reason: reason, isRetrying: isRetrying)
  }

  // MARK: - Display

  @Test func displayStringsNameTheServerAndTheReason() {
    let offline = state(reason: .offline)
    #expect(offline.serverURLText == "http://mac.tailnet:9119")
    #expect(offline.reasonText.contains("offline"))

    let unreachable = state(reason: .unreachable)
    #expect(unreachable.reasonText.contains("VPN/Tailscale"))
  }

  // MARK: - Retry

  @Test func retrySuccessDelegatesConnected() async {
    let store = TestStore(initialState: state()) {
      ConnectionFailedFeature()
    } withDependencies: {
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in [] }
    }

    await store.send(.retryTapped) { $0.isRetrying = true }
    await store.receive(\.retryResult.success) { $0.isRetrying = false }
    await store.receive(\.delegate, .connected(connection))
  }

  @Test func retryTransportFailureUpdatesReasonInPlace() async {
    let store = TestStore(initialState: state(reason: .unreachable)) {
      ConnectionFailedFeature()
    } withDependencies: {
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in throw RESTError.offline }
    }

    await store.send(.retryTapped) { $0.isRetrying = true }
    await store.receive(\.retryResult.failure) {
      $0.isRetrying = false
      $0.reason = .offline
    }
  }

  @Test func retryAuthRejectionDelegatesCredentialsRejected() async {
    let store = TestStore(initialState: state()) {
      ConnectionFailedFeature()
    } withDependencies: {
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in throw RESTError.unauthorized }
    }

    await store.send(.retryTapped) { $0.isRetrying = true }
    await store.receive(\.retryResult.failure) { $0.isRetrying = false }
    await store.receive(\.delegate, .credentialsRejected(connection))
  }

  @Test func retryNonRESTErrorIsTreatedAsUnreachable() async {
    struct Boom: Error {}
    let store = TestStore(initialState: state(reason: .offline)) {
      ConnectionFailedFeature()
    } withDependencies: {
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in throw Boom() }
    }

    await store.send(.retryTapped) { $0.isRetrying = true }
    await store.receive(\.retryResult.failure) {
      $0.isRetrying = false
      $0.reason = .unreachable
    }
  }

  // MARK: - Foreground auto-retry

  @Test func sceneBecameActiveRetries() async {
    let store = TestStore(initialState: state()) {
      ConnectionFailedFeature()
    } withDependencies: {
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in [] }
    }

    await store.send(.sceneBecameActive) { $0.isRetrying = true }
    await store.receive(\.retryResult.success) { $0.isRetrying = false }
    await store.receive(\.delegate, .connected(connection))
  }

  @Test func retryIsGuardedWhileOneIsInFlight() async {
    // Hold the probe open so the later sends genuinely land *mid-flight*.
    let (gate, release) = AsyncStream<Void>.makeStream()
    let probes = LockIsolated(0)
    let store = TestStore(initialState: state()) {
      ConnectionFailedFeature()
    } withDependencies: {
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in
        probes.withValue { $0 += 1 }
        for await _ in gate { break }
        return []
      }
    }

    await store.send(.retryTapped) { $0.isRetrying = true }
    // A foreground (or a second tap) landing mid-probe must change nothing and must not fan
    // out a parallel probe.
    await store.send(.sceneBecameActive)
    await store.send(.retryTapped)
    release.yield()
    release.finish()
    await store.receive(\.retryResult.success) { $0.isRetrying = false }
    await store.receive(\.delegate, .connected(connection))
    #expect(probes.value == 1)
  }

  // MARK: - Logout

  @Test func logoutTappedDelegatesUp() async {
    let store = TestStore(initialState: state()) {
      ConnectionFailedFeature()
    } withDependencies: {
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in [] }
    }

    await store.send(.logoutTapped)
    await store.receive(\.delegate, .logoutTapped)
  }
}
