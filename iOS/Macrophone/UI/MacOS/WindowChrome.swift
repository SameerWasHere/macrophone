import SwiftUI

// The watched window as a macOS window (Nov 1 2026): a title bar with the traffic lights — red
// closes the window on the Mac (asked first), yellow minimizes it, green fills the screen and
// back — the window's name in the middle (a tap lists its other windows), toolbar items at the
// right, Tahoe's corners and a window's shadow. iPadOS 26 put the same three lights on iPad
// windows; on a phone they do what they say to the Mac's own window.

/// The three lights. A light without an action is the grey of a window in the background.
struct TrafficLights: View {
    var onClose: (() -> Void)?
    var onMinimize: (() -> Void)?
    var onZoom: (() -> Void)?
    /// Zoomed: the green light's glyph turns to "back to how it was".
    var zoomed = false
    /// Drawn lit but not buttons: a picture of a window (the desktop's card), which is itself the
    /// button — the lights in colour, as on the window in front, taking no touch of their own.
    var decorative = false
    /// The glyphs inside the lights, which a Mac shows on hover; a touch shows them while held.
    @State private var showGlyphs = false

    var body: some View {
        if decorative {
            HStack(spacing: MacOSLook.lightGap) {
                ForEach([MacOSLook.close, MacOSLook.minimize, MacOSLook.zoom], id: \.self) { c in
                    Circle().fill(c)
                        .overlay(Circle().strokeBorder(MacOSLook.rim(c), lineWidth: 0.5))
                        .frame(width: MacOSLook.lightSize, height: MacOSLook.lightSize)
                }
            }
            .accessibilityHidden(true)
        } else {
            lights
        }
    }

    private var lights: some View {
        HStack(spacing: 0) {
            light(MacOSLook.close, glyph: "xmark", name: "Close Window", action: onClose, id: "window-close")
            light(MacOSLook.minimize, glyph: "minus", name: "Minimize", action: onMinimize, id: "window-minimize")
            light(MacOSLook.zoom, glyph: zoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                  name: zoomed ? "Back to How It Was" : "Fill the Screen", action: onZoom, id: "window-zoom")
        }
    }

    private func light(_ color: Color, glyph: String, name: String, action: (() -> Void)?, id: String) -> some View {
        Button { action?() } label: {
            ZStack {
                Circle()
                    .fill(action == nil ? Color.adaptive(light: Color(white: 0.84), dark: Color(white: 0.32)) : color)
                    .overlay(Circle().strokeBorder(action == nil ? Color.clear : MacOSLook.rim(color), lineWidth: 0.5))
                if action != nil {
                    Image(systemName: glyph)
                        .font(.system(size: 7, weight: .black))
                        .foregroundStyle(Color.black.opacity(0.55))
                        .opacity(showGlyphs ? 1 : 0)
                }
            }
            .frame(width: MacOSLook.lightSize, height: MacOSLook.lightSize)
            // Each light is a finger's width to hit, though it draws at a Mac's twelve points.
            .frame(width: MacOSLook.lightSize + MacOSLook.lightGap + 8, height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(LightPress(showGlyphs: $showGlyphs))
        .disabled(action == nil)
        .accessibilityLabel(name)
        .accessibilityIdentifier(id)
    }
}

/// A light pressed: every light shows its glyph, as the group does under a Mac's pointer.
private struct LightPress: ButtonStyle {
    @Binding var showGlyphs: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? -0.12 : 0)
            .onChange(of: configuration.isPressed) { _, pressed in
                withAnimation(.easeOut(duration: pressed ? 0.08 : 0.4)) { showGlyphs = pressed }
            }
    }
}

/// A macOS window round some content: the title bar, then the content, clipped to the window's
/// corners with its edge and its shadow.
struct MacWindowFrame<Title: View, Trailing: View, Content: View>: View {
    var onClose: (() -> Void)?
    var onMinimize: (() -> Void)?
    var onZoom: (() -> Void)?
    var zoomed = false
    /// Drawn as the window in front (lit lights, a deeper shadow) or behind (grey lights).
    var active = true
    /// A picture of a window (the desktop's card): lit lights that take no touch, the title after
    /// them rather than in the middle of the bar (a window with an item at its trailing end, as a
    /// Mac's unified toolbar sets it).
    var decorative = false
    /// The bar's own lights (a decorative frame round a picture of a window that has its own title
    /// bar and lights leaves them out: two sets, one under the other, read as two windows).
    var lights = true
    var barHeight: CGFloat = 34
    @ViewBuilder var title: () -> Title
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: MacOSLook.window, style: .continuous)
        VStack(spacing: 0) {
            Group {
                if decorative {
                    HStack(spacing: 10) {
                        if lights { TrafficLights(decorative: true) }
                        title()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        trailing()
                    }
                    .padding(.leading, 12)
                    .padding(.trailing, 5)
                } else {
                    ZStack {
                        // The title in the middle of the whole bar, as a Mac centres it.
                        title()
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 96)
                        HStack(spacing: 0) {
                            TrafficLights(onClose: active ? onClose : nil, onMinimize: active ? onMinimize : nil,
                                          onZoom: active ? onZoom : nil, zoomed: zoomed)
                                .padding(.leading, 4)
                            Spacer(minLength: 0)
                            trailing()
                                .padding(.trailing, 8)
                        }
                    }
                }
            }
            .frame(height: barHeight)
            .background(.bar)
            .overlay(alignment: .bottom) { Rectangle().fill(Ink.line).frame(height: 0.5) }
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(scheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(scheme == .dark ? (active ? 0.55 : 0.35) : (active ? 0.22 : 0.12)),
                radius: active ? 22 : 12, y: active ? 12 : 6)
    }
}

/// A window's title: the name, a chevron when it's a menu (the window's others), dimmed when the
/// window isn't live.
struct MacWindowTitle: View {
    var name: String
    var detail: String?
    var live = true
    var menu = false

    var body: some View {
        HStack(spacing: 4) {
            Text(name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(live ? Ink.ink : Ink.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let detail {
                Text(detail).font(.system(size: 13)).foregroundStyle(Ink.tertiary).lineLimit(1)
            }
            if menu {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Ink.tertiary)
            }
        }
    }
}

/// A toolbar item in a window's title bar: a glyph, borderless, as a Mac draws one.
struct MacToolbarButtonStyle: ButtonStyle {
    var on = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(on ? Light.cyan : Ink.secondary)
            .frame(width: 32, height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(configuration.isPressed ? Ink.ink.opacity(0.12) : (on ? Light.cyan.opacity(0.14) : .clear)))
            .contentShape(Rectangle())
    }
}
