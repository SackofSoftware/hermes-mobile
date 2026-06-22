import ComposableArchitecture
import HermesKit
import SnapshotTesting
import SwiftUI
import XCTest

@testable import HermesMobile

/// Snapshot coverage for the capability-aware auth screen (Password / Token segments,
/// token disclaimer, the "How to connect securely" details screen, capability-disabled
/// segment states) and the re-auth sheet (password vs token variants). Mirrors the host /
/// setup pattern in `ConnectionSnapshotTests` / `AddProfileSnapshotTests`: dark traits,
/// `deviceImage()` whole-screen render. Views wrap in a `NavigationStack` so the token
/// disclaimer's `NavigationLink` (and the re-auth sheet's own `NavigationStack`) compose.
final class AuthSnapshotTests: SnapshotTestCase {
  /// A tall fixed-size whole-screen render (device width, extra-tall height) so a long
  /// scrolling `Form` is captured in full rather than clipped at the device fold. Same dark
  /// traits + key-window compositing as `deviceImage()`.
  private func tallImage<V: SwiftUI.View>() -> Snapshotting<V, UIImage> {
    .image(
      drawHierarchyInKeyWindow: true,
      perceptualPrecision: 0.98,
      layout: .fixed(width: device.size!.width, height: 1400),
      traits: UITraitCollection(userInterfaceStyle: .dark)
    )
  }

  private func connectionView(_ state: ConnectionFeature.State) -> some View {
    NavigationStack {
      ConnectionView(
        store: Store(initialState: state) { ConnectionFeature() }
      )
    }
  }

  // MARK: - Auth screen: segments

  /// Password segment on a gated server with a password-capable provider: username +
  /// password fields, both segments enabled, Password preselected.
  func testAuthScreen_passwordSegment() {
    assertSnapshot(
      of: connectionView(
        ConnectionFeature.State(
          serverURL: "http://mac.tailnet:9119",
          username: "alice",
          password: "••••••••",
          method: .password,
          capability: .passwordAvailable(provider: "basic", displayName: "Basic"),
          status: .reachable(version: "0.16.0")
        )
      ),
      as: deviceImage()
    )
  }

  /// Token segment with no capability probed yet: session-token field plus the always-on
  /// disclaimer + "Learn how to connect securely" link.
  func testAuthScreen_tokenSegment() {
    assertSnapshot(
      of: connectionView(
        ConnectionFeature.State(
          serverURL: "http://mac.tailnet:9119",
          token: "••••••••",
          method: .token,
          status: .reachable(version: "0.16.0")
        )
      ),
      as: deviceImage()
    )
  }

  // MARK: - Token disclaimer + details screen

  /// The token disclaimer in context on a token-only server: the inline honesty note and
  /// the "This server only supports token sign-in." hint footer.
  func testAuthScreen_tokenDisclaimer_tokenOnly() {
    assertSnapshot(
      of: connectionView(
        ConnectionFeature.State(
          serverURL: "http://mac.tailnet:9119",
          token: "••••••••",
          method: .token,
          capability: .tokenOnly,
          status: .reachable(version: "0.16.0")
        )
      ),
      as: deviceImage()
    )
  }

  /// "How to connect securely" details screen — password NOT available (token-only):
  /// the WHY/HOW copy + Tailscale link, no password nudge section. Rendered into a tall,
  /// fixed canvas (wider/taller than the device fold) so the *whole* scrollable form is
  /// captured — the password-nudge section that distinguishes the two variants lives at the
  /// very bottom and would otherwise fall below the device fold.
  func testSecureConnectionInfo_passwordUnavailable() {
    assertSnapshot(
      of: NavigationStack { SecureConnectionInfoView(passwordAvailable: false) },
      as: tallImage()
    )
  }

  /// "How to connect securely" details screen — password available: adds the nudge-back
  /// section recommending Password sign-in (the bottom-most section). Tall render so that
  /// section is visible and the baseline differs from the token-only variant.
  func testSecureConnectionInfo_passwordAvailable() {
    assertSnapshot(
      of: NavigationStack { SecureConnectionInfoView(passwordAvailable: true) },
      as: tallImage()
    )
  }

  // MARK: - Capability-disabled segment states

  /// Gated server (password available) but the user is on the Token segment: the de-emphasis
  /// hint nudges back to password ("This server uses password login…").
  func testAuthScreen_gated_tokenDeemphasized() {
    assertSnapshot(
      of: connectionView(
        ConnectionFeature.State(
          serverURL: "http://mac.tailnet:9119",
          token: "••••••••",
          method: .token,
          capability: .passwordAvailable(provider: "basic", displayName: "Basic"),
          status: .reachable(version: "0.16.0")
        )
      ),
      as: deviceImage()
    )
  }

  /// Token-only server with the Password segment selected: Password is disabled (the segment
  /// stays usable for Token), and the footer explains the server only supports token sign-in.
  func testAuthScreen_tokenOnly_passwordDisabled() {
    assertSnapshot(
      of: connectionView(
        ConnectionFeature.State(
          serverURL: "http://mac.tailnet:9119",
          method: .token,
          capability: .tokenOnly,
          status: .reachable(version: "0.16.0")
        )
      ),
      as: deviceImage()
    )
  }

  // MARK: - Re-auth sheet

  /// Re-auth sheet, password variant: fixed server, prefilled username, password field,
  /// Sign in + "Quit to start".
  func testReauthSheet_password() {
    assertSnapshot(
      of: ReauthView(
        store: Store(
          initialState: ReauthFeature.State(
            serverURL: URL(string: "http://mac.tailnet:9119")!,
            method: .password,
            previousUsername: "alice",
            password: "••••••••"
          )
        ) { ReauthFeature() }
      ),
      as: deviceImage()
    )
  }

  /// Re-auth sheet, token variant: fixed server, session-token field, no username.
  func testReauthSheet_token() {
    assertSnapshot(
      of: ReauthView(
        store: Store(
          initialState: ReauthFeature.State(
            serverURL: URL(string: "http://mac.tailnet:9119")!,
            method: .token,
            token: "••••••••"
          )
        ) { ReauthFeature() }
      ),
      as: deviceImage()
    )
  }
}
