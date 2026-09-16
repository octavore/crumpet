// swift-tools-version: 6.0
import PackageDescription

// A standalone package that consumes Crumpet as a dependency, the same
// way a real app would, except the dependency is resolved from the parent
// directory instead of a Git URL. Swap the `.package(path:)` line below for a
// `.package(url:from:)` to depend on a published release.
let package = Package(
  name: "Example",
  platforms: [.macOS(.v15), .iOS(.v18)],
  dependencies: [
    .package(name: "Crumpet", path: "..")
  ],
  targets: [
    .executableTarget(
      name: "Example",
      dependencies: [
        .product(name: "Crumpet", package: "Crumpet")
      ],
      path: "Sources/Example"
    )
  ]
)
