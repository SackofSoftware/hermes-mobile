import ComposableArchitecture
import HermesKit
import SwiftUI

/// The chat screen: a scrolling transcript, a transient activity/error footer, and
/// the composer. Streams over the gateway via `ChatFeature`.
struct ChatView: View {
  @Bindable var store: StoreOf<ChatFeature>

  var body: some View {
    VStack(spacing: 0) {
      transcript
      footer
      Divider()
      ComposerView(
        text: $store.composerText,
        isSending: store.isSending,
        canSend: store.canSend,
        onSend: { store.send(.composerSubmitted) },
        onInterrupt: { store.send(.interruptTapped) }
      )
    }
    .navigationTitle(store.title ?? "Chat")
    .navigationBarTitleDisplayMode(.inline)
    .task { store.send(.task) }
    .onDisappear { store.send(.onDisappear) }
  }

  private var transcript: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 10) {
          ForEach(store.transcript) { row in
            rowView(row).id(row.id)
          }
        }
        .padding()
      }
      .onChange(of: store.transcript.last?.id) { _, last in
        guard let last else { return }
        withAnimation { proxy.scrollTo(last, anchor: .bottom) }
      }
    }
  }

  @ViewBuilder
  private func rowView(_ row: ChatRow) -> some View {
    switch row.kind {
    case let .message(role, text, isComplete):
      MessageBubbleView(role: role, text: text, isComplete: isComplete)
    case let .tool(name, state, result, durationS):
      ToolStatusView(name: name, state: state, result: result, durationS: durationS)
    case let .thinking(text):
      DisclosureGroup("Thinking") {
        Text(text).font(.caption).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .font(.caption)
    case let .status(_, text):
      Text(text).font(.caption).foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private var footer: some View {
    if let error = store.errorBanner {
      Label(error, systemImage: "exclamationmark.triangle")
        .font(.caption).foregroundStyle(.red)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
    } else if let activity = store.activity {
      Label(activity, systemImage: "ellipsis.circle")
        .font(.caption).foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
    }
  }
}
