import MacrophoneKit
import SwiftUI

// Settings as iOS's own Settings app draws it (Nov 1 2026, docs/DESIGN.md "Macrophone, as Apple
// would make it"): native inset-grouped lists, each row led by a white symbol on a small rounded
// square of one system colour, and the Mac as the banner at the top, where the Apple Account is.

/// The iOS Settings icon: a white symbol on a rounded square of one colour (29 pt at the default
/// text size, growing a little with it, as Settings' own do).
struct SettingsIcon: View {
    var symbol: String
    var color: Color
    var size: CGFloat = 29
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    var body: some View {
        let side = size * min(max(scale, 1), 1.5)
        Image(systemName: symbol)
            .font(.system(size: side * 0.55, weight: .medium))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.white)
            .frame(width: side, height: side)
            .background(AppIconShape().fill(color.gradient))
            .accessibilityHidden(true)
    }
}

/// Settings' switches are green, as an iPhone's own are; the accent stays blue for links, checks
/// and buttons.
struct SettingsSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration).toggleStyle(.switch).tint(Light.mint)
    }
}

extension ToggleStyle where Self == SettingsSwitchStyle {
    static var settings: SettingsSwitchStyle { SettingsSwitchStyle() }
}

/// A place's mark in a list: the app's own icon when the Mac sent one, else the place's glyph on
/// a Settings tile in its colour (Clipboard teal, Where I'm typing purple, an app blue).
struct PlaceIcon: View {
    var target: TargetRef
    var icon: Data?
    var size: CGFloat = 29

    var body: some View {
        if let img = IconCache.image(icon) {
            Image(uiImage: img).resizable().interpolation(.high).scaledToFit()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            SettingsIcon(symbol: TargetGlyph.symbol(for: target), color: TargetIcon.tint(target), size: size)
        }
    }
}

/// How the phone reaches the Mac, as a glyph: Wi-Fi at home, Apple's direct link nearby, the
/// Tailscale shield or the globe away (the same as the menu bar's route extra).
enum RouteGlyph {
    static func symbol(_ route: LinkRoute) -> String {
        switch route {
        case .homeNetwork: return "wifi"
        case .nearby: return "dot.radiowaves.left.and.right"
        case .tailscale: return "network.badge.shield.half.filled"
        case .internet: return "globe"
        }
    }

    /// The route's glyph only while it's connected (the last route outlives the connection).
    static func symbol(_ standing: MacStanding) -> String? {
        if case let .connected(route?) = standing { return symbol(route) }
        return nil
    }
}

/// Which Mac a name sounds like, for its glyph: an iMac, a Mac mini, a Mac Studio, a Mac Pro, else
/// a laptop (most of them are).
enum MacGlyph {
    static func symbol(for name: String?) -> String {
        let n = (name ?? "").lowercased()
        if n.contains("imac") { return "desktopcomputer" }
        if n.contains("mac mini") || n.contains("macmini") { return "macmini" }
        if n.contains("studio") { return "macstudio" }
        if n.contains("mac pro") { return "macpro.gen3" }
        return "laptopcomputer"
    }
}

/// The Mac at the top of Settings, as the Apple Account sits at the top of an iPhone's: a big
/// glyph on a round plate, the name, and how it's connected (the route's glyph and words).
struct MacBanner: View {
    var name: String
    var status: String
    var routeSymbol: String?
    var paired = true
    /// Big on the banner, bigger as a page's header.
    var plate: CGFloat = 60

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: paired ? MacGlyph.symbol(for: name) : "laptopcomputer")
                .font(.system(size: plate * 0.44, weight: .regular))
                .foregroundStyle(.white)
                .frame(width: plate, height: plate)
                .background(Circle().fill(paired ? Light.cyan.gradient : Color(uiColor: .systemGray).gradient))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Ink.ink)
                    .fixedSize(horizontal: false, vertical: true)
                let route = routeSymbol.map { Text(Image(systemName: $0)) + Text(" ") } ?? Text("")
                (route + Text(status))
                    .font(.subheadline)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.leading)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

/// A page's header, centred over its list: the Mac's glyph, its name, how it stands (the Mac's
/// own page, as an iPhone shows a device's).
struct MacPageHeader: View {
    var name: String
    var status: String
    var routeSymbol: String?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: MacGlyph.symbol(for: name))
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(.white)
                .frame(width: 80, height: 80)
                .background(Circle().fill(Light.cyan.gradient))
                .accessibilityHidden(true)
            Text(name)
                .font(.title2.weight(.bold))
                .foregroundStyle(Ink.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 5) {
                if let routeSymbol { Image(systemName: routeSymbol).accessibilityHidden(true) }
                Text(status)
            }
            .font(.subheadline)
            .foregroundStyle(Ink.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
