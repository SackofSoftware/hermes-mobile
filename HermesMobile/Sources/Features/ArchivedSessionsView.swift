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
          .listRowSeparator(.hidden)
      }
      ForEach(store.sessions) { session in
        Button {
          store.send(.sessionTapped(id: session.id))
        } label: {
          SessionRowView(session: session, now: store.now)
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
        .swipeActions(edge: .trailing) {
          restoreButton(session)
            .tint(.green)
        }
        .contextMenu {
          restoreButton(session)
          Button("Copy ID", systemImage: "doc.on.doc") {
            store.send(.copyIDButtonTapped(id: session.id))
          }
        }
      }
    }
    .listStyle(.plain)
    .listSectionSeparator(.hidden)
    .overlay {
      if store.sessions.isEmpty, !store.isLoading, store.loadError == nil {
        ContentUnavailableView("No archived sessions", systemImage: "archivebox")
      }
    }
    .overlay(alignment: .bottom) {
      CopiedToastView(token: store.copiedIDToastToken)
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
