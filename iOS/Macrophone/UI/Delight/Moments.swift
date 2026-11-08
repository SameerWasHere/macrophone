import SwiftUI
import UIKit

// The once-in-a-while moments (Delight, Nov 8 2026): a milestone's note, pairing's meeting, the
// Mac pill's hello when the link comes up, and the wallpaper's depth. Each costs nothing at rest.

/// A milestone's note (`Delight.milestone`): a small glass banner that drops in under the status
/// bar, says it once — the first dictation that ever lands; 1,000 / 10,000 / 100,000 words — and
/// goes after a few seconds or a tap. Only at rest (never over a window or the live words): one
/// that comes while something else has the screen waits for it. Reduce Motion: it fades.
struct MilestoneBanner: View {
    /// Nothing else has the screen (the desktop at rest).
    var atRest: Bool

    @ObservedObject private var delight = Delight.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Delight.Milestone?
    @State private var hide: Task<Void, Never>?
    @State private var glint = false

    var body: some View {
        VStack {
            if let m = shown {
                banner(m)
                    .padding(.horizontal, Space.margin)
                    .padding(.top, 6)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.25) : .spring(response: 0.45, dampingFraction: 0.8), value: shown)
        .onChange(of: delight.milestone) { _, _ in present() }
        .onChange(of: atRest) { _, _ in present() }
    }

    private func present() {
        guard atRest, shown == nil, let m = delight.milestone else { return }
        delight.milestone = nil
        shown = m
        glint.toggle()
        SoundCues.play(.milestone)
        Haptics.arrived()
        UIAccessibility.post(notification: .announcement, argument: "\(m.title). \(m.detail)")
        hide?.cancel()
        hide = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            shown = nil
        }
    }

    private func banner(_ m: Delight.Milestone) -> some View {
        Button {
            hide?.cancel()
            shown = nil
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(MacOSLook.intelligenceAngular).opacity(0.9)
                    Image(systemName: m.symbol)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .symbolEffect(.bounce, value: glint)
                }
                .frame(width: 38, height: 38)
                .shadow(color: Color(red: 0.74, green: 0.51, blue: 0.95).opacity(0.45), radius: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.title).font(.subheadline.weight(.semibold)).foregroundStyle(Ink.ink)
                    Text(m.detail).font(.footnote).foregroundStyle(Ink.secondary)
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: 420)
            .glass(Radius.large)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Dismisses this.")
        .accessibilityIdentifier("delight-milestone")
    }
}

// MARK: Pairing: the two meet

extension View {
    /// The success page's moment (one line where the check is drawn): a ring of the Thread's light
    /// blooms out from the check, sparks fly from it, and two notes meet. Reduce Motion: a glow
    /// that comes and goes.
    func pairingCelebration() -> some View { modifier(PairingCelebration()) }
}

struct PairingCelebration: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var go = false

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    if reduceMotion {
                        Circle().fill(MacOSLook.intelligenceAngular).blur(radius: 24)
                            .opacity(go ? 0 : 0.5)
                            .animation(.easeOut(duration: 1.4).delay(0.2), value: go)
                    } else {
                        // The ring.
                        MacOSLook.intelligenceAngular
                            .mask(Circle().strokeBorder(lineWidth: 3))
                            .blur(radius: 1)
                            .scaleEffect(go ? 2.6 : 0.7)
                            .opacity(go ? 0 : 0.9)
                            .animation(.easeOut(duration: 1.0), value: go)
                        // A soft wash behind it.
                        Circle().fill(MacOSLook.intelligenceAngular).blur(radius: 28)
                            .scaleEffect(go ? 1.6 : 0.4)
                            .opacity(go ? 0 : 0.55)
                            .animation(.easeOut(duration: 1.3), value: go)
                        // The sparks.
                        ForEach(0..<14, id: \.self) { i in
                            let a = Double(i) / 14 * 2 * .pi + 0.2
                            let r: CGFloat = i.isMultiple(of: 2) ? 96 : 74
                            Circle()
                                .fill(MacOSLook.intelligence[i % MacOSLook.intelligence.count])
                                .frame(width: i.isMultiple(of: 3) ? 7 : 5)
                                .offset(x: go ? CGFloat(cos(a)) * r : 0, y: go ? CGFloat(sin(a)) * r : 0)
                                .opacity(go ? 0 : 1)
                                .animation(.easeOut(duration: 0.9).delay(0.04 * Double(i % 4)), value: go)
                        }
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .onAppear {
                guard !go else { return }
                // A breath after the page arrives, so it's seen.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 180_000_000)
                    go = true
                    SoundCues.play(.paired)
                }
            }
    }
}

