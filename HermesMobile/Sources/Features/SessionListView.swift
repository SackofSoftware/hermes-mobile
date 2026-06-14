import ComposableArchitecture
import HermesKit
import SwiftUI

/// The session list: searchable, pull-to-refresh, "+" to start a new chat.
struct SessionListView: View {
  @Bindable var store: StoreOf<SessionListFeature>

  var body: some View {
    List {
      if let error = store.loadError {
        Label(error, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.red)
      }
      if store.isSearching {
        // Search results are flat (no workspace grouping).
        ForEach(store.sessions) { session in
          row(session)
        }
      } else {
        // Group by workspace, desktop-style.
        ForEach(store.groups) { group in
          Section(group.label) {
            ForEach(group.sessions) { session in
              row(session)
            }
          }
        }
      }
    }
    .overlay {
      if store.sessions.isEmpty, !store.isLoading, store.loadError == nil {
        ContentUnavailableView("No sessions", systemImage: "bubble.left.and.bubble.right")
      }
    }
    .navigationTitle("Sessions")
    .searchable(text: $store.searchQuery, prompt: "Search sessions")
    .refreshable { store.send(.pulledToRefresh) }
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button("Settings", systemImage: "gearshape") {
          store.send(.settingsButtonTapped)
        }
      }
      ToolbarItem(placement: .primaryAction) {
        Button("New", systemImage: "square.and.pencil") {
          store.send(.newSessionButtonTapped)
        }
      }
    }
    .task { store.send(.task) }
    .sheet(item: $store.scope(state: \.settings, action: \.settings)) { settingsStore in
      NavigationStack {
        SettingsView(store: settingsStore)
      }
    }
  }

  private func row(_ session: Session) -> some View {
    Button {
      store.send(.sessionTapped(session.id))
    } label: {
      SessionRowView(session: session, now: store.now)
    }
    .buttonStyle(.plain)
  }
}
