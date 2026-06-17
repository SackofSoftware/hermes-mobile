import ComposableArchitecture
import HermesKit
import SnapshotTesting
import SwiftUI
import XCTest

@testable import HermesMobile

/// Snapshots for the composer context-usage pill (#4) at a few fill levels plus the
/// unknown-max (text-only) state. Severity tint and label come from the HermesKit `Usage`
/// helpers; this suite only verifies the rendered pill.
final class ContextUsageSnapshotTests: SnapshotTestCase {
  /// 40% (moderate → yellow), 85% (high → orange), 97% (critical → red), all bar + label.
  func testContextPill_fillLevels() {
    let view = VStack(spacing: 16) {
      ContextUsagePill(usage: Usage(total: 80_000, contextUsed: 80_000, contextMax: 200_000, contextPercent: 40))
      ContextUsagePill(usage: Usage(total: 170_000, contextUsed: 170_000, contextMax: 200_000, contextPercent: 85))
      ContextUsagePill(usage: Usage(total: 194_000, contextUsed: 194_000, contextMax: 200_000, contextPercent: 97))
    }
    .padding()
    assertSnapshot(of: view, as: componentImage())
  }

  /// Unknown max: only `125k tok` text, no bar (avoids a misleading empty track).
  func testContextPill_unknownMax() {
    let view = ContextUsagePill(usage: Usage(total: 125_000, contextUsed: 125_000))
      .padding()
    assertSnapshot(of: view, as: componentImage())
  }

  /// The pill in place beside the model chip inside the composer toolbar.
  func testComposer_withContextPill() {
    let view = ComposerHost {
      ComposerView(
        text: .constant("How big is the context now?"),
        isSending: false, canSend: true,
        model: "claude-opus-4-8", reasoningEffort: "high",
        usage: Usage(total: 170_000, contextUsed: 170_000, contextMax: 200_000, contextPercent: 85),
        focused: $0,
        onModelTap: {}, onSend: {}, onInterrupt: {}
      )
    }
    .frame(width: device.size?.width ?? 390)
    assertSnapshot(of: view, as: componentImage())
  }
}
