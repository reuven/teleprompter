// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Teleprompter",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.9.0"),
        .package(url: "https://github.com/x-sheep/swift-property-based.git", from: "2.0.1"),
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
            dependencies: [
                "TeleprompterCore",
                .product(name: "PropertyBased", package: "swift-property-based"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
