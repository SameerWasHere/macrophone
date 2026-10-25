import MacrophoneKit
import SwiftUI
import UIKit

// The trackpad page (Oct 19 2026): a plate the size of the mic's area that works like a laptop's
// trackpad. One finger moves a pointer drawn in the window above (faster when the finger is);
// a tap clicks where it is; a second tap at once is a double-click; a tap, then a touch that stays
// and moves, drags (a hold that stays also starts a drag — let go without moving, it's a slow
// click); two fingers tapped is a right-click; two fingers moving scroll the window under the
// pointer, with a coast after a flick, as a swipe on the window does. The pointer stays where it's
// left, so hovering works, and the Mac draws its own pointer into the picture meanwhile.

struct TrackpadPage: View {
    @ObservedObject var input: MacInput
    @ObservedObject var watcher: Watcher
    /// A folded Duo's deck (Oct 25 2026): the trackpad is the whole half, like a laptop's — an
    /// even inset all round and the faint inner outline of a trackpad.
    var big = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: WatchLook.bezel, style: .continuous)
        ZStack {
            shape.fill(Ink.raised)
                .overlay(shape.fill(LinearGradient(colors: [Ink.ink.opacity(0.05), .clear], startPoint: .top, endPoint: .bottom)))
                .overlay(SpecularEdge(shape: shape))
                .overlay(shape.strokeBorder(contrast == .increased ? Ink.ink.opacity(0.45) : Ink.lineStrong, lineWidth: 1))
            if big {
                // The outline of the pad itself, a step in from the plate's edge, barely there.
                RoundedRectangle(cornerRadius: WatchLook.bezel - 6, style: .continuous)
                    .strokeBorder(Ink.ink.opacity(0.06), lineWidth: 1)
                    .padding(10)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            TrackpadSurface(input: input, watcher: watcher)
                .clipShape(shape)
            if !input.trackpadUsed {
                VStack(spacing: 6) {
                    Image(systemName: "hand.point.up.left")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Light.cyan)
                    Text("Move a finger to point · tap to click")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Ink.ink)
                    Text("Two fingers scroll, or tap for a right-click. Tap, then hold and move, to drag.")
                        .font(.caption)
                        .foregroundStyle(Ink.secondary)
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, WatchLook.sideMargin)
        .padding(.top, big ? 8 : 0)
        .padding(.bottom, 8)
        .animation(.easeOut(duration: 0.3), value: input.trackpadUsed)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Trackpad")
        .accessibilityValue("Pointer \(Int((input.pointer.x * 100).rounded())) percent across, \(Int((input.pointer.y * 100).rounded())) percent down")
        .accessibilityHint("Moves the pointer in \(watcher.name)'s window on your Mac. One finger points, a tap clicks, two fingers scroll or right-click.")
        .accessibilityIdentifier("input-trackpad")
    }
}

/// The surface itself: raw touches, so a tap, a double-tap, a tap-and-hold drag and two fingers
/// are told apart without a recognizer's delays.
struct TrackpadSurface: UIViewRepresentable {
    @ObservedObject var input: MacInput
    @ObservedObject var watcher: Watcher

    func makeUIView(context: Context) -> TrackpadTouchView {
        let v = TrackpadTouchView()
        wire(v)
        return v
    }

    func updateUIView(_ v: TrackpadTouchView, context: Context) { wire(v) }

    private func wire(_ v: TrackpadTouchView) {
        v.onMove = { d, dt in input.pointerMoved(by: d, dt: dt) }
        v.onTap = { n in input.tap(count: n) }
        v.onRightTap = { input.rightTap() }
        v.onDragBegan = { input.dragBegan() }
        v.onDragMoved = { d, dt in input.dragMoved(by: d, dt: dt) }
        v.onDragEnded = { input.dragEnded() }
        v.onScroll = { d in watcher.scroll(at: input.pointer.point, by: d) }
        v.onScrollPhase = { p in watcher.scrollPhase(p, at: input.pointer.point) }
        v.phased = watcher.macCanScroll
        v.windowPoints = input.windowPoints
    }
}