// MARK: The Mac pill says hello

/// When the Mac comes within reach — the first connect after pairing, a wake, back after it was
/// gone (not every return from the background: those keep looking connected) — a ring of light
/// spreads once from the pill's dot, like a Mac's menu bar extra lighting up. Reduce Motion: none
/// (the dot's own colour says it).
struct ConnectRipple: ViewModifier {
    var connected: Bool
    var color: Color = Light.cyan
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ring = 0

    struct Ring { var scale: CGFloat = 1; var opacity: Double = 0 }

    func body(content: Content) -> some View {
        content
            .overlay {
                Circle()
                    .strokeBorder(color, lineWidth: 1.5)
                    .keyframeAnimator(initialValue: Ring(), trigger: ring) { c, v in
                        c.scaleEffect(v.scale).opacity(v.opacity)
                    } keyframes: { _ in
                        KeyframeTrack(\.scale) {
                            LinearKeyframe(1, duration: 0.01)
                            CubicKeyframe(3.4, duration: 0.85)
                            LinearKeyframe(1, duration: 0.01)
                        }
                        KeyframeTrack(\.opacity) {
                            LinearKeyframe(0.9, duration: 0.01)
                            CubicKeyframe(0, duration: 0.85)
                        }
                    }
                    .allowsHitTesting(false)
            }
            .onChange(of: connected) { was, now in
                if now, !was, !reduceMotion { ring += 1 }
            }
    }
}

// MARK: The wallpaper's depth

/// The Mac's wallpaper behind the phone's desktop, with a little depth: it drifts a few points
/// against the phone's tilt, as the Home Screen's wallpaper does (`UIInterpolatingMotionEffect` —
/// the system's own parallax, applied by UIKit; no Core Motion of ours, nothing per frame in
/// SwiftUI). UIKit turns it off under Reduce Motion; it's off in Low Power Mode too.
struct ParallaxImage: UIViewRepresentable {
    var image: UIImage
    /// How far it drifts at the most, and how much it's drawn past the edges so none shows.
    static let reach: CGFloat = 12

    func makeUIView(context: Context) -> ParallaxImageView { ParallaxImageView() }
    func updateUIView(_ v: ParallaxImageView, context: Context) { v.imageView.image = image }
}

final class ParallaxImageView: UIView {
    let imageView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        isUserInteractionEnabled = false
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        addSubview(imageView)
        NotificationCenter.default.addObserver(self, selector: #selector(powerChanged),
                                               name: .NSProcessInfoPowerStateDidChange, object: nil)
        applyEffects()
    }
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        let r = ParallaxImage.reach
        imageView.frame = bounds.insetBy(dx: -r, dy: -r)
    }

    @objc private func powerChanged() { DispatchQueue.main.async { [weak self] in self?.applyEffects() } }

    private func applyEffects() {
        imageView.motionEffects.forEach(imageView.removeMotionEffect)
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        let r = ParallaxImage.reach
        let x = UIInterpolatingMotionEffect(keyPath: "center.x", type: .tiltAlongHorizontalAxis)
        x.minimumRelativeValue = -r; x.maximumRelativeValue = r
        let y = UIInterpolatingMotionEffect(keyPath: "center.y", type: .tiltAlongVerticalAxis)
        y.minimumRelativeValue = -r; y.maximumRelativeValue = r
        let group = UIMotionEffectGroup()
        group.motionEffects = [x, y]
        imageView.addMotionEffect(group)
    }
}
