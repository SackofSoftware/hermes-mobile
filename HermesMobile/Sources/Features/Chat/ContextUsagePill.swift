import HermesKit
import SwiftUI

/// Compact context-window gauge for the composer toolbar, mirroring the Hermes TUI
/// status-bar pill. A thin capsule track filled to `usage.contextFraction`, tinted by
/// `usage.severity`, paired with the numeric `usage.tokenLabel` (never color-only).
///
/// When the max is unknown (`contextFraction == nil`) only the token label is shown — no
/// bar — so we never render a misleading empty track. The view returns nothing when the
/// usage has no usable label; callers may also gate on `usage == nil`.
///
/// Display values come straight from the HermesKit `Usage` helpers; this view recomputes
/// no thresholds or formatting.
struct ContextUsagePill: View {
  let usage: Usage

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    if let label = usage.tokenLabel {
      let fraction = usage.contextFraction
      HStack(spacing: 6) {
        if let fraction {
          bar(fraction: fraction)
        }
        Text(label)
          .font(.caption2.weight(.medium).monospacedDigit())
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .padding(.horizontal, 9)
      .padding(.vertical, 5)
      .background(.quaternary, in: Capsule())
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Context usage")
      .accessibilityValue(label)
    }
  }

  /// A thin capsule track with a tinted fill clamped to `fraction`. Fill width animates
  /// gently as the conversation grows, but is held flat under reduce-motion.
  private func bar(fraction: Double) -> some View {
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        Capsule().fill(.tertiary)
        Capsule()
          .fill(usage.severity.tint)
          .frame(width: geo.size.width * CGFloat(min(1, max(0, fraction))))
      }
      .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: fraction)
    }
    .frame(width: 28, height: 6)
  }
}

extension ContextSeverity {
  /// Visual tint for the gauge fill, paired with the numeric label (no color-only meaning).
  /// Logic-free mapping; the *thresholds* are unit-tested in HermesKit, this is the
  /// *color choice* (snapshot-tested).
  var tint: Color {
    switch self {
    case .normal: .green
    case .moderate: .yellow
    case .high: .orange
    case .critical: .red
    }
  }
}
