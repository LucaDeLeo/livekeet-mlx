// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "livekeet-mlx",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LivekeetCore", targets: ["LivekeetCore"]),
        .executable(name: "livekeet", targets: ["livekeet"]),
        .executable(name: "LivekeetApp", targets: ["LivekeetApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", branch: "main"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0"),
    ],
    targets: [
        .target(
            name: "LivekeetCore",
            dependencies: [
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "MLXAudioVAD", package: "mlx-audio-swift"),
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "TOMLKit", package: "TOMLKit"),
            ]
        ),
        .executableTarget(
            name: "livekeet",
            dependencies: [
                "LivekeetCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "LivekeetApp",
            dependencies: ["LivekeetCore"]
        ),
    ]
)