final class TrackpadTouchView: UIView {
    var onMove: (CGVector, TimeInterval) -> Void = { _, _ in }
    var onTap: (Int) -> Void = { _ in }
    var onRightTap: () -> Void = {}
    var onDragBegan: () -> Void = {}
    var onDragMoved: (CGVector, TimeInterval) -> Void = { _, _ in }
    var onDragEnded: () -> Void = {}
    /// Two-finger scrolling, as fractions of the window (content follows the fingers).
    var onScroll: (CGVector) -> Void = { _ in }
    var onScrollPhase: (WatchScrollPhase) -> Void = { _ in }
    var phased = false
    var windowPoints = CGSize(width: 1400, height: 900)

    /// A tap within this of the last is its double (then triple); a touch that lands within it
    /// and moves is a drag.
    static let tapGap: TimeInterval = 0.35
    static let holdToDrag: TimeInterval = 0.5
    static let slop: CGFloat = 5

    private var touch: UITouch?
    private var downAt: TimeInterval = 0
    private var downPoint = CGPoint.zero
    private var last = CGPoint.zero
    private var lastTime: TimeInterval = 0
    private var moved = false
    private var dragging = false
    private var dragArmed = false
    private var holdTimer: Timer?
    private var lastTapAt: TimeInterval = -10
    private var lastTapCount = 0
    /// Two fingers: a tap (neither moved) or a scroll.
    private var second: UITouch?
    private var twoMoved = false
    private var twoLast = CGPoint.zero
    private var twoLastTime: TimeInterval = 0
    private var twoVelocity = CGVector.zero
    private var twoBegan = false
    private var pendingScroll = CGVector.zero
    private var link: CADisplayLink?
    private var momentum: ScrollMomentum?
    private var lastTick: CFTimeInterval = 0
    /// A soft light under each finger (the carousel fixes, Oct 19 2026): the plate answers the
    /// touch, so the trackpad feels alive — it follows the finger and fades as it lifts.
    private var glows: [ObjectIdentifier: CALayer] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError() }

    private func point(_ t: UITouch) -> CGPoint { t.location(in: self) }

    // MARK: The finger's light

    private func glowBegan(_ t: UITouch) {
        let r: CGFloat = 56
        let g = CAGradientLayer()
        g.type = .radial
        g.colors = [UIColor(Light.cyan).withAlphaComponent(0.30).cgColor, UIColor(Light.cyan).withAlphaComponent(0.10).cgColor, UIColor.clear.cgColor]
        g.locations = [0, 0.45, 1]
        g.startPoint = CGPoint(x: 0.5, y: 0.5)
        g.endPoint = CGPoint(x: 1, y: 1)
        g.bounds = CGRect(x: 0, y: 0, width: r * 2, height: r * 2)
        g.cornerRadius = r
        g.position = point(t)
        layer.addSublayer(g)
        glows[ObjectIdentifier(t)] = g
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.55
        grow.toValue = 1
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.14
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        g.add(group, forKey: "in")
    }

    private func glowMoved(_ t: UITouch) {
        guard let g = glows[ObjectIdentifier(t)] else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        g.position = point(t)
        CATransaction.commit()
    }

    private func glowEnded(_ t: UITouch) {
        guard let g = glows.removeValue(forKey: ObjectIdentifier(t)) else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1
        grow.toValue = UIAccessibility.isReduceMotionEnabled ? 1 : 1.35
        let group = CAAnimationGroup()
        group.animations = [fade, grow]
        group.duration = 0.32
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        g.opacity = 0
        g.add(group, forKey: "out")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) { g.removeFromSuperlayer() }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let now = CACurrentMediaTime()
        for t in touches {
            glowBegan(t)
            if touch == nil {
                touch = t
                downAt = now
                downPoint = point(t)
                last = downPoint
                lastTime = now
                moved = false
                dragging = false
                endMomentum()
                // Landed right after a tap: a move now is a drag from the tapped spot.
                dragArmed = now - lastTapAt < Self.tapGap
                holdTimer?.invalidate()
                holdTimer = Timer.scheduledTimer(withTimeInterval: Self.holdToDrag, repeats: false) { [weak self] _ in
                    guard let self, let _ = self.touch, !self.moved, !self.dragging, self.second == nil else { return }
                    self.dragging = true
                    self.onDragBegan()
                }
            } else if second == nil {
                second = t
                holdTimer?.invalidate()
                twoMoved = false
                twoBegan = false
                twoLast = midpoint()
                twoLastTime = now
                twoVelocity = .zero
                pendingScroll = .zero
            }
        }
    }

    private func midpoint() -> CGPoint {
        guard let a = touch, let b = second else { return last }
        let p = point(a), q = point(b)
        return CGPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let now = CACurrentMediaTime()
        touches.forEach(glowMoved)
        if second != nil {
            // Two fingers: a scroll, once they've moved past the slop.
            let m = midpoint()
            let d = CGVector(dx: m.x - twoLast.x, dy: m.y - twoLast.y)
            let dt = max(now - twoLastTime, 1.0 / 240)
            if !twoMoved {
                guard abs(m.x - twoLast.x) + abs(m.y - twoLast.y) > Self.slop else { return }
                twoMoved = true
                if phased, !twoBegan { twoBegan = true; onScrollPhase(.began) }
                startLink()
            }
            twoVelocity = CGVector(dx: d.dx / dt, dy: d.dy / dt)
            twoLast = m
            twoLastTime = now
            // The window moves as far as the fingers did, with the trackpad's gain.
            let s = TrackpadMotion.step(d, dt: dt)
            pendingScroll.dx += s.dx / windowPoints.width
            pendingScroll.dy += s.dy / windowPoints.height
            return
        }
        guard let t = touch, touches.contains(t) else { return }
        let p = point(t)
        if !moved {
            guard abs(p.x - downPoint.x) + abs(p.y - downPoint.y) > Self.slop else { return }
            moved = true
            holdTimer?.invalidate()
            if dragArmed, !dragging { dragging = true; onDragBegan() }
        }
        let d = CGVector(dx: p.x - last.x, dy: p.y - last.y)
        let dt = now - lastTime
        last = p
        lastTime = now
        if dragging { onDragMoved(d, dt) } else { onMove(d, dt) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches, cancelled: false) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches, cancelled: true) }

    private func lift(_ touches: Set<UITouch>, cancelled: Bool) {
        let now = CACurrentMediaTime()
        touches.forEach(glowEnded)
        if let s = second, touches.contains(s) || touches.contains(where: { $0 === touch }) {
            // The two-finger gesture ends when either lifts.
            second = nil
            if twoMoved {
                flushScroll()
                if phased {
                    onScrollPhase(.ended)
                    if !cancelled, let m = ScrollMomentum(velocity: twoVelocity) {
                        momentum = m
                        onScrollPhase(.momentumBegan)
                        step(dt: 1 / ScrollMomentum.tickRate)
                    } else { stopLink() }
                } else { stopLink() }
            } else if !cancelled, !moved {
                onRightTap()
            }
            // The first finger, if it's still down, starts over as a plain touch.
            if let t = touch, !touches.contains(t) {
                downPoint = point(t)
                last = downPoint
                moved = false
                dragArmed = false
            } else {
                touch = nil
                holdTimer?.invalidate()
            }
            return
        }
        guard let t = touch, touches.contains(t) else { return }
        holdTimer?.invalidate()
        touch = nil
        if dragging {
            dragging = false
            onDragEnded()
            lastTapAt = -10
        } else if !moved, !cancelled, now - downAt < 0.6 {
            let count = now - lastTapAt < Self.tapGap ? min(lastTapCount + 1, 3) : 1
            lastTapAt = now
            lastTapCount = count
            onTap(count)
        } else {
            lastTapAt = -10
        }
    }

    // MARK: Two-finger scrolling: a delta a display frame, then the coast

    private func startLink() {
        guard link == nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        let rate = Float(ScrollMomentum.tickRate)
        l.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        l.add(to: .main, forMode: .common)
        link = l
        lastTick = CACurrentMediaTime()
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
        momentum = nil
    }

    @objc private func tick(_ l: CADisplayLink) {
        let now = l.targetTimestamp
        let dt = now - lastTick
        lastTick = now
        if momentum != nil { step(dt: dt) } else { flushScroll() }
    }

    private func step(dt: CFTimeInterval) {
        guard var m = momentum, let s = m.step(dt: dt) else { endMomentum(); return }
        momentum = m
        onScroll(CGVector(dx: s.dx / windowPoints.width, dy: s.dy / windowPoints.height))
    }

    private func endMomentum() {
        let coasting = momentum != nil
        stopLink()
        if coasting, phased { onScrollPhase(.momentumEnded) }
    }

    private func flushScroll() {
        guard abs(pendingScroll.dx) + abs(pendingScroll.dy) > 0.0002 else { return }
        onScroll(pendingScroll)
        pendingScroll = .zero
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil { endMomentum(); holdTimer?.invalidate() }
    }
}

