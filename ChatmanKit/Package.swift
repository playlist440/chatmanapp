// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ChatmanKit",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v26),
        .watchOS(.v26),
        // Only so the package can be type-checked with `swift build` outside Xcode.
        // Nothing here is iOS-specific, so this costs nothing.
        .macOS(.v26)
    ],
    products: [
        .library(name: "ChatmanKit", targets: ["ChatmanKit"])
    ],
    targets: [
        // Deliberately no dependencies. Everything here is Foundation and
        // SwiftData, which keeps the watch binary small and the build simple.
        .target(name: "ChatmanKit", resources: [.process("Resources")]),
        .testTarget(name: "ChatmanKitTests", dependencies: ["ChatmanKit"])
    ]
)
