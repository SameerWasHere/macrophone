import MacrophoneKit
import SwiftUI
import UIKit

// Watching (Oct 14 2026) — the picked app's window on the Mac, in the area above the Thread:
//
//   ● LIVE · CLAUDE                        [Done]
//   ┌──────────────────────────────────────────┐
//   │  the window, pinned to its newest output │  pinch to zoom, drag to look around,
//   │  (centred on the column you type in)     │  double-tap to zoom in / back
//   └──────────────────────────────────────────┘
//   [↑] [↓]  [Approve]  [Stop]  [Copy]            Return / Esc for apps that aren't agents
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
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .shadow(color: color.opacity(0.8), radius: 4)
                .phaseAnimator([1.0, 0.45]) { dot, v in dot.opacity(watcher.phase == .live && !reduceMotion ? v : 1) }
                    animation: { _ in .easeInOut(duration: 1.1) }
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

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
        ZStack {
            Ink.raised
            if let image = watcher.image {
                WindowViewer(image: image, focus: watcher.focus, recenter: watcher.recenter, interactive: interactive,
                             onVisible: { watcher.visibleRect = $0 }, onTouch: { watcher.touch() })
                    .accessibilityLabel("\(watcher.name)'s window on your Mac")
                    .accessibilityHint(interactive ? "Pinch to zoom. Double-tap to zoom in or back out." : "")
                    .accessibilityAddTraits(.isImage)
            }
            if interactive { overlay }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Ink.line, lineWidth: 1))
        .animation(.easeInOut(duration: 0.25), value: watcher.phase)
    }

    @ViewBuilder private var overlay: some View {
        switch watcher.phase {
        case .live:
            EmptyView()
        case .starting:
            if watcher.image == nil {
                Note(symbol: nil, title: "Opening \(watcher.name)'s window", detail: nil) { ProgressView().tint(Ink.secondary) }
            }
        case .paused:
            Dimmed {
                Note(symbol: "pause.circle", title: "Paused to save battery", detail: nil) {
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

/// Scroll up, scroll down, Return (Approve), Esc (Stop), Copy.
struct WatchActions: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var watcher: Watcher

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(words: true)
            row(words: false)
        }
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    private func row(words: Bool) -> some View {
        HStack(spacing: 8) {
            icon("arrow.up", "Scroll up", .scrollUp)
            icon("arrow.down", "Scroll down", .scrollDown)
            Spacer(minLength: 0)
            action(watcher.agentLike ? "Approve" : "Return", "return", .returnKey, words: words,
                   hint: watcher.agentLike ? "Presses Return in \(watcher.name) — approves the highlighted choice." : "Presses Return in \(watcher.name).")
            action(watcher.agentLike ? "Stop" : "Esc", watcher.agentLike ? "stop.fill" : "escape", .escape, words: words,
                   hint: watcher.agentLike ? "Presses Esc in \(watcher.name) — stops what it's doing." : "Presses Esc in \(watcher.name).")
            Button { copy() } label: { label("Copy", "doc.on.doc", words: words) }
                .nativeGlassButton()
                .accessibilityLabel("Copy")
                .accessibilityHint("Copies the words on screen to this iPhone.")
                .accessibilityIdentifier("watch-copy")
        }
    }

    private func icon(_ symbol: String, _ name: String, _ a: WatchAction) -> some View {
        Button { watcher.perform(a) } label: {
            Image(systemName: symbol).font(.body.weight(.semibold)).frame(width: 22, height: 22)
        }
        .nativeGlassButton()
        .buttonBorderShape(.circle)
        .accessibilityLabel(name)
        .accessibilityIdentifier("watch-\(a.rawValue)")
    }

    private func action(_ title: String, _ symbol: String, _ a: WatchAction, words: Bool, hint: String) -> some View {
        Button { watcher.perform(a) } label: { label(title, symbol, words: words) }
            .nativeGlassButton()
            .accessibilityLabel(title)
            .accessibilityHint(hint)
            .accessibilityIdentifier("watch-\(a.rawValue)")
    }

    @ViewBuilder private func label(_ title: String, _ symbol: String, words: Bool) -> some View {
        if words {
            // Words alone: "Approve" and "Stop" have to read at a glance (icons alone didn't).
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1).fixedSize()
        } else {
            Image(systemName: symbol).font(.body.weight(.semibold)).frame(width: 22, height: 22)
        }
    }

    private func copy() {
        Haptics.tick()
        Task {
            let n = await watcher.copyVisibleText()
            if n > 0 {
                Haptics.success()
                model.explain(n == 1 ? "Copied the line on screen" : "Copied \(n) lines from \(watcher.name)")
            } else {
                Haptics.warning()
                model.explain("No words to copy on screen — zoom in on them, then Copy")
            }
        }
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
/// it stays where you put it. Double-tap zooms in there, or back to the start.
struct WindowViewer: UIViewRepresentable {
    var image: UIImage
    var focus: CGRect?
    var recenter: Int
    var interactive: Bool
    var onVisible: (CGRect) -> Void
    var onTouch: () -> Void

    func makeUIView(context: Context) -> ViewerScrollView {
        let v = ViewerScrollView()
        v.onVisible = onVisible
        v.onTouch = onTouch
        return v
    }

    func updateUIView(_ v: ViewerScrollView, context: Context) {
        v.onVisible = onVisible
        v.onTouch = onTouch
        v.update(image: image, focus: focus, recenter: recenter, interactive: interactive)
    }
}

final class ViewerScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private var imageSize: CGSize = .zero
    private var focus: CGRect?
    /// The person zoomed or dragged: leave the view where they put it.
    private var adjusted = false
    private var lastRecenter: Int?
    private var lastBounds: CGSize = .zero
    var onVisible: (CGRect) -> Void = { _ in }
    var onTouch: () -> Void = {}

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
        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        double.numberOfTapsRequired = 2
        addGestureRecognizer(double)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(image: UIImage, focus: CGRect?, recenter: Int, interactive: Bool) {
        isScrollEnabled = interactive
        pinchGestureRecognizer?.isEnabled = interactive
        gestureRecognizers?.compactMap { $0 as? UITapGestureRecognizer }.forEach { $0.isEnabled = interactive }
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
        reportVisible()
    }

    /// A picture smaller than the view sits in the middle of it.
    private func centerIfSmall() {
        let w = imageSize.width * zoomScale, h = imageSize.height * zoomScale
        let dx = max(0, (bounds.width - w) / 2), dy = max(0, (bounds.height - h) / 2)
        contentInset = UIEdgeInsets(top: dy, left: dx, bottom: dy, right: dx)
    }

    private func reportVisible() {
        guard imageSize.width > 0 else { return }
        let r = convert(bounds, to: imageView)
        onVisible(CGRect(x: r.minX / imageSize.width, y: r.minY / imageSize.height,
                         width: r.width / imageSize.width, height: r.height / imageSize.height))
    }

    @objc private func doubleTapped(_ g: UITapGestureRecognizer) {
        onTouch()
        if adjusted || zoomScale > startScale * 1.3 {
            reset(animated: true)
            return
        }
        adjusted = true
        let p = g.location(in: imageView)
        let target = min(startScale * 2, maximumZoomScale)
        let size = CGSize(width: bounds.width / target, height: bounds.height / target)
        zoom(to: CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height), animated: true)
    }

    // MARK: UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { adjusted = true; onTouch() }
    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) { adjusted = true; onTouch() }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerIfSmall(); reportVisible() }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { reportVisible() }
}
