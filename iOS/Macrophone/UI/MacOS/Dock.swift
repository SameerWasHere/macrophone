import MacrophoneKit
import SwiftUI

// Send to is the Dock (Nov 1 2026, Sameer: "borrow elements from macOS"). A glass shelf of the
// Mac's open apps, a running dot under each; a divider, then Clipboard and Where I'm typing —
// where a Mac keeps Downloads and the Trash — and + for any app on the Mac. The pick stands a
// little higher with its name over it, the way the Dock labels the icon under the pointer, so the
// Dock says where the words go without a line of its own. A finger scrubbing along the shelf
// magnifies the icons under it, as on a Mac with magnification on, and picks the one it lifts
// from; a long press is the Dock's menu — the app's windows as pictures (`DockWindowsPopover`).
// The pick, tapped again, shows its window.

/// The icons' side in this Dock: `DockLook.icon`, or less when that many wouldn't fit across.
private struct DockIconSize: EnvironmentKey { static let defaultValue: CGFloat = DockLook.icon }
extension EnvironmentValues {
    var dockIcon: CGFloat {
        get { self[DockIconSize.self] }
        set { self[DockIconSize.self] = newValue }
    }
}

enum DockLook {
    static let icon: CGFloat = 44
    static let spacing: CGFloat = 7
    static let shelfHeight: CGFloat = 72
    /// The room over the shelf for the pick's label and a magnified icon.
    static let headroom: CGFloat = 34
    /// How much an icon under the finger grows, and how far the swell reaches either side.
    static let magnify: CGFloat = 0.42
    static let reach: CGFloat = 92
}

/// Where the pick's icon is on screen (Nov 4 2026, Sameer picked "the Dock icon opens into the
/// window"): the window grows out of it and goes back into it, as a Mac's window does out of the
/// Dock. Nil while no Dock is drawn (the Duo, the cover): the window fades there, as before.
@MainActor
final class DockSpot {
    static let shared = DockSpot()
    var pick: CGRect?
}

struct SendToDock: View {
    @EnvironmentObject var model: AppModel
    var current: TargetRef
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Where a scrubbing finger is along the row, in the row's own space; nil when none is.
    @State private var finger: CGFloat?
    /// The row is wider than the shelf: it scrolls, and a drag scrolls rather than picks.
    @State private var overflows = false
    @State private var centres: [String: CGFloat] = [:]
    /// The icons' own width; the shelf is that, or the screen's less a margin (then they scroll in it).
    @State private var contentWidth: CGFloat?
    /// The pick's name label's width (it's kept on the shelf: `labelShift`).
    @State private var labelWidth: CGFloat = 0
    /// The pick's middle on the shelf as it shows (scrolled or not).
    @State private var pickMid: CGFloat?

