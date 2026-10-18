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
                .containerBackground(for: .widget) { WatchWidgetBackground() }
        }
        .configurationDisplayName("Watch on Mac")
        .description("Your Mac's open apps, a tap from watching their windows.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

private enum WidgetInk {
    static let ground = Color(red: 0.020, green: 0.024, blue: 0.051)
    static let raised = Color(red: 0.075, green: 0.082, blue: 0.125)
    static let ink = Color(red: 0.957, green: 0.949, blue: 0.980)
    static let secondary = Color(red: 0.788, green: 0.784, blue: 0.812)
    static let tertiary = Color(red: 0.620, green: 0.616, blue: 0.647)
    static let ember = Color(red: 0.914, green: 0.443, blue: 0.310)
    static let cyan = Color(red: 0.345, green: 0.725, blue: 0.871)
    static let violet = Color(red: 0.604, green: 0.525, blue: 0.902)
    static let mint = Color(red: 0.369, green: 0.839, blue: 0.635)
}

/// The app's ground with the Thread's light low across it: violet to cyan to mint, soft.
struct WatchWidgetBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [WidgetInk.raised, WidgetInk.ground], startPoint: .top, endPoint: .bottom)
            LinearGradient(colors: [WidgetInk.violet, WidgetInk.cyan, WidgetInk.mint], startPoint: .leading, endPoint: .trailing)
                .frame(height: 70)
                .blur(radius: 34)
                .opacity(0.32)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .offset(y: 26)
        }
    }
}

struct WatchWidgetView: View {
    let entry: WatchEntry
    /// Set only by the debug renderer (a view can't set the widget family itself).
    var familyOverride: WidgetFamily? = nil
    @Environment(\.widgetFamily) private var widgetFamily
    private var family: WidgetFamily { familyOverride ?? widgetFamily }

    var body: some View {
        Group {
            if entry.apps.isEmpty {
                empty
            } else if family == .systemMedium {
                medium
            } else {
                small
            }
        }
        .padding(12)
    }

    // MARK: Faces

    /// Small: four tiles filling the face, two by two, under the kicker.
    private var small: some View {
        let apps = Array(entry.apps.prefix(WidgetApp.limit))
        return VStack(alignment: .leading, spacing: 8) {
            kicker
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow { cell(apps, 0); cell(apps, 1) }
                GridRow { cell(apps, 2); cell(apps, 3) }
            }
        }
    }

    /// Medium: four tiles in a row, each with its name.
    private var medium: some View {
        VStack(alignment: .leading, spacing: 8) {
            kicker
            HStack(spacing: 8) {
                ForEach(Array(entry.apps.prefix(WidgetApp.limit).enumerated()), id: \.offset) { _, app in
                    tile(app, named: true)
                }
                ForEach(0..<max(0, WidgetApp.limit - entry.apps.count), id: \.self) { _ in placeholderTile }
            }
        }
    }

    private var kicker: some View {
        HStack(spacing: 5) {
            Image(systemName: "eye.fill").font(.system(size: 9, weight: .bold))
            Text("WATCH").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1.2)
            Spacer(minLength: 0)
            if entry.apps.contains(where: \.needsYou) {
                Circle().fill(WidgetInk.ember).frame(width: 6, height: 6)
            }
        }
        .foregroundStyle(WidgetInk.tertiary)
        .accessibilityHidden(true)
    }

    @ViewBuilder private func cell(_ apps: [WidgetApp], _ i: Int) -> some View {
        if apps.indices.contains(i) { tile(apps[i], named: false) } else { placeholderTile }
    }

    // MARK: Tiles

    /// One app on a pane of glass: its icon, the ember mark when a chat there answered you.
    private func tile(_ app: WidgetApp, named: Bool) -> some View {
        Link(destination: app.url) {
            VStack(spacing: 5) {
                icon(app)
                    .overlay(alignment: .topTrailing) {
                        if app.needsYou {
                            Circle().fill(WidgetInk.ember).frame(width: 11, height: 11)
                                .overlay(Circle().stroke(WidgetInk.ground, lineWidth: 2))
                                .offset(x: 3, y: -3)
                        }
                    }
                if named {
                    Text(app.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(WidgetInk.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(pane)
        }
        .accessibilityLabel("Watch \(app.name)" + (app.needsYou ? ", it answered you" : ""))
    }

    private var placeholderTile: some View {
        pane.opacity(0.45).frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityHidden(true)
    }

    /// The glass a tile sits on: a lit top edge over a faint fill.
    private var pane: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(WidgetInk.ink.opacity(0.07))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [WidgetInk.ink.opacity(0.28), WidgetInk.ink.opacity(0.05)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
            )
    }

    @ViewBuilder private func icon(_ app: WidgetApp) -> some View {
        let size: CGFloat = family == .systemMedium ? 44 : 40
        if let d = app.icon, let img = UIImage(data: d) {
            FullColorIcon(image: img)
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1.5)
        } else {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(WidgetInk.ink.opacity(0.12))
                .overlay(Text(String(app.name.prefix(1))).font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(WidgetInk.ink))
                .frame(width: size, height: size)
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            kicker
            Spacer(minLength: 0)
            Image(systemName: "macwindow").font(.system(size: 22, weight: .semibold)).foregroundStyle(WidgetInk.cyan)
            Text("Open Macrophone to see your Mac's apps here")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(WidgetInk.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetURL(URL(string: "macrophone://open"))
    }
}

/// An app icon that keeps its colours on a tinted home screen (iOS 18+).
private struct FullColorIcon: View {
    let image: UIImage
    var body: some View {
        if #available(iOS 18.0, *) {
            Image(uiImage: image).resizable().widgetAccentedRenderingMode(.fullColor).aspectRatio(contentMode: .fit)
        } else {
            Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
        }
    }
}
