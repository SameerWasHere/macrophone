import SwiftUI
import UIKit
import WidgetKit

// The Watch widget (Oct 18 2026): up to four of the Mac's open apps — the ones used most recently —
// each a tap away from watching its window. Small: a 2 × 2 grid; medium: a row of four with their
// names. An app whose chat answered you wears the ember mark, as in Send to. Nothing until the phone
// has heard from a Mac: then it says so and opens the app.

struct WatchEntry: TimelineEntry {
    let date: Date
    let apps: [WidgetApp]
}

struct WatchProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchEntry { WatchEntry(date: .now, apps: Self.sample) }

    func getSnapshot(in context: Context, completion: @escaping (WatchEntry) -> Void) {
        let apps = WidgetApp.load()
        completion(WatchEntry(date: .now, apps: apps.isEmpty && context.isPreview ? Self.sample : apps))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchEntry>) -> Void) {
        // The app reloads it whenever the list changes; nothing to tick here.
        completion(Timeline(entries: [WatchEntry(date: .now, apps: WidgetApp.load())], policy: .never))
    }

    static let sample = [
        WidgetApp(id: "app:com.apple.Terminal#", name: "Terminal", icon: nil, needsYou: true),
        WidgetApp(id: "app:com.anthropic.claudefordesktop#", name: "Claude", icon: nil, needsYou: false),
        WidgetApp(id: "app:com.apple.MobileSMS#", name: "Messages", icon: nil, needsYou: false),
        WidgetApp(id: "app:com.todesktop.cursor#", name: "Cursor", icon: nil, needsYou: false),
    ]
}

struct WatchAppsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetApp.kind, provider: WatchProvider()) { entry in
            WatchWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    LinearGradient(colors: [Color(red: 0.075, green: 0.082, blue: 0.125), Color(red: 0.020, green: 0.024, blue: 0.051)],
                                   startPoint: .top, endPoint: .bottom)
                }
        }
        .configurationDisplayName("Watch on Mac")
        .description("Your Mac's open apps, a tap from watching their windows.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct WatchWidgetView: View {
    let entry: WatchEntry
    @Environment(\.widgetFamily) private var family

    private static let ink = Color(red: 0.957, green: 0.949, blue: 0.980)
    private static let tertiary = Color(red: 0.620, green: 0.616, blue: 0.647)
    private static let ember = Color(red: 0.914, green: 0.443, blue: 0.310)
    private static let cyan = Color(red: 0.345, green: 0.725, blue: 0.871)

    var body: some View {
        if entry.apps.isEmpty {
            empty
        } else if family == .systemMedium {
            VStack(alignment: .leading, spacing: 10) {
                kicker
                HStack(alignment: .top, spacing: 0) {
                    ForEach(entry.apps.prefix(WidgetApp.limit), id: \.id) { app in
                        tile(app, size: 46, named: true).frame(maxWidth: .infinity)
                    }
                }
                Spacer(minLength: 0)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                kicker
                let apps = Array(entry.apps.prefix(WidgetApp.limit))
                Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow { cell(apps, 0); cell(apps, 1) }
                    GridRow { cell(apps, 2); cell(apps, 3) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var kicker: some View {
        HStack(spacing: 5) {
            Image(systemName: "eye").font(.system(size: 10, weight: .bold))
            Text("WATCH").font(.system(size: 11, weight: .semibold)).tracking(0.6)
        }
        .foregroundStyle(Self.tertiary)
        .accessibilityHidden(true)
    }

    @ViewBuilder private func cell(_ apps: [WidgetApp], _ i: Int) -> some View {
        if apps.indices.contains(i) { tile(apps[i], size: 44, named: false) } else { Color.clear.frame(width: 44, height: 44) }
    }

    private func tile(_ app: WidgetApp, size: CGFloat, named: Bool) -> some View {
        Link(destination: app.url) {
            VStack(spacing: 6) {
                icon(app, size: size)
                    .overlay(alignment: .topTrailing) {
                        if app.needsYou {
                            Circle().fill(Self.ember).frame(width: 12, height: 12)
                                .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 2))
                                .offset(x: 4, y: -4)
                        }
                    }
                if named {
                    Text(app.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Self.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
        }
        .accessibilityLabel("Watch \(app.name)" + (app.needsYou ? ", it answered you" : ""))
    }

    @ViewBuilder private func icon(_ app: WidgetApp, size: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
        if let d = app.icon, let img = UIImage(data: d) {
            Image(uiImage: img)
                .resizable()
                .widgetAccentedRenderingMode(.fullColor)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            shape.fill(Self.ink.opacity(0.1))
                .overlay(Text(String(app.name.prefix(1))).font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(Self.ink))
                .frame(width: size, height: size)
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            kicker
            Spacer(minLength: 0)
            Image(systemName: "macwindow").font(.system(size: 22, weight: .semibold)).foregroundStyle(Self.cyan)
            Text("Open Macrophone to see your Mac's apps here")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Self.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(URL(string: "macrophone://open"))
    }
}
