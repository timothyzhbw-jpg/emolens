// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "EmoLens",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "EmoLens", targets: ["EmoLens"])],
    targets: [
        .target(name: "EmoLensCore"),
        .executableTarget(name: "EmoLens", dependencies: ["EmoLensCore"]),
        .testTarget(name: "EmoLensCoreTests", dependencies: ["EmoLensCore"]),
    ]
)
