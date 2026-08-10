import ComposableArchitecture
import Foundation

/// Onboarding: a staged, capability-aware connection flow.
/// 1. Check the server URL is reachable (`GET /api/status`, unauthenticated) —
///    distinguishing unreachable from "reachable but not Hermes" — and probe its auth
///    capability (`/api/auth/providers` on a gated server) to preselect the segment.
/// 2. Authenticate in the chosen regime:
///    - **token** — validate the pasted token with one authenticated call
///      (`GET /api/sessions?limit=1`).
///    - **password** — `POST /auth/password-login` for a cookie session, then validate the
///      cookies with the same authenticated call.
/// 3. Persist the resulting `AuthSession` (token or cookie) in the Keychain and signal
///    `.delegate(.connected)`.

/// Which auth regime the user is entering credentials for. Driven by the server's
/// capability probe (see `ServerAuthCapability`) but ultimately the user's segment choice.
public enum AuthMethod: String, Equatable, Sendable {
  case password
  case token
}

@Reducer
public struct ConnectionFeature {
  @ObservableState
  public struct State: Equatable {
    public var serverURL: String
    public var token: String
    public var username: String
    public var password: String
    /// The user's selected auth segment. Preselected from the capability probe; the user
    /// may still switch to whichever segment is enabled.
    public var method: AuthMethod
    /// The server's advertised auth capability (probed alongside `/api/status`). `nil` until
    /// the reachability check completes. Drives segment enable/preselect.
    public var capability: ServerAuthCapability?
    public var status: Status
    /// A launch **retry screen is set aside behind this one**: the user reached onboarding via
    /// `ConnectionFailedView`'s *Change server*, which deletes nothing — the keychain session
    /// and the stored URL both survive. Shows the way back (`returnToConnectionFailedTapped`),
    /// so an exploratory tap isn't a one-way door: without it a password-mode user lands on a
    /// prefilled URL with an empty password field, the retry screen is gone, and the
    /// once-per-process launch probe won't run again — re-creating issue #62's exact symptom
    /// (re-type a password that never expired) from one tap, force-quit the only escape.
    ///
    /// Set by `AppFeature` alongside the stash it restores; false everywhere else (a plain
    /// logout, a credentials rejection, first launch), so the affordance appears **only** when
    /// there is genuinely something to go back to.
    public var canReturnToConnectionFailed: Bool

    public init(
      serverURL: String = "",
      token: String = "",
      username: String = "",
      password: String = "",
      method: AuthMethod = .token,
      capability: ServerAuthCapability? = nil,
      status: Status = .idle,
      canReturnToConnectionFailed: Bool = false
    ) {
      self.serverURL = serverURL
      self.token = token
      self.username = username
      self.password = password
      self.method = method
      self.capability = capability
      self.status = status
      self.canReturnToConnectionFailed = canReturnToConnectionFailed
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
      case invalidCredentials
      case failed(String)
    }

    /// Whether the Password segment may be selected. The probe says password is available;
    /// before the probe completes we optimistically allow it (`?? true` — capability gating
    /// must not be stricter than reality on unknowns).
    public var isPasswordEnabled: Bool {
      switch capability {
      case .passwordAvailable: return true
      case .tokenOnly, .oauthOnly: return false
      case nil: return true
      }
    }

    /// Whether the Token segment may be selected. Always available — token mode is the
    /// universal fallback — but de-emphasized when the server is gated (password preferred).
    public var isTokenEnabled: Bool { true }

    /// True on a gated server where the token path is a poor fit (UI may de-emphasize it).
    public var isTokenDeemphasized: Bool {
      switch capability {
      case .passwordAvailable, .oauthOnly: return true
      case .tokenOnly, nil: return false
      }
    }

    public var canConnect: Bool {
      guard status != .validating else { return false }
      switch status {
      case .reachable, .invalidToken, .invalidCredentials: break // allow a retry
      default: return false
      }
      switch method {
      case .password: return !username.isEmpty && !password.isEmpty
      case .token: return !token.isEmpty
      }
    }
  }

