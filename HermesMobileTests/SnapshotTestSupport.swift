import ComposableArchitecture
import HermesKit
import SnapshotTesting
import SwiftUI
import XCTest

@testable import HermesMobile

/// Shared scaffolding for the feature snapshot suites. Renders the feature views to PNGs
/// (under `__Snapshots__/<suite file name>/`). On first run there's no baseline, so each
/// assertion records the image and reports a failure — that's expected; the PNGs are the
/// deliverable.
///
/// Two render paths:
/// - **Whole-screen views** (`.device` layout) use `drawHierarchyInKeyWindow: true` so the
///   iOS 26 system chrome composites — bottom search field, Liquid Glass toolbar/buttons.
///   That requires the host app (this target has one) and isn't pixel-exact, so they run at
///   `perceptualPrecision: 0.98`.
/// - **Singular components** (`.sizeThatFits`) keep the fast, deterministic layer render.
///
/// Subclass this in each feature suite so the shared fixtures (`device`, `now`,
/// `connection`, `id`, `solidPNG`) stay in one place.
class SnapshotTestCase: XCTestCase {
  let device = ViewImageConfig.iPhone13Pro
  /// Fixed reference "now" so relative timestamps are deterministic.
  let now = Date(timeIntervalSince1970: 1_749_600_000)
  let connection = ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "t")

  func id(_ n: Int) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012x", n))")!
  }

  /// Dark appearance is pinned (the app is designed dark-first) so renders don't drift
  /// with the simulator's appearance setting. Without this the baselines flip to light
  /// mode on a light-mode simulator and every pixel mismatches.
  private static let darkTraits = UITraitCollection(userInterfaceStyle: .dark)

  /// Whole-screen snapshot: composites the iOS 26 system chrome (`drawHierarchyInKeyWindow`),
  /// so it needs the host app and isn't pixel-exact — runs at `perceptualPrecision: 0.98`.
  ///
  /// `precision` (the fraction of pixels that must clear that perceptual bar) defaults to a
  /// strict `1`. Lower it ONLY for a view containing a genuinely non-deterministic region —
  /// an indeterminate `ProgressView` spinner is captured at whatever rotation the render
  /// server happens to be at — and keep the allowance just big enough for that region, so the
  /// rest of the screen is still asserted pixel-for-pixel.
  func deviceImage<V: SwiftUI.View>(precision: Float = 1) -> Snapshotting<V, UIImage> {
    .image(
      drawHierarchyInKeyWindow: true,
      precision: precision,
      perceptualPrecision: 0.98,
      layout: .device(config: device),
      traits: Self.darkTraits
    )
  }

  /// Singular component snapshot: fast, deterministic layer render at `.sizeThatFits`.
  func componentImage<V: SwiftUI.View>() -> Snapshotting<V, UIImage> {
    .image(layout: .sizeThatFits, traits: Self.darkTraits)
  }

  /// Solid-color PNG so image-chip thumbnails render deterministically.
  func solidPNG(_ color: UIColor, _ side: CGFloat = 40) -> Data {
    UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).pngData { ctx in
      color.setFill()
      ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
    }
  }
}
