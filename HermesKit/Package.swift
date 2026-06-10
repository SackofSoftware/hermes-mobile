// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "HermesKit",
  platforms: [
    .iOS(.v17),
    .macOS(.v14), // so `swift test` runs the reducer suite on the Mac without a simulator
  ],
  products: [
    .library(name: "HermesKit", targets: ["HermesKit"]),
  ],
  dependencies: [
    .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "1.15.0"),
    .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.4.0"),
  ],
  targets: [
    .target(
      name: "HermesKit",
      dependencies: [
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
        // DependenciesMacros provides @DependencyClient for the REST/WS/Keychain clients.
        .product(name: "DependenciesMacros", package: "swift-dependencies"),
      ]
    ),
    .testTarget(
      name: "HermesKitTests",
      // Transitive deps (ComposableArchitecture, etc.) come through HermesKit — do not relink.
      dependencies: ["HermesKit"]
    ),
  ]
)
