import MacrophoneKit
import SwiftUI

// A long press on a Dock icon (Nov 5 2026): the app's windows as pictures, the way a Mac's App
// Exposé shows them — a glass popover over the icon, a card per window (its last kept picture,
// `WindowSnapshots`, at its own shape, with its title under it), sideways when there are many. A
// tap on a card sends there; Show Window under them watches it. A window with no kept picture
// yet is the app's icon on a plate. Nothing new on the wire: the pictures are the ones the phone
// kept the last time each window showed.

enum DockWindowsLook {
    static let pictureHeight: CGFloat = 112
    static let minWidth: CGFloat = 92
    static let maxWidth: CGFloat = 200
    /// A window with no picture yet: about a Mac window's shape.
    static let plateAspect: CGFloat = 1.45
    static let spacing: CGFloat = 14
    static let inset: CGFloat = 16
    static let corner: CGFloat = 10
    /// The smallest the popover is (its header and Show Window read at that).
    static let minPopover: CGFloat = 250
    /// The pictures are decoded at about three times a card's points.
    static let maxPixel: CGFloat = 640

    /// A card's width: its picture's shape at the set height, kept to sensible bounds.
    static func width(for size: CGSize?) -> CGFloat {
        guard let size, size.height > 0 else { return pictureHeight * plateAspect }
        return min(maxWidth, max(minWidth, (pictureHeight * size.width / size.height).rounded()))
    }
}

/// What the popover shows over one Dock icon.
struct DockWindowsPopover: View {
    @EnvironmentObject var model: AppModel
    var place: PlaceOption
    var current: TargetRef
    var macID: UUID?
    /// The popover's widest (the screen's less a margin).
    var room: CGFloat
    var needs: (LiveTarget) -> NeedsYou?
    /// Show Window is offered (a Mac connected, the place open on it).
    var canWatch: Bool
    var onPick: (TargetRef) -> Void
    var onWatch: (TargetRef) -> Void

    private var windows: [LiveTarget] { place.kind == .app ? place.windows : [] }

    /// Show Window watches the pick when it's one of these windows, else the newest.
    private var watchTarget: TargetRef {
        if place.holds(current) { return current }
        return windows.first?.ref ?? place.target
    }

    var body: some View {
        let widths = windows.map { DockWindowsLook.width(for: WindowSnapshots.pictureSize(key($0))) }
        let cards = widths.reduce(0, +) + DockWindowsLook.spacing * CGFloat(max(0, widths.count - 1)) + DockWindowsLook.inset * 2
        let width = min(room, max(DockWindowsLook.minPopover, windows.isEmpty ? DockWindowsLook.minPopover : cards))
        VStack(spacing: 0) {
            if !windows.isEmpty {
                header
                strip(widths: widths)
                    .padding(.bottom, 12)
            }
            if canWatch {
                if !windows.isEmpty { Divider().padding(.horizontal, DockWindowsLook.inset) }
                Button { onWatch(watchTarget) } label: {
                    HStack {
                        Text("Show Window")
                        Spacer()
                        Image(systemName: "eye")
                    }
                    .font(.body)
                    .foregroundStyle(Ink.ink)
                    .padding(.horizontal, DockWindowsLook.inset)
                    .frame(minHeight: 46)
                    .contentShape(Rectangle())
                }
                .buttonStyle(DockMenuRow())
                .accessibilityIdentifier("dock-show-window")
            }
            // Alerts for the window Show Window would show (Nov 6 2026).
            if model.canAlert, place.kind == .app {
                Divider().padding(.horizontal, DockWindowsLook.inset)
                let on = model.alertWatch(for: watchTarget)
                Button { model.setAlertWatch(on?.ref ?? watchTarget, on: on == nil) } label: {
                    HStack {
                        Text(on == nil ? "Alert Me When It Changes" : "Stop Alerts")
                        Spacer()
                        Image(systemName: on == nil ? "bell.badge" : "bell.slash")
                    }
                    .font(.body)
                    .foregroundStyle(Ink.ink)
                    .padding(.horizontal, DockWindowsLook.inset)
                    .frame(minHeight: 46)
                    .contentShape(Rectangle())
                }
                .buttonStyle(DockMenuRow())
                .accessibilityIdentifier(on == nil ? "dock-alert-on" : "dock-alert-off")
            }
        }
        .frame(width: width)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(windows.isEmpty ? place.name : "\(place.name) windows")
        .accessibilityIdentifier("dock-windows")
    }

