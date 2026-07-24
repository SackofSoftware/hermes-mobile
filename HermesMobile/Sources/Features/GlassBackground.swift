import SwiftUI

/// Liquid-glass background on iOS 26+, `.regularMaterial` + hairline fallback below.
///
/// One place for the `#available(iOS 26, *)` gate: the nav-bar profile pill, the
/// scroll-to-bottom button and the copied toast all render the same glass-vs-material
/// decision and only differ by shape, press-reactivity and the fallback's drop shadow.
struct GlassBackground<S: Shape>: ViewModifier {
  let shape: S
  /// `.interactive()` glass reacts to the touch on its own — controls only (a toast isn't one).
  var isInteractive = false
  /// Drop shadow for the pre-iOS-26 material fallback; Liquid Glass brings its own.
  /// A zero radius means no shadow.
  var fallbackShadowRadius: CGFloat = 0
  var fallbackShadowY: CGFloat = 0

  func body(content: Content) -> some View {
    if #available(iOS 26.0, *) {
      content.glassEffect(isInteractive ? .regular.interactive() : .regular, in: shape)
    } else {
      let base = content
        .background(.regularMaterial, in: shape)
        .overlay(shape.stroke(.quaternary, lineWidth: 0.5))
      if fallbackShadowRadius > 0 {
        base.shadow(color: .black.opacity(0.15), radius: fallbackShadowRadius, y: fallbackShadowY)
      } else {
        base
      }
    }
  }
}
