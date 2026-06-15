import ComposableArchitecture
import HermesKit
import SwiftUI

/// The session list: a flat (Codex-style) list, searchable, pull-to-refresh. Grouping
/// (by workspace / chronological) is chosen from the top-trailing menu, which also opens
/// the Archived sessions sheet. "New chat" lives in the bottom bar (alongside the iOS 26
/// bottom search field).
struct SessionListView: View {
  @Bindable var store: StoreOf<SessionListFeature>

  var body: some View {
    List {
      if let error = store.loadError {
        Label(error, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.red)
          .listRowSeparator(.hidden)
      }
      if store.isSearching {
        // Search results are flat, with the matching snippet shown.
        ForEach(store.sessions) { session in
          row(session, showsPreview: true)
        }
      } else {
        // Pinned sessions float to the top in both grouping modes.
        if !store.pinnedSessions.isEmpty {
          Section("Pinned") {
            ForEach(store.pinnedSessions) { session in
              row(session)
            }
          }
        }
        switch store.groupingMode {
        case .workspace:
          ForEach(store.groups) { group in
            groupSection(group)
          }
        case .chronological:
          // One flat, last-active-ordered list — no workspace headers.
          ForEach(store.chronologicalSessions) { session in
            row(session)
          }
        }
      }
    }
    .listStyle(.plain)
    .listSectionSeparator(.hidden) // flat list — no section hairlines (row hairlines hidden per-row)
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
      ToolbarItem(placement: .topBarTrailing) {
        organizeMenu
      }
    }
    // New chat lives at the bottom (Codex-style). A `safeAreaInset` keeps it in the
    // normal view hierarchy so it sits above the home indicator — and, on iOS 26 where
    // `.searchable` moves to the bottom, above the search field too.
    .safeAreaInset(edge: .bottom) {
      newChatBar
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
    .sheet(item: $store.scope(state: \.archived, action: \.archived)) { archivedStore in
      NavigationStack {
        ArchivedSessionsView(store: archivedStore)
      }
    }
  }

  /// The bottom "new session" button — a trailing circular FAB in the Hermes accent
  /// (icon-only: it starts a new session, not a chat). Rendered via `safeAreaInset` so the
  /// list content scrolls clear of it.
  private var newChatBar: some View {
    HStack {
      Spacer()
      Button {
        store.send(.newSessionButtonTapped)
      } label: {
        Image(systemName: "square.and.pencil")
          .font(.title2.weight(.semibold))
          .foregroundStyle(.white)
          .frame(width: 56, height: 56)
          .background(Color.hermesAccent, in: Circle())
          .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
      }
      .accessibilityLabel("New session")
    }
    .padding(.horizontal)
    .padding(.vertical, 8)
  }

  /// Top-trailing menu: choose the grouping mode (checkmark on the active one), then a
  /// divider and the Archived sessions entry. Mirrors the Codex "Organize / Manage" menu.
  private var organizeMenu: some View {
    Menu {
      Picker(
        "Grouping",
        selection: Binding(
          get: { store.groupingMode },
          set: { store.send(.setGroupingMode($0)) }
        )
      ) {
        Label("By workspace", systemImage: "folder").tag(SessionGroupingMode.workspace)
        Label("Chronological", systemImage: "clock").tag(SessionGroupingMode.chronological)
      }
      .pickerStyle(.inline)

      Divider()

      Button {
        store.send(.archivedButtonTapped)
      } label: {
        Label("Archived sessions", systemImage: "archivebox")
      }
    } label: {
      Label("Organize", systemImage: "line.3.horizontal.decrease.circle")
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
        .listRowSeparator(.hidden)
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
    .listRowSeparator(.hidden)
    .swipeActions(edge: .leading) {
      pinButton(session, isPinned: isPinned)
        .tint(.orange)
    }
    .swipeActions(edge: .trailing) {
      Button("Rename", systemImage: "pencil") {
        store.send(.renameButtonTapped(id: session.id))
      }
      .tint(.blue)
      Button("Archive", systemImage: "archivebox", role: .destructive) {
        store.send(.archiveButtonTapped(id: session.id))
      }
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
