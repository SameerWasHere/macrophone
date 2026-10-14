import MacrophoneKit
import SwiftUI
import UIKit

// The controls by the mic (Oct 13 2026, the elegance pass). Sameer: "The selecting where it goes
// and other toggles can be way better and more intuitive." The three things he changes on the fly
// are each glanceable and one tap, with no sheet for the common case:
//
//   ┌──────────────────────────────────────────────┐
//   │  (📋) (⌖) [ Claude ] (💬) (>_) (📝)   (⋯)     │  the dock: the Mac's open apps
//   │                ━━                            │  the lit one is where it goes
//   │  Send to Claude ⌄           (✈ Send after pasting) │
//   │  ✦ Cleanup  Off  Light [Medium] Heavy  Custom │
//   └──────────────────────────────────────────────┘
//
// 1. Where — a dock of the Mac's open apps as their own icons, like the Mac's Dock: Clipboard and
//    Where I'm typing first, then the apps newest first. The pick is lifted and lit with a bar
//    under it; a tap picks another. An app with several windows wears a count and a long-press
//    lists them; the end-cap (and the name under the dock) opens every place and window. While he
//    talks, an app said first lights in ember.
// 2. Send after pasting — one toggle, a paper plane that lights when on. Remembered per place and
//    synced with the Mac (`SendSelection`). Where it can't apply it says why.
// 3. Cleanup — Off · Light · Medium · Heavy · Custom, all five visible, one tap each. Custom follows
//    his own instructions (Medium's until he edits them): tapping it again, or a long-press, opens them.
//
// Every change ticks, applies to the next dictation (or the one being recorded) and goes to the Mac
// at once, and the status line under the mic says in a sentence what it now does.

// MARK: Places on the dock

/// One icon on the dock: a place, or an app standing for its windows.
struct DockPlace: Identifiable, Equatable {
    enum Kind: Equatable { case clipboard, front, app, closed }
    var id: String
    var kind: Kind
    /// What a tap picks (for an app with several windows, its newest).
    var target: TargetRef
    var name: String
    var icon: Data?
    /// An app's windows with somewhere to type, newest first (two or more get a count and a menu).
    var windows: [LiveTarget] = []

    func holds(_ t: TargetRef) -> Bool { target == t || windows.contains { t.matches($0) } }
}

extension AppModel {
    /// Clipboard, Where I'm typing, the picked app if it closed (so the pick is always on the dock),
    /// then the Mac's open apps — one icon per app, newest first.
    func dockPlaces(current: TargetRef) -> [DockPlace] {
        var out = [DockPlace(id: "clipboard", kind: .clipboard, target: .clipboard, name: "Clipboard"),
                   DockPlace(id: "front", kind: .front, target: .frontApp, name: "Where I'm typing")]
        if case .app = current, liveTarget(for: current) == nil {
            out.append(DockPlace(id: "closed", kind: .closed, target: current, name: current.displayName))
        }
        var index: [String: Int] = [:]
        for t in liveTargets {
            if let i = index[t.bundleID] { out[i].windows.append(t); continue }
            index[t.bundleID] = out.count
            out.append(DockPlace(id: "app:\(t.bundleID)", kind: .app, target: t.ref, name: t.appName, icon: t.icon, windows: [t]))
        }
        return out
    }
}

// MARK: The controls

