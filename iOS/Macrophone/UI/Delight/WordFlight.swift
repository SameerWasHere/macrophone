import MacrophoneKit
import SwiftUI

/// The words travel (Delight, Nov 8 2026). As a dictation goes out, its first words lift off the
/// transcript as a small glass chip and drop along a curve into the Dock icon they're going to —
/// the way a window goes into the Dock on a Mac — shrinking as they go, two motes of the Thread's
/// light trailing them. Into a window that's showing, they sink into it instead. When the Mac says
/// they landed, the icon catches them (`DockCatch`).
///
/// Drawn over the mic screen, taking no touch; built only for the 0.6 s of a flight (nothing at
/// rest). Not under Reduce Motion (the icon glows instead), not in full screen, not where there's
/// no Dock on screen to fly to (the Duo's inner screen) — the catch then happens on the landing.
struct WordFlightLayer: View {
    /// This layout has a Dock or a window the words can be seen going into.
    var allowed: Bool
    /// The window on screen the words go into, when one shows (global).
    var window: CGRect?
    /// The Dock's pick: the icon they drop into when they go there.
    var selection: TargetRef

    @ObservedObject private var delight = Delight.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flight: Trip?
    @State private var progress: CGFloat = 0

    struct Trip: Equatable {
        var id: UUID
        var words: String
        var from: CGPoint
        var control: CGPoint
        var to: CGPoint
        var endScale: CGFloat
    }

    static let duration = 0.62

    var body: some View {
        GeometryReader { g in
            ZStack {
                if let f = flight {
                    let origin = g.frame(in: .global).origin
                    let shift = { (p: CGPoint) in CGPoint(x: p.x - origin.x, y: p.y - origin.y) }
                    ForEach(0..<2, id: \.self) { i in
                        Circle()
                            .fill(MacOSLook.intelligence[(i * 2 + 1) % MacOSLook.intelligence.count])
                            .frame(width: 7 - CGFloat(i) * 2, height: 7 - CGFloat(i) * 2)
                            .blur(radius: 1.5)
                            .modifier(ArcFlight(progress: progress, lag: 0.07 * CGFloat(i + 1), from: shift(f.from),
                                                control: shift(f.control), to: shift(f.to), endScale: 0.4))
                    }
                    chip(f.words)
                        .modifier(ArcFlight(progress: progress, lag: 0, from: shift(f.from), control: shift(f.control),
                                            to: shift(f.to), endScale: f.endScale))
                }
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: delight.leaving) { _, l in if let l { start(l) } }
    }

    private func chip(_ words: String) -> some View {
        Text(words)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Ink.ink)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background {
                Capsule().fill(.regularMaterial)
                    .overlay {
                        // The Thread's light round its edge (masked, so the GPU draws it).
                        AngularGradient(colors: MacOSLook.intelligence + [MacOSLook.intelligence[0]], center: .center)
                            .mask(Capsule().strokeBorder(lineWidth: 1.2))
                            .opacity(0.9)
                    }
            }
            .shadow(color: Color(red: 0.74, green: 0.51, blue: 0.95).opacity(0.35), radius: 10, y: 2)
    }

    private func start(_ l: Delight.Leaving) {
        guard allowed, !reduceMotion, let to = destination(for: l), Self.onScreen(Delight.shared.wordsFrame) else {
            delight.flightSkipped()
            return
        }
        let w = Delight.shared.wordsFrame
        // From the transcript's first line, where the words were.
        let from = CGPoint(x: w.minX + min(w.width / 2, 110), y: w.minY + 18)
        // Down first, then curving in over the icon (a window going into the Dock) — never out
        // past the screen's side first, where an icon at the Dock's end would take it; into a
        // window, a shallow dip.
        let control = window != nil ? CGPoint(x: (from.x + to.point.x) / 2, y: min(from.y, to.point.y) - 40)
            : CGPoint(x: from.x + (to.point.x - from.x) * 0.3, y: from.y + (to.point.y - from.y) * 0.9)
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) {
            progress = 0
            flight = Trip(id: l.id, words: l.words, from: from, control: control, to: to.point, endScale: to.scale)
        }
        let id = l.id
        // The next pass, so the chip is laid out at its start before it moves.
        Task { @MainActor in
            withAnimation(.timingCurve(0.42, 0.0, 0.58, 1.0, duration: Self.duration)) {
                progress = 1
            } completion: {
                guard flight?.id == id else { return }
                flight = nil
                delight.flightArrived()
            }
        }
    }

    /// Where they go: into the window showing, else into the pick's icon on the Dock (only when
    /// that's where they're going, and the icon is on screen).
    private func destination(for l: Delight.Leaving) -> (point: CGPoint, scale: CGFloat)? {
        if let window, window.width > 40, window.height > 40 {
            return (CGPoint(x: window.midX, y: window.minY + window.height * 0.45), 0.55)
        }
        guard l.target == nil || l.target == selection, let icon = DockSpot.shared.pick, Self.onScreen(icon), icon.width > 4 else { return nil }
        return (CGPoint(x: icon.midX, y: icon.midY), 0.16)
    }

    private static func onScreen(_ r: CGRect) -> Bool {
        guard r.width > 1, r.height > 1 else { return false }
        let screens = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen.bounds }
        let bounds = screens.first ?? CGRect(x: 0, y: 0, width: 1000, height: 2000)
        return bounds.insetBy(dx: -4, dy: -4).contains(CGPoint(x: r.midX, y: r.midY))
    }
}

