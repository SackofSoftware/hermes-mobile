import ComposableArchitecture
import HermesKit
import SnapshotTesting
import SwiftUI
import XCTest

@testable import HermesMobile

/// Snapshots for the composer context-usage ring (#4 follow-up) at a few fill levels plus
/// the unknown-max (track-only) state, and the tap popover. Severity tint and percent come
/// from the HermesKit `Usage` helpers; this suite only verifies the rendered ring/detail.
final class ContextUsageSnapshotTests: SnapshotTestCase {
  /// 40% (normal → green), 62% (moderate → yellow), 85% (high → orange), 97% (critical →
  /// red): ring arc + centered percent.
  func testContextRing_fillLevels() {
    let view = VStack(spacing: 16) {
      ContextUsageRing(usage: Usage(total: 80_000, contextUsed: 80_000, contextMax: 200_000, contextPercent: 40))
      ContextUsageRing(usage: Usage(total: 124_000, contextUsed: 124_000, contextMax: 200_000, contextPercent: 62))
      ContextUsageRing(usage: Usage(total: 170_000, contextUsed: 170_000, contextMax: 200_000, contextPercent: 85))
      ContextUsageRing(usage: Usage(total: 194_000, contextUsed: 194_000, contextMax: 200_000, contextPercent: 97))
    }
    .padding()
    assertSnapshot(of: view, as: componentImage())
  }

  /// Unknown max: faint track ring only — no fill arc, no percent (avoids a misleading
  /// gauge). Tapping still reveals the token count in the popover.
  func testContextRing_unknownMax() {
    let view = ContextUsageRing(usage: Usage(total: 125_000, contextUsed: 125_000))
      .padding()
    assertSnapshot(of: view, as: componentImage())
  }

  /// Expanded popover body, full data: input/output split, compaction count, cost, and the
  /// critical near-full nudge (97% → red). Snapshotted directly since popovers don't render
  /// in-place.
  func testContextDetail_fullDataCritical() {
    let view = ContextUsageDetail(
      usage: Usage(
        input: 150_000, output: 44_000, total: 194_000,
        contextUsed: 194_000, contextMax: 200_000, contextPercent: 97,
        costUSD: 0.4231, compressions: 2
      )
    )
    .padding()
    assertSnapshot(of: view, as: componentImage())
  }

  /// Expanded popover body, minimal data: no cost, no compaction, non-critical (40%). Rows
  /// for absent fields are omitted rather than shown as blanks/zeros, and no nudge appears.
  func testContextDetail_minimal() {
    let view = ContextUsageDetail(
      usage: Usage(
        input: 60_000, output: 20_000, total: 80_000,
        contextUsed: 80_000, contextMax: 200_000, contextPercent: 40
      )
    )
    .padding()
    assertSnapshot(of: view, as: componentImage())
  }

  /// The ring in place beside the model chip inside the composer toolbar.
  func testComposer_withContextRing() {
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
