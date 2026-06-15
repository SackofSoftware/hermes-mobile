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
        // (isPinned is derived inside `row` so pinned sessions in search show Unpin.)
      } else {
        // Pinned sessions float to the top, above the workspace groups.
        if !store.pinnedSessions.isEmpty {
          Section("Pinned") {
            ForEach(store.pinnedSessions) { session in
              row(session)
            }
          }
        }
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
    .onDisappear { store.send(.onDisappear) }
    .alert(
      "Rename session",
      isPresented: Binding(
        get: { store.renamingID != nil },
        set: { presented in if !presented { store.send(.cancelRename) } }
      )
    ) {
      TextField("Title", text: $store.renameDraft)
      Button("Save") { store.send(.confirmRename) }
      Button("Cancel", role: .cancel) { store.send(.cancelRename) }
    }
    .confirmationDialog($store.scope(state: \.confirmationDialog, action: \.confirmationDialog))
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
    // Derive pinned state from the store so every row (search, grouped, Pinned section)
    // reflects the true state — search rows used to default to unpinned and offered a
    // no-op "Pin" for already-pinned sessions.
    let isPinned = store.pinnedIDs.contains(session.id)
    return Button {
      store.send(.sessionTapped(session.id))
    } label: {
      SessionRowView(
        session: session,
        now: store.now,
        showsPreview: showsPreview,
        isUnread: store.unreadSessionIDs.contains(session.id),
        isPinned: isPinned,
        isActive: session.isActive == true
      )
    }
    .buttonStyle(.plain)
    .swipeActions(edge: .leading) {
      pinButton(session, isPinned: isPinned)
        .tint(.orange)
    }
    .swipeActions(edge: .trailing) {
      Button("Archive", systemImage: "archivebox", role: .destructive) {
        store.send(.archiveButtonTapped(id: session.id))
      }
      Button("Rename", systemImage: "pencil") {
        store.send(.renameButtonTapped(id: session.id))
      }
      .tint(.blue)
    }
    .contextMenu {
      pinButton(session, isPinned: isPinned)
      Button("Rename", systemImage: "pencil") {
        store.send(.renameButtonTapped(id: session.id))
      }
      Button("Archive", systemImage: "archivebox", role: .destructive) {
        store.send(.archiveButtonTapped(id: session.id))
      }
    }
  }

  @ViewBuilder
  private func pinButton(_ session: Session, isPinned: Bool) -> some View {
    // Animate the send so the row glides between its workspace group and the Pinned
    // section (and the section itself fades in/out) instead of jumping.
    if isPinned {
      Button("Unpin", systemImage: "pin.slash") {
        store.send(.unpinSession(id: session.id), animation: .snappy)
      }
    } else {
      Button("Pin", systemImage: "pin") {
        store.send(.pinSession(id: session.id), animation: .snappy)
      }
    }
  }
}
