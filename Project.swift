import Foundation
import ProjectDescription

// Debug-only server preset. Baked in at generate time from the environment so a
// developer can do `HERMES_DEFAULT_SERVER_URL=http://<tailnet-host>:9119 tuist generate`
// without committing their tailnet address/token. Empty by default.
let debugServerURL = ProcessInfo.processInfo.environment["HERMES_DEFAULT_SERVER_URL"] ?? ""

// Apple team for device/TestFlight signing, baked in at generate time. Empty for
// simulator-only work (simulator builds pass CODE_SIGNING_ALLOWED=NO). For a device
// build: `DEVELOPMENT_TEAM=<your 10-char team id> tuist generate`.
let developmentTeam = ProcessInfo.processInfo.environment["DEVELOPMENT_TEAM"] ?? ""

let project = Project(
  name: "HermesMobile",
  packages: [
    .local(path: "HermesKit"),
    .remote(
      url: "https://github.com/pointfreeco/swift-snapshot-testing",
      requirement: .upToNextMajor(from: "1.17.0")
    ),
  ],
  targets: [
    .target(
      name: "HermesMobile",
      destinations: [.iPhone],
      product: .app,
      bundleId: "me.honcharenko.HermesMobile",
      deploymentTargets: .iOS("17.0"),
      infoPlist: .extendingDefault(with: [
        "UILaunchScreen": ["UIColorName": ""],
        "HermesDefaultServerURL": .string(debugServerURL),
        // The app connects to user-specified self-hosted servers over http (Tailscale/LAN),
        // so domain-scoped ATS exceptions aren't possible — allow cleartext loads.
        "NSAppTransportSecurity": [
          "NSAllowsArbitraryLoads": true,
        ],
        // On device, reaching a private/tailnet host can trigger the local-network prompt.
        "NSLocalNetworkUsageDescription": "Hermes Mobile connects to your self-hosted Hermes server over your private network or Tailscale.",
        // Only standard encryption (HTTPS/TLS) — exempt; lets TestFlight skip the
        // export-compliance prompt so builds are testable immediately.
        "ITSAppUsesNonExemptEncryption": false,
      ]),
      sources: ["HermesMobile/Sources/**"],
      resources: ["HermesMobile/Resources/**"],
      dependencies: [
        .package(product: "HermesKit"),
      ],
      settings: .settings(
        base: [
          "DEVELOPMENT_TEAM": .string(developmentTeam),
          "CODE_SIGN_STYLE": "Automatic",
          "MARKETING_VERSION": "1.0",
          "CURRENT_PROJECT_VERSION": "1",
          "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        ],
        configurations: [
          .debug(name: "Debug"),
          .release(name: "Release"),
        ]
      )
    ),
    .target(
      name: "HermesMobileTests",
      destinations: [.iPhone],
      product: .unitTests,
      bundleId: "me.honcharenko.HermesMobileTests",
      deploymentTargets: .iOS("17.0"),
      sources: ["HermesMobileTests/**"],
      dependencies: [
        .target(name: "HermesMobile"),
        .package(product: "SnapshotTesting"),
      ]
    ),
  ]
)
