import SwiftUI

/// A circular "jump to latest" button shown over the transcript when the user has
/// scrolled up. Uses Liquid Glass on iOS 26+, falling back to a material on earlier OSes.
struct ScrollToBottomButton: View {
  let action: () -> Void

  var body: some View {
    // Uses `.onTapGesture`, NOT `Button`: inside the SwiftUI transcript engine a `Button` here
    // never received taps (a sibling `.onTapGesture` in the same container did — verified on
    // device), while the UICollectionView engine hosts this view in its own controller where
    // either works. An explicit tap gesture is reliable in both contexts; button semantics are
    // restored for VoiceOver via accessibility traits/action.
    Image(systemName: "chevron.down")
      .font(.body.weight(.semibold))
      .foregroundStyle(.primary)
      .frame(width: 44, height: 44)
      // Interactive glass gives the press highlight; it coexists with our `.onTapGesture`,
      // which owns the actual tap action.
      .modifier(GlassBackground(shape: Circle(), isInteractive: true, fallbackShadowRadius: 4, fallbackShadowY: 2))
      .contentShape(Circle())
      .onTapGesture(perform: action)
      .accessibilityElement()
      .accessibilityLabel("Scroll to latest")
      .accessibilityAddTraits(.isButton)
      .accessibilityAction(.default, action)
  }
}
