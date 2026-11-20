// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "T3Bar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "T3Bar",
            path: "Sources/T3Bar",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "T3BarTests",
            dependencies: ["T3Bar"],
            path: "Tests/T3BarTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
