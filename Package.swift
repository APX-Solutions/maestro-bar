// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "MaestroBar",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(name: "MaestroBar", path: "Sources/MaestroBar")
    ]
)
