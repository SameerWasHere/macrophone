import SwiftUI
import UIKit

// The window's picture flies between the desktop and the window view (Nov 7 2026, round 4).
// Opening used to scale the whole window view — its header, key row and page row — down into the
// card and grow it back out, so for a few frames there were two title bars and two pictures on
// screen, and Done left a tiny key row inside the card. Now only the picture moves, as a window
// does out of App Exposé: it lifts off the card (or the Dock icon), flies to where the window
// view shows it — at the zoom and spot the viewer will open it at — and the view's chrome fades
// in round it at its own size; Done fades the chrome first and flies the picture home.

/// One picture in flight: where it's clipped (the card's picture, or the viewer's visible part)
/// and where the whole picture lies (larger than the clip when the viewer is zoomed in).
struct WindowZoomPlace: Equatable {
    var clip: CGRect
    var picture: CGRect
    var corner: CGFloat
    var opacity: Double = 1

    /// A picture shown whole in a rect (the card, aspect-fit already).
    static func whole(_ r: CGRect, corner: CGFloat) -> WindowZoomPlace {
        WindowZoomPlace(clip: r, picture: r, corner: corner)
    }
}

@MainActor
final class WindowZoom: ObservableObject {
    static let shared = WindowZoom()

    @Published private(set) var image: UIImage?
    @Published private(set) var place: WindowZoomPlace?
    /// The card's own picture waits under the flying one.
    @Published private(set) var cardHidden = false
    /// An open's flight is under way and the window view stays hidden until it's most of the way.
    @Published private(set) var holdsPanel = false
    /// Done's flight: the view keeps its header while it fades, so its picture doesn't jump.
    @Published private(set) var leaving = false
    /// The hidden window view, once faded out, is drawn tiny: still drawn (its first frame on an
    /// open costs nothing), but no longer over the desktop — XCUITest finds hidden elements on
    /// the iOS 27 simulator and took the card and the Dock under it as covered.
    @Published private(set) var panelParked = true
    private var parkTask: Task<Void, Never>?
    private var generation = 0
    /// The open's flight has somewhere to go.
    private var aimed = false
    /// The window came out of the Dock's icon: Done puts it back there.
    private var openedFromIcon = false

    var flying: Bool { place != nil }

