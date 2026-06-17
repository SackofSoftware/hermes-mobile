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
  // Popover presentation is pure UI with no bearing on app/session state, so it lives in
  // local view @State rather than `ChatFeature` — keeps the reducer lean (no action/state
  // for a transient disclosure).
  @State private var showDetail = false

  var body: some View {
    if let label = usage.tokenLabel {
      let fraction = usage.contextFraction
      Button {
        showDetail = true
      } label: {
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
      }
      .buttonStyle(.plain)
      .popover(isPresented: $showDetail) {
        ContextUsageDetail(usage: usage)
          .presentationCompactAdaptation(.popover)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Context usage")
      .accessibilityValue(label)
      .accessibilityHint("Shows the context breakdown")
    }
  }

  /// A thin capsule track with a tinted fill set to `fraction` (already clamped to `0...1`
  /// by `usage.contextFraction`). Fill width animates gently as the conversation grows, but
  /// is held flat under reduce-motion.
  private func bar(fraction: Double) -> some View {
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        Capsule().fill(.tertiary)
        Capsule()
          .fill(usage.severity.tint)
          .frame(width: geo.size.width * CGFloat(fraction))
      }
      .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: fraction)
    }
    .frame(width: 28, height: 6)
  }
}

/// Expanded breakdown shown in the pill's popover: used / max, the input vs output split,
/// the compaction count, and the running cost. Rows whose data is absent are omitted rather
/// than rendered as blanks/zeros, and a near-full nudge appears at `.critical` severity.
///
/// All display values come straight from the HermesKit `Usage` helpers/fields — this view
/// recomputes no thresholds or formatting. It's factored out (vs. an inline `.popover`
/// closure) so it can be snapshot-tested directly, since popovers don't snapshot in-place.
struct ContextUsageDetail: View {
  let usage: Usage

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Context usage")
        .font(.subheadline.weight(.semibold))

      VStack(alignment: .leading, spacing: 6) {
        if let label = usage.tokenLabel {
          row("Used", label)
        }
        if let input = usage.input {
          row("Input", Usage.formatTokens(input))
        }
        if let output = usage.output {
          row("Output", Usage.formatTokens(output))
        }
        if let compressions = usage.compressions, compressions > 0 {
          row("Compactions", "compacted \(compressions)x")
        }
        if let cost = usage.costUSD {
          row("Cost", formatCost(cost))
        }
      }
      .font(.caption.monospacedDigit())

      if usage.severity == .critical {
        Label("Context almost full — Hermes may compact soon.", systemImage: "exclamationmark.triangle.fill")
          .font(.caption2)
          .foregroundStyle(.orange)
          .labelStyle(.titleAndIcon)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding()
    .frame(minWidth: 220, alignment: .leading)
  }

  private func row(_ title: String, _ value: String) -> some View {
    HStack {
      Text(title).foregroundStyle(.secondary)
      Spacer(minLength: 16)
      Text(value).fontWeight(.medium)
    }
  }

  /// `$0.42`-style cost. Cents-scale costs keep more precision so they don't read as `$0.00`.
  private func formatCost(_ cost: Double) -> String {
    let decimals = cost < 1 ? 4 : 2
    return "$\(String(format: "%.\(decimals)f", cost))"
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
