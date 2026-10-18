// Asks this Mac to draw an app's icon the way the system does — for a .icon bundle on macOS 26+,
// that is the real Liquid Glass rendering (specular, refraction, translucency, the squircle).
//
//   xcrun swiftc -parse-as-library -target arm64-apple-macos14.0 scripts/icon-system-render.swift -o /tmp/icon-system-render
//   /tmp/icon-system-render <Some.app> <out.png> [px] [light|dark]
//
// Used by scripts/icon-render-check.sh on the stub bundles it compiles from each .icon.

import AppKit
import UniformTypeIdentifiers

@main
struct Main {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 3 else { print("usage: icon-system-render <app> <out.png> [px] [light|dark]"); exit(2) }
        let px = args.count > 3 ? Int(args[3]) ?? 1024 : 1024
        let appearance = NSAppearance(named: args.count > 4 && args[4] == "dark" ? .darkAqua : .aqua)!
        let icon = NSWorkspace.shared.icon(forFile: args[1])
        icon.size = NSSize(width: px, height: px)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        appearance.performAsCurrentDrawingAppearance {
            icon.draw(in: NSRect(x: 0, y: 0, width: px, height: px), from: .zero, operation: .sourceOver, fraction: 1)
        }
        NSGraphicsContext.restoreGraphicsState()
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
        print("wrote \(args[2])")
    }
}