/// The dock, then where it goes and Send after pasting, then cleanup. Lives in a fixed slot (see
/// MainView), so nothing here can move the mic.
struct QuickControls: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var settings: Settings
    @ObservedObject var recorder: Recorder
    var recording: Bool
    /// iPhone SE-class heights: a smaller dock and tighter rows.
    var compact = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage("onboarding.macNudgeDismissed") private var macNudgeDismissed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let live: (target: TargetRef, send: Bool, byVoice: Bool) = recording ? model.liveRoute(recorder.transcript)
            : (model.selection.target, model.selection.send, false)
        VStack(spacing: compact ? 3 : 6) {
            if model.isPaired {
                PlaceDock(current: live.target, said: live.byVoice, compact: compact)
                placeLine(live.target, said: live.byVoice)
            } else if showNudge {
                Spacer(minLength: 0)
                MacAppNudge { withAnimation(Motion.pick(Motion.depart, reduce: reduceMotion)) { macNudgeDismissed = true } }
                    .transition(.opacity)
                Spacer(minLength: 0)
            } else {
                UnpairedPlace()
            }
            CleanupSteps(settings: settings, compact: compact, recording: recording) { model.sheet = .customCleanup }
        }
        .padding(.horizontal, 16)
        // Quieter while recording, but still live: a change applies to the words being spoken.
        .opacity(recording ? 0.72 : 1)
        .animation(.easeInOut(duration: 0.25), value: recording)
    }

    /// The first dictations without a Mac: it worked here; this is how to get it there.
    private var showNudge: Bool { !model.isPaired && model.latest?.delivery == .copiedOnPhone && !macNudgeDismissed }

    @ViewBuilder private func placeLine(_ target: TargetRef, said: Bool) -> some View {
        if typeSize.isAccessibilitySize {
            VStack(spacing: 6) {
                PlaceName(target: target, said: said)
                SendSwitch(settings: settings, target: target)
            }
        } else {
            HStack(spacing: 10) {
                PlaceName(target: target, said: said)
                    .frame(maxWidth: .infinity, alignment: .leading)
                SendSwitch(settings: settings, target: target)
            }
        }
    }
}

/// The plate every control wears: a faint fill and a hairline (firm under Increase Contrast).
struct ControlPlate: ViewModifier {
    var lit: Color?
    var radius: CGFloat = 20
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let high = contrast == .increased
        content
            .background(shape.fill(lit.map { $0.opacity(0.16) } ?? Ink.ink.opacity(0.05)))
            .overlay(shape.strokeBorder(lit.map { $0.opacity(high ? 0.9 : 0.5) } ?? (high ? Ink.ink.opacity(0.45) : Ink.line), lineWidth: 1))
    }
}

// MARK: Where

/// The Mac's open apps as their icons, Clipboard and Where I'm typing first.
struct PlaceDock: View {
    @EnvironmentObject var model: AppModel
    var current: TargetRef
    var said: Bool
    var compact = false
    @State private var width: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let places = model.dockPlaces(current: current)
        let selected = places.first { $0.holds(current) }?.id
        let notOpen = model.isNotOpen(current)
        let tint = said ? Light.ember : (notOpen ? Light.ochre : Light.cyan)
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(places) { p in
                        DockIcon(place: p, selected: p.id == selected, tint: tint, current: current, compact: compact,
                                 onPick: { pick($0) }, onMore: { model.sheet = .sendTo })
                            .id(p.id)
                    }
                    AllPlacesCap { model.sheet = .sendTo }
                }
                .padding(.horizontal, 10)
                // A few places sit centred; many scroll, the pick kept in view.
                .frame(minWidth: width)
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .mask {
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.05),
                                       .init(color: .black, location: 0.95), .init(color: .clear, location: 1)],
                               startPoint: .leading, endPoint: .trailing)
            }
            .onAppear { if let selected { proxy.scrollTo(selected, anchor: .center) } }
            .onChange(of: selected) { _, id in
                guard let id else { return }
                withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .snappy(duration: 0.4)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .frame(height: PlaceDock.height(compact))
        .opacity(model.isConnected ? 1 : 0.78)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Places on your Mac")
        .accessibilityIdentifier("place-dock")
    }

    static func height(_ compact: Bool) -> CGFloat { compact ? 48 : 58 }

    private func pick(_ t: TargetRef) {
        guard t != model.selection.target else { return }
        Haptics.tick()
        model.pick(t)
        model.explain(Self.sentence(for: t, send: model.selection.send))
    }

    /// What the next dictation will do, in a sentence.
    static func sentence(for t: TargetRef, send: Bool) -> String {
        switch t {
        case .clipboard: return "Copies to your Mac's clipboard, to paste yourself"
        case .frontApp: return send ? "Pastes where you're typing on your Mac, then sends" : "Pastes where you're typing on your Mac"
        case .app: return send ? "Pastes into \(t.displayName), then sends" : "Pastes into \(t.displayName) — you press send"
        }
    }
}

