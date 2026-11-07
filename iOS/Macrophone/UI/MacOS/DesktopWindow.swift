import MacrophoneKit
import SwiftUI

// The pick's window on the desktop (Nov 7 2026, Sameer: "what should be easy to access vs buried
// in a menu"): the room between the menu bar and the Dock was empty, and the only way to watch was
// tapping the picked Dock icon a second time. Now that room holds the pick's window, drawn as a
// small Mac window — the picture it showed last time inside a real title bar — and the whole card
// is the button that shows it. The window grows out of the card, and Done puts it back.
//
//   ┌ ● ● ●  ▣ Claude  Fix the login bug …   [👁 Watch] ┐
//   │                                                  │
//   │            (the window's kept picture)           │
//   └──────────────────────────────────────────────────┘

/// Where the card is on screen: the window grows out of it when the card opened it, and goes back
/// into it on Done. Nil while no card is drawn.
@MainActor
final class DesktopWindowSpot {
    static let shared = DesktopWindowSpot()
    var frame: CGRect?
}

extension EnvironmentValues {
    /// The phone's window panel, built and hidden at rest (`WatchWindow`).
    @Entry var watchWindowHidden = false
    /// …and the pick's kept picture, which its viewer holds meanwhile: the first open after launch
    /// finds its viewer made and framed.
    @Entry var watchRestPicture: UIImage? = nil
}

/// A layer kept built while another has the screen (the desktop under the window, the window at
/// rest): no touch, and nothing of it for VoiceOver. (XCUITest still finds what's in it on the
/// iOS 27 simulator, hidden or not — Nov 7 2026 — so the kept window panel also drops its header
/// while hidden: a test asking whether Done exists gets the true answer.)
struct OutOfReach: ViewModifier {
    var hidden: Bool
    func body(content: Content) -> some View {
        content
            .allowsHitTesting(!hidden)
            .accessibilityElement(children: hidden ? .ignore : .contain)
            .accessibilityHidden(hidden)
    }
}

enum DesktopWindowLook {
    static let bar: CGFloat = 32
    /// Below this much room the card isn't drawn (an SE at accessibility sizes): a window too
    /// small to read is only clutter over the wallpaper.
    static let leastRoom: CGFloat = 140
    static let widest: CGFloat = 440
    /// A window with no picture yet is drawn this shape (a Mac window's usual).
    static let defaultAspect: CGFloat = 16.0 / 10.0
}

struct DesktopWindowCard: View {
    @EnvironmentObject var model: AppModel
    var target: TargetRef
    /// The room it may take (the desktop between the menu bar and the Dock).
    var room: CGSize
    /// Under the window or the words: kept laid out (Done shrinks the window back into it), taking
    /// no touch.
    var hidden = false
    var onWatch: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    /// Bumped when a window's picture is kept: the card reads the new one.
    @State private var kept = 0

    private var key: String? { WindowSnapshots.key(mac: model.pairedMac?.id, target: target) }
    private var isDesktop: Bool { DesktopWatch.isDesktop(target) }
    private var notOpen: Bool { model.isNotOpen(target) }
    /// The looks hold through the return grace (`looksConnected`): back from the background the card
    /// never flashes dim; a tap then opens on the connect (`watchWhenConnected`).
    private var canWatch: Bool { model.looksConnected && !notOpen }

    private var name: String {
        if isDesktop { return "Whole Screen" }
        if case .frontApp = target { return "Where I'm typing" }
        return Places.appName(target, in: model)
    }

    /// The window's own title, under the app's name ("Fix the login bug — claude").
    private var detail: String? {
        if isDesktop { return model.pairedMac?.name }
        guard let t = model.liveTarget(for: target)?.windowTitle, !t.isEmpty, t != name else { return nil }
        return t
    }

    private var spoken: String {
        if isDesktop { return "Show your Mac's whole screen" }
        if case .frontApp = target { return "Show the app you're typing in" }
        return "Show \(name.hasSuffix("s") ? name + "'" : name + "'s") window"
    }