    var body: some View {
        let places = model.placeOptions(current: current)
        let apps = places.filter { $0.kind == .app || $0.kind == .closed || $0.kind == .opening }
        let stacks = places.filter { $0.kind == .clipboard || $0.kind == .front }
        let selected = places.first { $0.holds(current) }?.id
        let notOpen = model.isNotOpen(current)
        GeometryReader { outer in
            let room = outer.size.width - 16
            let width = min(contentWidth ?? room, room)
            // Like the Mac's Dock, the icons shrink until every one fits — never cut off, never a
            // row to scroll (Nov 1 2026, Sameer: "It should never be cut off").
            let n = CGFloat(apps.count + stacks.count + 1)
            let fixed: CGFloat = 20 + 5 + (n + 1) * DockLook.spacing
            let side = min(DockLook.icon, max(26, ((room - fixed) / n).rounded(.down)))
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(alignment: .bottom, spacing: DockLook.spacing) {
                        ForEach(apps) { p in icon(p, selected: selected, notOpen: notOpen, shelf: width, room: outer.size.width - 24) }
                        // No open apps: nothing for the divider to divide (Nov 5 2026).
                        if !apps.isEmpty { DockDivider() }
                        ForEach(stacks) { p in icon(p, selected: selected, notOpen: notOpen, shelf: width, room: outer.size.width - 24) }
                        DockApplications(scale: scale(for: "more")) { model.sheet = .openApp }
                            .background(centre("more"))
                    }
                    .environment(\.dockIcon, side)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10 + (DockLook.icon - side) / 2)
                    .padding(.top, DockLook.headroom)
                    .coordinateSpace(.named("dock"))
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { w in
                        contentWidth = w
                        overflows = w > room + 1
                    }
                    .simultaneousGesture(scrub(places: places))
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
                .scrollClipDisabled()
                // The shelf hugs the icons, as the Dock does, centred — never wider than the
                // screen: past that the icons scroll inside it, trimmed at its sides only (the
                // pick's name and a swelling icon rise above it).
                .frame(width: width)
                .coordinateSpace(.named("shelf"))
                .mask(RoundedRectangle(cornerRadius: MacOSLook.dock, style: .continuous).padding(.top, -80))
                .background(alignment: .bottom) { shelf.frame(width: width) }
                .frame(maxWidth: .infinity)
                .onAppear { if let selected { proxy.scrollTo(selected, anchor: .center) } }
                .onChange(of: selected) { _, id in
                    guard let id else { return }
                    withAnimation(Motion.pick(.snappy(duration: 0.35), reduce: reduceMotion)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .frame(height: DockLook.shelfHeight + DockLook.headroom)
        .onDisappear { DockSpot.shared.pick = nil }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Send to, on your Mac's Dock")
        .accessibilityIdentifier("places")
    }

    /// The shelf: Liquid Glass, a Dock's rounded slab.
    private var shelf: some View {
        let shape = RoundedRectangle(cornerRadius: MacOSLook.dock, style: .continuous)
        return Group {
            if #available(iOS 26.0, *) {
                Color.clear.glassEffect(.regular, in: shape)
            } else {
                shape.fill(.regularMaterial).overlay(shape.strokeBorder(Ink.line, lineWidth: 0.5))
            }
        }
        .frame(height: DockLook.shelfHeight)
        .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
        .allowsHitTesting(false)
    }

    private func icon(_ p: PlaceOption, selected: String?, notOpen: Bool, shelf: CGFloat, room: CGFloat) -> some View {
        let isPick = p.id == selected
        return DockIcon(place: p, selected: isPick, current: current,
                        scale: scale(for: p.id),
                        watchable: isPick && current != .clipboard && model.looksConnected && !notOpen,
                        needs: model.looksConnected ? model.needs(p) : nil,
                        windowNeeds: { model.looksConnected ? model.needs($0) : nil },
                        macID: model.pairedMac?.id,
                        canWatchWindows: model.looksConnected && p.kind == .app,
                        room: room,
                        onWatchWindow: { watch($0) },
                        label: isPick ? current.displayName : nil,
                        notOpen: isPick && notOpen,
                        labelShift: isPick ? labelShift(shelf: shelf) : 0,
                        onLabelWidth: { labelWidth = $0 },
                        onPickMid: { pickMid = $0 },
                        onWatch: { watch() }) { pick($0) }
            .id(p.id)
            .background(centre(p.id))
    }

    /// The pick's name kept on the shelf (Nov 4 2026): over an icon near either end it ran past
    /// the shelf's side and was cut there ("alendar" over a Calendar just opened, first in
    /// line). It slides in just enough to stay whole, as a Mac's Dock label stays on screen.
    /// (Where the icon is on the shelf as it shows, scrolled or not: `pickMid`.)
    private func labelShift(shelf: CGFloat) -> CGFloat {
        guard labelWidth > 0, let c = pickMid, shelf > 0 else { return 0 }
        let half = labelWidth / 2, edge: CGFloat = 4
        let lo = half + edge, hi = shelf - half - edge
        guard lo <= hi else { return shelf / 2 - c }
        return min(max(c, lo), hi) - c
    }

    /// Records an icon's middle along the row (for the magnification).
    private func centre(_ id: String) -> some View {
        Color.clear.onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("dock")).midX } action: { centres[id] = $0 }
    }

    /// The swell under a scrubbing finger: a cosine bump, the icon right under it the biggest.
    private func scale(for id: String) -> CGFloat {
        guard let finger, !reduceMotion, let c = centres[id] else { return 1 }
        let d = abs(c - finger)
        guard d < DockLook.reach else { return 1 }
        return 1 + DockLook.magnify * (0.5 + 0.5 * cos(.pi * d / DockLook.reach))
    }

    /// A finger moving along the Dock magnifies; lifted after a scrub, it picks the icon under it.
    private func scrub(places: [PlaceOption]) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named("dock"))
            .onChanged { v in
                guard !overflows else { return }
                withAnimation(.interactiveSpring(response: 0.18, dampingFraction: 0.82)) { finger = v.location.x }
            }
            .onEnded { v in
                defer { withAnimation(Motion.pick(.spring(response: 0.3, dampingFraction: 0.75), reduce: reduceMotion)) { finger = nil } }
                guard !overflows else { return }
                let near = centres.min { abs($0.value - v.location.x) < abs($1.value - v.location.x) }
                guard let near, abs(near.value - v.location.x) < DockLook.icon else { return }
                if near.key == "more" { model.sheet = .openApp; return }
                if let p = places.first(where: { $0.id == near.key }) { pick(p.target) }
            }
    }

    private func watch() {
        guard current != .clipboard, model.looksConnected, !model.isNotOpen(current) else { return }
        // The link only looks up (back from the background): it opens on the connect.
        model.watchWhenConnected(current)
    }

    /// Show Window from an icon's window previews: that window becomes the pick and shows — after
    /// the popover has gone, so the window grows out of its icon (`DockSpot`) rather than under it.
    private func watch(_ t: TargetRef) {
        pick(t)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 320_000_000)
            guard t == model.selection.target, t != .clipboard, model.looksConnected, !model.isNotOpen(t) else { return }
            model.watchWhenConnected(t)
        }
    }

    private func pick(_ t: TargetRef) {
        guard t != model.selection.target else { return }
        Haptics.pick()
        withAnimation(Motion.pick(Motion.snap, reduce: reduceMotion)) { model.pick(t) }
        if let live = model.liveTarget(for: t), !live.typeable {
            model.explain(Places.tapFirst(live.appName))
        } else {
            model.explain(Places.sentence(for: t, send: model.selection.send))
        }
    }
}

