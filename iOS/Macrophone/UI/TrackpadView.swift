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
    /// The plate's room at the sides.
    var inset: CGFloat = WatchLook.sideMargin
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: WatchLook.bezel, style: .continuous)
        ZStack {
            // A Force Touch trackpad's glass: aluminium in light, space black in dark (Nov 1 2026).
            ForceTouchSurface(corner: WatchLook.bezel)
                .overlay { if contrast == .increased { shape.strokeBorder(Ink.ink.opacity(0.45), lineWidth: 1) } }
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
                    Text(big ? "Two fingers scroll, pinch or right-click. Three fingers: up for Mission Control, sideways for your desktops, tap to look up. Spread four for the desktop." : "Two fingers scroll, or tap for a right-click. Tap, then hold and move, to drag.")
                        .font(.caption)
                        .foregroundStyle(Ink.secondary)
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, inset)
        .padding(.top, big ? 8 : 0)
        .padding(.bottom, 8)
        .animation(.easeOut(duration: 0.3), value: input.trackpadUsed)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Trackpad")
        .accessibilityValue("Pointer \(Int((input.pointer.x * 100).rounded())) percent across, \(Int((input.pointer.y * 100).rounded())) percent down")
        .accessibilityHint("Moves the pointer in \(watcher.name)'s window on your Mac. One finger points, a tap clicks, two fingers scroll, pinch to zoom or right-click, three fingers sweep to Mission Control or another desktop or tap to look up a word, four fingers spread show the desktop.")
        .accessibilityIdentifier("input-trackpad")
    }
}

/// The surface itself: raw touches, so a tap, a double-tap, a tap-and-hold drag and two fingers
/// are told apart without a recognizer's delays.
struct TrackpadSurface: UIViewRepresentable {
    @ObservedObject var input: MacInput
    @ObservedObject var watcher: Watcher
    /// Any touch that does something (full screen's pad stays up while it's used).
    var onUse: () -> Void = {}

    func makeUIView(context: Context) -> TrackpadTouchView {
        let v = TrackpadTouchView()
        wire(v)
        return v
    }

    func updateUIView(_ v: TrackpadTouchView, context: Context) { wire(v) }

    private func wire(_ v: TrackpadTouchView) {
        let used = onUse
        v.onMove = { d, dt in used(); input.pointerMoved(by: d, dt: dt) }
        v.onTap = { n in used(); input.tap(count: n) }
        v.onRightTap = { used(); input.rightTap() }
        v.onDragBegan = { used(); input.dragBegan() }
        v.onDragMoved = { d, dt in used(); input.dragMoved(by: d, dt: dt) }
        v.onDragEnded = { used(); input.dragEnded() }
        v.onScroll = { d in used(); watcher.scroll(at: input.pointer.point, by: d) }
        v.onScrollPhase = { p in used(); watcher.scrollPhase(p, at: input.pointer.point) }
        v.onThreeSwipe = { dir in used(); input.threeFingerSwipe(dir) }
        v.onGesture = { g in used(); input.trackpadGesture(g) }
        v.phased = watcher.macCanScroll
        v.windowPoints = input.windowPoints
    }
}

/// A sweep of three fingers, as the Mac's trackpad has them.
enum TrackpadSwipe { case up, down, left, right }