// MARK: The pointer, drawn over the window

/// The pointer the trackpad moves (the carousel fixes, Oct 19 2026 — Sameer: the trackpad
/// "doesn't move the cursor"; it did, 1,027 moves reached the Mac, but the phone's ring was small,
/// started at the window's centre off the zoomed view and sat under the Newest button): an arrow
/// like the Mac's own, white with a dark edge and a cyan glow so it reads on a light or a dark
/// window, drawn above the picture and everything over it. Placed by the window's viewer on
/// every move, scroll and zoom — in UIKit, nothing through SwiftUI per frame. The one pointer:
/// the Mac no longer draws its own into the stream (it lagged this one as a ghost).
final class PointerSpriteView: UIView {
    private let glow = CAShapeLayer()
    private let arrow = CAShapeLayer()
    private(set) var shown = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        let path = Self.arrowPath
        for l in [glow, arrow] {
            l.path = path
            l.contentsScale = UIScreen.main.scale
            l.lineJoin = .round
            l.bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
            l.anchorPoint = .zero
            layer.addSublayer(l)
        }
        glow.fillColor = UIColor(Light.cyan).cgColor
        glow.strokeColor = UIColor(Light.cyan).cgColor
        glow.lineWidth = 3
        glow.opacity = 0.55
        glow.shadowColor = UIColor(Light.cyan).cgColor
        glow.shadowOpacity = 1
        glow.shadowRadius = 6
        glow.shadowOffset = .zero
        arrow.fillColor = UIColor.white.cgColor
        arrow.strokeColor = UIColor.black.withAlphaComponent(0.85).cgColor
        arrow.lineWidth = 1.2
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The Mac's arrow, the tip at the origin, about 16 × 25 points.
    static var arrowPath: CGPath {
        let p = UIBezierPath()
        let k: CGFloat = 1.3
        p.move(to: .zero)
        p.addLine(to: CGPoint(x: 0, y: 17.3 * k))
        p.addLine(to: CGPoint(x: 4.2 * k, y: 13.3 * k))
        p.addLine(to: CGPoint(x: 7.3 * k, y: 19.6 * k))
        p.addLine(to: CGPoint(x: 10.4 * k, y: 18.2 * k))
        p.addLine(to: CGPoint(x: 7.3 * k, y: 12 * k))
        p.addLine(to: CGPoint(x: 12.8 * k, y: 12 * k))
        p.close()
        return p.cgPath
    }