    /// The window view came or went: it's unparked at once, parked once it has faded out.
    func panelChanged(shown: Bool) {
        parkTask?.cancel()
        if shown {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { panelParked = false }
            return
        }
        parkTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard let self, !Task.isCancelled else { return }
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { self.panelParked = true }
        }
    }

    // MARK: Open

    /// The card was tapped: the picture lifts off it now, before the window view exists.
    func liftFromCard(image: UIImage?, card: CGRect?) {
        guard let image, let card, card.width > 1 else { return }
        start(image: image, at: .whole(card, corner: DesktopWindowLook.corner))
        cardHidden = true
        holdsPanel = true
        openedFromIcon = false
        // The window may wait for the Mac (back from the background): the picture goes back.
        let g = generation
        after(1.2, g) { if !self.aimed { self.finish() } }
    }

    /// The window view is up: fly to its picture. Opened from somewhere other than the card (the
    /// Dock's second tap, a widget, a hook), the flight starts at the Dock's icon when it's on
    /// screen, else the card when it's drawn; nowhere to start from, the view only fades.
    func opened(image: UIImage?, area: CGRect, compact: Bool) {
        if place == nil {
            guard let image else { return }
            if let icon = DockSpot.shared.pick, Self.onScreen(icon), icon.width > 1,
               let t = DockSpot.shared.watchedAt, t.timeIntervalSinceNow > -1.5 {
                openedFromIcon = true
                var from = WindowZoomPlace.whole(Self.fit(image.size, in: icon), corner: 6)
                from.opacity = 0
                start(image: image, at: from)
            } else if let card = DesktopWindowSpot.shared.frame, Self.onScreen(card) {
                openedFromIcon = false
                start(image: image, at: .whole(card, corner: DesktopWindowLook.corner))
                cardHidden = true
            } else { return }
            holdsPanel = true
        }
        let g = generation
        guard let image = self.image else { return }
        aimed = true
        // A first aim from the layout the view is known to have; the viewer itself, once it has
        // laid out with its header, corrects it in flight (the spring keeps its speed).
        let aim = Self.estimate(image: image.size, area: area, compact: compact)
        withAnimation(Motion.settle) { place = aim }
        after(0.05, g) {
            if let real = Self.viewerPlace(in: area) { withAnimation(Motion.settle) { self.place = real } }
        }
        // Most of the way: the view's chrome fades in round the picture, then the picture gives
        // way to the view's own (the same pixels: the viewer holds the kept picture).
        after(0.28, g) { withAnimation(.easeOut(duration: 0.15)) { self.holdsPanel = false } }
        // (Soon after: the Mac's first frame lands about half a second in, and anything new on it
        // would show double under a picture still fading.)
        after(0.38, g) { withAnimation(.easeOut(duration: 0.1)) { self.place?.opacity = 0 } }
        after(0.5, g) { self.finish() }
    }

    // MARK: Done

    /// The view is going: measured as it was on screen (before it lays out again without its
    /// header), its chrome fades and the picture flies home — into the Dock's icon when the open
    /// came from there and it's on screen, else into the card.
    func closing(image: UIImage?, area: CGRect, compact: Bool, fromCard: Bool) {
        guard let image else { return }
        let home: WindowZoomPlace
        if !fromCard, openedFromIcon, let icon = DockSpot.shared.pick, Self.onScreen(icon), icon.width > 1 {
            home = WindowZoomPlace(clip: Self.fit(image.size, in: icon), picture: Self.fit(image.size, in: icon), corner: 6, opacity: 0)
        } else if let card = DesktopWindowSpot.shared.frame, Self.onScreen(card) {
            // The card shows the same picture whole, aspect-fit in its own shape.
            let r = Self.fit(image.size, in: card)
            home = .whole(r, corner: DesktopWindowLook.corner)
            cardHidden = true
        } else { return }
        let from = Self.viewerPlace(in: area) ?? Self.estimate(image: image.size, area: area, compact: compact)
        start(image: image, at: from)
        leaving = true
        let g = generation
        withAnimation(Motion.settle) { place = home }
        after(0.35, g) { self.leaving = false }
        after(0.42, g) { self.finish() }
    }

    // MARK: The flight

    private func start(image: UIImage, at p: WindowZoomPlace) {
        generation &+= 1
        aimed = false
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            self.image = image
            self.place = p
        }
    }

    private func finish() {
        var t = Transaction()
        t.disablesAnimations = true
        aimed = false
        withTransaction(t) {
            image = nil
            place = nil
            cardHidden = false
            holdsPanel = false
            leaving = false
        }
    }

    /// Ends any flight at once (the mic opening, Reduce Motion turned on, the layout changing).
    func cancel() {
        generation &+= 1
        finish()
    }

    private func after(_ s: Double, _ g: Int, _ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + s) { [weak self] in
            guard let self, self.generation == g else { return }
            work()
        }
    }

    // MARK: Geometry

    private static func onScreen(_ r: CGRect) -> Bool {
        let screen = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds ?? UIScreen.main.bounds
        return screen.contains(r)
    }

    /// A picture of this size, whole and centred in a rect.
    static func fit(_ size: CGSize, in r: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return r }
        let s = min(r.width / size.width, r.height / size.height)
        let w = size.width * s, h = size.height * s
        return CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
    }

    /// Where the window view puts its picture, from its known layout (`WatchPanel`: a 4 pt
    /// breath, the header, the row gap, then the bezel), its foot where the viewer at rest ends.
    static func estimate(image: CGSize, area: CGRect, compact: Bool) -> WindowZoomPlace {
        let inset = WatchLook.sideMargin + WatchLook.bezelWidth
        let top = area.minY + 4 + WatchLook.header + (compact ? 6 : 8) + WatchLook.bezelWidth
        let foot = viewerPlace(in: area).map { $0.clip.maxY } ?? (area.maxY - 60)
        let clip = CGRect(x: area.minX + inset, y: top, width: max(1, area.width - 2 * inset), height: max(1, foot - top))
        let fitAll = min(clip.width / max(1, image.width), clip.height / max(1, image.height))
        // A kept picture shaped unlike the view opens whole (the viewer's `keptOtherShape` rule,
        // Nov 8 2026): the aim says so too, or the flight overshot and shrank back in its first
        // 50 ms.
        let otherShape = abs((image.width / max(1, image.height)) / (clip.width / max(1, clip.height)) - 1) > 0.15
        // (Round 2: a picture of another shape covers the frame from its top-left, as the viewer
        // opens it.)
        let s = otherShape ? ViewerScrollView.coverScale(image: image, width: clip.width, visibleHeight: clip.height, cap: ViewerScrollView.coverCap(fill: false))
            : ViewerScrollView.startScale(image: image, width: clip.width, visibleHeight: clip.height, focus: nil, fill: false, maxZoom: max(1, fitAll * 2))
        let w = image.width * s, h = image.height * s
        // Narrower than the view: centred; taller: its foot (the newest) at the view's foot —
        // another shape: the top-left.
        let x = otherShape ? clip.minX : w < clip.width ? clip.midX - w / 2 : clip.minX
        let y = otherShape ? clip.minY : h < clip.height ? clip.midY - h / 2 : clip.maxY - h
        return WindowZoomPlace(clip: clip, picture: CGRect(x: x, y: y, width: w, height: h), corner: WatchLook.screen)
    }

    /// The window view's viewer as it is now: what of it shows, and where the whole picture lies
    /// at its zoom and scroll — so the flight lands on exactly the pixels it hands over to.
    static func viewerPlace(in area: CGRect) -> WindowZoomPlace? {
        guard let window = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.keyWindow else { return nil }
        var best: (ViewerScrollView, CGRect)?
        func walk(_ v: UIView) {
            if let s = v as? ViewerScrollView, s.window != nil, !s.isHidden {
                let r = s.convert(s.bounds, to: nil)
                if r.intersects(area), r.width * r.height > (best.map { $0.1.width * $0.1.height } ?? 0) { best = (s, r) }
                return
            }
            v.subviews.forEach(walk)
        }
        walk(window)
        // (A parked view measures tiny: no use.)
        guard let (viewer, clip) = best, clip.width > area.width / 2, clip.height > 1,
              let content = viewer.delegate?.viewForZooming?(in: viewer) else { return nil }
        let picture = content.convert(content.bounds, to: nil)
        guard picture.width > 1, picture.height > 1 else { return nil }
        // The window's own corners, at the zoom it shows at (Nov 8 2026): the flight lands on
        // the clipped picture's shape, and the card's 12 pt corner opens into it.
        return WindowZoomPlace(clip: clip, picture: picture, corner: viewer.pictureCorner * viewer.zoomScale)
    }
}

