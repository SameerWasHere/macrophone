import AppKit
import SwiftUI

// Macrophone's tokens on the Mac (docs/DESIGN.md › "The Mac app as Apple would make it", Nov 7
// 2026). The old names stay — every pane, the popup and the menu use them — but they are Apple's
// own colours now, so every window follows light and dark (General › Appearance). The shared
// pieces a pane is built from (PanePage, PaneSection, PlateRow, SettingsIcon…) are MacLook.swift.

enum Ink {
    /// The window's ground (windowBackgroundColor).
    static let ground = Color(nsColor: .windowBackgroundColor)
    /// A box on the ground: a list, a text area, a grouped form's rows.
    static let raised = Color(nsColor: .controlBackgroundColor)
    /// A well inside a box (code, the shortcut recorder).
    static let sunk = Color(nsColor: .textBackgroundColor)
    static let ink = Color(nsColor: .labelColor)
    static let secondary = Color(nsColor: .secondaryLabelColor)
    /// Quiet words: between secondaryLabel and tertiaryLabel, so a description still reads; as
    /// secondaryLabel under Increase Contrast.
    static let tertiary = Color(nsColor: NSColor(name: "MacrophoneTertiary") { a in
        if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast { return .secondaryLabelColor }
        return a.isDark ? NSColor(white: 1, alpha: 0.45) : NSColor(white: 0, alpha: 0.45)
    })
    static let line = Color(nsColor: .separatorColor)
    static let lineStrong = Color(nsColor: .gridColor)
    static let lineHeavy = Color(nsColor: .tertiaryLabelColor)

    static let groundNS = NSColor.windowBackgroundColor

    /// A control's rest fill (the shortcut recorder).
    static let well = Color(nsColor: .controlBackgroundColor)
    /// The keyboard focus ring.
    static let focus = Color(nsColor: .keyboardFocusIndicatorColor)
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua, .vibrantDark, .vibrantLight, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua])
        .map { [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua].contains($0) } ?? false }
}

/// One radius per layer: plates 10 (a grouped form's), the controls on them 6, cards 12, sheets 16.
enum Radius {
    static let plate: CGFloat = 10
    static let control: CGFloat = 6
    static let card: CGFloat = 12
    static let sheet: CGFloat = 16
}

/// The spacing rhythm (a grouped form's, where a pane isn't one).
enum Space {
    static let margin: CGFloat = 20
    static let section: CGFloat = 20
    static let label: CGFloat = 6
    static let inset: CGFloat = 10
    static let gap: CGFloat = 10
}

/// The lights: Apple's system colours. Each carries one meaning.
enum Light {
    /// The accent: a connected phone, the pick, the one thing to do.
    static let cyan = Color.accentColor
    static let teal = Color(nsColor: .systemTeal)
    /// Delivered, allowed, done.
    static let mint = Color(nsColor: .systemGreen)
    static let gold = Color(nsColor: .systemYellow)
    /// Your action / the mic is in use.
    static let ember = Color(nsColor: .systemOrange)
    static let violet = Color(nsColor: .systemPurple)
    /// Failure.
    static let rose = Color(nsColor: .systemRed)
    /// Queued / delayed / caution: yellow in dark, amber in light (yellow can't be read on white).
    static let ochre = Color(nsColor: NSColor(name: "MacrophoneOchre") { a in
        a.isDark ? NSColor.systemYellow : NSColor(srgbRed: 0.70, green: 0.42, blue: 0.0, alpha: 1)
    })

    /// Apple Intelligence's colours (the landing glow's and the phone's Thread).
    static let spectrum: [Color] = [Color(hex: 0x459AFF), Color(hex: 0xBC82F3), Color(hex: 0xF572B7), Color(hex: 0xFF9857)]
    static let spectrumStops: [Gradient.Stop] = [
        .init(color: Color(hex: 0x459AFF), location: 0), .init(color: Color(hex: 0xBC82F3), location: 0.34),
        .init(color: Color(hex: 0xF572B7), location: 0.67), .init(color: Color(hex: 0xFF9857), location: 1),
    ]
}

/// The display accommodations in System Settings › Accessibility › Display.
enum A11y {
    static var increaseContrast: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
    static var reduceTransparency: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }
}

