import MacrophoneKit
import SwiftUI

// The pick's window on the desktop (Nov 7 2026, Sameer: "what should be easy to access vs buried
// in a menu"): the room between the menu bar and the Dock holds the pick's window, and the whole
// card is the button that shows it — the one way to watch you can see from the desktop. Drawn as
// App Exposé draws a window (round 4, the same night): the picture it showed last time, whole —
// its own title bar and all, so never a second, drawn one over it — and a caption under it. The
// window's picture flies out of the card on open and back into it on Done (`WindowZoom`).
//
//   ┌──────────────────────────────────────┐
//   │ ● ● ●        (the window's           │
//   │               kept picture)       👁 │
//   └──────────────────────────────────────┘
//          ▣ Claude  Fix the login bug …

/// Where the card's picture is on screen: the window's picture flies out of it when the card
/// opened it, and back into it on Done. Nil while no card is drawn.
@MainActor
final class DesktopWindowSpot {
    static let shared = DesktopWindowSpot()
    /// The picture's rect (not the caption's), in global space.
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
            .accessibilityGone(hidden)
    }
}

enum DesktopWindowLook {
    /// Below this much room the card isn't drawn (an SE at accessibility sizes): a window too
    /// small to read is only clutter over the wallpaper.
    static let leastRoom: CGFloat = 140
    static let widest: CGFloat = 440
    /// Air above and below the card, between the menu bar and the Dock.
    static let air: CGFloat = 24
    static let corner: CGFloat = 12
    /// The caption under the picture, and the gap over it.
    static let caption: CGFloat = 20
    static let captionGap: CGFloat = 8
    /// A window with no picture yet: a quiet plate, never taller than this.
    static let plateHeight: CGFloat = 180
    static let badge: CGFloat = 26
}

struct DesktopWindowCard: View {
    @EnvironmentObject var model: AppModel
    var target: TargetRef
    /// The room it may take (the desktop between the menu bar and the Dock, less its air).
    var room: CGSize
    /// Under the window or the words: kept laid out (Done flies the picture back into it), taking
    /// no touch.
    var hidden = false
    var onWatch: () -> Void
    @ObservedObject private var zoom = WindowZoom.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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

    /// The window's own title, beside the app's name ("Fix the login bug — claude").
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

    private var invitation: String {
        if isDesktop { return "Show your Mac's screen here" }
        if case .frontApp = target { return "Show the app you're typing in" }
        return "Show the \(name) window here"
    }

    var body: some View {
        let _ = kept
        let picture = notOpen ? nil : WindowSnapshots.cached(key)
        Group {
            if notOpen, let bid = target.bundleID {
                VStack(spacing: DesktopWindowLook.captionGap) {
                    plate {
                        VStack(spacing: 8) {
                            DockTile(target: target, icon: icon, size: 40).saturation(0).opacity(0.7)
                            Text("\(name) isn't open").font(.subheadline.weight(.semibold)).foregroundStyle(Ink.secondary)
                            Button("Open \(name)") { model.openOnMac(MacApp(bundleID: bid, name: name)) }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .accessibilityIdentifier("desktop-window-open")
                        }
                        .padding(12)
                    }
                }
                .accessibilityElement(children: .contain)
            } else {
                Button(action: onWatch) {
                    VStack(spacing: DesktopWindowLook.captionGap) {
                        if let picture {
                            thumbnail(picture)
                        } else {
                            plate {
                                VStack(spacing: 8) {
                                    DockTile(target: target, icon: icon, size: 40)
                                    Text(invitation)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(Ink.secondary)
                                        .multilineTextAlignment(.center)
                                }
                                .padding(12)
                            }
                        }
                        caption
                    }
                    .contentShape(Rectangle())
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
        .opacity(canWatch || notOpen ? 1 : 0.55)
        .accessibilityHidden(hidden)
        .allowsHitTesting(!hidden)
        .onDisappear { DesktopWindowSpot.shared.frame = nil }
        .onReceive(NotificationCenter.default.publisher(for: WindowSnapshots.didKeep)) { n in
            if (n.object as? String) == key { kept &+= 1 }
        }
        .animation(Motion.pick(Motion.settle, reduce: reduceMotion), value: key)
        .animation(.easeInOut(duration: 0.2), value: canWatch)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    /// The picture's room: the card's less its caption.
    private var pictureRoom: CGSize {
        CGSize(width: min(room.width, DesktopWindowLook.widest),
               height: max(1, room.height - DesktopWindowLook.caption - DesktopWindowLook.captionGap))
    }

    /// The window as App Exposé shows it: whole, never cropped, its corners rounded, a hairline
    /// and a soft shadow lifting it off the wallpaper.
    private func thumbnail(_ picture: UIImage) -> some View {
        let aspect = picture.size.width / max(1, picture.size.height)
        var w = pictureRoom.width, h = w / aspect
        if h > pictureRoom.height { h = pictureRoom.height; w = h * aspect }
        let shape = RoundedRectangle(cornerRadius: DesktopWindowLook.corner, style: .continuous)
        return Image(uiImage: picture)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fill)
            .frame(width: w.rounded(), height: h.rounded())
            .clipShape(shape)
            .overlay(shape.strokeBorder(Ink.line, lineWidth: 0.5))
            .overlay(alignment: .bottomTrailing) { EyeBadge().padding(8) }
            // While its picture is flying (to the window or back), the card's own waits under it.
            .opacity(zoom.cardHidden ? 0 : 1)
            .shadow(color: .black.opacity(0.16), radius: 14, y: 5)
            .id(key)
            .transition(.opacity)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { DesktopWindowSpot.shared.frame = $0 }
    }

    /// No picture yet, or the app isn't open: a quiet plate in the window's place.
    private func plate<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        let shape = RoundedRectangle(cornerRadius: DesktopWindowLook.corner, style: .continuous)
        let h = min(DesktopWindowLook.plateHeight, room.height / 2, pictureRoom.height)
        return content()
            .frame(width: min(pictureRoom.width, 320), height: max(h, 120))
            .background(shape.fill(.regularMaterial))
            .overlay(shape.strokeBorder(Ink.line, lineWidth: 0.5))
            .overlay(alignment: .bottomTrailing) { if !notOpen { EyeBadge().padding(8) } }
            .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { DesktopWindowSpot.shared.frame = $0 }
    }

    /// Under the picture: the app, the window's title, and what it's waiting for.
    private var caption: some View {
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
        .frame(height: DesktopWindowLook.caption)
        .frame(maxWidth: pictureRoom.width)
        .padding(.horizontal, 4)
    }

    private var icon: Data? {
        model.liveTarget(for: target)?.icon ?? target.bundleID.flatMap { b in model.macApps.first { $0.bundleID == b }?.icon }
    }

    private var needs: NeedsYou? {
        guard model.looksConnected, let live = model.liveTarget(for: target) else { return nil }
        return model.needs(live)
    }

    private var needsWords: String? { needs.map { $0.asking ? "Asking you something" : "Answered you" } }
}

/// The picture's corner badge, as Photos marks a video: it says a tap plays it live. Decorative —
/// the card's own label says so to VoiceOver.
private struct EyeBadge: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Image(systemName: "eye.fill")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Ink.ink)
            .frame(width: DesktopWindowLook.badge, height: DesktopWindowLook.badge)
            .background {
                if #available(iOS 26.0, *), !reduceTransparency {
                    Color.clear.glassEffect(.regular, in: Circle())
                } else {
                    Circle().fill(.regularMaterial)
                }
            }
            .accessibilityHidden(true)
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