/// One icon. Unpicked ones sit back; the pick is lifted, lit, with a bar under it like the Dock's.
private struct DockIcon: View {
    var place: DockPlace
    var selected: Bool
    var tint: Color
    var current: TargetRef
    var compact = false
    var onPick: (TargetRef) -> Void
    var onMore: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Button {
            // An app already picked keeps its window; otherwise its newest.
            if !place.holds(current) { onPick(place.target) }
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    Circle()
                        .fill(RadialGradient(colors: [tint.opacity(0.38), tint.opacity(0)], center: .center, startRadius: 2, endRadius: 30))
                        .frame(width: 60, height: 60)
                        .opacity(selected ? 1 : 0)
                    TargetIcon(target: place.target, icon: place.icon, size: compact ? 30 : 36)
                        .saturation(place.kind == .closed ? 0 : 1)
                        .overlay(alignment: .topTrailing) { badge }
                }
                .frame(width: compact ? 42 : 48, height: compact ? 38 : 46)
                .scaleEffect(selected ? 1.12 : 0.86)
                Capsule()
                    .fill(selected ? tint : Ink.ink.opacity(0))
                    .frame(width: selected ? 16 : 4, height: 3)
                    .shadow(color: tint.opacity(selected ? 0.9 : 0), radius: 4)
            }
            .frame(width: compact ? 46 : 52, height: compact ? 46 : 56)
            // Increase Contrast: the others stay nearly whole; the bar and the size still say which.
            .opacity(selected ? 1 : (place.kind == .closed ? 0.4 : (contrast == .increased ? 0.88 : 0.6)))
            .contentShape(Rectangle())
        }
        .buttonStyle(DockPressStyle())
        .animation(Motion.pick(Motion.snap, reduce: reduceMotion), value: selected)
        .contextMenu {
            if place.windows.count > 1 {
                Section("\(place.name) windows") {
                    ForEach(place.windows) { w in
                        Button { onPick(w.ref) } label: {
                            if current.matches(w) { Label(w.windowTitle ?? w.appName, systemImage: "checkmark") }
                            else { Text(w.windowTitle ?? w.appName) }
                        }
                    }
                }
            }
            Button(action: onMore) { Label("All places", systemImage: "square.grid.2x2") }
        }
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(selected ? "" : "Sends your dictations here.")
    }

    @ViewBuilder private var badge: some View {
        if place.kind == .closed {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Light.ochre)
                .padding(3)
                .background(Circle().fill(Ink.ground))
                .offset(x: 6, y: -6)
        } else if place.windows.count > 1 {
            Text("\(place.windows.count)")
                .font(.system(size: 10, weight: .bold).monospacedDigit())
                .foregroundStyle(Ink.ink)
                .frame(minWidth: 15, minHeight: 15)
                .background(Circle().fill(Ink.raised))
                .overlay(Circle().strokeBorder(Ink.lineStrong, lineWidth: 1))
                .offset(x: 6, y: -6)
        }
    }

    private var label: String {
        var s = place.name
        if place.windows.count > 1 { s += ", \(place.windows.count) windows" }
        if place.kind == .closed { s += ", not open on your Mac" }
        return s
    }
}

/// A press settles the icon in, like the Dock.
private struct DockPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(Motion.snap, value: configuration.isPressed)
    }
}

/// The end-cap: every place, every window.
private struct AllPlacesCap: View {
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Ink.secondary)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Ink.ink.opacity(0.06)))
                .overlay(Circle().strokeBorder(Ink.line, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                .frame(width: 50, height: 58)
                .offset(y: -4)
                .contentShape(Rectangle())
        }
        .buttonStyle(DockPressStyle())
        .accessibilityLabel("All places")
        .accessibilityHint("Shows every place on your Mac and its windows.")
        .accessibilityIdentifier("all-places")
    }
}

