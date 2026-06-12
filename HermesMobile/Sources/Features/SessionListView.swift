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
      ForEach(store.sessions) { session in
        Button {
          store.send(.sessionTapped(session.id))
        } label: {
          SessionRowView(session: session)
        }
        .buttonStyle(.plain)
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
      ToolbarItem(placement: .primaryAction) {
        Button("New", systemImage: "square.and.pencil") {
          store.send(.newSessionButtonTapped)
        }
      }
    }
    .task { store.send(.task) }
  }
}
