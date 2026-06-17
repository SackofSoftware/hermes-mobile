import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

@MainActor
struct AddProfileFeatureTests {
  private let connection = ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "tok")

  @Test func invalidNameSetsNameErrorAndBlocksCreate() async {
    let store = TestStore(initialState: AddProfileFeature.State(connection: connection)) {
      AddProfileFeature()
    }
    store.exhaustivity = .off

    await store.send(.binding(.set(\.name, "testOS"))) {
      $0.name = "testOS"
    }
    #expect(store.state.nameError == ProfileName.hint)
    #expect(store.state.canCreate == false)
  }

  @Test func validNameEnablesCreate() async {
    let store = TestStore(initialState: AddProfileFeature.State(connection: connection)) {
      AddProfileFeature()
    }
    store.exhaustivity = .off

    await store.send(.binding(.set(\.name, "work"))) {
      $0.name = "work"
    }
    #expect(store.state.nameError == nil)
    #expect(store.state.canCreate == true)
  }

  @Test func emptyNameHasNoErrorButCannotCreate() {
    let state = AddProfileFeature.State(connection: connection)
    #expect(state.nameError == nil)
    #expect(state.canCreate == false)
  }

  @Test func createSuccessWithBlankSoulSkipsUpdateSoul() async {
    let createdName = LockIsolated<String?>(nil)
    let soulCalled = LockIsolated(false)
    var state = AddProfileFeature.State(connection: connection)
    state.name = "work"
    state.soul = "   " // blank after trimming

    let store = TestStore(initialState: state) {
      AddProfileFeature()
    } withDependencies: {
      $0.hermesProfiles.create = { @Sendable _, name, _ in createdName.setValue(name) }
      $0.hermesProfiles.updateSoul = { @Sendable _, _, _ in soulCalled.setValue(true) }
    }

    await store.send(.createTapped) {
      $0.isCreating = true
    }
    await store.receive(\.createResponse.success) {
      $0.isCreating = false
    }
    await store.receive(\.delegate.created)

    #expect(createdName.value == "work")
    #expect(soulCalled.value == false) // blank soul → no updateSoul call
  }

  @Test func createSuccessWithSoulCallsUpdateSoul() async {
    let soul = LockIsolated<(String, String)?>(nil)
    var state = AddProfileFeature.State(connection: connection)
    state.name = "work"
    state.soul = "You are helpful."

    let store = TestStore(initialState: state) {
      AddProfileFeature()
    } withDependencies: {
      $0.hermesProfiles.create = { @Sendable _, _, _ in }
      $0.hermesProfiles.updateSoul = { @Sendable _, name, content in soul.setValue((name, content)) }
    }

    await store.send(.createTapped) {
      $0.isCreating = true
    }
    await store.receive(\.createResponse.success) {
      $0.isCreating = false
    }
    await store.receive(\.delegate.created)

    #expect(soul.value?.0 == "work")
    #expect(soul.value?.1 == "You are helpful.")
  }

  @Test func createServer400SetsErrorBannerAndClearsCreating() async {
    var state = AddProfileFeature.State(connection: connection)
    state.name = "test"

    let store = TestStore(initialState: state) {
      AddProfileFeature()
    } withDependencies: {
      $0.hermesProfiles.create = { @Sendable _, _, _ in throw RESTError.server(status: 400) }
    }

    await store.send(.createTapped) {
      $0.isCreating = true
    }
    await store.receive(\.createResponse.failure) {
      $0.isCreating = false
      $0.errorBanner = RESTError.server(status: 400).message
    }
  }
}
