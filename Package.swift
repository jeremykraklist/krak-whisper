// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KrakWhisper",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "KrakWhisper", targets: ["KrakWhisper"]),
        .executable(name: "KrakWhisperMac", targets: ["KrakWhisperMac"]),
        .library(name: "KrakWhisperKeyboard", targets: ["KrakWhisperKeyboard"])
    ],
    dependencies: [
        .package(url: "https://github.com/exPHAT/SwiftWhisper.git", from: "1.2.0")
    ],
    targets: [
        .target(
            name: "KrakWhisper",
            dependencies: [
                .product(name: "SwiftWhisper", package: "SwiftWhisper")
            ],
            path: "KrakWhisper/Sources"
        ),
        .target(
            name: "KrakWhisperKeyboard",
            dependencies: [
                "KrakWhisper",
                .product(name: "SwiftWhisper", package: "SwiftWhisper")
            ],
            path: "KrakWhisperKeyboard",
            exclude: ["Info.plist", "KrakWhisperKeyboard.entitlements"]
        ),
        .executableTarget(
            name: "KrakWhisperMac",
            dependencies: ["KrakWhisper"],
            path: "KrakWhisperMac/Sources"
        ),
        .testTarget(
            name: "KrakWhisperTests",
            dependencies: ["KrakWhisper"],
            path: "KrakWhisper/Tests"
        )
    ]
)
