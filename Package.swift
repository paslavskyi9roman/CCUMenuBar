// swift-tools-version:5.9
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
    ]
)
