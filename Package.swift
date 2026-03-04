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
        .package(url: "https://github.com/exPHAT/SwiftWhisper.git", from: "1.2.0"),
        .package(url: "https://github.com/ggerganov/llama.cpp.git", revision: "b6d6c5289f1c9c677657c380591201ddb210b649")
    ],
    targets: [
        .target(
            name: "KrakWhisper",
            dependencies: [
                .product(name: "SwiftWhisper", package: "SwiftWhisper"),
                .product(name: "llama", package: "llama.cpp")
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
