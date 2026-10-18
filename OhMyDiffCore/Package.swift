// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "OhMyDiffCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "OhMyDiffCore", targets: ["OhMyDiffCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/tree-sitter/swift-tree-sitter", from: "0.9.0"),
        .package(url: "https://github.com/alex-pinkus/tree-sitter-swift", exact: "0.7.4-with-generated-files"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-typescript", from: "0.23.2"),
        // Later releases only compile `scanner.c` when the manifest runs from the package directory,
        // which SwiftPM does not do, so these four are pinned to the last tags listing it explicitly.
        .package(url: "https://github.com/tree-sitter/tree-sitter-javascript", exact: "0.23.1"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-python", exact: "0.23.6"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-go", from: "0.25.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-rust", from: "0.24.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-json", from: "0.24.8"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-yaml", exact: "0.7.0"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-markdown", from: "0.5.3"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-css", exact: "0.23.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-html", from: "0.23.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-bash", from: "0.25.1"),
    ],
    targets: [
        .target(
            name: "OhMyDiffCore",
            dependencies: [
                .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
                .product(name: "TreeSitterSwift", package: "tree-sitter-swift"),
                .product(name: "TreeSitterTypeScript", package: "tree-sitter-typescript"),
                .product(name: "TreeSitterJavaScript", package: "tree-sitter-javascript"),
                .product(name: "TreeSitterPython", package: "tree-sitter-python"),
                .product(name: "TreeSitterGo", package: "tree-sitter-go"),
                .product(name: "TreeSitterRust", package: "tree-sitter-rust"),
                .product(name: "TreeSitterJSON", package: "tree-sitter-json"),
                .product(name: "TreeSitterYAML", package: "tree-sitter-yaml"),
                .product(name: "TreeSitterMarkdown", package: "tree-sitter-markdown"),
                .product(name: "TreeSitterCSS", package: "tree-sitter-css"),
                .product(name: "TreeSitterHTML", package: "tree-sitter-html"),
                .product(name: "TreeSitterBash", package: "tree-sitter-bash"),
            ],
            resources: [.copy("GitButler/gitbutler.json")]),
        .testTarget(name: "OhMyDiffCoreTests", dependencies: ["OhMyDiffCore"]),
    ]
)
