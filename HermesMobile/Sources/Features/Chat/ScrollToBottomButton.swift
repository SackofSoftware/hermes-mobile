import SwiftUI

/// A circular "jump to latest" button shown over the transcript when the user has
/// scrolled up. Uses Liquid Glass on iOS 26+, falling back to a material on earlier OSes.
struct ScrollToBottomButton: View {
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: "chevron.down")
        .font(.body.weight(.semibold))
        .foregroundStyle(.primary)
        .frame(width: 44, height: 44)
    }
    .buttonStyle(.plain) // keep the chevron `.primary`, not the accent tint
    .modifier(GlassCircle())
    .accessibilityLabel("Scroll to latest")
  }
}

/// Liquid-glass circular background on iOS 26+, material + hairline fallback below.
private struct GlassCircle: ViewModifier {
  func body(content: Content) -> some View {
    if #available(iOS 26.0, *) {
      content.glassEffect(.regular.interactive(), in: .circle)
    } else {
      content
        .background(.regularMaterial, in: Circle())
        .overlay(Circle().stroke(.quaternary, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    }
  }
}