    /// The tip here, in this view's coordinates. The first placing after a hide comes in with a
    /// pulse, so the eye finds it.
    func place(_ p: CGPoint) {
        // The tip is the point; the body falls right and down from it — at the window's right or
        // bottom edge it would be cut off, so there the arrow mirrors to stay whole.
        let flipX: CGFloat = p.x > bounds.width - 22 ? -1 : 1
        let flipY: CGFloat = p.y > bounds.height - 30 ? -1 : 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [glow, arrow] {
            l.position = p
            l.transform = CATransform3DMakeScale(flipX, flipY, 1)
        }
        CATransaction.commit()
        guard !shown else { return }
        shown = true
        isHidden = false
        // (The pulse animates the scale, which the mirror also uses: none at an edge.)
        guard !UIAccessibility.isReduceMotionEnabled, flipX == 1, flipY == 1 else { return }
        let pulse = CABasicAnimation(keyPath: "transform.scale")
        pulse.fromValue = 1.9
        pulse.toValue = 1
        pulse.duration = 0.28
        pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.18
        arrow.add(pulse, forKey: "in")
        arrow.add(fade, forKey: "fade")
        glow.add(pulse, forKey: "in")
    }

    func hide() {
        shown = false
        isHidden = true
    }
}

/// The sprite in the window's own stack, above everything drawn over the picture.
struct PointerOverlay: UIViewRepresentable {
    let sprite: PointerSpriteView

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        sprite.frame = v.bounds
        sprite.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        v.addSubview(sprite)
        return v
    }

    func updateUIView(_ v: UIView, context: Context) {
        if sprite.superview !== v {
            sprite.removeFromSuperview()
            sprite.frame = v.bounds
            v.addSubview(sprite)
        }
    }
}

/// What the window's view and the pointer share: the sprite the viewer places, and the viewer
/// itself (for where the visible middle is when the trackpad opens).
@MainActor
final class PointerLink: ObservableObject {
    let sprite = PointerSpriteView()
    weak var viewer: ViewerScrollView?
}
