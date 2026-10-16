import MacrophoneKit
import SwiftUI
import UIKit

// Watching (Oct 14 2026) — the picked app's window on the Mac, in the area above the Thread:
//
//   ● LIVE · CLAUDE                        [Done]
//   ┌──────────────────────────────────────────┐
//   │  the window, pinned to its newest output │  tap = a click there on the Mac;
//   │  (centred on the column you type in)     │  pinch to zoom, drag to look around
//   └──────────────────────────────────── [Newest] (once you've moved away)
//   [ Esc ] [ ↑ ] [ ↓ ] [ Return ]                 the same keys in every app: move through a
//                                                 menu, confirm, back out
//
// The mic, the Thread and the status line don't move. Holding the mic shrinks the window to a
// strip at the top, so the question stays in view while the words take the rest.

struct WatchPanel: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var watcher: Watcher
    var compact = false

    var body: some View {
        VStack(spacing: compact ? 8 : 10) {
            header
            WatchWindow(watcher: watcher, interactive: true)
                .frame(maxHeight: .infinity)
            WatchActions(watcher: watcher)
                .opacity(watcher.phase == .live ? 1 : 0)
                .allowsHitTesting(watcher.phase == .live)
                .accessibilityHidden(watcher.phase != .live)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, compact ? 8 : 14)
        // The window is a picture; its chrome (the kicker, Done, the keys) stays a moderate size so
        // the whole panel always fits above the Thread — at accessibility sizes it overflowed both ends.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 10) {
            WatchKicker(watcher: watcher)
            Spacer(minLength: 8)
            Button("Done") {
                Haptics.tick()
                watcher.close()
            }
            .font(.subheadline.weight(.semibold))
            .nativeGlassButton()
            .accessibilityHint("Stops showing the window and brings back Send to and Cleanup.")
            .accessibilityIdentifier("watch-done")
        }
        .frame(minHeight: 44)
    }
}

