import MacrophoneKit
import SwiftUI
import UIKit

// Watching (Oct 14 2026) — the picked app's window on the Mac, in the area above the Thread:
//
//   ● LIVE · CLAUDE                   [Aa] [Done]   Aa: the Mac's window narrower, so its text
//   ┌──────────────────────────────────────────┐   reads larger here (Normal · Larger · Largest)
//   │  the window, pinned to its newest output │  tap = a click there on the Mac;
//   │  (centred on the column you type in)     │  one finger looks around (Pan) or scrolls
//   └─────────────────────────────── [Newest] ┘  the Mac's window (Scroll); pinch zooms
//   [Esc] [↑] [↓] [⏎]            [Pan | Scroll]  one row, under the thumb
//   [ Esc ] [ ↑ ] [ ↓ ] [ Return ]                 the same keys in every app: move through a
//                                                 menu, confirm, back out
//
// The mic, the Thread and the status line don't move. Holding the mic shrinks the window to a
// strip at the top, so the question stays in view while the words take the rest.

struct WatchPanel: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var watcher: Watcher
    var compact = false
    /// The window just switched to, named for a moment ("Terminal — codex ~/api").
    @State private var switchedTo: String?
    @State private var switchedTask: Task<Void, Never>?

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
        // Swipe in from a side edge (in the margin beside the window, under a thumb) for the
        // previous or next window; the menu on the name is the visible way to the same thing.
        .overlay(alignment: .leading) { edge(step: -1) }
        .overlay(alignment: .trailing) { edge(step: 1) }
        .overlay(alignment: .top) {
            if let switchedTo {
                Text(switchedTo)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Ink.ink)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 62)
                    .padding(.horizontal, 32)
                    .transition(.opacity)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityAction(named: "Next window") { go(1) }
        .accessibilityAction(named: "Previous window") { go(-1) }
        // The window is a picture; its chrome (the kicker, Done, the keys) stays a moderate size so
        // the whole panel always fits above the Thread — at accessibility sizes it overflowed both ends.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: Sessions — the windows to flip between

    private var sessions: [LiveTarget] { model.watchSessions }

    private var current: Int? {
        guard let t = watcher.target else { return nil }
        return sessions.firstIndex { t.matches($0) }
    }

    private func go(_ step: Int) {
        if let t = model.watchStep(step) { announce(t) }
    }

    private func show(_ t: LiveTarget) {
        if model.watchSession(t) { announce(t) }
    }

    private func announce(_ t: LiveTarget) {
        switchedTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { switchedTo = t.title }
        UIAccessibility.post(notification: .announcement, argument: t.title)
        switchedTask = Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.3)) { switchedTo = nil }
        }
    }

    /// A strip in the margin beside the window: a swipe in from it flips to the next window.
    private func edge(step: Int) -> some View {
        Color.clear
            .frame(width: 14)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 12).onEnded { v in
                let dx = v.translation.width
                guard abs(dx) > 40, abs(dx) > abs(v.translation.height) else { return }
                // From the right edge, a swipe to the left is the next; from the left, to the right, the previous.
                if (step > 0 && dx < 0) || (step < 0 && dx > 0) { go(step) }
            })
            .accessibilityHidden(true)
    }

    private var header: some View {
        HStack(spacing: 10) {
            if sessions.count > 1 {
                Menu {
                    ForEach(sessions) { t in
                        Button { show(t) } label: {
                            if watcher.target?.matches(t) ?? false { Label(t.title, systemImage: "checkmark") } else { Text(t.title) }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        WatchKicker(watcher: watcher)
                        Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(Ink.tertiary)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("Window: \(watcher.name)")
                .accessibilityHint("Shows another window from your Mac — and sends there. You can also swipe in from the side.")
                .accessibilityIdentifier("watch-sessions")
                if sessions.count <= 8, let i = current {
                    HStack(spacing: 5) {
                        ForEach(0..<sessions.count, id: \.self) { k in
                            Circle().fill(k == i ? Ink.secondary : Ink.line).frame(width: 5, height: 5)
                        }
                    }
                    .accessibilityHidden(true)
                }
            } else {
                WatchKicker(watcher: watcher)
            }
            Spacer(minLength: 8)
            if watcher.macCanFit, watcher.target != .clipboard {
                WatchFitMenu(watcher: watcher)
            }
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

/// "Aa" — readable text (Oct 17 2026): a menu of Normal · Larger · Largest. Larger and Largest
/// make the Mac's window narrower and taller, about the phone's shape, so its text reads larger
/// here; the Mac puts the window back when watching stops. Remembered per app.
struct WatchFitMenu: View {
    @ObservedObject var watcher: Watcher

    var body: some View {
        Menu {
            // One short line: a menu cuts a long one with "…".
            Text("Narrows \(watcher.name)'s window so its text reads larger here")
            Picker("Text size", selection: Binding(get: { watcher.fit }, set: { watcher.setFit($0) })) {
                ForEach(WatchFit.allCases, id: \.self) { f in Text(f.title).tag(f) }
            }
        } label: {
            Text("Aa")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(watcher.fit == .normal ? Ink.ink : Light.cyan)
                .frame(minWidth: 30, minHeight: 30)
        }
        .nativeGlassButton()
        .disabled(watcher.phase != .live)
        .accessibilityLabel("Text size on your Mac's window: \(watcher.fit.title)")
        .accessibilityHint("Makes \(watcher.name)'s window narrower on your Mac so its text reads larger here.")
        .accessibilityIdentifier("watch-fit")
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
    /// A moment of words after the Pan | Scroll switch flips or Aa changes: what happens now.
    @State private var dragNote: String?
    @State private var dragNoteTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
        ZStack {
            Ink.raised
            if watcher.hasPicture {
                WindowViewer(image: watcher.image, video: watcher.videoSize != nil ? watcher.video : nil, videoSize: watcher.videoSize ?? .zero,
                             focus: watcher.focus, recenter: watcher.recenter, interactive: interactive && watcher.phase == .live,
                             drag: watcher.drag, phased: watcher.macCanScroll,
                             onTouch: { watcher.touch() },
                             onTap: { watcher.click($0) }, onScroll: { watcher.scroll(at: $0, by: $1) },
                             onScrollPhase: { watcher.scrollPhase($0, at: $1) },
                             onAdjusted: { moved in if interactive { watcher.setMovedAway(moved) } })
                    .accessibilityLabel("\(watcher.name)'s window on your Mac")
                    .accessibilityHint(interactive ? (watcher.drag == .pan
                        ? "Tap to click there on your Mac. Drag to look around the window; pinch to zoom. Switch to Scroll to scroll the window on your Mac."
                        : "Tap to click there on your Mac. Swipe to scroll the window on your Mac; two fingers move the picture.") : "")
                    .accessibilityAddTraits(.isImage)
            }
            if interactive && watcher.movedAway && watcher.phase == .live {
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
            if let dragNote, interactive && watcher.phase == .live {
                Text(dragNote)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Ink.ink)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(.opacity)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
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
        .onChange(of: watcher.noteSeq) { _, _ in
            guard interactive else { return }
            let words = watcher.noteWords
            UIAccessibility.post(notification: .announcement, argument: words)
            dragNoteTask?.cancel()
            withAnimation(.easeOut(duration: 0.15)) { dragNote = words }
            dragNoteTask = Task {
                try? await Task.sleep(nanoseconds: 2_200_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeIn(duration: 0.3)) { dragNote = nil }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: watcher.phase)
        .animation(.easeInOut(duration: 0.2), value: watcher.movedAway)
    }

    @ViewBuilder private var overlay: some View {
        switch watcher.phase {
        case .live:
            EmptyView()
        case .starting:
            if !watcher.hasPicture {
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

/// Pan | Scroll — what one finger does on the window. Pan (the default) moves around the picture;
/// Scroll scrolls the window on the Mac, right where the finger is (and two fingers move the
/// picture). It ends the key row on the right, where the thumb rests, so a watched window works
/// with one hand.
struct WatchDragSwitch: View {
    @ObservedObject var watcher: Watcher
    @Namespace private var pill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            option(.pan, "Pan", symbol: "hand.draw")
            option(.scroll, "Scroll", symbol: "arrow.up.and.down")
        }
        .padding(3)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Ink.line, lineWidth: 1))
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("What one finger does")
    }

    private func option(_ d: Watcher.Drag, _ title: String, symbol: String) -> some View {
        let on = watcher.drag == d
        return Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.82)) { watcher.setDrag(d) }
        } label: {
            Label(title, systemImage: symbol)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(on ? Ink.ground : Ink.secondary)
                .padding(.horizontal, 10)
                .frame(minHeight: 38)
                .background {
                    if on { Capsule().fill(Light.cyan).matchedGeometryEffect(id: "pill", in: pill) }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityHint(d == .pan ? "One finger moves around the picture." : "One finger scrolls the window on your Mac.")
        .accessibilityIdentifier("watch-drag-\(d.rawValue)")
    }
}

/// While the mic is open: the bottom of the window, small, so the question stays in view.
struct WatchStrip: View {
    @ObservedObject var watcher: Watcher
    var compact = false

    var body: some View {
        WatchWindow(watcher: watcher, interactive: false)
            .frame(height: compact ? 72 : 104)
            .opacity(watcher.hasPicture ? 1 : 0)
            .accessibilityHidden(true)
    }
}

/// Esc · ↑ · ↓ · Return — the same four keys in every app (Sameer, Oct 14 2026: "basic things
/// that allow the user to navigate very quickly or confirm things very quickly") — and Pan | Scroll,
/// all on one row under the thumb (Oct 16 2026). While the window asks a question, its answers take
/// the keys' place ("the buttons should replace the default up, down, return, esc buttons"), with
/// Esc and Keys kept small beside the switch.
struct WatchActions: View {
    @ObservedObject var watcher: Watcher
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let p = watcher.answers {
                answers(p)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
            } else {
                keys.transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86), value: watcher.answers?.id)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    private func answers(_ p: WatchPrompt) -> some View {
        VStack(spacing: 6) {
            ForEach(Array(p.choices.enumerated()), id: \.offset) { i, c in
                Button { watcher.choose(i) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        if let n = c.number {
                            Text("\(n)").font(.mono(.footnote, weight: .semibold)).foregroundStyle(Ink.tertiary)
                        }
                        Text(c.label)
                            .font(.subheadline.weight(.semibold))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .nativeGlassButton()
                .accessibilityLabel(c.label)
                .accessibilityHint("Answers \(watcher.name) on your Mac.")
                .accessibilityIdentifier("watch-answer-\(i)")
            }
            HStack(spacing: 6) {
                key(.escape, label: Text("Esc"), name: "Escape").fixedSize()
                Button { watcher.showKeys() } label: {
                    Label("Keys", systemImage: "keyboard").font(.subheadline.weight(.semibold)).frame(minHeight: 30)
                }
                .nativeGlassButton()
                .controlSize(.small)
                .fixedSize()
                .accessibilityHint("Shows Esc, the arrows and Return instead of these answers.")
                .accessibilityIdentifier("watch-keys")
                Spacer(minLength: 0)
                WatchDragSwitch(watcher: watcher).fixedSize()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(p.question ?? "\(watcher.name) is asking")
    }

    private var keys: some View {
        HStack(spacing: 6) {
            key(.escape, label: Text("Esc"), name: "Escape")
            key(.arrowUp, label: Image(systemName: "arrow.up"), name: "Up arrow")
            key(.arrowDown, label: Image(systemName: "arrow.down"), name: "Down arrow")
            key(.returnKey, label: Image(systemName: "return"), name: "Return")
            WatchDragSwitch(watcher: watcher)
                .fixedSize()
                .padding(.leading, 4)
        }
    }

    private func key<L: View>(_ a: WatchAction, label: L, name: String) -> some View {
        Button { watcher.perform(a) } label: {
            label
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 30)
        }
        .nativeGlassButton()
        .controlSize(.small)
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
/// ring where it landed. One finger moves the picture (Pan, the default) or scrolls the Mac's
/// window right there (Scroll — Sameer, Oct 14 2026: "swipe gestures could trigger small scrolls
/// … where the swipe occurs"); in Scroll, two fingers move the picture; a pinch zooms it.
///
/// A swipe is a trackpad gesture on the Mac (Oct 17 2026): its deltas go once a display frame,
/// bracketed by where the finger is (landed, lifted), and a flick coasts — the phone steps the
/// momentum on a display link and sends it, so the Mac's window keeps moving after the finger
/// lifts, as under a trackpad. A Mac from before gets the deltas alone, and one flick delta.
///
/// The window is a picture (`image`) or video (`video`, the Watcher's one `VideoCanvas`, which
/// this viewer hosts over the picture while video flows — taken over from whichever viewer had it,
/// the strip or the window, which keeps a snapshot for its fade-out).
struct WindowViewer: UIViewRepresentable {
    var image: UIImage?
    var video: VideoCanvas?
    var videoSize: CGSize
    var focus: CGRect?
    var recenter: Int
    var interactive: Bool
    var drag: Watcher.Drag
    /// The Mac takes a swipe's phases (it named "scroll").
    var phased: Bool
    var onTouch: () -> Void
    var onTap: (CGPoint) -> Void
    var onScroll: (CGPoint, CGVector) -> Void
    var onScrollPhase: (WatchScrollPhase, CGPoint) -> Void
    var onAdjusted: (Bool) -> Void

    func makeUIView(context: Context) -> ViewerScrollView {
        let v = ViewerScrollView()
        wire(v)
        return v
    }

    func updateUIView(_ v: ViewerScrollView, context: Context) {
        wire(v)
        v.update(image: image, video: video, videoSize: videoSize, focus: focus, recenter: recenter, interactive: interactive, drag: drag, phased: phased)
    }

    private func wire(_ v: ViewerScrollView) {
        v.onTouch = onTouch
        v.onTap = onTap
        v.onScroll = onScroll
        v.onScrollPhase = onScrollPhase
        v.onAdjusted = onAdjusted
    }
}

final class ViewerScrollView: UIScrollView, UIScrollViewDelegate {
    /// What zooms: the picture, with the video canvas over it while video flows.
    private let canvas = UIView()
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
    var onScrollPhase: (WatchScrollPhase, CGPoint) -> Void = { _, _ in }
    var onAdjusted: (Bool) -> Void = { _ in }
    private var tapper: UITapGestureRecognizer!
    private var swiper: UIPanGestureRecognizer!
    /// The swipe so far, not yet sent (sent once a display frame), and where it started.
    private var pendingScroll = CGVector.zero
    private var scrollAnchor = CGPoint.zero
    /// The Mac takes the swipe's phases: a gesture, then a coast.
    private var phased = false
    /// Ticks once a display frame while a finger swipes or a flick coasts: the deltas since the
    /// last tick go out as one (sixty a second at most, whatever the display's rate).
    private var scrollLink: CADisplayLink?
    private var momentum: ScrollMomentum?
    private var lastTick: CFTimeInterval = 0

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
        canvas.addSubview(imageView)
        addSubview(canvas)
        tapper = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        addGestureRecognizer(tapper)
        swiper = UIPanGestureRecognizer(target: self, action: #selector(swiped(_:)))
        swiper.maximumNumberOfTouches = 1
        addGestureRecognizer(swiper)
        apply(drag: .pan)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Pan: one finger moves the picture (the scroll view's own drag). Scroll: one finger scrolls the
    /// Mac's window, and the picture moves with two.
    private func apply(drag: Watcher.Drag) {
        panGestureRecognizer.minimumNumberOfTouches = drag == .pan ? 1 : 2
        swiper.isEnabled = drag == .scroll && isScrollEnabled
    }

    func update(image: UIImage?, video: VideoCanvas?, videoSize: CGSize, focus: CGRect?, recenter: Int, interactive: Bool, drag: Watcher.Drag, phased: Bool) {
        isScrollEnabled = interactive
        pinchGestureRecognizer?.isEnabled = interactive
        tapper.isEnabled = interactive
        self.phased = phased
        apply(drag: drag)
        let focusChanged = focus != self.focus && !adjusted
        self.focus = focus
        imageView.image = image
        adopt(video)
        let size = video != nil ? videoSize : image?.size ?? .zero
        guard size != .zero else { return }
        if size != imageSize {
            // A new size (first picture, or the window was resized): start over.
            imageSize = size
            zoomScale = 1
            canvas.frame = CGRect(origin: .zero, size: size)
            imageView.frame = canvas.bounds
            video?.frame = canvas.bounds
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

    /// Hosts the video canvas over the picture, or lets it go. Taken from another viewer (the
    /// window's, when the strip opens; the strip's, when it closes), that one keeps a snapshot
    /// in its place for its fade-out. Nothing per frame: the canvas draws itself.
    private func adopt(_ video: VideoCanvas?) {
        canvas.subviews.filter { $0.tag == Self.snapshotTag }.forEach { $0.removeFromSuperview() }
        guard let video else { return }
        guard video.superview !== canvas else { return }
        if let old = video.superview, let snap = video.snapshotView(afterScreenUpdates: false) {
            snap.frame = video.frame
            snap.tag = Self.snapshotTag
            old.addSubview(snap)
        }
        video.removeFromSuperview()
        video.frame = canvas.bounds
        canvas.addSubview(video)
    }

    private static let snapshotTag = 7001

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
        let p = g.location(in: canvas)
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
            // A new swipe while the last flick still coasts ends the coast first, so the Mac sees
            // its end before this gesture's beginning.
            endMomentum()
            let p = g.location(in: canvas)
            scrollAnchor = CGPoint(x: min(max(p.x / imageSize.width, 0), 1), y: min(max(p.y / imageSize.height, 0), 1))
            pendingScroll = .zero
            g.setTranslation(.zero, in: self)
            if phased { onScrollPhase(.began, scrollAnchor) }
            startLink()
        case .changed:
            let t = g.translation(in: self)
            g.setTranslation(.zero, in: self)
            // As fractions of the window, so the Mac moves its content as far as the finger did.
            pendingScroll.dx += t.x / shown.width
            pendingScroll.dy += t.y / shown.height
        case .ended:
            flushScroll()
            let v = g.velocity(in: self)
            if phased {
                onScrollPhase(.ended, scrollAnchor)
                // A flick coasts, a delta per frame from the lift-off speed, until it fades.
                if let m = ScrollMomentum(velocity: CGVector(dx: v.x, dy: v.y)) {
                    momentum = m
                    onScrollPhase(.momentumBegan, scrollAnchor)
                    step(dt: 1 / ScrollMomentum.tickRate)
                } else {
                    stopLink()
                }
            } else {
                // A Mac from before: a flick carries on a little, in one delta.
                pendingScroll.dy += min(max(v.y * 0.12, -900), 900) / shown.height
                flushScroll()
                stopLink()
            }
        default:
            flushScroll()
            if phased { onScrollPhase(.ended, scrollAnchor) }
            stopLink()
        }
    }

    private func startLink() {
        guard scrollLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        let rate = Float(ScrollMomentum.tickRate)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        link.add(to: .main, forMode: .common)
        scrollLink = link
        lastTick = CACurrentMediaTime()
    }

    private func stopLink() {
        scrollLink?.invalidate()
        scrollLink = nil
        momentum = nil
    }

    /// Once a display frame: the finger's deltas since the last, or the coast's next step.
    @objc private func tick(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let dt = now - lastTick
        lastTick = now
        if momentum != nil { step(dt: dt) } else { flushScroll() }
    }

    /// One step of the coast, in the picture's points as the finger's deltas are — nothing left
    /// to move ends it.
    private func step(dt: CFTimeInterval) {
        guard var m = momentum, let s = m.step(dt: dt) else { endMomentum(); return }
        momentum = m
        let shown = CGSize(width: imageSize.width * zoomScale, height: imageSize.height * zoomScale)
        guard shown.width > 0, shown.height > 0 else { endMomentum(); return }
        onScroll(scrollAnchor, CGVector(dx: s.dx / shown.width, dy: s.dy / shown.height))
    }

    private func endMomentum() {
        let coasting = momentum != nil
        stopLink()
        if coasting { onScrollPhase(.momentumEnded, scrollAnchor) }
    }

    private func flushScroll() {
        guard abs(pendingScroll.dx) + abs(pendingScroll.dy) > 0.0005 else { return }
        onScroll(scrollAnchor, pendingScroll)
        pendingScroll = .zero
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil { endMomentum() }
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

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { canvas }

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
