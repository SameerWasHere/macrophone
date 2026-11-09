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
    /// Dimmed while it can't act (the Mac connecting again), as a Mac greys a disabled extra.
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: MacOSLook.extraGlyph, weight: .semibold))
            // One ink, as a Mac's template extras are (Nov 8 2026): hierarchical drew the clock's
            // face grey beside a solid display and gear.
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(on ? Light.cyan : Ink.ink)
            .opacity(enabled ? 1 : 0.35)
            .animation(.easeOut(duration: 0.2), value: enabled)
            .frame(minWidth: 44, minHeight: MacOSLook.menuBar)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(configuration.isPressed ? Ink.ink.opacity(0.14) : .clear)
                .padding(.vertical, 4))
            .contentShape(Rectangle())
    }
}

/// The menu bar's left item pressed: the same rounded highlight as an extra's.
struct MenuBarNameStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        // The bar's full height is the button's (a finger's 44 pt — and the size VoiceOver reads).
        configuration.label
            .frame(minHeight: MacOSLook.menuBar)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(configuration.isPressed ? Ink.ink.opacity(0.14) : .clear)
                .padding(.vertical, 4))
    }
}
