// swift-tools-version: 6.0
import PackageDescription

// A stand-in Mac for proving the phone's routing: offers three open apps and two automations,
// prints every Send-to change (SELECTION …) and what each dictation carries — target, send,
// whether the name was said, cleanup level, raw and sent text — and answers with realistic
// details ("Sent to Messages", "… isn't open on your Mac — copied instead"). Type
// "select com.apple.MobileSMS send" to change the choice on the "Mac". Run:
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