/// "● LIVE · CLAUDE", "PAUSED · CLAUDE", "MAC NOT CONNECTED".
struct WatchKicker: View {
    @ObservedObject var watcher: Watcher
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            // Breathes while live, driven by Core Animation: it costs the app nothing per frame
            // (a SwiftUI repeat animation re-rendered the view sixty times a second).
            LiveDot(color: UIColor(color), breathing: watcher.phase == .live && !reduceMotion)
                .frame(width: 8, height: 8)
                .shadow(color: color.opacity(0.8), radius: 4)
                .accessibilityHidden(true)
            Text(words.uppercased())
                .font(.mono(.caption, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(watcher.phase == .live ? Ink.secondary : Ink.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(words)
        .accessibilityIdentifier("watch-kicker")
    }

    private var words: String {
        let n = watcher.name
        switch watcher.phase {
        case .starting: return "Opening \(n)"
        case .live: return "Live · \(n)"
        case .paused(.mac): return "Stopped · \(n)"
        case .paused: return "Paused · \(n)"
        case .needsPermission, .unavailable: return n
        case .offline: return "Mac not connected"
        }
    }

    private var color: Color {
        switch watcher.phase {
        case .live: return Light.cyan
        case .starting: return Ink.tertiary
        case .paused: return Ink.tertiary
        case .needsPermission, .unavailable, .offline: return Light.ochre
        }
    }
}

/// The window itself, on its plate, with what's going on laid over it when it isn't live.
struct WatchWindow: View {
    @ObservedObject var watcher: Watcher
    var interactive: Bool
    /// The person zoomed or dragged away from the start (the Newest button shows).
    @State private var adjusted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
        ZStack {
            Ink.raised
            if let image = watcher.image {
                WindowViewer(image: image, focus: watcher.focus, recenter: watcher.recenter, interactive: interactive && watcher.phase == .live,
                             onTouch: { watcher.touch() },
                             onTap: { watcher.click($0) }, onScroll: { watcher.scroll(at: $0, by: $1) }, onAdjusted: { moved in if moved != adjusted { adjusted = moved } })
                    .accessibilityLabel("\(watcher.name)'s window on your Mac")
                    .accessibilityHint(interactive ? "Tap to click there on your Mac. Swipe to scroll it. Pinch to zoom; two fingers move the picture." : "")
                    .accessibilityAddTraits(.isImage)
            }
            if interactive && adjusted && watcher.phase == .live {
                Button { watcher.showNewest() } label: {
                    Label("Newest", systemImage: "arrow.down.to.line").font(.footnote.weight(.semibold))
                }
                .nativeGlassButton()
                .controlSize(.small)
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .transition(.opacity)
                .accessibilityHint("Back to the newest output, at the bottom of the window.")
                .accessibilityIdentifier("watch-newest")
            }
            if interactive { overlay }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Ink.line, lineWidth: 1))
        // The window comes alive: one pass of light round its edge as the first picture lands.
        .overlay {
            if interactive && !reduceMotion {
                shape.strokeBorder(Light.cyan, lineWidth: 1.5)
                    .keyframeAnimator(initialValue: 0.0, trigger: watcher.cameAlive) { ring, a in ring.opacity(a) } keyframes: { _ in
                        CubicKeyframe(0.9, duration: 0.18)
                        CubicKeyframe(0, duration: 0.9)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .onChange(of: watcher.cameAlive) { _, _ in if interactive { Haptics.soft() } }
        .animation(.easeInOut(duration: 0.25), value: watcher.phase)
        .animation(.easeInOut(duration: 0.2), value: adjusted)
    }

    @ViewBuilder private var overlay: some View {
        switch watcher.phase {
        case .live:
            EmptyView()
        case .starting:
            if watcher.image == nil {
                Note(symbol: nil, title: "Opening \(watcher.name)'s window", detail: nil) { ProgressView().tint(Ink.secondary) }
            }
        case .paused(let reason):
            Dimmed {
                Note(symbol: reason == .mac ? "stop.circle" : "pause.circle",
                     title: reason == .mac ? "Stopped from your Mac" : "Paused to save battery",
                     detail: reason == .mac ? "Macrophone's menu on your Mac stopped the pictures. Resume asks for them again." : nil) {
                    Button { watcher.resume() } label: { Label("Resume", systemImage: "play.fill").fontWeight(.semibold) }
                        .watchProminentButton()
                        .accessibilityIdentifier("watch-resume")
                }
            }
        case .offline:
            Dimmed {
                Note(symbol: "wifi.exclamationmark", title: "Your Mac isn't connected",
                     detail: "The window comes back when it is.") { EmptyView() }
            }
        case .needsPermission:
            Dimmed {
                Note(symbol: "rectangle.dashed.badge.record", title: "Your Mac needs to allow Screen Recording",
                     detail: "Turn on Macrophone in Privacy & Security › Screen Recording on your Mac. It only ever shows the app you pick.") {
                    Button { watcher.perform(.openScreenRecordingSettings) } label: {
                        Text("Open the setting on my Mac").fontWeight(.semibold)
                    }
                    .watchProminentButton()
                    .accessibilityIdentifier("watch-open-permission")
                }
            }
        case let .unavailable(why, canReveal):
            Dimmed {
                Note(symbol: "macwindow", title: why, detail: nil) {
                    if canReveal {
                        Button { watcher.perform(.reveal) } label: { Text("Show it on my Mac").fontWeight(.semibold) }
                            .watchProminentButton()
                    }
                }
            }
        }
    }

    /// The last picture, darkened, under a note — or the plain plate when there's no picture.
    private struct Dimmed<Content: View>: View {
        @ViewBuilder var content: Content
        var body: some View {
            ZStack {
                Ink.ground.opacity(0.72)
                content
            }
        }
    }

    private struct Note<Action: View>: View {
        var symbol: String?
        var title: String
        var detail: String?
        @ViewBuilder var action: Action
        var body: some View {
            VStack(spacing: 10) {
                if let symbol {
                    Image(systemName: symbol).font(.title2).foregroundStyle(Ink.secondary).accessibilityHidden(true)
                }
                Text(title).font(.headline).foregroundStyle(Ink.ink)
                if let detail {
                    Text(detail).font(.footnote).foregroundStyle(Ink.tertiary)
                }
                action.padding(.top, 4)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 24)
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        }
    }
}

/// While the mic is open: the bottom of the window, small, so the question stays in view.
struct WatchStrip: View {
    @ObservedObject var watcher: Watcher
    var compact = false

    var body: some View {
        WatchWindow(watcher: watcher, interactive: false)
            .frame(height: compact ? 72 : 104)
            .opacity(watcher.image == nil ? 0 : 1)
            .accessibilityHidden(true)
    }
}

/// Esc · ↑ · ↓ · Return — the same four keys in every app (Sameer, Oct 14 2026: "basic things
/// that allow the user to navigate very quickly or confirm things very quickly").
struct WatchActions: View {
    @ObservedObject var watcher: Watcher

    var body: some View {
        HStack(spacing: 8) {
            key(.escape, label: Text("Esc"), name: "Escape")
            key(.arrowUp, label: Image(systemName: "arrow.up"), name: "Up arrow")
            key(.arrowDown, label: Image(systemName: "arrow.down"), name: "Down arrow")
            key(.returnKey, label: Text("Return"), name: "Return")
        }
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    private func key<L: View>(_ a: WatchAction, label: L, name: String) -> some View {
        Button { watcher.perform(a) } label: {
            label
                .font(.body.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: 28)
        }
        .nativeGlassButton()
        .accessibilityLabel(name)
        .accessibilityHint("Presses \(name) in \(watcher.name) on your Mac.")
        .accessibilityIdentifier("watch-\(a.rawValue)")
    }
}

private extension View {
    @ViewBuilder func watchProminentButton() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glassProminent).tint(Light.cyan).foregroundStyle(Ink.ground)
        } else {
            buttonStyle(.borderedProminent).tint(Light.cyan).foregroundStyle(Ink.ground)
        }
    }
}

// MARK: The zoomable picture

/// The window's picture in a zooming scroll view: it opens on the column you type in, at the
/// bottom (the newest output), and stays there as pictures arrive — until you zoom or drag, then
/// it stays where you put it (Newest brings it back). A tap is a click there on the Mac, with a
/// ring where it landed; a one-finger swipe scrolls the Mac's window right there (Sameer, Oct 14
/// 2026: "swipe gestures could trigger small scrolls … where the swipe occurs"); two fingers move
/// the picture, a pinch zooms it.
struct WindowViewer: UIViewRepresentable {
    var image: UIImage
    var focus: CGRect?
    var recenter: Int
    var interactive: Bool
    var onTouch: () -> Void
    var onTap: (CGPoint) -> Void
    var onScroll: (CGPoint, CGVector) -> Void
    var onAdjusted: (Bool) -> Void

