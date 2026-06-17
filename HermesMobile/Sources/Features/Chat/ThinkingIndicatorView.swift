import HermesKit
import SwiftUI

/// The live "Thinking" indicator that owns a turn's reasoning + status line.
///
/// While the turn is in flight (`isComplete == false`) it shows a shimmering
/// "Thinking" label with a live `1h 1m 1s` elapsed timer (read from
/// `store.thinkingSeconds` via `liveSeconds`); its disclosed area accumulates the
/// reasoning text and the latest `status.update` line. On completion it freezes into a
/// static, collapsed `Thinking · <elapsed>` disclosure kept in the transcript so past
/// reasoning + status stay reviewable.
struct ThinkingIndicatorView: View {
  /// Live elapsed seconds while active (`store.thinkingSeconds`); ignored once complete.
  let liveSeconds: Int
  /// Accumulated reasoning/thinking text (may be empty while only status has arrived).
  let reasoning: String
  /// Latest `status.update` text (context-size / compaction line), shown in the body.
  let status: String?
  /// Frozen elapsed, written at completion; read instead of `liveSeconds` when complete.
  let elapsedSeconds: Int
  /// `false` while the turn runs (live timer + shimmer), `true` once frozen.
  let isComplete: Bool

  /// Forces the reduce-motion (flat) shimmer variant when non-nil; `nil` reads the
  /// `accessibilityReduceMotion` environment value (production default). Only set in
  /// snapshot tests: `accessibilityReduceMotion` is a read-only `KeyPath`, not a
  /// `WritableKeyPath`, so `.environment(\.accessibilityReduceMotion, …)` does not compile
  /// and the value can't be injected into the snapshot host.
  let reduceMotionOverride: Bool?

  @State private var isExpanded: Bool

  init(
    liveSeconds: Int,
    reasoning: String,
    status: String?,
    elapsedSeconds: Int,
    isComplete: Bool,
    initiallyExpanded: Bool = false,
    reduceMotionOverride: Bool? = nil
  ) {
    self.liveSeconds = liveSeconds
    self.reasoning = reasoning
    self.status = status
    self.elapsedSeconds = elapsedSeconds
    self.isComplete = isComplete
    self.reduceMotionOverride = reduceMotionOverride
    _isExpanded = State(initialValue: initiallyExpanded)
  }

  var body: some View {
    if isComplete {
      DisclosureGroup(isExpanded: $isExpanded) {
        disclosedBody
      } label: {
        Text("Thinking · \(formatElapsed(elapsedSeconds))")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .font(.caption)
    } else {
      DisclosureGroup(isExpanded: $isExpanded) {
        disclosedBody
      } label: {
        ThinkingLabel(elapsed: liveSeconds, reduceMotionOverride: reduceMotionOverride)
      }
      .font(.caption)
    }
  }

  /// Shared disclosed body: reasoning then the latest status line.
  @ViewBuilder
  private var disclosedBody: some View {
    VStack(alignment: .leading, spacing: 6) {
      if !reasoning.isEmpty {
        Text(reasoning)
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      if let status, !status.isEmpty {
        Label(status, systemImage: "ellipsis.circle")
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// The active label: "Thinking" + a live elapsed timer, with a shimmer that sweeps the
/// text while the turn runs. Held flat under reduce-motion.
private struct ThinkingLabel: View {
  let elapsed: Int
  /// When non-nil, overrides the environment reduce-motion value (snapshot tests only).
  var reduceMotionOverride: Bool?

  @Environment(\.accessibilityReduceMotion) private var environmentReduceMotion
  @State private var shimmerPhase: CGFloat = -1

  private var reduceMotion: Bool { reduceMotionOverride ?? environmentReduceMotion }

  var body: some View {
    // Visible label dims the timer (`.secondary`); the shimmer mask uses full alpha across
    // the whole label so the band reads evenly over both words.
    labelContent(dimTimer: true)
      .foregroundStyle(.primary)
      .overlay { shimmer }
      .mask { labelContent(dimTimer: false) }
  }

  /// "Thinking" + elapsed timer. Single source of the label's text/layout for both the
  /// visible content and the shimmer mask so the two can't drift; `dimTimer` applies the
  /// `.secondary` timer tint for the visible copy only (the mask wants full alpha).
  @ViewBuilder
  private func labelContent(dimTimer: Bool) -> some View {
    HStack(spacing: 6) {
      Text("Thinking")
        .font(.caption.weight(.medium))
      Text(formatElapsed(elapsed))
        .font(.caption.monospacedDigit())
        .foregroundStyle(dimTimer ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
      Spacer(minLength: 0)
    }
  }

  /// A bright band swept across the text via a moving linear gradient. Disabled (and
  /// invisible) under reduce-motion so the label simply reads flat.
  @ViewBuilder
  private var shimmer: some View {
    if reduceMotion {
      EmptyView()
    } else {
      GeometryReader { geo in
        LinearGradient(
          colors: [.clear, Color.white.opacity(0.65), .clear],
          startPoint: .leading,
          endPoint: .trailing
        )
        .frame(width: geo.size.width * 0.5)
        .offset(x: shimmerPhase * geo.size.width * 1.5)
        .blendMode(.plusLighter)
      }
      .allowsHitTesting(false)
      .onAppear {
        withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
          shimmerPhase = 1
        }
      }
    }
  }
}
