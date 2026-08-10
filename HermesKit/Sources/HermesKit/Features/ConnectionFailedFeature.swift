import ComposableArchitecture
import Foundation

/// Shown instead of onboarding when **launch auto-connect** fails for a purely *transport*
/// reason (`.offline` / `.unreachable`): the stored credentials are presumed fine — the phone
/// simply couldn't reach the server (VPN/Tailscale off, no internet, agent down). Dropping to
/// onboarding there would force a password-mode user to re-type credentials that never
/// expired, so this screen keeps the session and offers a Retry instead.
///
/// A genuine auth rejection never lands here — `AppFeature` routes those to onboarding as
/// before, and if a *retry* from this screen comes back with a non-transport error the
/// reducer bubbles `.credentialsRejected` so the user ends up in the same place.
///
/// The reducer is pure routing + the retry probe: clearing the keychain/prefs on
/// `.logoutTapped` lives in `AppFeature`, next to the other two full-logout recipes.
@Reducer
public struct ConnectionFailedFeature {
  @ObservableState
  public struct State: Equatable {
    /// The connection that failed to validate — retried verbatim, and its `baseURL` is what
    /// the screen names so the user can tell *which* server is unreachable.
    public var connection: ServerConnection
    /// Why the last attempt failed. Always a transport error (`.offline`/`.unreachable`);
    /// anything else routes away from this screen.
    public var reason: RESTError
    /// A probe is in flight — drives the spinner and guards against double-firing (a Retry
    /// tap racing the foreground auto-retry).
    public var isRetrying: Bool

    public init(connection: ServerConnection, reason: RESTError, isRetrying: Bool = false) {
      self.connection = connection
      self.reason = reason
      self.isRetrying = isRetrying
    }

    /// The server the app failed to reach, as typed by the user during onboarding.
    public var serverURLText: String { connection.baseURL.absoluteString }

    /// One-line explanation of the failure, split so "you're offline" doesn't send the user
    /// hunting for a dead server (and vice-versa).
    public var reasonText: String {
      switch reason {
      case .offline:
        "You appear to be offline. Check Wi‑Fi or cellular data and try again."
      default:
        "The server didn’t respond. If it’s on a private network (VPN/Tailscale), make sure that connection is on."
      }
    }
  }

  public enum Action: Equatable, Sendable {
    case retryTapped
    /// The app came back to the foreground — re-probe (the user very likely just turned the
    /// VPN back on, which is exactly the moment a manual tap is most annoying).
    case sceneBecameActive
    case logoutTapped
    case retryResult(Result<EmptySuccess, RESTError>)
    case delegate(Delegate)

    /// `Void` isn't `Equatable`; this is the success payload of a probe that only matters
    /// for having *not* thrown.
    public struct EmptySuccess: Equatable, Sendable {
      public init() {}
    }

    @CasePathable
    public enum Delegate: Equatable, Sendable {
      /// The stored credentials validated — `AppFeature` builds home exactly as it does for
      /// a successful launch auto-connect.
      case connected(ServerConnection)
      /// The retry reached the server and it rejected us (401 and friends) — retrying can't
      /// fix that, so fall back to onboarding for re-entry.
      case credentialsRejected(ServerConnection)
      /// Abandon the stored session — `AppFeature` runs the full-logout recipe.
      case logoutTapped
    }
  }

  @Dependency(\.hermesREST) var rest

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .retryTapped, .sceneBecameActive:
        // One probe at a time: a foreground while a manual retry is still in flight (or two
        // fast taps) must not fan out into parallel probes.
        guard !state.isRetrying else { return .none }
        state.isRetrying = true
        let connection = state.connection
        return .run { [rest] send in
          do {
            _ = try await rest.sessions(connection, 1, 0, .recent)
            await send(.retryResult(.success(.init())))
          } catch {
            await send(.retryResult(.failure(asRESTError(error))))
          }
        }

      case .retryResult(.success):
        state.isRetrying = false
        return .send(.delegate(.connected(state.connection)))

      case let .retryResult(.failure(error)):
        state.isRetrying = false
        switch error {
        case .offline, .unreachable:
          // Still a transport failure — stay put, but refresh the reason (offline ⇄
          // unreachable can flip between attempts).
          state.reason = error
          return .none
        default:
          // We reached the server and it turned us away — this screen can't help.
          return .send(.delegate(.credentialsRejected(state.connection)))
        }

      case .logoutTapped:
        return .send(.delegate(.logoutTapped))

      case .delegate:
        return .none
      }
    }
  }
}