enum Motion {
    static let settle = Animation.spring(response: 0.4, dampingFraction: 0.85)
    static let snap = Animation.spring(response: 0.25, dampingFraction: 0.7)
    static let arrive = Animation.spring(response: 0.35, dampingFraction: 0.85)
    static let depart = Animation.spring(response: 0.45, dampingFraction: 0.86)
    /// Ease-out-back: the ✓ popping in.
    static let pop = Animation.timingCurve(0.34, 1.56, 0.64, 1, duration: 0.42)

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

enum Typeface {
    /// SF Pro, as every Apple app (the New York serif is retired, Nov 7 2026; the name stays).
    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
    /// Code, tokens, addresses: SF Mono.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    /// Numbers that tick or line up (times, counts): SF Pro with monospaced digits.
    static func digits(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

/// A small label: sentence case, semibold, secondary — Apple's (no uppercase tracked mono any
/// more, Nov 7 2026).
struct Kicker: View {
    let text: String
    var color: Color = Ink.secondary
    var size: CGFloat = 11
    init(_ text: String, color: Color = Ink.secondary, size: CGFloat = 11) {
        self.text = text; self.color = color; self.size = size
    }
    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A capsule label, e.g. "Delayed".
struct Chip: View {
    let text: String
    var color: Color = Ink.secondary
    var icon: String?
    var body: some View {
        HStack(spacing: 3) {
            if let icon { Image(systemName: icon).font(.system(size: 9, weight: .semibold)) }
            Text(text).font(.system(size: 10.5, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.14)))
        .fixedSize()
    }
}

/// The window's buttons are the system's own (Nov 7 2026): `filled` is the one thing to do
/// (bordered prominent, the accent), the rest are bordered. A rose tint is a destructive one.
/// Kept as a style so every pane — and any written against the old look — gets native buttons.
struct PillButtonStyle: PrimitiveButtonStyle {
    var tint: Color = Ink.ink
    var filled = true
    func makeBody(configuration: Configuration) -> some View {
        if filled {
            Button(configuration).buttonStyle(.borderedProminent)
        } else if tint == Light.rose {
            Button(role: .destructive, action: configuration.trigger) { configuration.label }
                .buttonStyle(.bordered)
        } else {
            Button(configuration).buttonStyle(.bordered)
        }
    }
}

/// The ring a custom text field wears while it has the keyboard (the system draws one for its
/// own fields).
struct FieldFocusRing: ViewModifier {
    var focused: Bool
    var radius: CGFloat = Radius.control
    /// Like AppKit's ring, it shows only while the window is key.
    @Environment(\.controlActiveState) private var active
    func body(content: Content) -> some View {
        let on = focused && active == .key
        content
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Ink.focus.opacity(on ? 0.8 : 0), lineWidth: 3)
                .padding(-2))
            .animation(Motion.reduceMotion ? nil : .easeOut(duration: 0.12), value: on)
    }
}

extension View {
    func fieldFocusRing(_ focused: Bool, radius: CGFloat = Radius.control) -> some View {
        modifier(FieldFocusRing(focused: focused, radius: radius))
    }
}

/// Copyable code on a well (the token, commands, config).
struct CodePlate: View {
    let text: String
    /// What the Copy button copies, when it differs from what's shown (a masked token).
    var copyText: String? = nil
    var copyLabel = "Copy"
    @State private var copied = false
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(text)
                .font(Typeface.mono(11.5, .regular))
                .foregroundStyle(Ink.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                Clipboard.copyPlain(copyText ?? text)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 16)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(copied ? Light.mint : Ink.secondary)
            .help(copied ? "Copied" : copyLabel)
            .accessibilityLabel(copied ? "Copied" : copyLabel)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Radius.control + 2, style: .continuous).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: Radius.control + 2, style: .continuous).strokeBorder(Ink.line, lineWidth: 0.5))
    }
}

/// Plain clipboard writes (copy buttons in the UI — not the paste path).
enum Clipboard {
    static func copyPlain(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }
}

/// Behind-window blur for the popup (a HUD, dark on purpose).
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
    }
}

extension Date {
    /// "just now", "2 min ago", "3 h ago", "yesterday", "Oct 4".
    var relativeShort: String {
        let s = Date().timeIntervalSince(self)
        if s < 45 { return "just now" }
        if s < 3600 { return "\(max(1, Int((s / 60).rounded()))) min ago" }
        if s < 86_400 && Calendar.current.isDateInToday(self) { return "\(Int(s / 3600)) h ago" }
        if Calendar.current.isDateInYesterday(self) { return "yesterday" }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMM d")
        return f.string(from: self)
    }

    var clockTime: String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: self)
    }
}