    var body: some View {
        let _ = kept
        let picture = WindowSnapshots.cached(key)
        let aspect = picture.map { $0.size.width / max(1, $0.size.height) } ?? DesktopWindowLook.defaultAspect
        let size = fitted(aspect: aspect)
        Group {
            if notOpen, let bid = target.bundleID {
                window(picture: nil, size: size, trailing: { EmptyView() }) {
                    VStack(spacing: 10) {
                        DockTile(target: target, icon: icon, size: 40).saturation(0).opacity(0.7)
                        Text("\(name) isn't open").font(.subheadline.weight(.semibold)).foregroundStyle(Ink.secondary)
                        Button("Open \(name)") { model.openOnMac(MacApp(bundleID: bid, name: name)) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .accessibilityIdentifier("desktop-window-open")
                    }
                    .padding(12)
                }
                .accessibilityElement(children: .contain)
            } else {
                Button(action: onWatch) {
                    window(picture: picture, size: size, trailing: { watchLabel }) {
                        VStack(spacing: 8) {
                            DockTile(target: target, icon: icon, size: 40)
                            Text(isDesktop ? "Show your Mac's screen here" : target == .frontApp ? "Show the app you're typing in" : "Show the \(name) window here")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Ink.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(12)
                    }
                }
                .buttonStyle(CardPress())
                .disabled(!canWatch)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken)
                .accessibilityValue(needsWords ?? "")
                .accessibilityHint(model.looksConnected ? "Watch it live and control it from here." : "Waiting for your Mac to connect.")
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("desktop-window")
            }
        }
        .accessibilityHidden(hidden)
        .allowsHitTesting(!hidden)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { DesktopWindowSpot.shared.frame = $0 }
        .onDisappear { DesktopWindowSpot.shared.frame = nil }
        .onReceive(NotificationCenter.default.publisher(for: WindowSnapshots.didKeep)) { n in
            if (n.object as? String) == key { kept &+= 1 }
        }
        .animation(Motion.pick(Motion.settle, reduce: reduceMotion), value: key)
        .animation(Motion.pick(Motion.settle, reduce: reduceMotion), value: size)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    /// The picture's shape inside the room, the title bar on top; never so narrow that the bar
    /// can't hold the lights, the name and Watch.
    private func fitted(aspect: CGFloat) -> CGSize {
        let maxW = min(room.width, DesktopWindowLook.widest)
        let maxPicture = max(1, room.height - DesktopWindowLook.bar)
        var w = maxW, h = w / aspect
        if h > maxPicture { h = maxPicture; w = h * aspect }
        w = max(w, min(maxW, 260))
        return CGSize(width: w.rounded(), height: (h + DesktopWindowLook.bar).rounded())
    }

    private var icon: Data? {
        model.liveTarget(for: target)?.icon ?? target.bundleID.flatMap { b in model.macApps.first { $0.bundleID == b }?.icon }
    }

    private var needs: NeedsYou? {
        guard model.looksConnected, let live = model.liveTarget(for: target) else { return nil }
        return model.needs(live)
    }

    private var needsWords: String? { needs.map { $0.asking ? "Asking you something" : "Answered you" } }

    private func window<T: View, E: View>(picture: UIImage?, size: CGSize, @ViewBuilder trailing: () -> T, @ViewBuilder empty: () -> E) -> some View {
        let trailingView = trailing(), emptyView = empty()
        return MacWindowFrame(decorative: true, lights: picture == nil, barHeight: DesktopWindowLook.bar) {
            titleRow
        } trailing: {
            trailingView
        } content: {
            ZStack {
                Ink.sunk
                if let picture {
                    Image(uiImage: picture)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .id(key)
                        .transition(.opacity)
                } else {
                    emptyView.transition(.opacity)
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private var titleRow: some View {
        HStack(spacing: 6) {
            DockTile(target: target, icon: icon, size: 16)
            Text(name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Ink.ink)
                .lineLimit(1)
                .layoutPriority(1)
            if let w = model.alertWatch(for: target) {
                AlertWatchBadge(calm: w.calm).scaleEffect(0.8).frame(width: 15, height: 15)
            }
            if let words = needsWords {
                HStack(spacing: 4) {
                    Circle().fill(Light.ember).frame(width: 7, height: 7)
                    Text(words).font(.system(size: 12, weight: .semibold)).foregroundStyle(Light.ember).lineLimit(1)
                }
                .fixedSize()
            } else if let detail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private var watchLabel: some View {
        Label("Watch", systemImage: "eye")
            .font(.system(size: 13, weight: .semibold))
            .labelStyle(WatchLabelStyle())
            .foregroundStyle(canWatch ? Light.cyan : Ink.tertiary)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Capsule().fill((canWatch ? Light.cyan : Ink.tertiary).opacity(0.14)))
            .fixedSize()
    }
}

private struct WatchLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 11, weight: .bold))
            configuration.title
        }
    }
}

/// The card pressed: it settles a touch, as a window clicked on a Mac comes forward.
private struct CardPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .brightness(configuration.isPressed ? -0.04 : 0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}
