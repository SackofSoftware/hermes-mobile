import ComposableArchitecture
import HermesKit
import SwiftUI

/// Onboarding screen: enter a server URL, check reachability, paste a token, connect.
struct ConnectionView: View {
  @Bindable var store: StoreOf<ConnectionFeature>

  var body: some View {
    Form {
      Section {
        TextField("http://host:9119", text: $store.serverURL)
          .keyboardType(.URL)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        Button("Check connection") { store.send(.checkServerTapped) }
          .disabled(!store.canCheck)
      } header: {
        Text("Server")
      } footer: {
        statusFooter
      }

      Section("Token") {
        SecureField("Session token", text: $store.token)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        Button("Connect") { store.send(.connectTapped) }
          .disabled(!store.canConnect)
      }
    }
  }

  @ViewBuilder
  private var statusFooter: some View {
    switch store.status {
    case .idle:
      EmptyView()
    case .checking:
      Label("Checking…", systemImage: "ellipsis.circle")
    case .invalidURL:
      Label("Enter a valid server URL.", systemImage: "exclamationmark.triangle")
        .foregroundStyle(.red)
    case .unreachable:
      Label("Couldn’t reach the server.", systemImage: "xmark.octagon")
        .foregroundStyle(.red)
    case .notHermes:
      Label("Reachable, but doesn’t look like Hermes.", systemImage: "questionmark.diamond")
        .foregroundStyle(.orange)
    case let .reachable(version):
      Label("Reachable — Hermes \(version ?? "?")", systemImage: "checkmark.circle")
        .foregroundStyle(.green)
    case .validating:
      Label("Validating token…", systemImage: "ellipsis.circle")
    case .invalidToken:
      Label("Invalid token.", systemImage: "xmark.octagon")
        .foregroundStyle(.red)
    case let .failed(message):
      Label(message, systemImage: "exclamationmark.triangle")
        .foregroundStyle(.red)
    }
  }
}

#Preview {
  ConnectionView(
    store: Store(initialState: ConnectionFeature.State()) {
      ConnectionFeature()
    }
  )
}
