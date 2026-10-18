import SwiftUI
import UIKit

// The Macrophone look (docs/DESIGN.md): near-black blue ink, the Filament's spectrum,
// meaning colours, serif for the words, mono for the machine. Dark only.

enum Ink {
    static let ground = Color(red: 0.020, green: 0.024, blue: 0.051)      // #05060D
    static let raised = Color(red: 0.075, green: 0.082, blue: 0.125)      // #131520
    static let sunk = Color(red: 0.008, green: 0.012, blue: 0.031)
    static let ink = Color(red: 0.957, green: 0.949, blue: 0.980)         // #F4F2FA
    static let secondary = Color(red: 0.788, green: 0.784, blue: 0.812)   // #C9C8CF
    static let tertiary = Color(red: 0.620, green: 0.616, blue: 0.647)    // #9E9DA5
    static let faint = ink.opacity(0.08)
    static let line = ink.opacity(0.14)
    static let lineStrong = ink.opacity(0.22)
}

enum Light {
    static let cyan = Color(red: 0.345, green: 0.725, blue: 0.871)    // #58B9DE  connected Mac
    static let teal = Color(red: 0.361, green: 0.827, blue: 0.765)    // #5CD3C3
    static let mint = Color(red: 0.369, green: 0.839, blue: 0.635)    // #5ED6A2  delivered
    static let gold = Color(red: 0.910, green: 0.753, blue: 0.424)    // #E8C06C
    static let ember = Color(red: 0.914, green: 0.443, blue: 0.310)   // #E9714F  mic live / your action
    static let violet = Color(red: 0.604, green: 0.525, blue: 0.902)  // #9A86E6
    static let ochre = Color(red: 0.788, green: 0.616, blue: 0.408)   // #C99D68  queued / caution
    static let rose = Color(red: 0.902, green: 0.431, blue: 0.494)    // #E66E7E  failure
}

/// The Filament's spectrum as raw RGB, for per-frame gradient building.
struct RGB: Equatable {
    var r: Double, g: Double, b: Double
    static let cyan = RGB(r: 0.345, g: 0.725, b: 0.871)
    static let teal = RGB(r: 0.361, g: 0.827, b: 0.765)
    static let mint = RGB(r: 0.369, g: 0.839, b: 0.635)
    static let gold = RGB(r: 0.910, g: 0.753, b: 0.424)
    static let ember = RGB(r: 0.914, g: 0.443, b: 0.310)
    static let violet = RGB(r: 0.604, g: 0.525, b: 0.902)
    static let ochre = RGB(r: 0.788, g: 0.616, b: 0.408)
    static let rose = RGB(r: 0.902, g: 0.431, b: 0.494)
    static let white = RGB(r: 1, g: 1, b: 1)
    static let spectrum: [RGB] = [.cyan, .teal, .mint, .gold, .ember, .violet]

    func mix(_ o: RGB, _ t: Double) -> RGB {
        RGB(r: r + (o.r - r) * t, g: g + (o.g - g) * t, b: b + (o.b - b) * t)
    }
    func color(_ opacity: Double = 1) -> Color { Color(red: r, green: g, blue: b, opacity: opacity) }

    /// The spectrum sampled at u in 0…1.
    static func spectrumAt(_ u: Double) -> RGB {
        let s = spectrum
        let x = min(max(u, 0), 1) * Double(s.count - 1)
        let i = min(Int(x), s.count - 2)
        return s[i].mix(s[i + 1], x - Double(i))
    }
}

enum Motion {
    static let settle = Animation.spring(response: 0.4, dampingFraction: 0.85)
    static let snap = Animation.spring(response: 0.25, dampingFraction: 0.7)
    static let arrive = Animation.spring(response: 0.35, dampingFraction: 0.85)
    static let depart = Animation.spring(response: 0.45, dampingFraction: 0.86)

