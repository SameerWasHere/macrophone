// swift-tools-version: 6.0
import PackageDescription

// A stand-in Mac for proving the phone's routing: offers targets with voice prefixes (mpctl
// serve offers one plain "Default") and prints what each dictation carries — the text, the
// target and how it was picked (profileSource). Run:
//   cd iOS/scripts/route-sink && swift run route-sink --state /tmp/mp-ios2/sink
let package = Package(
    name: "route-sink",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../../Packages/MacrophoneKit")],
    targets: [
        .executableTarget(name: "route-sink", dependencies: [.product(name: "MacrophoneKit", package: "MacrophoneKit")],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