/// "Send to Claude ⌄" under the dock: where it goes, in words; a tap opens every place.
struct PlaceName: View {
    @EnvironmentObject var model: AppModel
    var target: TargetRef
    var said: Bool

    var body: some View {
        let name = target.displayName
        let notOpen = model.isNotOpen(target)
        Button { model.sheet = .sendTo } label: {
            // Whole words always: the lead word goes first, then a size, then two lines. Never "…".
            ViewThatFits(in: .horizontal) {
                row(lead: true, name: name, notOpen: notOpen, font: .subheadline)
                row(lead: false, name: name, notOpen: notOpen, font: .subheadline)
                row(lead: false, name: name, notOpen: notOpen, font: .footnote)
                row(lead: false, name: name, notOpen: notOpen, font: .footnote, wrap: true)
                row(lead: false, name: name, notOpen: notOpen, font: .caption, wrap: true)
                // A very long window title: three small lines, shrunk to fit whole rather than cut.
                row(lead: false, name: name, notOpen: notOpen, font: .caption2, wrap: true, lines: 3)
                    .minimumScaleFactor(0.6)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .animation(Motion.snap, value: name)
        }
        .buttonStyle(.plain)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityLabel(accessibility(name: name, notOpen: notOpen))
        .accessibilityHint("Shows every place on your Mac and its windows.")
        .accessibilityIdentifier("send-to")
    }

    private func row(lead: Bool, name: String, notOpen: Bool, font: Font, wrap: Bool = false, lines: Int = 2) -> some View {
        var t = Text(name).font(font.weight(.semibold)).foregroundColor(notOpen ? Ink.secondary : Ink.ink)
        if lead { t = Text(said ? "You said " : "Send to ").font(font).foregroundColor(said ? Light.ember : Ink.tertiary) + t }
        // The status line says the rest ("Claude isn't open on your Mac — it'll be copied instead").
        if notOpen { t = t + Text(" · closed").font(font).foregroundColor(Light.ochre) }
        t = t + Text("  ") + Text(Image(systemName: "chevron.down")).font(.caption2.weight(.bold)).foregroundColor(Ink.tertiary)
        return t
            .lineLimit(wrap ? lines : 1)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: !wrap, vertical: lines < 3)
            .contentTransition(.opacity)
    }

    private func accessibility(name: String, notOpen: Bool) -> String {
        if said { return "Sending this one to \(name), because you said it" }
        return "Send to: \(name)" + (notOpen ? ", not open on your Mac — it'll be copied instead" : "")
    }
}

/// Unpaired: it copies on this iPhone; one tap to pair.
private struct UnpairedPlace: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Button { model.sheet = .pairing } label: {
            HStack(spacing: 12) {
                Image(systemName: "iphone")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Light.teal)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Light.teal.opacity(0.14)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Copies on this iPhone").font(.subheadline.weight(.semibold)).foregroundStyle(Ink.ink)
                    Text("Pair your Mac to send to its apps").font(.footnote).foregroundStyle(Light.cyan)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(Ink.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .modifier(ControlPlate(radius: 18))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxHeight: .infinity)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityLabel("Send to: this iPhone's clipboard. Pair your Mac to choose where it goes.")
        .accessibilityHint("Pairs this iPhone with Macrophone on your Mac.")
        .accessibilityIdentifier("send-to")
    }
}

// MARK: Send after pasting