  public enum Action: BindableAction {
    case binding(BindingAction<State>)
    /// The screen appeared — auto-check a pre-filled URL (#38).
    case onAppear
    /// Reachability check (debounced after typing, or fired on submit/focus-loss).
    case checkServer
    /// The URL field was submitted or lost focus — check immediately.
    case serverFieldCommitted
    case connectTapped
    /// "Back to the connection screen" — only offered while `canReturnToConnectionFailed` is
    /// set. Pure routing: nothing typed here is validated or persisted, the parent just puts
    /// the stashed retry screen back.
    case returnToConnectionFailedTapped
    /// Abandon everything this screen has in flight — the URL debounce, the reachability
    /// probe, and (the one that matters) the connect/login round-trip — and drop back to
    /// `.idle`.
    ///
    /// Sent by `AppFeature` when onboarding leaves the screen without connecting: the stashed
    /// retry screen is handed back, or the user logs out. `ConnectionFeature` is a permanently
    /// scoped `Scope`, **not** an `ifLet` child, so nothing cancels its effects implicitly —
    /// a login that resolves after the user left would persist the credentials it was
    /// validating and delegate `.connected`, navigating home over the screen they came back to
    /// (or resurrecting the session they just abandoned). Only the parent knows the screen is
    /// gone, and only this screen owns the cancel ids, so it takes an action to say so.
    case cancelInFlightRequests
    /// `/api/status` result plus the (optional) `/api/auth/providers` probe, folded so the
    /// capability is computed in one place.
    case serverStatusResponse(Result<ServerStatus, RESTError>, providers: [AuthProvider]?)
    case tokenValidationResponse(Result<ServerConnection, RESTError>)
    /// Password login → cookie session validated → ready to persist + connect.
    case passwordLoginResponse(Result<ServerConnection, RESTError>)
    case delegate(Delegate)

    @CasePathable
    public enum Delegate {
      case connected(ServerConnection)
      /// Put the launch retry screen back (the user took *Change server* and changed their
      /// mind). `AppFeature` owns the stash — this only asks.
      case returnToConnectionFailedRequested
    }
  }

  private enum CancelID { case urlDebounce, statusCheck, connect }

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

