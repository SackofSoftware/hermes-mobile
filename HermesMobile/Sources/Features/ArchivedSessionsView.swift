import ComposableArchitecture
import HermesKit
import SwiftUI

/// The Archived sessions sheet: a flat list of soft-archived sessions. Swipe (or long-press)
/// to **Restore** (un-archive), or tap to open/resume the session in the main stack.
struct ArchivedSessionsView: View {
  @Bindable var store: StoreOf<ArchivedSessionsFeature>
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    List {
      if let error = store.loadError {
        Label(error, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.red)
      }
      ForEach(store.sessions) { session in
        Button {
          store.send(.sessionTapped(id: session.id))
        } label: {
          SessionRowView(session: session, now: store.now)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
          restoreButton(session)
            .tint(.green)
        }
        .contextMenu {
          restoreButton(session)
        }
      }
    }
    .listStyle(.plain)
    .overlay {
      if store.sessions.isEmpty, !store.isLoading, store.loadError == nil {
        ContentUnavailableView("No archived sessions", systemImage: "archivebox")
      }
    }
    .navigationTitle("Archived")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button("Done") { dismiss() }
      }
    }
    .task { store.send(.task) }
  }

  private func restoreButton(_ session: Session) -> some View {
    Button("Restore", systemImage: "arrow.uturn.backward") {
      store.send(.restoreButtonTapped(id: session.id))
    }
  }
}
