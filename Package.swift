// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KrakWhisper",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "KrakWhisper", targets: ["KrakWhisper"])
    ],
    dependencies: [
        .package(url: "https://github.com/exPHAT/SwiftWhisper.git", branch: "master")
    ],
    targets: [
        .target(
            name: "KrakWhisper",
            dependencies: [
                .product(name: "SwiftWhisper", package: "SwiftWhisper")
            ],
            path: "KrakWhisper/Sources"
        ),
        .testTarget(
            name: "KrakWhisperTests",
            dependencies: ["KrakWhisper"],
            path: "KrakWhisper/Tests"
        )
    ]
)
