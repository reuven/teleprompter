// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Teleprompter",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.9.0")
    ],
    targets: [
        .target(
            name: "TeleprompterCore",
            dependencies: [.product(name: "Markdown", package: "swift-markdown")]
        ),
        .executableTarget(
            name: "Teleprompter",
            dependencies: ["TeleprompterCore"]
        ),
        .testTarget(
            name: "TeleprompterCoreTests",
            dependencies: ["TeleprompterCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
