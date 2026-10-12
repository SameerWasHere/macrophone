// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacrophoneKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MacrophoneKit", targets: ["MacrophoneKit"]),
        .executable(name: "mpctl", targets: ["mpctl"]),
    ],
    targets: [
        .target(name: "MacrophoneKit", swiftSettings: [.swiftLanguageMode(.v5)]),
        // The protocol proof: pairs and exchanges dictations with no UI on either side.
        .executableTarget(name: "mpctl", dependencies: ["MacrophoneKit"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "MacrophoneKitTests", dependencies: ["MacrophoneKit"],
                    // The cleanup test set is read by `mpctl cleanup-eval`, not bundled.
                    exclude: ["CleanupSamples.json"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
