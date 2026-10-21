// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LostFoundCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "LostFoundCore", targets: ["LostFoundCore"])],
    targets: [
        .target(name: "LostFoundCore", path: "Lost&Found/Core"),
        .testTarget(name: "LostFoundCoreTests", dependencies: ["LostFoundCore"], path: "Tests")
    ]
)