/// The Mac trackpad's other moves (Oct 31 2026, Sameer: "enable all the Mac multi finger track
/// pad gestures"): a pinch zooms, three fingers tapped look a word up, four fingers spread show
/// the desktop. (A sweep of three or four is `TrackpadSwipe`.)
enum TrackpadGesture { case zoomIn, zoomOut, lookUp, showDesktop }

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
    /// Three fingers swept (the Mac's own trackpad moves): Mission Control, App Exposé, the
    /// desktops either side.
    var onThreeSwipe: (TrackpadSwipe) -> Void = { _ in }
    /// A pinch, a three-finger tap, a four-finger spread.
    var onGesture: (TrackpadGesture) -> Void = { _ in }
    /// Three fingers down: everything else waits until every finger has lifted.
    private var third: UITouch?
    private var threeStart = CGPoint.zero
    private var threeFired = false
    private var threeAt: TimeInterval = 0
    /// The most fingers down at once in this three-finger gesture, and how far apart they were
    /// when the fourth landed (a spread of four shows the desktop).
    private var mostFingers = 0
    private var fourSpread: CGFloat = 0
    private var held: Set<ObjectIdentifier> = []
    /// Every finger down, for the centroid and the spread of three or four.
    private var fingers: [ObjectIdentifier: UITouch] = [:]
    /// Two fingers moving apart or together: a pinch, not a scroll (decided as they leave the
    /// slop); the spread at the last zoom step.
    private var pinching = false
    private var pinchBase: CGFloat = 0
    private var twoStartSpread: CGFloat = 0

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
            held.insert(ObjectIdentifier(t))
            fingers[ObjectIdentifier(t)] = t
            if third != nil {
                mostFingers = max(mostFingers, held.count)
                if held.count == 4, !threeFired { fourSpread = spread(); threeStart = threeCentroid() }
                continue
            }
            if touch != nil, second != nil {
                // A third finger: a sweep of three. A scroll under way ends first.
                third = t
                holdTimer?.invalidate()
                if twoMoved {
                    flushScroll()
                    if phased { onScrollPhase(.ended) }
                    stopLink()
                }
                threeStart = threeCentroid()
                threeFired = false
                threeAt = now
                mostFingers = held.count
                fourSpread = 0
                continue
            }
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
                pinching = false
                twoStartSpread = twoSpread()
                pinchBase = twoStartSpread
            }
        }
    }

    private func threeCentroid() -> CGPoint {
        let ts = Array(fingers.values)
        guard !ts.isEmpty else { return .zero }
        let ps = ts.map(point)
        return CGPoint(x: ps.map(\.x).reduce(0, +) / CGFloat(ps.count), y: ps.map(\.y).reduce(0, +) / CGFloat(ps.count))
    }

    /// How far the fingers are from their middle, on average.
    private func spread() -> CGFloat {
        let c = threeCentroid(), ps = fingers.values.map(point)
        guard !ps.isEmpty else { return 0 }
        return ps.map { hypot($0.x - c.x, $0.y - c.y) }.reduce(0, +) / CGFloat(ps.count)
    }

    private func twoSpread() -> CGFloat {
        guard let a = touch, let b = second else { return 0 }
        let p = point(a), q = point(b)
        return hypot(p.x - q.x, p.y - q.y)
    }

    private func midpoint() -> CGPoint {
        guard let a = touch, let b = second else { return last }
        let p = point(a), q = point(b)
        return CGPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let now = CACurrentMediaTime()
        touches.forEach(glowMoved)
        if third != nil {
            guard !threeFired else { return }
            // Four fingers spread apart: the desktop (the Mac's thumb-and-three-fingers spread).
            if held.count >= 4, fourSpread > 0, spread() > fourSpread * 1.4 {
                threeFired = true
                onGesture(.showDesktop)
                return
            }
            let c = threeCentroid()
            let dx = c.x - threeStart.x, dy = c.y - threeStart.y
            guard max(abs(dx), abs(dy)) > 50 else { return }
            threeFired = true
            onThreeSwipe(abs(dy) > abs(dx) ? (dy < 0 ? .up : .down) : (dx < 0 ? .left : .right))
            return
        }
        if second != nil {
            let m = midpoint()
            let d = CGVector(dx: m.x - twoLast.x, dy: m.y - twoLast.y)
            let dt = max(now - twoLastTime, 1.0 / 240)
            if pinching {
                // A zoom step each time the fingers are a quarter further apart or closer.
                let sp = twoSpread()
                if sp > pinchBase * 1.25 { pinchBase = sp; onGesture(.zoomIn) }
                else if sp < pinchBase / 1.25 { pinchBase = sp; onGesture(.zoomOut) }
                return
            }
            if !twoMoved {
                // Two fingers: a pinch when they mostly move apart or together, else a scroll,
                // once they've moved past the slop.
                let change = abs(twoSpread() - twoStartSpread)
                let travel = abs(m.x - twoLast.x) + abs(m.y - twoLast.y)
                if change > 18, change > travel * 1.5 {
                    pinching = true
                    pinchBase = twoStartSpread
                    return
                }
                guard travel > Self.slop else { return }
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
        touches.forEach { held.remove(ObjectIdentifier($0)); fingers.removeValue(forKey: ObjectIdentifier($0)) }
        if third != nil {
            // A sweep of three is over only when every finger is up; three that land and lift
            // without moving are a tap: look up the word under the pointer.
            if held.isEmpty {
                if !threeFired, !cancelled, mostFingers == 3, now - threeAt < 0.5 { onGesture(.lookUp) }
                third = nil
                second = nil
                touch = nil
                moved = false
                twoMoved = false
                lastTapAt = -10
            }
            return
        }
        if let s = second, touches.contains(s) || touches.contains(where: { $0 === touch }) {
            // The two-finger gesture ends when either lifts.
            second = nil
            if pinching {
                pinching = false
            } else if twoMoved {
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
/// started at the window's centre off the zoomed view and sat under the Newest button), drawn
/// above the picture and everything over it. Placed by the window's viewer on every move, scroll
/// and zoom — in UIKit, nothing through SwiftUI per frame. The one pointer: the Mac no longer
/// draws its own into the stream (it lagged this one as a ghost).
///
/// Nov 1 2026 (Sameer: "make it a bit smaller … it should contextually change just like it does
/// on the Mac"): it is the Mac's own pointer — the arrow, the I-beam over text, the hand over a
/// link, the resize arrows at an edge — sent by a Mac that names `MacCursor.feature` each time
/// its shape changes (`PointerShape`), drawn at its size in points. Until one arrives (and for a
/// Mac from before) it's a drawn arrow like the Mac's: black with a white edge, the same size.
final class PointerSpriteView: UIView {
    private let arrow = CAShapeLayer()
    /// The Mac's own cursor, when it sent one.
    private let shape = CALayer()
    private(set) var shown = false
    private var lastPoint: CGPoint?
    private var shapeID: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        arrow.path = Self.arrowPath
        arrow.contentsScale = UIScreen.main.scale
        arrow.lineJoin = .round
        arrow.bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        arrow.anchorPoint = .zero
        arrow.fillColor = UIColor.black.cgColor
        arrow.strokeColor = UIColor.white.cgColor
        arrow.lineWidth = 1.3
        shape.contentsScale = UIScreen.main.scale
        shape.contentsGravity = .resize
        shape.magnificationFilter = .linear
        for l in [arrow, shape] {
            l.shadowColor = UIColor.black.cgColor
            l.shadowOpacity = 0.35
            l.shadowRadius = 1.5
            l.shadowOffset = CGSize(width: 0, height: 1)
            layer.addSublayer(l)
        }
        isHidden = true
        applyShape()
        NotificationCenter.default.addObserver(self, selector: #selector(shapeChanged), name: PointerShape.changed, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The Mac's arrow, the tip at the origin, about 13 × 20 points.
    static var arrowPath: CGPath {
        let p = UIBezierPath()
        p.move(to: .zero)
        p.addLine(to: CGPoint(x: 0, y: 17.3))
        p.addLine(to: CGPoint(x: 4.2, y: 13.3))
        p.addLine(to: CGPoint(x: 7.3, y: 19.6))
        p.addLine(to: CGPoint(x: 10.4, y: 18.2))
        p.addLine(to: CGPoint(x: 7.3, y: 12))
        p.addLine(to: CGPoint(x: 12.8, y: 12))
        p.close()
        return p.cgPath
    }

    @objc private func shapeChanged() {
        applyShape()
        if let lastPoint, shown { place(lastPoint) }
    }

    /// The Mac's cursor (or the drawn arrow when there's none), sized in points with its hot spot
    /// at the layer's anchor — so placing it puts the point that clicks under the pointer.
    private func applyShape() {
        let s = PointerShape.shared
        guard s.id != shapeID else { return }
        shapeID = s.id
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let image = s.image?.cgImage, s.size.width > 0, s.size.height > 0 {
            shape.contents = image
            shape.bounds = CGRect(origin: .zero, size: s.size)
            shape.anchorPoint = CGPoint(x: s.hotSpot.x / s.size.width, y: s.hotSpot.y / s.size.height)
            shape.isHidden = false
            arrow.isHidden = true
        } else {
            shape.contents = nil
            shape.isHidden = true
            arrow.isHidden = false
        }
        CATransaction.commit()
    }

    /// The point that clicks here, in this view's coordinates. The first placing after a hide
    /// comes in with a pulse, so the eye finds it.
    func place(_ p: CGPoint) {
        lastPoint = p
        let mac = !shape.isHidden
        // The drawn arrow falls right and down from its tip — at the window's right or bottom
        // edge it would be cut off, so there it mirrors to stay whole. (The Mac's cursors stay as
        // they are, as on the Mac at the screen's edge: a mirrored I-beam or hand would read wrong.)
        let flipX: CGFloat = !mac && p.x > bounds.width - 16 ? -1 : 1
        let flipY: CGFloat = !mac && p.y > bounds.height - 24 ? -1 : 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.position = p
        arrow.position = p
        arrow.transform = CATransform3DMakeScale(flipX, flipY, 1)
        CATransaction.commit()
        guard !shown else { return }
        shown = true
        isHidden = false
        // (The pulse animates the scale, which the mirror also uses: none at an edge.)
        guard !UIAccessibility.isReduceMotionEnabled, flipX == 1, flipY == 1 else { return }
        let pulse = CABasicAnimation(keyPath: "transform.scale")
        pulse.fromValue = 1.8
        pulse.toValue = 1
        pulse.duration = 0.28
        pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.18
        for l in [arrow, shape] {
            l.add(pulse, forKey: "in")
            l.add(fade, forKey: "fade")
        }
    }

    func hide() {
        shown = false
        isHidden = true
    }
}

/// The Mac's pointer as it looks now (`MacCursor`, sent while the trackpad's pointer is up and on
/// each change), shared by every pointer on screen (two can be alive in a cross-fade). Nil: the
/// drawn arrow. Kept across shows — the same Mac sends its shape again on each — and dropped on a
/// switch to another Mac.
@MainActor
final class PointerShape {
    static let shared = PointerShape()
    static let changed = Notification.Name("macrophone.pointerShape")
    private(set) var id: String?
    private(set) var image: UIImage?
    /// In points, and the point that clicks from the top left.
    private(set) var size: CGSize = .zero
    private(set) var hotSpot: CGPoint = .zero

    func set(_ c: MacCursor?) {
        guard c?.id != id else { return }
        guard let c, let img = UIImage(data: c.png, scale: 2) else {
            guard id != nil else { return }
            id = nil; image = nil; size = .zero; hotSpot = .zero
            NotificationCenter.default.post(name: Self.changed, object: nil)
            return
        }
        id = c.id
        image = img
        size = CGSize(width: c.width, height: c.height)
        hotSpot = CGPoint(x: c.hotX, y: c.hotY)
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }
}

extension AppModel: LinkClientCursorDelegate {
    func linkClient(_ client: LinkClient, macCursor: MacCursor) {
        PointerShape.shared.set(macCursor)
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
