import SwiftUI

// The menu bar (Nov 1 2026): a slim strip across the top of the desktop, under the iPhone's own
// status bar — transparent over the wallpaper, as Tahoe's is. On the left the bold name a Mac
// puts there: your Mac's at rest, the watched app's while a window shows (its menu is the Window
// menu, where macOS keeps the frontmost app's). On the right, monochrome menu extras: the way
// it's connected, Control Center (the Mac's sound, screen and music), History, Settings — or,
// watching, Sound, Control Center and Done. On the Duo's cover and the inner screen on its side
// the same items stand in the system's vertical bar instead.

struct MacMenuBar<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 2) {
            leading()
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 10)
        .frame(height: MacOSLook.menuBar)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }
}

/// A menu extra: a glyph, borderless, as the right of a Mac's menu bar has them; pressed, the
/// rounded highlight a Mac draws behind an open menu extra.
struct MenuExtraStyle: ButtonStyle {
    var on = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: MacOSLook.extraGlyph, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(on ? Light.cyan : Ink.ink)
            .frame(minWidth: 36, minHeight: MacOSLook.menuBar)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(configuration.isPressed ? Ink.ink.opacity(0.14) : .clear)
                .padding(.vertical, 4))
            .contentShape(Rectangle())
    }
}

/// The bold name at the menu bar's left: a symbol, the name, and a chevron when it opens a menu.
struct MenuBarName: View {
    var symbol: String?
    var name: String
    var detail: String?
    var chevron = true

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).accessibilityHidden(true)
            }
            Text(name).font(.system(size: 15, weight: .bold)).lineLimit(1)
            if let detail {
                Text(detail).font(.system(size: 13, weight: .regular)).foregroundStyle(Ink.secondary).lineLimit(1)
            }
            if chevron {
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(Ink.secondary)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(Ink.ink)
        .padding(.horizontal, 8)
        .frame(minHeight: MacOSLook.menuBar)
        .contentShape(Rectangle())
    }
}

/// The menu bar's left item pressed: the same rounded highlight as an extra's.
struct MenuBarNameStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(configuration.isPressed ? Ink.ink.opacity(0.14) : .clear)
                .padding(.vertical, 4))
    }
}