    /// The spring, or a plain fade under Reduce Motion.
    static func pick(_ a: Animation, reduce: Bool) -> Animation { reduce ? .easeInOut(duration: 0.2) : a }
}

enum Radius {
    static let small: CGFloat = 14
    static let medium: CGFloat = 18
    static let large: CGFloat = 22
    /// The controls panel by the mic: the rows' 16pt inset plus a 10pt curve.
    static let panel: CGFloat = 26
}

/// The page's spacing, shared so every screen keeps the same edges (the design-review pass,
/// Oct 18 2026): one margin from the screen's edge for the top bar, the panel and the watched
/// window; one inset from a panel's edge to its rows; a wider one for running text (the header,
/// the transcript, the status line), which reads better set in from the controls.
enum Space {
    static let margin: CGFloat = 16
    static let inset: CGFloat = 16
    static let text: CGFloat = 24
}

extension Font {
    /// The words: New York, scaled with Dynamic Type.
    static func serif(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .serif).weight(weight)
    }
    /// Kickers and timers: SF Mono.
    static func mono(_ style: Font.TextStyle, weight: Font.Weight = .medium) -> Font {
        .system(style, design: .monospaced).weight(weight)
    }
}

/// A small-caps mono kicker: "LISTENING · 00:12".
struct Kicker: View {
    var text: String
    var color: Color = Ink.tertiary
    init(_ text: String, color: Color = Ink.tertiary) { self.text = text; self.color = color }
    var body: some View {
        Text(text.uppercased())
            .font(.mono(.caption2, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A panel: Liquid Glass on iOS 26+ (a rounded rect of regular glass), else ultra-thin material
/// over the ground with a hairline and a soft shadow. Increase Contrast: a firmer edge.
/// Reduce Transparency: a solid raised plate.
struct GlassPanel: ViewModifier {
    var radius: CGFloat = Radius.medium
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        let high = contrast == .increased
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if #available(iOS 26.0, *), !reduceTransparency {
            content
                .glassEffect(.regular.tint(Ink.raised.opacity(0.35)), in: shape)
                .overlay { if high { shape.strokeBorder(Ink.ink.opacity(0.45), lineWidth: 1) } }
        } else {
            content
                .background {
                    shape
                        .fill(.ultraThinMaterial)
                        .overlay(shape.fill(Ink.raised.opacity(high || reduceTransparency ? 0.95 : 0.55)))
                }
                .overlay(shape.strokeBorder(high ? Ink.ink.opacity(0.45) : Ink.line, lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        }
    }
}

extension View {
    func glass(_ radius: CGFloat = Radius.medium) -> some View { modifier(GlassPanel(radius: radius)) }
}

// MARK: Liquid Glass (iOS 26+), with the system's bordered look as the fallback

extension View {
    /// A native glass button (`.glass` on iOS 26+, `.bordered` below).
    @ViewBuilder func nativeGlassButton() -> some View {
        if #available(iOS 26.0, *) { buttonStyle(.glass) } else { buttonStyle(.bordered).tint(Ink.ink) }
    }

    /// The round icon buttons in the top bar: native circular glass on iOS 26+.
    @ViewBuilder func circleGlassButton() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glass).buttonBorderShape(.circle)
        } else {
            buttonStyle(IconButtonStyle())
        }
    }

    /// Toolbar confirm buttons (Done): prominent glass on iOS 26+.
    @ViewBuilder func doneButtonStyle() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glassProminent).tint(Light.cyan).fontWeight(.semibold).foregroundStyle(Ink.ground)
        } else {
            fontWeight(.semibold)
        }
    }
}

/// The top bar's round icon buttons below iOS 26: a 44pt circle with a hairline.
struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Ink.secondary)
            .frame(width: 44, height: 44)
            .modifier(IconPlate(pressed: configuration.isPressed))
            .contentShape(Circle())
    }
}