/// One toggle: a paper plane that lights when the Mac will press send after pasting. Where it
/// can't apply it says why (and a tap explains).
struct SendSwitch: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var settings: Settings
    /// The place it applies to: the choice, or an app said first while recording.
    var target: TargetRef

    var body: some View {
        if let reason = disabledReason(target) {
            Button { model.explain(longReason(target)) } label: {
                HStack(spacing: 7) {
                    Image(systemName: "paperplane").font(.footnote.weight(.semibold)).accessibilityHidden(true)
                    Text(reason).font(.footnote.weight(.medium)).lineLimit(1).fixedSize()
                }
                .foregroundStyle(Ink.tertiary)
                .padding(.horizontal, 14)
                .frame(minHeight: 40)
                .modifier(ControlPlate())
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Send after pasting: unavailable. \(reason).")
            .accessibilityHint("Says why.")
            .accessibilityIdentifier("send-toggle")
        } else {
            let on = model.sendSetting(for: target)
            Button {
                Haptics.tick()
                withAnimation(Motion.snap) { model.setSend(!on, for: target) }
                model.explain(PlaceDock.sentence(for: target, send: !on))
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: on ? "paperplane.fill" : "paperplane")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(on ? Light.cyan : Ink.tertiary)
                        .contentTransition(.symbolEffect(.replace))
                        .accessibilityHidden(true)
                    ViewThatFits(in: .horizontal) {
                        Text("Send after pasting").lineLimit(1).fixedSize()
                        Text("Then send").lineLimit(1).fixedSize()
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(on ? Ink.ink : Ink.secondary)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 40)
                .modifier(ControlPlate(lit: on ? Light.cyan : nil))
                .shadow(color: Light.cyan.opacity(on ? 0.25 : 0), radius: 10)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Send after pasting")
            .accessibilityValue(on ? "On" : "Off")
            .accessibilityAddTraits(.isToggle)
            .accessibilityHint("When on, your Mac presses send after pasting into \(target.displayName).")
            .accessibilityIdentifier("send-toggle")
        }
    }

    private func disabledReason(_ t: TargetRef) -> String? {
        t.canSend ? nil : "Clipboard can't send"
    }

    private func longReason(_ t: TargetRef) -> String {
        "Clipboard only copies — pick an app to paste and send"
    }
}

// MARK: Cleanup

