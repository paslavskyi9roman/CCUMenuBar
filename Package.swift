// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "CCUMenuBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "CCUMenuBar",
            path: "Sources/CCUMenuBar",
            resources: [
                .copy("Resources/ccu-statusline-bridge.sh")
            ]
        ),
        .testTarget(
            name: "CCUMenuBarTests",
            dependencies: ["CCUMenuBar"]
        )
    ],
    // Keep source compiling in the Swift 5 language mode (no new strict-
    // concurrency errors) — the tools-version bump to 6.0 is only needed so
    // SwiftPM auto-links the `Testing` module (import Testing) to the test
    // target; it isn't available under tools-version 5.9.
    swiftLanguageModes: [.v5]
)
