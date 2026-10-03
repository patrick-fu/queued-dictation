// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QueuedDictation",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DictationCore", targets: ["DictationCore"]),
        .executable(name: "QueuedDictation", targets: ["QueuedDictation"])
    ],
    targets: [
        .target(name: "DictationCore"),
        .executableTarget(name: "QueuedDictation", dependencies: ["DictationCore"]),
        .testTarget(name: "DictationCoreTests", dependencies: ["DictationCore"])
    ]
)
