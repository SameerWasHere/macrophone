import SwiftUI
import UIKit

// The Macrophone look (docs/DESIGN.md, "Macrophone, as Apple would make it", Nov 1 2026): Apple's
// own semantic colours, so the app follows the system into light and dark (or the choice in
// Settings › Appearance); the system accent for "your Mac"; SF Pro for everything. The names are
// the old ones (Ink, Light) so every screen moved with one file.

enum Ink {
    /// A page: grouped background (#F2F2F7 light, black dark) — Settings' ground.
    static let ground = Color(uiColor: .systemGroupedBackground)
    /// A row or plate on the page (white light, #1C1C1E dark).
    static let raised = Color(uiColor: .secondarySystemGroupedBackground)
    /// Under a picture: the hollow a window sits in.
    static let sunk = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .black : .systemGray5 })
    static let ink = Color(uiColor: .label)
    static let secondary = Color(uiColor: .secondaryLabel)
    /// Quiet words that still read over a wallpaper (darker than systemGray in light, lighter in
    /// dark). Nov 8 2026: 0.42 / systemGray read ~2 : 1 over a mid-blue picture under the veil (the
    /// recording's "To Terminal · Medium cleanup", the window row's hint); now ~3 : 1 and ~4 : 1.
    static let tertiary = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.64, green: 0.64, blue: 0.67, alpha: 1) : UIColor(red: 0.33, green: 0.33, blue: 0.35, alpha: 1) })
    static let faint = ink.opacity(0.08)
    static let line = Color(uiColor: .separator)
    static let lineStrong = ink.opacity(0.22)
    /// A glyph or label on a filled accent (a prominent button, a lit key): white, as Apple's are.
    static let onTint = Color.white
}

/// The meaning colours — Apple's system colours, each tuned by the system for light and dark.
/// The old names stay: cyan is the accent (your Mac, a pick, a lit control).
enum Light {
    static let cyan = Color(uiColor: .systemBlue)       // your Mac / the accent
    static let teal = Color(uiColor: .systemTeal)       // sending
    static let mint = Color(uiColor: .systemGreen)      // delivered
    static let gold = Color(uiColor: .systemYellow)
    static let ember = Color(uiColor: .systemOrange)    // mic live / your action (iOS's mic-in-use colour)
    static let violet = Color(uiColor: .systemPurple)
    /// Queued / caution: yellow in dark, a darker amber in light (yellow text can't be read on white).
    static let ochre = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? .systemYellow : UIColor(red: 0.69, green: 0.45, blue: 0.0, alpha: 1) })
    static let rose = Color(uiColor: .systemRed)        // failure
}

/// The Filament's colours as raw RGB, for per-frame gradient building (the system colours' dark
/// variants — they read on both grounds).
struct RGB: Equatable {
    var r: Double, g: Double, b: Double
    static let cyan = RGB(r: 0.039, g: 0.518, b: 1.0)      // systemBlue
    static let teal = RGB(r: 0.251, g: 0.784, b: 0.878)    // systemTeal
    static let mint = RGB(r: 0.188, g: 0.820, b: 0.345)    // systemGreen
    static let gold = RGB(r: 1.0, g: 0.839, b: 0.039)      // systemYellow
    static let ember = RGB(r: 1.0, g: 0.624, b: 0.039)     // systemOrange
    static let violet = RGB(r: 0.749, g: 0.353, b: 0.949)  // systemPurple
    static let ochre = RGB(r: 0.902, g: 0.690, b: 0.180)
    static let rose = RGB(r: 1.0, g: 0.271, b: 0.227)      // systemRed
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

    /// What leaves when another layout takes its place: gone at once, so it never shows through
    /// what arrives (Nov 4 2026 — the cover's row lingered, faded, under the window coming in).
    static let leave = Animation.easeOut(duration: 0.12)
    /// What arrives once something has left (`leave`): a short fade, after it.
    static let afterLeave = Animation.easeOut(duration: 0.22).delay(0.1)

    /// The spring, or a plain fade under Reduce Motion.
    static func pick(_ a: Animation, reduce: Bool) -> Animation { reduce ? .easeInOut(duration: 0.2) : a }
}

extension AnyTransition {
    /// One layout handing over to another: what leaves goes at once, what arrives fades in on the
    /// spring that carries the change.
    static var handoff: AnyTransition { .asymmetric(insertion: .opacity, removal: .opacity.animation(Motion.leave)) }
    /// The same, with what arrives waiting for what leaves (the Duo's cover, Nov 4 2026): never two
    /// screens through each other — the window and the words, the window and Send to.
    static var handoffAfter: AnyTransition {
        .asymmetric(insertion: .opacity.animation(Motion.afterLeave), removal: .opacity.animation(Motion.leave))
    }
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
    /// The words: SF Pro, scaled with Dynamic Type (New York until Nov 1 2026 — the name stays).
    static func serif(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style).weight(weight)
    }
    /// Kickers and timers: SF Pro with figures of one width, so a clock never jitters.
    static func mono(_ style: Font.TextStyle, weight: Font.Weight = .medium) -> Font {
        .system(style).weight(weight).monospacedDigit()
    }
}