    private var header: some View {
        HStack(spacing: 8) {
            DockTile(target: place.target, icon: place.icon, size: 22)
            Text(place.shortName)
                .font(.headline)
                .foregroundStyle(Ink.ink)
                .oneLine()
            Spacer(minLength: 8)
            if windows.count > 1 {
                Text("\(windows.count) windows")
                    .font(.subheadline)
                    .foregroundStyle(Ink.secondary)
            }
        }
        .padding(.horizontal, DockWindowsLook.inset)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func strip(widths: [CGFloat]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: DockWindowsLook.spacing) {
                    ForEach(Array(windows.enumerated()), id: \.element.id) { i, w in
                        DockWindowCard(window: w, key: key(w), icon: place.icon, width: widths[i],
                                       picked: current.matches(w), needs: needs(w),
                                       onPick: { onPick(w.ref) },
                                       onWatch: canWatch ? { onWatch(w.ref) } : nil)
                            .id(w.id)
                    }
                }
                .padding(.horizontal, DockWindowsLook.inset)
                .padding(.vertical, 4)
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
            .scrollBounceBehavior(.basedOnSize)
            .onAppear {
                if let w = windows.first(where: { current.matches($0) }) { proxy.scrollTo(w.id, anchor: .center) }
            }
        }
    }

    private func key(_ w: LiveTarget) -> String? { WindowSnapshots.key(mac: macID, target: w.ref) }
}

/// One window: its kept picture (or the app's icon on a plate), its title, the mark if it answered.
private struct DockWindowCard: View {
    var window: LiveTarget
    var key: String?
    var icon: Data?
    var width: CGFloat
    var picked: Bool
    var needs: NeedsYou?
    var onPick: () -> Void
    var onWatch: (() -> Void)?
    @State private var picture: UIImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var title: String {
        let t = window.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? window.appName : t
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DockWindowsLook.corner, style: .continuous)
        let shown = picture ?? WindowSnapshots.smallCached(key)
        Button(action: onPick) {
            VStack(spacing: 8) {
                ZStack {
                    if let shown {
                        Image(uiImage: shown)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fill)
                            .frame(width: width, height: DockWindowsLook.pictureHeight)
                            .transition(.opacity)
                    } else {
                        shape.fill(Ink.ink.opacity(0.06))
                        DockTile(target: window.ref, icon: icon, size: 46)
                    }
                }
                .frame(width: width, height: DockWindowsLook.pictureHeight)
                .clipShape(shape)
                .overlay(shape.strokeBorder(Ink.line, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.14), radius: 6, y: 2)
                // The pick: ringed in the accent, as a selected window in Mission Control.
                .overlay {
                    if picked {
                        RoundedRectangle(cornerRadius: DockWindowsLook.corner + 4, style: .continuous)
                            .strokeBorder(Light.cyan, lineWidth: 2.5)
                            .padding(-4)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if needs != nil {
                        Circle().fill(Light.ember).frame(width: 14, height: 14)
                            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                            .offset(x: 5, y: -5)
                    }
                }
                VStack(spacing: 2) {
                    Text(title)
                        .font(.footnote.weight(picked ? .semibold : .medium))
                        .foregroundStyle(Ink.ink)
                        .multilineTextAlignment(.center)
                        .lines(2)
                    if let needs {
                        Text(needs.asking ? "Asking you" : "Answered you")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Light.ember)
                    }
                }
                .frame(width: width)
            }
            .padding(.top, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(DockCardPress())
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: picture != nil)
        .task(id: key) {
            if picture == nil { picture = await WindowSnapshots.small(key, maxPixel: DockWindowsLook.maxPixel) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(needs.map { $0.asking ? "Asking you something" : "Answered you" } ?? "")
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(picked ? .isSelected : [])
        .accessibilityHint(picked ? "Your dictations go here." : "Sends your dictations to this window.")
        .accessibilityAction { onPick() }
        .accessibilityAction(named: "Show Window") { onWatch?() }
        .accessibilityIdentifier("dock-window-\(window.id)")
    }
}

/// A card pressed: it settles in a little, as a window under the pointer does in Mission Control.
private struct DockCardPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A menu's row: lit while pressed.
private struct DockMenuRow: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Ink.ink.opacity(configuration.isPressed ? 0.08 : 0))
    }
}
