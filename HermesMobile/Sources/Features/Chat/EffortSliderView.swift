import HermesKit
import SwiftUI

/// Reasoning effort as a single Faster ↔ Smarter slider.
///
/// A six-row checklist made effort look like six unrelated options. It isn't — it's one
/// dial with an obvious direction, and naming the ends ("Faster", "Smarter") says what the
/// levels actually buy you far better than the words "minimal" and "xhigh" do on their own.
///
/// The track snaps to discrete stops because the server only accepts those exact levels
/// (`ModelOptions.reasoningEfforts`); a continuous slider would imply precision that
/// doesn't exist.
struct EffortSliderView: View {
  /// Current level, e.g. "medium". Unknown/absent values park at the default stop.
  let effort: String?
  /// Disabled mid-turn, matching the rest of the picker.
  var isBusy: Bool = false
  let onSelect: (String) -> Void

  private var levels: [String] { ModelOptions.reasoningEfforts }

  private var index: Int {
    guard let effort, let i = levels.firstIndex(of: effort.lowercased()) else {
      // Park on "medium" when the server hasn't said — the same default it uses.
      return levels.firstIndex(of: "medium") ?? 0
    }
    return i
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        Text("Effort")
          .foregroundStyle(.secondary)
        Text(displayName(levels[index]))
          .fontWeight(.semibold)
        Spacer()
      }
      .font(.subheadline)

      HStack {
        Text("Faster")
        Spacer()
        Text("Smarter")
      }
      .font(.caption)
      .foregroundStyle(.secondary)

      slider
    }
    .opacity(isBusy ? 0.5 : 1)
    .allowsHitTesting(!isBusy)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Reasoning effort")
    .accessibilityValue(displayName(levels[index]))
    .accessibilityAdjustableAction { direction in
      let next = direction == .increment ? index + 1 : index - 1
      guard levels.indices.contains(next) else { return }
      onSelect(levels[next])
    }
  }

  /// A track with a stop per level and a draggable knob. Built by hand rather than with
  /// `Slider(step:)` so the stops are visible — the whole point is seeing how many
  /// positions exist and where you are among them.
  private var slider: some View {
    GeometryReader { geo in
      let count = max(levels.count - 1, 1)
      let usable = max(geo.size.width - Self.knob, 1)
      let step = usable / CGFloat(count)
      let knobX = step * CGFloat(index)

      ZStack(alignment: .leading) {
        Capsule()
          .fill(.quaternary)
          .frame(height: Self.track)
        // Filled portion: shows progress toward "Smarter" at a glance.
        Capsule()
          .fill(.tertiary)
          .frame(width: knobX + Self.knob / 2, height: Self.track)
        // Stop markers, skipping the one under the knob so it doesn't show through.
        ForEach(levels.indices, id: \.self) { i in
          if i != index {
            Circle()
              .fill(.secondary.opacity(0.5))
              .frame(width: 4, height: 4)
              .offset(x: step * CGFloat(i) + Self.knob / 2 - 2)
          }
        }
        Circle()
          .fill(.white)
          .shadow(radius: 1.5, y: 1)
          .frame(width: Self.knob, height: Self.knob)
          .offset(x: knobX)
      }
      .frame(height: Self.knob)
      .contentShape(.rect)
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in
            let raw = (value.location.x - Self.knob / 2) / step
            let clamped = Int(raw.rounded())
            guard levels.indices.contains(clamped), clamped != index else { return }
            onSelect(levels[clamped])
          }
      )
    }
    .frame(height: Self.knob)
  }

  private static let knob: CGFloat = 26
  private static let track: CGFloat = 10

  /// "xhigh" is an API token, not a word — spell the levels the way a person would.
  private func displayName(_ level: String) -> String {
    switch level {
    case "none": return "None"
    case "minimal": return "Minimal"
    case "low": return "Low"
    case "medium": return "Medium"
    case "high": return "High"
    case "xhigh": return "Max"
    default: return level.capitalized
    }
  }
}

#Preview {
  VStack(spacing: 24) {
    EffortSliderView(effort: "medium") { _ in }
    EffortSliderView(effort: "xhigh") { _ in }
    EffortSliderView(effort: "none", isBusy: true) { _ in }
  }
  .padding()
}
