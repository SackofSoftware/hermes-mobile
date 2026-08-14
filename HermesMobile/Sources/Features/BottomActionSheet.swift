import ComposableArchitecture
import SwiftUI

extension View {
  /// Presents a reducer-owned `ConfirmationDialogState` as a **bottom action sheet**.
  ///
  /// Drop-in replacement for TCA's `.confirmationDialog(_:)` store modifier. On iOS 26 no
  /// system presentation docks at the bottom any more — verified in the iOS 26.5
  /// simulator:
  /// - SwiftUI's `confirmationDialog` renders as a floating popover anchored to the
  ///   modifier's view, dropping the title and the Cancel button (FB20644893);
  /// - UIKit's `UIAlertController(.actionSheet)` anchors to any configured popover
  ///   `sourceView` the same way, and presents as a **centered** card without one.
  ///
  /// So the bottom sheet is rendered directly: a height-fitted sheet whose content is
  /// derived from the same `ConfirmationDialogState` — the state model (and every reducer
  /// test written against it) is untouched; only the presentation layer differs.
  /// Semantics mirror the SwiftUI modifier: a button's action is sent through the store
  /// (dialog state is ephemeral, so the reducer clears it and the sheet dismisses); Cancel
  /// and swipe-down dismiss through the binding, which sends the usual `.dismiss`.
  func bottomActionSheet<Action>(
    _ item: Binding<Store<ConfirmationDialogState<Action>, Action>?>
  ) -> some View {
    sheet(item: item) { store in
      BottomActionSheetView(store: store)
    }
  }
}

/// The sheet's content: title + message over the dialog's buttons, stacked full-width with
/// the destructive action styled red — the pre-iOS-26 action-sheet shape, docked at the
/// bottom via a content-fitted height detent.
struct BottomActionSheetView<Action>: View {
  let store: Store<ConfirmationDialogState<Action>, Action>
  @Environment(\.dismiss) private var dismiss
  /// Measured content height driving the sheet's detent (seeded with a sane fallback so
  /// the first frame isn't a full-height sheet).
  @State private var contentHeight: CGFloat = 200

  var body: some View {
    let state = store.withState { $0 }
    VStack(spacing: 20) {
      VStack(spacing: 6) {
        Text(state.title)
          .font(.headline)
        if let message = state.message {
          Text(message)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
      }
      VStack(spacing: 10) {
        ForEach(state.buttons) { button in
          self.button(button)
        }
      }
    }
    .padding(.horizontal, 20)
    .padding(.top, 24)
    .padding(.bottom, 12)
    .frame(maxWidth: .infinity)
    // Report the NATURAL height even while the detent still has the sheet too short —
    // without this the measurement reads the compressed layout (message truncated to
    // one line) and the detent settles there.
    .fixedSize(horizontal: false, vertical: true)
    .onGeometryChange(for: CGFloat.self) { proxy in
      proxy.size.height
    } action: { height in
      contentHeight = height
    }
    .presentationDetents([.height(contentHeight)])
    .presentationDragIndicator(.hidden)
  }

  /// One dialog button: full-width capsule, red label for the destructive role. A button
  /// carrying an action sends it through the store (which also dismisses — dialog state is
  /// ephemeral); an action-less one (Cancel) just dismisses, sending `.dismiss` through
  /// the sheet binding.
  private func button(_ state: ButtonState<Action>) -> some View {
    Button {
      state.withAction { action in
        if let action {
          store.send(action)
        } else {
          dismiss()
        }
      }
    } label: {
      Text(state.label)
        .font(.body.weight(.semibold))
        .foregroundStyle(state.role == .destructive ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
        .frame(maxWidth: .infinity, minHeight: 50)
        .background(Color(.secondarySystemFill), in: Capsule())
    }
    .buttonStyle(.plain)
  }
}
