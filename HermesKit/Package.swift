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
    // GRDB-backed SQLite persistence for the non-authoritative chat snapshot cache. Kept
    // strictly behind `ChatSnapshotClient` (no reactive `@FetchAll`) — see the plan.
    .package(url: "https://github.com/pointfreeco/sqlite-data", from: "1.0.0"),
  ],
  targets: [
    .target(
      name: "HermesKit",
      dependencies: [
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
        // DependenciesMacros provides @DependencyClient for the REST/WS/Keychain clients.
        .product(name: "DependenciesMacros", package: "swift-dependencies"),
        // SQLiteData re-exports GRDB; the snapshot store uses a private DatabaseQueue.
        .product(name: "SQLiteData", package: "sqlite-data"),
      ]
    ),
    .testTarget(
      name: "HermesKitTests",
      // Transitive deps (ComposableArchitecture, etc.) come through HermesKit — do not relink.
      dependencies: ["HermesKit"]
    ),
  ]
)
