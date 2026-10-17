// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "OhMyDiffCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "OhMyDiffCore", targets: ["OhMyDiffCore"]),
    ],
    targets: [
        .target(name: "OhMyDiffCore"),
        .testTarget(name: "OhMyDiffCoreTests", dependencies: ["OhMyDiffCore"]),
    ]
)
