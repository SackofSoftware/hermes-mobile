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
        // Top-level "Sessions" section header. Future sibling areas (e.g. "Cron jobs")
        // render their own header the same way, all scoped to the active profile pill.
        sessionsSectionHeader
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
    // The profile pill is the centered (principal) title; "Sessions" is a list section
    // header instead, leaving room for future sibling sections (e.g. "Cron jobs"). The
    // pill needs the inline bar, so keep the nav title empty + inline in both cases.
    .navigationTitle("")
    .navigationBarTitleDisplayMode(.inline)
    .searchable(text: $store.searchQuery, prompt: "Search sessions")
    .refreshable { store.send(.pulledToRefresh) }
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button("Settings", systemImage: "gearshape") {
          store.send(.settingsButtonTapped)
        }
      }
      if store.profilesSupported {
        ToolbarItem(placement: .principal) {
          profilePill
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
    .alert(
      "Rename profile",
      isPresented: Binding(
        get: { store.renamingProfileName != nil },
        set: { presented in if !presented { store.send(.cancelRenameProfile) } }
      )
    ) {
      TextField("Profile name", text: $store.profileRenameDraft)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
      Button("Save") { store.send(.confirmRenameProfile) }
      Button("Cancel", role: .cancel) { store.send(.cancelRenameProfile) }
    } message: {
      Text(ProfileName.hint)
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
    .sheet(item: $store.scope(state: \.addProfile, action: \.addProfile)) { addProfileStore in
      NavigationStack {
        AddProfileView(store: addProfileStore)
      }
    }
  }

  /// Top-level content section header. The active profile is shown in the pill (the
  /// centered nav title); this labels the sessions list as one section so future sibling
  /// sections (e.g. "Cron jobs") can sit alongside it under the same profile.
  private var sessionsSectionHeader: some View {
    Text("Sessions")
      .font(.title2.weight(.bold))
      .listRowSeparator(.hidden)
      .listRowBackground(Color.clear)
      .accessibilityAddTraits(.isHeader)
  }

  // MARK: Profile pill

  /// Safari-style centered pill in the navigation bar: the active profile's icon (a house
  /// for the default profile; none for custom ones), its name, and a chevron. Tapping it
  /// opens the profile `Menu`. Rendered only when the agent supports profiles
  /// (`profilesSupported`); otherwise the static "Sessions" title is shown instead.
  private var profilePill: some View {
    Menu {
      profileMenuContent
    } label: {
      HStack(spacing: 4) {
        if isSelectedDefault {
          Image(systemName: "house.fill")
            .imageScale(.small)
        }
        Text(store.selectedProfileName)
          .fontWeight(.semibold)
          .lineLimit(1)
        Image(systemName: "chevron.down")
          .font(.caption2.weight(.semibold))
      }
      .foregroundStyle(.primary)
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .modifier(GlassCapsule())
    }
    .accessibilityLabel("Profile: \(store.selectedProfileName)")
  }

  /// The profile `Menu`'s contents: each profile (checkmark on the active one; custom
  /// profiles offer rename/delete in a nested menu), a divider, then "Add profile".
  @ViewBuilder
  private var profileMenuContent: some View {
    ForEach(store.profiles) { profile in
      if profile.isDefault {
        Button {
          store.send(.selectProfile(name: profile.name))
        } label: {
          Label(profile.name, systemImage: "house")
        }
      } else {
        // Custom profiles: select on tap, with a nested menu for rename/delete.
        Menu {
          Button {
            store.send(.selectProfile(name: profile.name))
          } label: {
            Label("Switch to this profile", systemImage: "arrow.right.circle")
          }
          Divider()
          Button {
            store.send(.renameProfileTapped(name: profile.name))
          } label: {
            Label("Rename", systemImage: "pencil")
          }
          Button(role: .destructive) {
            store.send(.deleteProfileButtonTapped(name: profile.name))
          } label: {
            Label("Delete", systemImage: "trash")
          }
        } label: {
          Label(profile.name, systemImage: "person.crop.circle")
        }
      }
    }

    Divider()

    Button {
      store.send(.addProfileTapped)
    } label: {
      Label("Add profile", systemImage: "plus")
    }
  }

  private var isSelectedDefault: Bool {
    store.profiles[id: store.selectedProfileName]?.isDefault
      ?? (store.selectedProfileName == SessionListFeature.State.defaultProfileName)
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

/// Liquid-glass capsule background on iOS 26+, material + hairline fallback below.
/// Gives the profile pill the Safari-style glass chip look in the navigation bar.
private struct GlassCapsule: ViewModifier {
  func body(content: Content) -> some View {
    if #available(iOS 26.0, *) {
      content.glassEffect(.regular.interactive(), in: .capsule)
    } else {
      content
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(.quaternary, lineWidth: 0.5))
    }
  }
}
