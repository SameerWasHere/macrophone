import AppKit
import SwiftUI

/// Macrophone's tokens (docs/DESIGN.md). Dark is the identity; every window forces it.
enum Ink {
    static let ground = Color(red: 0.020, green: 0.024, blue: 0.051)          // #05060D
    static let raised = Color(red: 0.075, green: 0.082, blue: 0.125)          // #131520
    static let sunk = Color(red: 0.012, green: 0.014, blue: 0.032)
    static let ink = Color(red: 0.957, green: 0.949, blue: 0.980)             // #F4F2FA
    static let secondary = Color(red: 0.788, green: 0.784, blue: 0.812)       // #C9C8CF
    /// Quiet words. Brighter under Increase Contrast.
    static var tertiary: Color {
        A11y.increaseContrast ? Color(red: 0.76, green: 0.757, blue: 0.784) : Color(red: 0.620, green: 0.616, blue: 0.647) // #9E9DA5
    }
    // Hairlines: 8 / 14 / 22% of the ink, about three times that under Increase Contrast.
    static var line: Color { ink.opacity(A11y.increaseContrast ? 0.26 : 0.08) }
    static var lineStrong: Color { ink.opacity(A11y.increaseContrast ? 0.36 : 0.14) }
    static var lineHeavy: Color { ink.opacity(A11y.increaseContrast ? 0.5 : 0.22) }

    static let groundNS = NSColor(srgbRed: 0.020, green: 0.024, blue: 0.051, alpha: 1)

    /// A control's rest fill on a plate (the search field, the shortcut recorder).
    static let well = Color(red: 0.040, green: 0.045, blue: 0.075)
    /// The keyboard focus ring (teal, like the window's tint).
    static let focus = Color(hex: 0x5CD3C3)
}

/// One radius per layer: plates 14, the controls on them 10, cards that float 18, sheets 22.
enum Radius {
    static let plate: CGFloat = 14
    static let control: CGFloat = 10
    static let card: CGFloat = 18
    static let sheet: CGFloat = 22
}

/// The spacing rhythm of a pane: 32 at the margins, 24 between sections, 8 from a section's
/// label to its plate, 16 inside a plate, 12 between a row's columns.
enum Space {
    static let margin: CGFloat = 32
    static let section: CGFloat = 24
    static let label: CGFloat = 8
    static let inset: CGFloat = 16
    static let gap: CGFloat = 12
}

/// The lights. Each carries one meaning.
enum Light {
    static let cyan = Color(hex: 0x58B9DE)      // a connected Mac / phone
    static let teal = Color(hex: 0x5CD3C3)
    static let mint = Color(hex: 0x5ED6A2)      // delivered
    static let gold = Color(hex: 0xE8C06C)
    static let ember = Color(hex: 0xE9714F)     // your action
    static let violet = Color(hex: 0x9A86E6)
    static let rose = Color(hex: 0xE66E7E)      // failure
    static let ochre = Color(hex: 0xC99D68)     // queued / delayed / caution

    static let spectrum: [Color] = [cyan, teal, mint, gold, ember, violet]
    static let spectrumStops: [Gradient.Stop] = [
        .init(color: cyan, location: 0), .init(color: teal, location: 0.22), .init(color: mint, location: 0.40),
        .init(color: gold, location: 0.60), .init(color: ember, location: 0.80), .init(color: violet, location: 1),
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
    /// The words are the hero: New York.
    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

/// Small-caps status line in SF Mono, tracked out.
struct Kicker: View {
    let text: String
    var color: Color = Ink.tertiary
    var size: CGFloat = 10.5
    init(_ text: String, color: Color = Ink.tertiary, size: CGFloat = 10.5) {
        self.text = text; self.color = color; self.size = size
    }
    var body: some View {
        Text(text.uppercased())
            .font(Typeface.mono(size, .semibold))
            .tracking(1.2)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A raised plate with a hairline — the window's section container.
struct Plate<Content: View>: View {
    var padding: CGFloat = 0
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.plate, style: .continuous).fill(Ink.raised.opacity(0.72)))
            .overlay(RoundedRectangle(cornerRadius: Radius.plate, style: .continuous).strokeBorder(Ink.line, lineWidth: 1))
    }
}

/// A labelled section: the kicker, its plate, and an optional quiet note under it — the one
/// rhythm every pane keeps (label → plate 8, plate → note 8).
struct PaneSection<Content: View>: View {
    var label: String?
    var note: String?
    @ViewBuilder var content: Content
    init(_ label: String? = nil, note: String? = nil, @ViewBuilder content: () -> Content) {
        self.label = label; self.note = note; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: Space.label) {
            if let label { SectionLabel(label) }
            content
            if let note, !note.isEmpty { PlateNote(note) }
        }
    }
}

/// The quiet line under a plate ("Your iPhone sees this name…").
struct PlateNote: View {
    let text: String
    var color: Color = Ink.tertiary
    init(_ text: String, color: Color = Ink.tertiary) { self.text = text; self.color = color }
    var body: some View {
        Text(text)
            .font(.system(size: 11.5)).foregroundStyle(color)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }
}