/// Off · Light · Medium · Heavy · Custom, all visible, one tap each. The pick slides; the status line
/// says what it does. Custom wears a pencil while it's picked: tapping it again (or a long-press)
/// opens its instructions.
struct CleanupSteps: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var settings: Settings
    var compact = false
    /// While recording the editor waits (a sheet would cover the mic); the tap says so instead.
    var recording = false
    /// Opens the Custom instructions (a sheet by the mic, a push in Settings).
    var onEditCustom: () -> Void
    @Namespace private var pill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let available = model.cleanupAvailability.isAvailable && settings.isEnglish
        let level = available ? settings.cleanupLevel : .off
        // Whole words always: the lead word goes first, then the lead itself, then a size.
        ViewThatFits(in: .horizontal) {
            // The word only where the steps still breathe; else the wand alone says what the row is.
            row(level: level, available: available, lead: .word, font: .footnote, room: 11)
            row(level: level, available: available, lead: .glyph, font: .footnote, room: 6)
            row(level: level, available: available, lead: .none, font: .footnote, room: 5)
            row(level: level, available: available, lead: .none, font: .caption, room: 4)
        }
        .padding(3)
        .modifier(ControlPlate(radius: 22))
        .padding(.vertical, 1)
        // Five words in a row: capped like the rest of the chrome, with the Large Content Viewer.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cleanup-level")
        .overlay {
            // Unavailable: the whole control is one explanation.
            if !available {
                Button { model.explain(unavailableReason) } label: { Color.clear.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cleanup off: unavailable")
                    .accessibilityHint(unavailableReason)
                    .accessibilityIdentifier("cleanup-unavailable")
            }
        }
    }

    private enum Lead { case word, glyph, none }

    private func row(level: CleanupLevel, available: Bool, lead: Lead, font: Font, room: CGFloat) -> some View {
        HStack(spacing: 0) {
            if lead != .none {
                HStack(spacing: 5) {
                    Image(systemName: "wand.and.stars").font(.caption.weight(.semibold)).foregroundStyle(Light.teal)
                    if lead == .word { Text("Cleanup").font(.footnote.weight(.medium)).foregroundStyle(Ink.secondary).fixedSize() }
                }
                .padding(.leading, 10)
                .padding(.trailing, 4)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Cleanup")
                .accessibilityAddTraits(.isHeader)
            }
            HStack(spacing: 0) {
                ForEach(CleanupLevel.allCases) { l in
                    step(l, on: l == level, enabled: available, font: font, room: room)
                }
            }
            .opacity(available ? 1 : 0.5)
        }
    }

    private func step(_ l: CleanupLevel, on: Bool, enabled: Bool, font: Font, room: CGFloat) -> some View {
        Button {
            guard enabled else { return }
            if on {
                // Custom picked already: the tap opens its instructions.
                if l == .custom {
                    if recording { model.explain("Edit your instructions once this one's sent"); return }
                    Haptics.tick()
                    onEditCustom()
                }
                return
            }
            Haptics.tick()
            withAnimation(Motion.pick(.snappy(duration: 0.3), reduce: reduceMotion)) { model.setCleanupLevel(l) }
            model.explain(Self.sentence(for: l, edited: model.customInstructionsEdited))
        } label: {
            HStack(spacing: 3) {
                Text(l.title)
                    .font(font.weight(on ? .semibold : .medium))
                    .lineLimit(1)
                    .fixedSize()
                if l == .custom, on {
                    Image(systemName: "pencil")
                        .font(.caption2.weight(.bold))
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(on ? Ink.ground : Ink.secondary)
            .padding(.horizontal, room)
            .frame(maxWidth: .infinity, minHeight: compact ? 34 : 38)
            .background {
                if on { Capsule().fill(Ink.ink).matchedGeometryEffect(id: "pick", in: pill) }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if l == .custom, enabled, !recording {
                Button { onEditCustom() } label: { Label("Edit Custom Instructions", systemImage: "pencil") }
            }
        }
        .accessibilityLabel("\(l.title) cleanup")
        .accessibilityValue(l == .custom && model.customInstructionsEdited ? "Your own instructions" : l.summary)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityHint(l == .custom ? (on ? "Opens its instructions." : "Then tap it again to edit its instructions.") : "")
        .modifier(EditInstructionsAction(active: l == .custom && enabled && !recording, action: onEditCustom))
        .accessibilityShowsLargeContentViewer { Text("\(l.title) cleanup") }
        .accessibilityIdentifier("cleanup-\(l.rawValue)")
    }

    /// What the next dictation's cleanup will do, in a sentence.
    static func sentence(for l: CleanupLevel, edited: Bool) -> String {
        switch l {
        case .off: return "Cleanup off — sent exactly as heard"
        case .custom: return edited ? "Custom cleanup — your own instructions. Tap Custom again to edit them"
                                    : "Custom cleanup — Medium's instructions until you edit them. Tap Custom again to edit"
        default: return "\(l.title) cleanup — \(l.summary.dropLast())"
        }
    }

    private var unavailableReason: String {
        if !settings.isEnglish { return "Cleanup works in English only for now — your words are sent exactly as heard" }
        return model.cleanupAvailability.explanation + " Until then, your words are sent exactly as heard."
    }
}

/// VoiceOver's "Edit instructions" on the Custom step.
private struct EditInstructionsAction: ViewModifier {
    var active: Bool
    var action: () -> Void
    func body(content: Content) -> some View {
        if active { content.accessibilityAction(named: "Edit instructions", action) } else { content }
    }
}

/// The controls at their tallest, for the fixed slot: the dock, the name line beside the toggle,
/// the cleanup steps (stacked at accessibility sizes).
struct QuickControlsTemplate: View {
    var compact = false
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        VStack(spacing: compact ? 3 : 6) {
            Color.clear.frame(height: PlaceDock.height(compact))
            if typeSize.isAccessibilitySize {
                Text("A\nB").font(.footnote).frame(minHeight: 44)
                Color.clear.frame(height: 44)
            } else {
                Text("A\nB").font(.footnote).frame(minHeight: 44)
            }
            Text("A").font(.footnote).frame(minHeight: compact ? 34 : 38).padding(3).padding(.vertical, 1)
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        }
        .frame(maxWidth: .infinity)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }
}