/// A point along a quadratic curve, with the chip shrinking (mostly at the end, as it drops into
/// the icon) and fading in its last quarter. `lag` holds a trailing mote a little behind.
private struct ArcFlight: ViewModifier, Animatable {
    var progress: CGFloat
    var lag: CGFloat
    var from: CGPoint
    var control: CGPoint
    var to: CGPoint
    var endScale: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let t = min(1, max(0, (progress - lag) / max(0.01, 1 - lag)))
        let u = 1 - t
        let p = CGPoint(x: u * u * from.x + 2 * u * t * control.x + t * t * to.x,
                        y: u * u * from.y + 2 * u * t * control.y + t * t * to.y)
        let scale = 1 - (1 - endScale) * t * t
        let fadeIn = min(1, progress / 0.08)
        let fadeOut = t < 0.78 ? 1 : max(0, 1 - (t - 0.78) / 0.22)
        content
            .scaleEffect(scale)
            .opacity(Double(fadeIn * fadeOut) * (lag > 0 ? 0.8 : 1))
            .position(p)
    }
}

/// The Dock icon's catch (Delight, Nov 8 2026): when the words land, the pick's icon dips under
/// their weight, hops and settles, a glow of the Thread's light behind it; when they don't, it
/// shakes its head, as a Mac's login field does. While an app opens on the Mac from here
/// (`PlaceOption.Kind.opening`), its icon bounces the way a Mac's Dock does while an app launches.
/// Reduce Motion: the glow alone; the launch keeps its spinner.
struct DockCatch: ViewModifier {
    var selected: Bool
    var opening: Bool

    @ObservedObject private var catches = DockCatches.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The values the last catch was made with (keyframes read them when the trigger moves).
    @State private var trigger = 0
    @State private var ok = true
    @State private var launchHop: CGFloat = 0
    @State private var launching: Task<Void, Never>?

    struct Values {
        var hop: CGFloat = 0
        var squash: CGFloat = 1
        var shake: CGFloat = 0
        var glow: Double = 0
    }

    func body(content: Content) -> some View {
        let still = reduceMotion
        let landed = ok
        content
            .offset(y: -launchHop)
            .keyframeAnimator(initialValue: Values(), trigger: trigger) { c, v in
                c
                    .background {
                        Circle()
                            .fill(AngularGradient(colors: MacOSLook.intelligence + [MacOSLook.intelligence[0]], center: .center))
                            .blur(radius: 9)
                            .scaleEffect(1.15)
                            .opacity(v.glow)
                    }
                    .scaleEffect(x: 2 - v.squash, y: v.squash, anchor: .bottom)
                    .offset(x: v.shake, y: -v.hop)
            } keyframes: { _ in
                KeyframeTrack(\.squash) {
                    CubicKeyframe(still || !landed ? 1 : 0.86, duration: 0.08)
                    SpringKeyframe(still || !landed ? 1 : 1.05, duration: 0.16, spring: .snappy)
                    SpringKeyframe(1, duration: 0.3, spring: .bouncy)
                }
                KeyframeTrack(\.hop) {
                    LinearKeyframe(0, duration: 0.08)
                    CubicKeyframe(still || !landed ? 0 : 10, duration: 0.16)
                    CubicKeyframe(0, duration: 0.17)
                    CubicKeyframe(still || !landed ? 0 : 3, duration: 0.1)
                    CubicKeyframe(0, duration: 0.1)
                }
                KeyframeTrack(\.shake) {
                    let k: CGFloat = still || landed ? 0 : 1
                    CubicKeyframe(-7 * k, duration: 0.05)
                    CubicKeyframe(6 * k, duration: 0.07)
                    CubicKeyframe(-4.5 * k, duration: 0.07)
                    CubicKeyframe(3 * k, duration: 0.07)
                    CubicKeyframe(-1.5 * k, duration: 0.07)
                    CubicKeyframe(0, duration: 0.07)
                }
                KeyframeTrack(\.glow) {
                    CubicKeyframe(landed ? 0.85 : 0, duration: 0.16)
                    CubicKeyframe(landed ? 0.6 : 0, duration: 0.2)
                    CubicKeyframe(0, duration: 0.45)
                }
            }
            .onChange(of: catches.event) { _, e in
                guard selected, let e else { return }
                ok = e.ok
                trigger = e.seq
            }
            .onChange(of: opening, initial: true) { _, on in launch(on) }
            .onDisappear { launching?.cancel() }
    }

    /// The launch bounce: up quickly, down falling, again and again until the app is open.
    private func launch(_ on: Bool) {
        launching?.cancel()
        guard on, !reduceMotion else {
            withAnimation(.easeIn(duration: 0.2)) { launchHop = 0 }
            return
        }
        launching = Task { @MainActor in
            while !Task.isCancelled {
                withAnimation(.timingCurve(0.2, 0.7, 0.4, 1, duration: 0.28)) { launchHop = 14 }
                try? await Task.sleep(nanoseconds: 280_000_000)
                withAnimation(.timingCurve(0.6, 0, 0.8, 0.3, duration: 0.26)) { launchHop = 0 }
                try? await Task.sleep(nanoseconds: 420_000_000)
            }
        }
    }
}
