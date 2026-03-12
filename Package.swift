// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BackToUSSRCore",
    platforms: [
        .macOS(.v11),
    ],
    products: [
        .library(
            name: "BackToUSSRCore",
            targets: ["BackToUSSRCore"]
        ),
    ],
    targets: [
        .target(
            name: "BackToUSSRCore",
            path: "src/Core"
        ),
        .testTarget(
            name: "BackToUSSRCoreTests",
            dependencies: ["BackToUSSRCore"]
        ),
    ]
)
