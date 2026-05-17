// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "apple-cli",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "apple-cli",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/apple-cli",
            swiftSettings: [
                .unsafeFlags([
                    "-framework", "EventKit",
                    "-framework", "Contacts",
                    "-framework", "CoreGraphics",
                    "-framework", "AppKit",
                    "-framework", "ApplicationServices",
                ])
            ]
        ),
    ]
)
