import ComposableArchitecture
import Foundation

/// Onboarding: a staged connection flow.
/// 1. Check the server URL is reachable (`GET /api/status`, unauthenticated) —
///    distinguishing unreachable from "reachable but not Hermes".
/// 2. Validate the pasted token with one authenticated call (`GET /api/sessions?limit=1`).
/// 3. Persist the token in the Keychain and signal `.delegate(.connected)`.
@Reducer
public struct ConnectionFeature {
  @ObservableState
  public struct State: Equatable {
    public var serverURL: String
    public var token: String
    public var status: Status

    public init(serverURL: String = "", token: String = "", status: Status = .idle) {
      self.serverURL = serverURL
      self.token = token
      self.status = status
    }

    public enum Status: Equatable, Sendable {
      case idle
      case checking
      case invalidURL
      case unreachable
      case notHermes
      case reachable(version: String?)
      case validating
      case invalidToken
      case failed(String)
    }

    public var canConnect: Bool {
      guard !token.isEmpty, status != .validating else { return false }
      switch status {
      case .reachable, .invalidToken: return true // .invalidToken allows a retry
      default: return false
      }
    }
  }

  public enum Action: BindableAction {
    case binding(BindingAction<State>)
    /// Reachability check (debounced after typing, or fired on submit/focus-loss).
    case checkServer
    /// The URL field was submitted or lost focus — check immediately.
    case serverFieldCommitted
    case connectTapped
    case serverStatusResponse(Result<ServerStatus, RESTError>)
    case tokenValidationResponse(Result<ServerConnection, RESTError>)
    case delegate(Delegate)

    @CasePathable
    public enum Delegate {
      case connected(ServerConnection)
    }
  }

  private enum CancelID { case urlDebounce, statusCheck }

  @Dependency(\.hermesREST) var rest
  @Dependency(\.keychain) var keychain
  @Dependency(\.preferences) var preferences
  @Dependency(\.continuousClock) var clock

  public init() {}

  public var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding(\.serverURL):
        state.status = .idle // a new URL invalidates any prior reachability result
        guard !state.serverURL.trimmingCharacters(in: .whitespaces).isEmpty else {
          return .cancel(id: CancelID.urlDebounce)
        }
        // Auto-check after the user stops typing (covers paste too).
        return .run { [clock] send in
          try await clock.sleep(for: .milliseconds(600))
          await send(.checkServer)
        }
        .cancellable(id: CancelID.urlDebounce, cancelInFlight: true)

      case .binding:
        return .none

      case .serverFieldCommitted:
        // Submit / focus-loss → check now, pre-empting the debounce.
        return .merge(.cancel(id: CancelID.urlDebounce), .send(.checkServer))

      case .checkServer:
        guard let url = parseServerURL(state.serverURL) else {
          state.status = .invalidURL
          return .none
        }
        state.status = .checking
        return .run { [rest] send in
          do {
            let status = try await rest.status(url)
            await send(.serverStatusResponse(.success(status)))
          } catch let error as RESTError {
            await send(.serverStatusResponse(.failure(error)))
          } catch {
            await send(.serverStatusResponse(.failure(.unreachable)))
          }
        }
        .cancellable(id: CancelID.statusCheck, cancelInFlight: true)

      case let .serverStatusResponse(.success(status)):
        state.status = .reachable(version: status.version)
        return .none

      case let .serverStatusResponse(.failure(error)):
        switch error {
        case .decoding: state.status = .notHermes
        case .unreachable: state.status = .unreachable
        default: state.status = .failed(error.message)
        }
        return .none

      case .connectTapped:
        guard let url = parseServerURL(state.serverURL) else {
          state.status = .invalidURL
          return .none
        }
        let connection = ServerConnection(baseURL: url, token: state.token)
        state.status = .validating
        return .run { [rest, keychain, preferences] send in
          do {
            _ = try await rest.sessions(connection, 1, 0, .recent)
          } catch let error as RESTError {
            await send(.tokenValidationResponse(.failure(error)))
            return
          } catch {
            await send(.tokenValidationResponse(.failure(.unreachable)))
            return
          }
          // Validated: persist the token + server URL (for launch auto-connect),
          // then signal the parent.
          try? keychain.saveToken(connection.token ?? "")
          preferences.saveServerURL(connection.baseURL.absoluteString)
          await send(.tokenValidationResponse(.success(connection)))
        }

      case let .tokenValidationResponse(.success(connection)):
        return .send(.delegate(.connected(connection)))

      case let .tokenValidationResponse(.failure(error)):
        switch error {
        case .unauthorized: state.status = .invalidToken
        default: state.status = .failed(error.message)
        }
        return .none

      case .delegate:
        return .none
      }
    }
  }
}

/// Lenient URL parsing: accept `host:port` by defaulting to `http://`.
func parseServerURL(_ string: String) -> URL? {
  let trimmed = string.trimmingCharacters(in: .whitespaces)
  guard !trimmed.isEmpty else { return nil }
  let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
  guard let url = URL(string: withScheme), url.host?.isEmpty == false else { return nil }
  return url
}
