// swift-tools-version:5.10
import PackageDescription

// Platform-independent core of the app: API models, the server protocol, the
// REST/WebSocket clients and the sync math. Builds and tests on Linux too, so
// the logic can be checked without a device.
let package = Package(
    name: "MusicSynqKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MusicSynqKit", targets: ["MusicSynqKit"]),
    ],
    targets: [
        .target(name: "MusicSynqKit"),
        .testTarget(name: "MusicSynqKitTests", dependencies: ["MusicSynqKit"]),
    ],
    swiftLanguageVersions: [.v5]
)