/// One icon on the Dock: the app's own icon (or a place's), the running dot under it, the
/// "answered you" mark, and — the pick — lifted with its name over it.
private struct DockIcon: View {
    @EnvironmentObject var model: AppModel
    var place: PlaceOption
    var selected: Bool
    var current: TargetRef
    var scale: CGFloat
    var watchable: Bool
    var needs: NeedsYou?
    var windowNeeds: (LiveTarget) -> NeedsYou?
    var macID: UUID?
    /// Show Window is offered under an app's window previews.
    var canWatchWindows = false
    /// The previews' widest.
    var room: CGFloat = 320
    var onWatchWindow: (TargetRef) -> Void = { _ in }
    /// The pick's label: where the words go ("Terminal — claude — ~/app").
    var label: String?
    var notOpen = false
    /// How far the label slides sideways to stay on the shelf.
    var labelShift: CGFloat = 0
    var onLabelWidth: (CGFloat) -> Void = { _ in }
    var onPickMid: (CGFloat) -> Void = { _ in }
    var onWatch: () -> Void
    var onPick: (TargetRef) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dockIcon) private var dockIcon
    /// The window previews are up (a long press).
    @State private var showsWindows = false
    /// The long press's own lift isn't a tap.
    @State private var swallowTap = false

    /// A long press shows something: an app's windows, or Show Window on the pick.
    private var hasPreviews: Bool { place.kind == .app && !place.windows.isEmpty }
    private var hasMenu: Bool { hasPreviews || (selected && watchable) }

    var body: some View {
        let size = dockIcon
        Button {
            if swallowTap { swallowTap = false; return }
            if let n = needs, let w = place.windows.first(where: n.concerns), !current.matches(w) { onPick(w.ref) }
            else if !place.holds(current) { onPick(place.target) }
            else { onWatch() }
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    DockTile(target: place.target, icon: place.icon, size: size)
                        .saturation(place.kind == .closed ? 0 : 1)
                        .opacity(place.kind == .closed && !selected ? 0.55 : 1)
                    if place.kind == .opening { ProgressView().controlSize(.small) }
                }
                .frame(width: size, height: size)
                .onGeometryChange(for: CGRect?.self) { [selected] g in selected ? g.frame(in: .global) : nil } action: { r in
                    if let r { DockSpot.shared.pick = r }
                }
                .onGeometryChange(for: CGFloat?.self) { [selected] g in selected ? g.frame(in: .named("shelf")).midX : nil } action: { x in
                    if let x { onPickMid(x) }
                }
                .overlay(alignment: .topTrailing) {
                    if needs != nil {
                        Circle().fill(Light.ember).frame(width: 13, height: 13)
                            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                            .offset(x: 4, y: -4)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .overlay(alignment: .topLeading) {
                    // On watch for changes: a bell at the icon's other corner.
                    if let w = model.alertWatch(for: place) {
                        AlertWatchBadge(calm: w.calm)
                            .offset(x: -5, y: -4)
                            .transition(.scale(scale: 0.5).combined(with: .opacity))
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if watchable {
                        Image(systemName: "eye.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 19, height: 19)
                            .background(Circle().fill(Light.cyan))
                            .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                            .offset(x: 5, y: 5)
                            .transition(.scale(scale: 0.5).combined(with: .opacity))
                            .accessibilityHidden(true)
                    }
                }
                // The running dot: an open app's (Clipboard and Where I'm typing aren't apps).
                Circle()
                    .fill(Ink.ink.opacity(place.kind == .app || place.kind == .opening ? (selected ? 0.9 : 0.55) : 0))
                    .frame(width: 4, height: 4)
            }
            .scaleEffect(scale, anchor: .bottom)
            .frame(width: size * scale)
            .offset(y: selected ? -5 : 0)
        }
        .buttonStyle(DockPress())
        .animation(Motion.pick(Motion.snap, reduce: reduceMotion), value: selected)
        .animation(Motion.snap, value: needs != nil)
        .animation(Motion.snap, value: model.alertWatch(for: place) != nil)
        // A long press: the app's windows as pictures over the icon (App Exposé), in a glass
        // popover rather than a context menu — a context menu's preview takes no taps and
        // doesn't scroll, and each card here is a window to pick. The scrub's drag moves the
        // finger past the press's reach, so magnifying along the Dock never opens it.
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.42, maximumDistance: 10).onEnded { _ in
            guard hasMenu else { return }
            swallowTap = true
            Haptics.grab()
            showsWindows = true
        })
        .popover(isPresented: $showsWindows, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
            DockWindowsPopover(place: place, current: current, macID: macID, room: room,
                               needs: windowNeeds,
                               canWatch: hasPreviews ? canWatchWindows : watchable,
                               onPick: { t in
                                   showsWindows = false
                                   onPick(t)
                               },
                               onWatch: { t in
                                   showsWindows = false
                                   if hasPreviews { onWatchWindow(t) } else { onWatch() }
                               })
                .presentationCompactAdaptation(.popover)
        }
        .onChange(of: showsWindows) { _, up in if !up { swallowTap = false } }
        .accessibilityLabel(accessibilityName)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(watchable ? "Tap again to watch its window on your Mac." : selected ? "" : "Sends your dictations here.")
        .accessibilityAction(named: "Watch") { if watchable { onWatch() } }
        .accessibilityAction(named: hasPreviews ? "Show Windows" : "Options") { if hasMenu { showsWindows = true } }
        // The pick's name over it: its own element (VoiceOver reads it as the Send to heading),
        // outside the button so it never becomes the button's own words.
        .overlay(alignment: .top) {
            if let label {
                DockLabel(text: label, warning: notOpen ? "Not open" : nil)
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { onLabelWidth($0) }
                    .offset(x: labelShift, y: -DockLook.headroom + 2 - (scale - 1) * dockIcon - (selected ? 5 : 0))
                    // The old name goes at once (a Dock's label just moves to the next icon):
                    // fading out over the new one's arrival, the two read as one garbled line
                    // for a few frames (Nov 4 2026).
                    .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)),
                                            removal: .opacity.animation(.easeOut(duration: 0.06))))
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Send to: \(label)" + (notOpen ? ", not open on your Mac — it'll be copied instead" : "")
                                        + (needs.map { $0.asking ? ", asking you something" : ", answered you" } ?? ""))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("send-to")
            }
        }
    }

    private var accessibilityName: String {
        var s = place.name
        if place.windows.count > 1 { s += ", \(place.windows.count) windows" }
        if place.kind == .closed { s += ", not open on your Mac" }
        if place.kind == .opening { s += ", opening on your Mac" }
        if let needs { s += needs.asking ? ", asking you something" : ", answered you" }
        return s
    }
}