// MARK: - Full screen: one continuous grow (Nov 8 2026)

// The review: "Full screen in/out is a dissolve between two differently-zoomed copies with a
// cropped state between … A Mac app going full screen is one continuous grow." The windowed view
// and `DuoFullScreen` have a viewer each and used to cross-fade. Now the picture flies: in, from
// the window's frame to the screen (covering it, anchored top-left as a Mac window's content is
// while it zooms); out, from the screen back to the window's frame, whole. The viewers swap
// underneath, each starting where the flight ends, and the status bar stays hidden until the
// window has shrunk.

@MainActor
final class FullScreenZoom: ObservableObject {
    static let shared = FullScreenZoom()
    @Published private(set) var image: UIImage?
    @Published private(set) var place: WindowZoomPlace?
    /// A flight is up (the status bar waits for it; the layouts under it swap meanwhile).
    @Published private(set) var flying = false
    /// The flight has arrived and is fading out: the viewer under it fades in.
    @Published private(set) var landing = false
    private var generation = 0
    static let duration: TimeInterval = 0.42

    /// Into full screen: from where the window's viewer shows its picture to the screen.
    func enter(image: UIImage?, from: WindowZoomPlace?, screen: CGRect, corner: CGFloat) {
        guard let image, let from else { return }
        // Covering from the top-left, capped (round 2: a 0.7 window on a 1.42 screen covered it
        // at twice its size); past the cap the picture sits top-left on the dark ground.
        let s = ViewerScrollView.coverScale(image: image.size, width: screen.width, visibleHeight: screen.height, cap: ViewerScrollView.coverCap(fill: true))
        let picture = CGRect(x: screen.minX, y: screen.minY, width: image.size.width * s, height: image.size.height * s)
        fly(image: image, from: from, to: WindowZoomPlace(clip: screen, picture: picture, corner: corner * s))
    }

