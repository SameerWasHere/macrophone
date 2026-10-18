#if DEBUG
import SwiftUI
import WidgetKit

/// MACROPHONE_WIDGET_SHOT=<dir>: the Watch widget drawn at its small and medium sizes to PNGs
/// (the home screen can't be driven headless), with the app's current four apps.
enum DebugWidgetShot {
    @MainActor static func run(to dir: String) {
        let apps = WidgetApp.load()
        let entry = WatchEntry(date: .now, apps: apps.isEmpty ? WatchProvider.sample : apps)
        for (name, family, size) in [("small", WidgetFamily.systemSmall, CGSize(width: 170, height: 170)),
                                     ("medium", WidgetFamily.systemMedium, CGSize(width: 364, height: 170))] {
            let view = ZStack { WatchWidgetBackground(); WatchWidgetView(entry: entry, familyOverride: family) }
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            let r = ImageRenderer(content: view)
            r.scale = 3
            if let img = r.uiImage, let data = img.pngData() {
                try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("widget-\(name).png"))
            }
        }
    }
}
#endif