/// A pane's empty state: a quiet mark, a serif line, one sentence of what to do.
struct EmptyState<Mark: View, Action: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var mark: Mark
    @ViewBuilder var action: Action
    init(title: String, detail: String, @ViewBuilder mark: () -> Mark, @ViewBuilder action: () -> Action = { EmptyView() }) {
        self.title = title; self.detail = detail; self.mark = mark(); self.action = action()
    }
    var body: some View {
        VStack(spacing: 10) {
            mark.padding(.bottom, 4)
            Text(title).font(Typeface.serif(19)).foregroundStyle(Ink.secondary)
            Text(detail)
                .font(.system(size: 12.5)).foregroundStyle(Ink.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)
            action.padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 52)
    }
}

/// One row on a plate: a title, an optional line under it, and a control on the right.
struct PlateRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var subtitleColor: Color = Ink.tertiary
    var icon: String?
    var iconColor: Color = Ink.secondary
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: Space.gap) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(iconColor)
                    .frame(width: 22)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Ink.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 11.5)).foregroundStyle(subtitleColor)
                        .lineSpacing(1.5)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Space.gap)
            trailing
        }
        .padding(.horizontal, Space.inset)
        .padding(.vertical, 11)
        .frame(minHeight: 50)
    }
}

extension PlateRow where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, subtitleColor: Color = Ink.tertiary, icon: String? = nil, iconColor: Color = Ink.secondary) {
        self.init(title: title, subtitle: subtitle, subtitleColor: subtitleColor, icon: icon, iconColor: iconColor) { EmptyView() }
    }
}

/// The hairline between a plate's rows. The default inset lines up with a `PlateRow`'s words
/// (the icon column and its gap), the way System Settings does it.
struct PlateDivider: View {
    var inset: CGFloat = PlateDivider.rowInset
    static let rowInset: CGFloat = Space.inset + 22 + Space.gap
    var body: some View { Rectangle().fill(Ink.line).frame(height: 1).padding(.leading, inset).accessibilityHidden(true) }
}

/// A pane's heading: serif title, a plain sentence under it, and room on the title's line for
/// one action (Devices › Pair iPhone).
struct PaneHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    init(title: String, subtitle: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title; self.subtitle = subtitle; self.trailing = trailing()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: Space.gap) {
                Text(title).font(Typeface.serif(28, .regular)).foregroundStyle(Ink.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                trailing
            }
            Text(subtitle).font(.system(size: 13)).foregroundStyle(Ink.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 620, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 2)
    }
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Kicker(text).padding(.leading, 4).padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A capsule label, e.g. "Sends text off this Mac".
struct Chip: View {
    let text: String
    var color: Color = Ink.secondary
    var icon: String?
    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.system(size: 9, weight: .bold)) }
            Text(text).font(.system(size: 10.5, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.13)))
        .overlay(Capsule().strokeBorder(color.opacity(0.22), lineWidth: 0.5))
        .fixedSize()
    }
}

/// The one quiet primary style used across the window: a filled capsule for the one thing to
/// do, an outlined one for the rest. Hover lifts it a step, a press settles it, disabled fades
/// it, and the keyboard's focus ring follows the capsule.
struct PillButtonStyle: ButtonStyle {
    var tint: Color = Ink.ink
    var filled = true
    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, tint: tint, filled: filled)
    }

    private struct PillBody: View {
        let configuration: Configuration
        let tint: Color
        let filled: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false

        var body: some View {
            let pressed = configuration.isPressed
            configuration.label
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(filled ? Ink.ground : tint)
                .padding(.horizontal, 14).padding(.vertical, 6)
                .frame(minHeight: 26)
                .background(Capsule().fill(filled ? tint.opacity(pressed ? 0.72 : (hover ? 1 : 0.94))
                                                  : tint.opacity(pressed ? 0.18 : (hover ? 0.13 : 0.08))))
                .overlay(Capsule().strokeBorder(filled ? Color.clear : tint.opacity(hover ? 0.4 : 0.28), lineWidth: 1))
                .contentShape(Capsule())
                .contentShape(.focusEffect, Capsule())
                .opacity(enabled ? 1 : 0.45)
                .onHover { hover = $0 }
                .animation(Motion.reduceMotion ? nil : .easeOut(duration: 0.12), value: hover)
                .animation(Motion.reduceMotion ? nil : .easeOut(duration: 0.08), value: pressed)
        }
    }
}

/// The teal ring a custom text field wears while it has the keyboard (the system draws one
/// for its own fields; ours sit on plates and draw their own).
struct FieldFocusRing: ViewModifier {
    var focused: Bool
    var radius: CGFloat = Radius.control
    /// Like AppKit's ring, it shows only while the window is key.
    @Environment(\.controlActiveState) private var active
    func body(content: Content) -> some View {
        let on = focused && active == .key
        content
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Ink.focus.opacity(on ? 0.7 : 0), lineWidth: 2)
                .padding(-1))
            .animation(Motion.reduceMotion ? nil : .easeOut(duration: 0.12), value: on)
    }
}

extension View {
    func fieldFocusRing(_ focused: Bool, radius: CGFloat = Radius.control) -> some View {
        modifier(FieldFocusRing(focused: focused, radius: radius))
    }
}

/// Copyable mono text on a sunk plate (the token, commands, config).
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
                Label(copied ? "Copied" : copyLabel, systemImage: copied ? "checkmark" : "doc.on.doc")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(copied ? Light.mint : Ink.secondary)
            .accessibilityLabel(copied ? "Copied" : copyLabel)
            .animation(Motion.reduceMotion ? nil : .easeOut(duration: 0.15), value: copied)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Ink.sunk))
        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Ink.line, lineWidth: 1))
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

/// Behind-window blur for the popup and sheets.
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
