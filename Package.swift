// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacFrameGen",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "MacFrameGen",
            path: "Sources/MacFrameGen",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