    func makeUIView(context: Context) -> ViewerScrollView {
        let v = ViewerScrollView()
        wire(v)
        return v
    }

    func updateUIView(_ v: ViewerScrollView, context: Context) {
        wire(v)
        v.update(image: image, focus: focus, recenter: recenter, interactive: interactive)
    }

    private func wire(_ v: ViewerScrollView) {
        v.onTouch = onTouch
        v.onTap = onTap
        v.onScroll = onScroll
        v.onAdjusted = onAdjusted
    }
}

final class ViewerScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private var imageSize: CGSize = .zero
    private var focus: CGRect?
    /// The person zoomed or dragged: leave the view where they put it.
    private var adjusted = false { didSet { if adjusted != oldValue { onAdjusted(adjusted) } } }
    private var lastRecenter: Int?
    private var lastBounds: CGSize = .zero
    var onTouch: () -> Void = {}
    var onTap: (CGPoint) -> Void = { _ in }
    var onScroll: (CGPoint, CGVector) -> Void = { _, _ in }
    var onAdjusted: (Bool) -> Void = { _ in }
    private var tapper: UITapGestureRecognizer!
    private var swiper: UIPanGestureRecognizer!
    /// The swipe so far, not yet sent (sent ~30 times a second), and where it started.
    private var pendingScroll = CGVector.zero
    private var scrollAnchor = CGPoint.zero
    private var lastScrollSend = Date.distantPast

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        decelerationRate = .fast
        bouncesZoom = true
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .clear
        imageView.contentMode = .scaleToFill
        imageView.layer.minificationFilter = .trilinear
        addSubview(imageView)
        tapper = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        addGestureRecognizer(tapper)
        // One finger scrolls the Mac's window; the picture itself moves with two.
        panGestureRecognizer.minimumNumberOfTouches = 2
        swiper = UIPanGestureRecognizer(target: self, action: #selector(swiped(_:)))
        swiper.maximumNumberOfTouches = 1
        addGestureRecognizer(swiper)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(image: UIImage, focus: CGRect?, recenter: Int, interactive: Bool) {
        isScrollEnabled = interactive
        pinchGestureRecognizer?.isEnabled = interactive
        tapper.isEnabled = interactive
        swiper.isEnabled = interactive
        let focusChanged = focus != self.focus && !adjusted
        self.focus = focus
        imageView.image = image
        let size = image.size
        if size != imageSize {
            // A new size (first picture, or the window was resized): start over.
            imageSize = size
            zoomScale = 1
            imageView.frame = CGRect(origin: .zero, size: size)
            contentSize = size
            configureZoom()
            reset(animated: false)
        } else if lastRecenter != nil, recenter != lastRecenter {
            reset(animated: true)
        } else if focusChanged {
            reset(animated: false)
        }
        lastRecenter = recenter
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != lastBounds, imageSize != .zero, bounds.width > 0 else { return }
        lastBounds = bounds.size
        configureZoom()
        reset(animated: false)
    }

    /// The scale that shows the column you type in across the width (or the whole window, if
    /// it's narrow), never smaller than the whole window's width.
    private var startScale: CGFloat {
        guard imageSize.width > 0, bounds.width > 0 else { return 1 }
        let fitWidth = bounds.width / imageSize.width
        let fillHeight = bounds.height / imageSize.height
        if let f = focus, f.width > 0.12 {
            return min(max(fitWidth, bounds.width / (f.width * imageSize.width * 1.08)), maximumZoomScale)
        }
        return max(fitWidth, min(fillHeight, fitWidth * 1.8))
    }

    private func configureZoom() {
        guard imageSize.width > 0, bounds.width > 0 else { return }
        let fitAll = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        minimumZoomScale = fitAll
        maximumZoomScale = max(1.6, fitAll * 6)
    }

    /// Back to the start: the column, at the bottom.
    private func reset(animated: Bool) {
        guard imageSize != .zero, bounds.width > 0 else { return }
        adjusted = false
        let s = startScale
        let apply = {
            self.setZoomScale(s, animated: false)
            self.centerIfSmall()
            let w = self.imageSize.width * s, h = self.imageSize.height * s
            let cx = (self.focus.map { $0.midX } ?? 0.5) * w
            let x = min(max(cx - self.bounds.width / 2, 0), max(0, w - self.bounds.width))
            let y = max(0, h - self.bounds.height)
            self.contentOffset = CGPoint(x: x - self.contentInset.left, y: y - self.contentInset.top)
        }
        if animated { UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseInOut, .allowUserInteraction], animations: apply) }
        else { apply() }
    }

    /// A picture smaller than the view sits in the middle of it.
    private func centerIfSmall() {
        let w = imageSize.width * zoomScale, h = imageSize.height * zoomScale
        let dx = max(0, (bounds.width - w) / 2), dy = max(0, (bounds.height - h) / 2)
        contentInset = UIEdgeInsets(top: dy, left: dx, bottom: dy, right: dx)
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        guard imageSize.width > 0 else { return }
        let p = g.location(in: imageView)
        let n = CGPoint(x: p.x / imageSize.width, y: p.y / imageSize.height)
        guard (0...1).contains(n.x), (0...1).contains(n.y) else { return }
        ring(at: g.location(in: self))
        onTap(n)
    }

    @objc private func swiped(_ g: UIPanGestureRecognizer) {
        guard imageSize.width > 0, zoomScale > 0 else { return }
        let shown = CGSize(width: imageSize.width * zoomScale, height: imageSize.height * zoomScale)
        switch g.state {
        case .began:
            onTouch()
            let p = g.location(in: imageView)
            scrollAnchor = CGPoint(x: min(max(p.x / imageSize.width, 0), 1), y: min(max(p.y / imageSize.height, 0), 1))
            pendingScroll = .zero
            g.setTranslation(.zero, in: self)
        case .changed:
            let t = g.translation(in: self)
            g.setTranslation(.zero, in: self)
            // As fractions of the window, so the Mac moves its content as far as the finger did.
            pendingScroll.dx += t.x / shown.width
            pendingScroll.dy += t.y / shown.height
            if Date().timeIntervalSince(lastScrollSend) > 0.033 { flushScroll() }
        case .ended:
            // A flick carries on a little, like a trackpad.
            let v = g.velocity(in: self)
            pendingScroll.dy += min(max(v.y * 0.12, -900), 900) / shown.height
            flushScroll()
        default:
            flushScroll()
        }
    }

    private func flushScroll() {
        guard abs(pendingScroll.dx) + abs(pendingScroll.dy) > 0.0005 else { return }
        onScroll(scrollAnchor, pendingScroll)
        pendingScroll = .zero
        lastScrollSend = Date()
    }

    /// Where the click landed: a ring that grows and fades.
    private func ring(at p: CGPoint) {
        let r: CGFloat = 16
        let layer = CAShapeLayer()
        layer.path = UIBezierPath(ovalIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2)).cgPath
        layer.position = p
        layer.fillColor = UIColor(Light.cyan).withAlphaComponent(0.25).cgColor
        layer.strokeColor = UIColor(Light.cyan).cgColor
        layer.lineWidth = 2
        self.layer.addSublayer(layer)
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.4
        grow.toValue = 1.4
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.45
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.opacity = 0
        layer.add(group, forKey: "ring")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { layer.removeFromSuperlayer() }
    }

    // MARK: UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { adjusted = true; onTouch() }
    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) { adjusted = true; onTouch() }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerIfSmall() }
}

/// The kicker's dot: a breath of light driven by Core Animation while the window is live. The
/// animation runs on the render server, so the app's CPU stays idle between pictures.
private struct LiveDot: UIViewRepresentable {
    var color: UIColor
    var breathing: Bool

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.layer.cornerRadius = 4
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ v: UIView, context: Context) {
        v.layer.backgroundColor = color.cgColor
        let running = v.layer.animation(forKey: "breathe") != nil
        if breathing && !running {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1
            a.toValue = 0.45
            a.duration = 1.1
            a.autoreverses = true
            a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            v.layer.add(a, forKey: "breathe")
        } else if !breathing && running {
            v.layer.removeAnimation(forKey: "breathe")
        }
    }
}
