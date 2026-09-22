// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "EmoLens",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "EmoLens", targets: ["EmoLens"]),
        .executable(name: "EmoLensDemo", targets: ["EmoLensDemo"]),
    ],
    targets: [
        .target(name: "EmoLensCore"),
        .executableTarget(name: "EmoLens", dependencies: ["EmoLensCore"]),
        .executableTarget(name: "EmoLensDemo"),
        .testTarget(name: "EmoLensCoreTests", dependencies: ["EmoLensCore"]),
    ]
)
