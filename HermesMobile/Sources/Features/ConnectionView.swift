import ComposableArchitecture
import HermesKit
import SwiftUI

/// Onboarding screen: type a server URL (validated automatically), pick an auth method
/// (Password / Token, gated by the server's advertised capability), then connect.
struct ConnectionView: View {
  @Bindable var store: StoreOf<ConnectionFeature>
  @FocusState private var urlFocused: Bool

  var body: some View {
    Form {
      Section {
        TextField("http://host:9119", text: $store.serverURL)
          .keyboardType(.URL)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .focused($urlFocused)
          .submitLabel(.go)
          .onSubmit { store.send(.serverFieldCommitted) }
          .onChange(of: urlFocused) { _, focused in
            if !focused { store.send(.serverFieldCommitted) } // check on focus-loss
          }
      } header: {
        Text("Server")
      } footer: {
        statusFooter
      }

      Section {
        Picker("Auth method", selection: $store.method) {
          Text("Password")
            .tag(AuthMethod.password)
          Text("Token")
            .tag(AuthMethod.token)
        }
        .pickerStyle(.segmented)
        .disabled(!store.isPasswordEnabled && store.method == .token)

        switch store.method {
        case .password:
          TextField("Username", text: $store.username)
            .textContentType(.username)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          SecureField("Password", text: $store.password)
            .textContentType(.password)
        case .token:
          SecureField("Session token", text: $store.token)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          tokenDisclaimer
        }

        Button("Connect") { store.send(.connectTapped) }
          .disabled(!store.canConnect)
      } header: {
        Text("Sign in")
      } footer: {
        methodHint
      }
    }
  }

  /// Always-visible honesty note under the token field: what a token grants, where it's
  /// safe, and a push to the details screen. Static copy + one nav link (no logic).
  @ViewBuilder
  private var tokenDisclaimer: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label {
        Text("Never expires · private network only · full access")
      } icon: {
        Image(systemName: "exclamationmark.shield")
          .foregroundStyle(.orange)
      }
      .font(.footnote)

      NavigationLink {
        SecureConnectionInfoView(passwordAvailable: store.isPasswordEnabled)
      } label: {
        Text("Learn how to connect securely")
          .font(.footnote)
      }
    }
    .padding(.vertical, 2)
  }

  /// Capability-driven hint under the auth section.
  @ViewBuilder
  private var methodHint: some View {
    if !store.isPasswordEnabled, store.method == .token, store.capability != nil {
      // Token-only server: Password is disabled — explain why.
      Text("This server only supports token sign-in.")
        .foregroundStyle(.secondary)
    } else if store.isTokenDeemphasized, store.method == .token {
      // Gated server: token is a poor fit — nudge toward password.
      Text("This server uses password login. Token sign-in is for private-network setups only.")
        .foregroundStyle(.secondary)
    } else {
      EmptyView()
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
      Label("Signing in…", systemImage: "ellipsis.circle")
    case .invalidToken:
      Label("Invalid token.", systemImage: "xmark.octagon")
        .foregroundStyle(.red)
    case .invalidCredentials:
      Label("Invalid username or password.", systemImage: "xmark.octagon")
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
