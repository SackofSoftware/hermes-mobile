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
        // Search results are flat, with the matching snippet shown.
        ForEach(store.sessions) { session in
          row(session, showsPreview: true)
        }
      } else {
        // Group by workspace, desktop-style, with per-group "Show more".
        ForEach(store.groups) { group in
          groupSection(group)
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

  @ViewBuilder
  private func groupSection(_ group: SessionGroup) -> some View {
    let visible = store.state.visibleSessions(in: group)
    let hidden = group.sessions.count - visible.count
    let isExpanded = store.expandedGroups.contains(group.id)
    Section(group.label) {
      ForEach(visible) { session in
        row(session)
      }
      if hidden > 0 || isExpanded, group.sessions.count > SessionListFeature.State.collapsedLimit {
        Button(isExpanded ? "Show less" : "Show \(hidden) more") {
          store.send(.toggleGroupExpansion(groupID: group.id))
        }
        .font(.subheadline)
      }
    }
  }

  private func row(_ session: Session, showsPreview: Bool = false) -> some View {
    Button {
      store.send(.sessionTapped(session.id))
    } label: {
      SessionRowView(
        session: session,
        now: store.now,
        showsPreview: showsPreview,
        isUnread: store.unreadSessionIDs.contains(session.id)
      )
    }
    .buttonStyle(.plain)
  }
}
