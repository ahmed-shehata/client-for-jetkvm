// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WebRTC",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "WebRTC", targets: ["WebRTC"]),
    ],
    targets: [
        .binaryTarget(name: "WebRTC", path: "WebRTC.xcframework"),
    ]
)
