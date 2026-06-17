import ComposableArchitecture
import Foundation

/// The Add-profile form (presented as a sheet from the session list). Mirrors the
/// desktop's create-profile dialog: a name (validated against `ProfileName`), a
/// "clone from default" toggle, and an optional SOUL.md body.
///
/// Creating is a two-call sequence (matching the desktop): `profiles.create` then, when
/// the SOUL.md text is non-blank, `profiles.updateSoul`. On success it emits
/// `.delegate(.created(name:))` so the parent can refresh and select the new profile; on
/// failure it surfaces the `RESTError.message` (a server 400 detail verbatim) in an
/// inline error banner.
@Reducer
public struct AddProfileFeature {
  @ObservableState
  public struct State: Equatable {
    public var connection: ServerConnection
    public var name: String
    public var cloneFromDefault: Bool
    public var soul: String
    public var isCreating: Bool
    public var errorBanner: String?

    /// Inline name validation: `nil` while the field is empty (so the form starts clean),
    /// otherwise `ProfileName.hint` when the typed name fails the profile-name pattern.
    public var nameError: String? {
      let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return nil }
      return ProfileName.isValid(trimmed) ? nil : ProfileName.hint
    }

    /// The Create button is enabled only for a non-empty, valid name that isn't already
    /// being created.
    public var canCreate: Bool {
      let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
      return !trimmed.isEmpty && ProfileName.isValid(trimmed) && !isCreating
    }

    public init(
      connection: ServerConnection,
      name: String = "",
      cloneFromDefault: Bool = true,
      soul: String = "",
      isCreating: Bool = false,
      errorBanner: String? = nil
    ) {
      self.connection = connection
      self.name = name
      self.cloneFromDefault = cloneFromDefault
      self.soul = soul
      self.isCreating = isCreating
      self.errorBanner = errorBanner
    }
  }

  public enum Action: BindableAction {
    case binding(BindingAction<State>)
    case createTapped
    /// Result of the create-then-soul sequence — the success payload is the new name.
    case createResponse(Result<String, RESTError>)
    case cancelTapped
    case delegate(Delegate)

    @CasePathable
    public enum Delegate {
      /// A profile was created — the parent refreshes the list and selects it.
      case created(name: String)
    }
  }

  @Dependency(\.hermesProfiles) var profiles

  public init() {}

  public var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .createTapped:
        guard state.canCreate else { return .none }
        state.isCreating = true
        state.errorBanner = nil
        let name = state.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let soul = state.soul.trimmingCharacters(in: .whitespacesAndNewlines)
        return .run { [profiles, connection = state.connection, cloneFromDefault = state.cloneFromDefault] send in
          do {
            try await profiles.create(connection, name, cloneFromDefault)
            if !soul.isEmpty {
              try await profiles.updateSoul(connection, name, soul)
            }
            await send(.createResponse(.success(name)))
          } catch let error as RESTError {
            await send(.createResponse(.failure(error)))
          } catch {
            await send(.createResponse(.failure(.unreachable)))
          }
        }

      case let .createResponse(.success(name)):
        state.isCreating = false
        return .send(.delegate(.created(name: name)))

      case let .createResponse(.failure(error)):
        state.isCreating = false
        state.errorBanner = error.message
        return .none

      case .cancelTapped:
        return .none

      case .delegate:
        return .none
      }
    }
  }
}