      case .onAppear:
        // A pre-filled URL (launch auto-connect fallback / logout) is validated immediately
        // so the sign-in step unlocks without the user having to focus the field first (#38).
        // Reuses the field-driven check path — no duplicated validation logic. Only fires
        // from a pristine `.idle` so a re-appear (e.g. popping back from the secure-connect
        // details screen) never clobbers a completed or in-flight check.
        guard state.status == .idle,
              !state.serverURL.trimmingCharacters(in: .whitespaces).isEmpty
        else { return .none }
        return .send(.checkServer)

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
            // Only a gated server has providers worth probing; token-only servers (and
            // older builds) skip the extra round-trip and keep today's exact behaviour.
            // A providers failure (404/transport) is swallowed → treated as no providers.
            var providers: [AuthProvider]?
            if status.authRequired == true {
              providers = (try? await rest.authProviders(url)) ?? nil
            }
            await send(.serverStatusResponse(.success(status), providers: providers))
          } catch {
            await send(.serverStatusResponse(.failure(asRESTError(error)), providers: nil))
          }
        }
        .cancellable(id: CancelID.statusCheck, cancelInFlight: true)

      case let .serverStatusResponse(.success(status), providers):
        let capability = ServerAuthCapability(from: status, providers: providers)
        state.capability = capability
        state.status = .reachable(version: status.version)
        // Preselect the segment the server actually supports: password when available,
        // token otherwise. Don't override a token-only server's disabled Password.
        switch capability {
        case .passwordAvailable: state.method = .password
        case .tokenOnly, .oauthOnly: state.method = .token
        }
        return .none

      case let .serverStatusResponse(.failure(error), _):
        state.capability = nil
        switch error {
        case .decoding: state.status = .notHermes
        // `.offline` is a transport failure like `.unreachable` — same footer (the
        // "trouble connecting to your agent?" help link is exactly what's wanted here too).
        case .offline, .unreachable: state.status = .unreachable
        default: state.status = .failed(error.message)
        }
        return .none

      case .cancelInFlightRequests:
        // Drop the spinner too: the status this screen was left in describes a request that no
        // longer exists, and a latched `.checking`/`.validating` would come back with it.
        if state.status == .checking || state.status == .validating { state.status = .idle }
        return .merge(
          .cancel(id: CancelID.urlDebounce),
          .cancel(id: CancelID.statusCheck),
          .cancel(id: CancelID.connect)
        )

      case .returnToConnectionFailedTapped:
        // Nothing to undo locally — this screen persists only on a successful connect, so a
        // half-typed URL/password simply goes away with the state the parent rebuilds.
        return .send(.delegate(.returnToConnectionFailedRequested))

      case .connectTapped:
        guard let url = parseServerURL(state.serverURL) else {
          state.status = .invalidURL
          return .none
        }
        state.status = .validating
        switch state.method {
        case .token:
          // Token path — byte-identical to today: validate with one authenticated call,
          // then persist the token + server URL and signal the parent.
          let connection = ServerConnection(baseURL: url, token: state.token)
          return .run { [rest, keychain, preferences] send in
            do {
              _ = try await rest.sessions(connection, 1, 0, .recent)
            } catch {
              await send(.tokenValidationResponse(.failure(asRESTError(error))))
              return
            }
            // The user may have left the screen while this was in flight
            // (`.cancelInFlightRequests`). `Send` already swallows the delegate on a cancelled
            // task, but the persistence below runs BEFORE it — writing a session and a server
            // URL the user abandoned (possibly one they just logged out of).
            guard !Task.isCancelled else { return }
            try? keychain.saveSession(.token(connection.token ?? ""))
            preferences.saveServerURL(connection.baseURL.absoluteString)
            await send(.tokenValidationResponse(.success(connection)))
          }
          .cancellable(id: CancelID.connect, cancelInFlight: true)

        case .password:
          // Password path: log in for cookies, validate them with one authenticated call,
          // then persist the cookie session + server URL and signal the parent.
          let provider = state.capability?.passwordProvider ?? "basic"
          let username = state.username
          let password = state.password
          return .run { [rest, keychain, preferences] send in
            let cookieSession: CookieSession
            do {
              cookieSession = try await rest.passwordLogin(url, provider, username, password)
            } catch {
              await send(.passwordLoginResponse(.failure(asRESTError(error))))
              return
            }
            // Abandoned mid-login (`.cancelInFlightRequests`)? Then don't touch the shared
            // cookie jar at all: activation FLUSHES it, and the session the user went back to
            // authenticates out of that same jar.
            guard !Task.isCancelled else { return }
            // Activate the captured cookies into the shared jar BEFORE the validating call —
            // otherwise the live REST transport reads an empty `.shared` and 401s.
            keychain.activateCookieSession(cookieSession)
            let connection = ServerConnection(baseURL: url, auth: .cookie(cookieSession))
            do {
              _ = try await rest.sessions(connection, 1, 0, .recent)
            } catch {
              await send(.passwordLoginResponse(.failure(asRESTError(error))))
              return
            }
            guard !Task.isCancelled else { return } // see the token path
            try? keychain.saveSession(.cookie(cookieSession))
            preferences.saveServerURL(connection.baseURL.absoluteString)
            await send(.passwordLoginResponse(.success(connection)))
          }
          .cancellable(id: CancelID.connect, cancelInFlight: true)
        }

      case let .tokenValidationResponse(.success(connection)):
        return .send(.delegate(.connected(connection)))

      case let .tokenValidationResponse(.failure(error)):
        switch error {
        case .unauthorized: state.status = .invalidToken
        default: state.status = .failed(error.message)
        }
        return .none

      case let .passwordLoginResponse(.success(connection)):
        return .send(.delegate(.connected(connection)))

      case let .passwordLoginResponse(.failure(error)):
        switch error {
        // 401 from login (bad creds) or from the validating call (cookies rejected).
        case .unauthorized: state.status = .invalidCredentials
        // Surface server copy verbatim for the rest (429 rate-limit, 503 unreachable,
        // 404 unsupported provider, other) via `RESTError.message`.
        default: state.status = .failed(error.message)
        }
        return .none

      case .delegate:
        return .none
      }
    }
  }
}

/// Normalize a thrown error from a REST call to a `RESTError` — the shared funnel every
/// reducer (`ConnectionFeature`, `ReauthFeature`, `ConnectionFailedFeature`, `AppFeature`)
/// uses after a `rest.*` call: a typed `RESTError` passes through verbatim, and anything else
/// goes through `RESTError.init(transport:)`, the SAME classifier `HermesRESTClient`'s own
/// transport catches use. Routing raw errors through that init (rather than a blanket
/// `.unreachable`) is what keeps the offline-vs-unreachable split intact for any client
/// implementation that surfaces a bare `URLError` — a wrapper, a future non-`URLSession`
/// transport, a test double — instead of it working only when the live client classified first.
func asRESTError(_ error: any Error) -> RESTError {
  error as? RESTError ?? RESTError(transport: error)
}

/// Lenient URL parsing: accept `host:port` by defaulting to `http://`.
func parseServerURL(_ string: String) -> URL? {
  let trimmed = string.trimmingCharacters(in: .whitespaces)
  guard !trimmed.isEmpty else { return nil }
  let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
  guard let url = URL(string: withScheme), url.host?.isEmpty == false else { return nil }
  return url
}
