// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "macos-cli",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        // Pure, framework-light logic that can be unit-tested hermetically
        // (no EventKit/Contacts/TCC prompts). The executable target depends on it.
        .target(
            name: "MacCLICore",
            path: "Sources/MacCLICore"
        ),
        .executableTarget(
            name: "macos-cli",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "MacCLICore",
            ],
            path: "Sources/macos-cli",
            swiftSettings: [
                .unsafeFlags([
                    "-framework", "EventKit",
                    "-framework", "Contacts",
                    "-framework", "CoreGraphics",
                    "-framework", "AppKit",
                    "-framework", "ApplicationServices",
                    "-framework", "Vision",
                    "-framework", "PDFKit",
                    "-framework", "CoreLocation",
                    "-framework", "IOBluetooth",
                ])
            ]
        ),
        // XCTest suite — canonical, runs under `swift test` when a full Xcode is present.
        .testTarget(
            name: "MacCLICoreTests",
            dependencies: ["MacCLICore"],
            path: "Tests/MacCLICoreTests"
        ),
        // Dependency-free mirror of the XCTest assertions, runnable on a
        // Command-Line-Tools-only toolchain where XCTest is unavailable:
        //   swift run MacCLICoreTestRunner
        .executableTarget(
            name: "MacCLICoreTestRunner",
            dependencies: ["MacCLICore"],
            path: "Sources/MacCLICoreTestRunner"
        ),
    ]
)
