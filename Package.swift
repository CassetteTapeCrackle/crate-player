// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Crate",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CrateCore"),
        .testTarget(name: "CrateCoreTests", dependencies: ["CrateCore"]),
    ]
)