private struct IconPlate: ViewModifier {
    var pressed: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        content
            .background(Circle().fill(reduceTransparency ? Ink.raised : Ink.ink.opacity(pressed ? 0.12 : 0.05)))
            .overlay(Circle().strokeBorder(contrast == .increased ? Ink.ink.opacity(0.45) : Ink.line, lineWidth: 1))
    }
}

/// Pill buttons: the filled primary and the outlined secondary.
struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, quiet }
    var kind: Kind = .primary
    var tint: Color = Ink.ink
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
            .padding(.vertical, 13)
            .frame(minHeight: 50)
            .foregroundStyle(kind == .primary ? Ink.ground : tint)
            .background {
                switch kind {
                case .primary:
                    Capsule().fill(tint).shadow(color: tint.opacity(0.35), radius: 14, y: 4)
                case .secondary:
                    Capsule().fill(Ink.ink.opacity(0.06)).overlay(Capsule().strokeBorder(Ink.lineStrong, lineWidth: 1))
                case .quiet:
                    Color.clear
                }
            }
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(Motion.snap, value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

extension View {
    /// The pill buttons: native Liquid Glass on iOS 26+ (`.glassProminent` for the primary, lit with
    /// its tint; `.glass` for the secondary); `PillButtonStyle` below, for the quiet kind, and under
    /// Reduce Transparency.
    func pillStyle(_ kind: PillButtonStyle.Kind = .primary, tint: Color = Ink.ink) -> some View {
        modifier(PillStyle(kind: kind, tint: tint))
    }
}

private struct PillStyle: ViewModifier {
    var kind: PillButtonStyle.Kind
    var tint: Color
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), !reduceTransparency, kind != .quiet {
            let label = content
                .font(.body.weight(.semibold))
                .multilineTextAlignment(.center)
                .controlSize(.extraLarge)
            if kind == .primary {
                label.buttonStyle(.glassProminent).tint(tint).foregroundStyle(tint == Ink.ink ? Ink.ground : Color.white)
            } else {
                label.buttonStyle(.glass).foregroundStyle(tint)
            }
        } else {
            content.pillStyle(kind, tint: tint)
        }
    }
}

/// Small chip button (Copy, Resend, Raw/Cleaned).
struct ChipButtonStyle: ButtonStyle {
    var tint: Color = Ink.secondary
    var filled = false
    @Environment(\.colorSchemeContrast) private var contrast
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .foregroundStyle(tint)
            .background(Capsule().fill(filled ? tint.opacity(0.16) : Ink.ink.opacity(0.05)))
            .overlay(Capsule().strokeBorder(filled ? tint.opacity(0.35) : (contrast == .increased ? Ink.ink.opacity(0.45) : Ink.line), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

/// Fades the bottom (and optionally top) of scrolling text instead of cutting it.
struct EdgeFade: ViewModifier {
    var top: CGFloat = 0
    var bottom: CGFloat = 24
    func body(content: Content) -> some View {
        content.mask {
            VStack(spacing: 0) {
                if top > 0 { LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: top) }
                Rectangle()
                if bottom > 0 { LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: bottom) }
            }
        }
    }
}

extension View {
    func edgeFade(top: CGFloat = 0, bottom: CGFloat = 24) -> some View { modifier(EdgeFade(top: top, bottom: bottom)) }
}

/// The haptic vocabulary (DESIGN.md): light on start, soft on stop, success / warning / error,
/// and a tick when a control by the mic changes.
@MainActor
enum Haptics {
    static func tick() { UISelectionFeedbackGenerator().selectionChanged() }
    static func light() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func soft() { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
}

/// The page background: ground ink with a faint cool glow at the top.
struct GroundBackground: View {
    var glow: Color = Light.cyan
    var body: some View {
        ZStack {
            Ink.ground
            RadialGradient(colors: [glow.opacity(0.10), .clear], center: .init(x: 0.5, y: 0.0), startRadius: 10, endRadius: 520)
        }
        .ignoresSafeArea()
    }
}
