// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CharmingEditor",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        // The reusable markdown editor: a SwiftUI view that renders and edits
        // Markdown with live syntax highlighting on macOS and iOS.
        .library(name: "CharmingEditor", targets: ["CharmingEditor"])
    ],
    dependencies: [
        .package(url: "https://github.com/tree-sitter/swift-tree-sitter", from: "0.8.0"),
        .package(
            url: "https://github.com/tree-sitter-grammars/tree-sitter-markdown",
            from: "0.5.3"),
    ],
    targets: [
        .target(
            name: "CharmingEditor",
            dependencies: [
                .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
                .product(name: "TreeSitterMarkdown", package: "tree-sitter-markdown"),
            ],
            path: "Sources/CharmingEditor"
        ),
        // The demo app lives in its own standalone package under `Example/`,
        // which imports this library as a dependency (see `Example/Package.swift`).
        .testTarget(
            name: "CharmingEditorTests",
            dependencies: ["CharmingEditor"],
            path: "Tests/CharmingEditorTests"
        ),
    ]
)