/// The name over the pick: a small glass label, as the Dock shows over the icon under the pointer.
struct DockLabel: View {
    var text: String
    var warning: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Ink.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 230)
            if let warning {
                Text(warning).font(.system(size: 12, weight: .semibold)).foregroundStyle(Light.ochre)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .modifier(DockLabelGlass())
    }
}

private struct DockLabelGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(Capsule().fill(.thickMaterial)).overlay(Capsule().strokeBorder(Ink.line, lineWidth: 0.5))
        }
    }
}

/// A place as an app icon: the Mac app's own picture, or — Clipboard, Where I'm typing, an app
/// with no icon — a squircle in the place's colour with its symbol in white, as macOS draws a
/// system folder or utility.
struct DockTile: View {
    var target: TargetRef
    var icon: Data?
    var size: CGFloat

    var body: some View {
        if let img = IconCache.image(icon) {
            Image(uiImage: img).resizable().interpolation(.high).scaledToFit()
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                .accessibilityHidden(true)
        } else {
            let tint = TargetIcon.tint(target)
            AppIconShape()
                .fill(LinearGradient(colors: [tint.blended(with: .white, 0.18), tint.blended(with: .black, 0.12)], startPoint: .top, endPoint: .bottom))
                .overlay(Image(systemName: TargetGlyph.symbol(for: target))
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(.white))
                .overlay(AppIconShape().strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
                .frame(width: size * 0.84, height: size * 0.84)
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                .accessibilityHidden(true)
        }
    }
}

/// The Dock's divider between the apps and the stacks.
private struct DockDivider: View {
    @Environment(\.dockIcon) private var dockIcon
    var body: some View {
        Capsule().fill(Ink.ink.opacity(0.22)).frame(width: 1, height: dockIcon * 0.78)
            .padding(.horizontal, 2)
            .padding(.bottom, 12)
            .accessibilityHidden(true)
    }
}

/// + at the Dock's end: any app on the Mac, open or not.
private struct DockApplications: View {
    var scale: CGFloat
    var action: () -> Void
    @Environment(\.dockIcon) private var dockIcon

    var body: some View {
        let size = dockIcon
        Button(action: action) {
            VStack(spacing: 4) {
                AppIconShape()
                    .fill(Ink.ink.opacity(0.08))
                    .overlay(AppIconShape().strokeBorder(Ink.ink.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                    .overlay(Image(systemName: "plus").font(.system(size: size * 0.36, weight: .semibold)).foregroundStyle(Ink.secondary))
                    .frame(width: size * 0.84, height: size * 0.84)
                    .frame(width: size, height: size)
                Color.clear.frame(width: 4, height: 4)
            }
            .scaleEffect(scale, anchor: .bottom)
            .frame(width: size * scale)
        }
        .buttonStyle(DockPress())
        .accessibilityLabel("More apps")
        .accessibilityHint("Opens any app on your Mac, even one that isn't open, and sends there.")
        .accessibilityIdentifier("more-apps")
    }
}

/// A Dock icon pressed: it dims a touch, as an icon clicked on a Mac does.
private struct DockPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? -0.18 : 0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
