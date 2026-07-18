// swift-tools-version: 6.0
import PackageDescription

// A standalone package that consumes CharmingEditor as a dependency, the same
// way a real app would, except the dependency is resolved from the parent
// directory instead of a Git URL. Swap the `.package(path:)` line below for a
// `.package(url:from:)` to depend on a published release.
let package = Package(
    name: "Example",
    platforms: [.macOS(.v14), .iOS(.v18)],
    dependencies: [
        .package(name: "CharmingEditor", path: "..")
    ],
    targets: [
        .executableTarget(
            name: "Example",
            dependencies: [
                .product(name: "CharmingEditor", package: "CharmingEditor")
            ],
            path: "Sources/Example"
        )
    ]
)