    /// Out of full screen: from the screen to the window's frame, the picture covering it from
    /// its top-left (the windowed viewer opens it so too — `otherShape` — until the Mac's
    /// reshaped picture reflows the content inside the same outline).
    func exit(image: UIImage?, from: WindowZoomPlace?, to frame: CGRect, corner: CGFloat) {
        guard let image, let from, frame.width > 1 else { return }
        let s = ViewerScrollView.coverScale(image: image.size, width: frame.width, visibleHeight: frame.height, cap: ViewerScrollView.coverCap(fill: false))
        let picture = CGRect(x: frame.minX, y: frame.minY, width: image.size.width * s, height: image.size.height * s)
        fly(image: image, from: from, to: WindowZoomPlace(clip: frame, picture: picture, corner: corner * s))
    }

    /// The window's viewer has laid out (after an exit): the flight lands on it exactly.
    func aim(_ to: WindowZoomPlace) {
        guard flying else { return }
        withAnimation(Motion.settle) { place = to }
    }

    private func fly(image: UIImage, from: WindowZoomPlace, to: WindowZoomPlace) {
        generation &+= 1
        let g = generation
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { self.image = image; self.place = from; self.flying = true; self.landing = false }
        withAnimation(Motion.settle) { self.place = to }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration) { [weak self] in
            guard let self, self.generation == g else { return }
            // The viewer under it shows the same pixels now: a short fade hands over.
            self.landing = true
            withAnimation(.easeOut(duration: 0.12)) { self.place?.opacity = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) { [weak self] in
                guard let self, self.generation == g else { return }
                var t = Transaction(); t.disablesAnimations = true
                withTransaction(t) { self.image = nil; self.place = nil; self.flying = false; self.landing = false }
            }
        }
    }

    func cancel() {
        generation &+= 1
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { image = nil; place = nil; flying = false; landing = false }
    }
}

/// The full-screen flight, drawn over everything at the root (global coordinates).
struct FullScreenZoomFlight: View {
    @ObservedObject var zoom = FullScreenZoom.shared
    var body: some View {
        ZStack(alignment: .topLeading) {
            if let image = zoom.image, let p = zoom.place {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: p.picture.width, height: p.picture.height)
                    .offset(x: p.picture.minX - p.clip.minX, y: p.picture.minY - p.clip.minY)
                    .frame(width: p.clip.width, height: p.clip.height, alignment: .topLeading)
                    .clipShape(RoundedRectangle(cornerRadius: p.corner, style: .circular))
                    .offset(x: p.clip.minX, y: p.clip.minY)
                    .opacity(p.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Hands its content the flight's state, observed (the window view's fade and header follow it).
struct WithWindowZoom<Content: View>: View {
    @ObservedObject private var zoom = WindowZoom.shared
    @ViewBuilder var content: (WindowZoom) -> Content
    var body: some View { content(zoom) }
}

/// The picture in flight, drawn over the top area (`MainView.phoneBody`). Placed in global
/// space: `origin` is the area's own top-left there.
struct WindowZoomFlight: View {
    @ObservedObject var zoom = WindowZoom.shared
    var origin: CGPoint

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let image = zoom.image, let p = zoom.place {
                let shape = RoundedRectangle(cornerRadius: p.corner, style: .continuous)
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: p.picture.width, height: p.picture.height)
                    .offset(x: p.picture.minX - p.clip.minX, y: p.picture.minY - p.clip.minY)
                    .frame(width: p.clip.width, height: p.clip.height, alignment: .topLeading)
                    .clipShape(shape)
                    .shadow(color: .black.opacity(0.16 * p.opacity), radius: 14, y: 5)
                    .offset(x: p.clip.minX - origin.x, y: p.clip.minY - origin.y)
                    .opacity(p.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
