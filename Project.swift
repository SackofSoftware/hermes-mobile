import Foundation
import ProjectDescription

// Debug-only server preset. Baked in at generate time from the environment so a
// developer can do `HERMES_DEFAULT_SERVER_URL=http://<tailnet-host>:9119 tuist generate`
// without committing their tailnet address/token. Empty by default.
let debugServerURL = ProcessInfo.processInfo.environment["HERMES_DEFAULT_SERVER_URL"] ?? ""

let project = Project(
  name: "HermesMobile",
  packages: [
    .local(path: "HermesKit"),
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
      ]),
      sources: ["HermesMobile/Sources/**"],
      dependencies: [
        .package(product: "HermesKit"),
      ],
      settings: .settings(
        configurations: [
          .debug(name: "Debug"),
          .release(name: "Release"),
        ]
      )
    ),
  ]
)