/// A small label over a group, as iOS sets one: "Send to", "Listening · 00:12".
struct Kicker: View {
    var text: String
    var color: Color = Ink.secondary
    init(_ text: String, color: Color = Ink.secondary) { self.text = text; self.color = color }
    var body: some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A symbol on a small tinted plate — the mark the app uses for a place without an icon
/// (`TargetIcon`), and since the refinement pass (Oct 18 2026) for every row glyph in Settings,
/// so a list row carries the same mark as the panel by the mic.
struct GlyphPlate: View {
    var symbol: String
    var tint: Color
    var size: CGFloat = 28
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(shape.fill(tint.opacity(0.16)))
            .overlay(shape.strokeBorder(tint.opacity(0.3), lineWidth: 1))
            .accessibilityHidden(true)
    }
}

/// A plate's edge lit from above, like light on glass: a hairline that is brightest along the
/// top and fades toward the foot (the refinement pass). Increase Contrast: a firm, even edge.
struct SpecularEdge<S: InsettableShape>: View {
    var shape: S
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        if contrast == .increased {
            shape.strokeBorder(Ink.ink.opacity(0.45), lineWidth: 1)
        } else {
            // The gradient masked by the hairline, not the hairline stroked with a gradient: a
            // gradient stroke is drawn on the CPU into a backing store the plate's whole size, and
            // a big plate (the watched window) cost ~200 ms a draw — on every frame of a resize
            // (Nov 4 2026, measured on the Duo's Show it here). Masked, the GPU draws it.
            LinearGradient(colors: [Ink.ink.opacity(0.30), Ink.line, Ink.ink.opacity(0.07)],
                           startPoint: .top, endPoint: .bottom)
                .mask(shape.strokeBorder(lineWidth: 1))
                .allowsHitTesting(false)
        }
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
            buttonStyle(.glassProminent).tint(Light.cyan).fontWeight(.semibold).foregroundStyle(Ink.onTint)
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
            .foregroundStyle(kind == .primary ? (tint == Ink.ink ? Color(uiColor: .systemBackground) : Ink.onTint) : tint)
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
                label.buttonStyle(.glassProminent).tint(tint).foregroundStyle(tint == Ink.ink ? Color(uiColor: .systemBackground) : Ink.onTint)
            } else {
                label.buttonStyle(.glass).foregroundStyle(tint)
            }
        } else {
            content.buttonStyle(PillButtonStyle(kind: kind, tint: tint))
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

/// The haptic vocabulary (DESIGN.md) — one meaning, one feel, everywhere. Every haptic in the
/// app goes through these; nothing makes a generator of its own.
///
/// - `micOpen()` rigid: the mic opens, at the finger. Prepared ahead (`readyMic()`).
/// - `micClose()` soft: the mic closes, the words on their way.
/// - `landed()` success: what you sent arrived — a dictation landed, a photo or file, the Mac's
///   clipboard, an app opened or quit, a pairing made, an undo done.
/// - `caution()` warning: held, not lost — queued, not confirmed, near the length limit, a Mac
///   that couldn't do it this time.
/// - `failed()` error: it didn't happen.
/// - `pick()` selection: a choice among options moved — a place in the Dock or Send to, a page,
///   a cleanup level, a switch, a Mac, a window, a size, a slider's detent.
/// - `press()` light: a key, a click or a command went to the Mac — a key, a tap, an answer, a
///   trackpad gesture, a Mac Control, a Window command, Copy, Send Again, Refresh, Wake. A held
///   key's repeats are felt once (`quietly`).
/// - `rightClick()` medium: a right-click (a hold, two fingers) — the context menu's firmer tap.
/// - `grab()` soft, lighter: something taken in hand — a drag picked up, the floating mic
///   lifted, the trackpad summoned.
/// - `arrived()` soft: something settled into place — a window's first picture, a fold, a
///   window closed on the Mac, the floating mic set down, a milestone's note.
/// - The Thread plucked (Delight, Nov 8 2026) is its own: a tension while it's pulled and a twang
///   that decays with the string, a curve rather than a tap (`ThreadHaptics`, Core Haptics).
///
/// Nothing on navigation — opening a sheet, Done, Show it here, full screen, opening a window
/// (its first picture is `arrived`): what moves on screen says it. One event, one haptic: a view
/// calling a model method that already speaks stays quiet.
@MainActor
enum Haptics {
    private static let selection = UISelectionFeedbackGenerator()
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let soft = UIImpactFeedbackGenerator(style: .soft)
    private static let notice = UINotificationFeedbackGenerator()
    private static var hushed = 0

    /// The mic starts on touch-down, so there's no moment before the tap to prepare in: the engine
    /// is woken when the app comes forward and after each dictation, when a tap is likeliest
    /// (`prepare` holds it a few seconds, then it sleeps again).
    static func readyMic() { rigid.prepare() }

    static func micOpen() { play { rigid.impactOccurred(intensity: 0.85) } }
    static func micClose() { play { soft.impactOccurred(); rigid.prepare() } }
    static func landed() { play { notice.notificationOccurred(.success) } }
    static func caution() { play { notice.notificationOccurred(.warning) } }
    static func failed() { play { notice.notificationOccurred(.error) } }
    static func pick() { play { selection.selectionChanged() } }
    static func press() { play { light.impactOccurred(intensity: 0.7) } }
    static func rightClick() { play { medium.impactOccurred() } }
    static func grab() { play { soft.impactOccurred(intensity: 0.6) } }
    static func arrived() { play { soft.impactOccurred() } }

    /// Runs `body` without a haptic: a held key's repeats, felt once on its first press.
    static func quietly(_ body: () -> Void) {
        hushed += 1
        defer { hushed -= 1 }
        body()
    }

    private static func play(_ feel: () -> Void) {
        guard hushed == 0 else { return }
        feel()
    }
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
