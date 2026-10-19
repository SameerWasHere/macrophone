import MacrophoneKit
import SwiftUI

// The controls by the mic (Oct 13 2026, the native pass). Sameer: "These selectors are bad overall
// in clarity, looks and in placement on the screen for easy reach. This is not native Liquid Glass."
// So: one grouped panel in thumb reach, above the Thread, built from Apple's own controls —
//
//   ┌──────────────────────────────────────────────┐
//   │ SEND TO                                      │
//   │ Claude                                       │
//   │ [📋] [⌖] [✦] [💬] [>_] [📝] →               │  native glass buttons; the pick is
//   │ Clipboard  Where I'm typing  Claude  …       │  .glassProminent (tinted), on a material plate
//   ├──────────────────────────────────────────────┤
//   │ Send after pasting                     [ ●]  │  a native Toggle
//   ├──────────────────────────────────────────────┤
//   │ Cleanup                                      │
//   │ [ Off | Light | Medium | Heavy | Custom ]    │  a native segmented Picker
//   │ Medium — fixes grammar and false starts      │
//   └──────────────────────────────────────────────┘
//
// Every change ticks, applies to the next dictation and goes to the Mac at once; the status line
// under the mic says in a sentence what it now does.

// MARK: Places

/// One button in the Send to row: a place, or an app standing for its windows.
struct PlaceOption: Identifiable, Equatable {
    enum Kind: Equatable { case clipboard, front, app, closed, opening }
    var id: String
    var kind: Kind
    /// What a tap picks (for an app with several windows, its newest).
    var target: TargetRef
    /// The full name ("Terminal — claude"), for VoiceOver and the window menu.
    var name: String
    /// The one-line name under the icon ("Terminal").
    var shortName: String
    var icon: Data?
    /// An app's windows with somewhere to type, newest first (two or more get a menu).
    var windows: [LiveTarget] = []
    /// No place to type found in it: after the line, where the words go into the box you tap.
    var canType = true

    func holds(_ t: TargetRef) -> Bool { target == t || windows.contains { t.matches($0) } }
}

extension AppModel {
    /// Clipboard, Where I'm typing, the picked app if it closed (so the pick is always in the row),
    /// then the Mac's open apps — one button per app, newest first.
    func placeOptions(current: TargetRef) -> [PlaceOption] {
        var out = [PlaceOption(id: "clipboard", kind: .clipboard, target: .clipboard, name: "Clipboard", shortName: "Clipboard"),
                   PlaceOption(id: "front", kind: .front, target: .frontApp, name: "Where I'm typing", shortName: "Where I'm typing")]
        if case let .app(bid, _, _) = current, liveTarget(for: current) == nil {
            // Just opened from "Open an app": it's on its way, with its icon.
            let opening = isOpening(bid)
            out.append(PlaceOption(id: "closed", kind: opening ? .opening : .closed, target: current, name: current.displayName,
                                   shortName: Places.appName(current, in: self),
                                   icon: opening ? macApps.first { $0.bundleID == bid }?.icon : nil))
        }
        var index: [String: Int] = [:]
        for t in liveTargets {
            if let i = index[t.bundleID] { out[i].windows.append(t); continue }
            index[t.bundleID] = out.count
            out.append(PlaceOption(id: "app:\(t.bundleID)", kind: .app, target: t.ref, name: t.appName,
                                   shortName: t.appName, icon: t.icon, windows: [t], canType: t.typeable))
        }
        return out
    }
}

/// The words for places.
enum Places {
    /// What the next dictation will do, in a sentence (the status line).
    static func sentence(for t: TargetRef, send: Bool) -> String {
        switch t {
        case .clipboard: return "Copies to your Mac's clipboard, to paste yourself"
        case .frontApp: return send ? "Pastes where you're typing on your Mac, then sends" : "Pastes where you're typing on your Mac"
        case .app: return send ? "Pastes into \(t.displayName), then sends" : "Pastes into \(t.displayName) — you press send"
        }
    }

    /// For an app with no place to type found: where the words go.
    static func tapFirst(_ name: String) -> String { "Pastes into the text box you tap in \(name)" }

    /// The app's own name for a target ("Terminal" for "Terminal — claude").
    @MainActor static func appName(_ t: TargetRef, in model: AppModel) -> String {
        if let live = model.liveTarget(for: t) { return live.appName }
        let name = t.displayName
        return name.components(separatedBy: " — ").first ?? name
    }

    /// The line under Send after pasting: what the switch does here, or why it can't.
    @MainActor static func sendDetail(_ t: TargetRef, in model: AppModel) -> String {
        switch t {
        case .clipboard: return "Clipboard only copies — pick an app to send"
        case .frontApp: return "Presses Return where you're typing, after pasting"
        case .app: return "Presses Return in \(appName(t, in: model)) after pasting"
        }
    }
}

// MARK: The panel

/// Send to, Send after pasting, Cleanup — one grouped panel. Paired or not, it sits above the
/// Thread in a flexible area (see MainView), so nothing here can move the mic.
struct QuickControls: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var settings: Settings
    var compact = false
    /// The Thread's light, under the panel: the plate's foot takes a breath of it.
    var glow: Color = Light.cyan
    @AppStorage("onboarding.macNudgeDismissed") private var macNudgeDismissed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let target = model.selection.target
        VStack(spacing: 0) {
            if model.isPaired {
                PlacesRow(current: target, compact: compact)
                PanelDivider()
                SendAfterPastingRow(target: target, compact: compact)
            } else if showNudge {
                MacAppNudge { withAnimation(Motion.pick(Motion.depart, reduce: reduceMotion)) { macNudgeDismissed = true } }
                    .transition(.opacity)
            } else {
                UnpairedPlace()
            }
            PanelDivider()
            CleanupRow(settings: settings, compact: compact) { model.sheet = .customCleanup }
        }
        .controlPanel(glow: glow)
        .padding(.horizontal, Space.margin)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    /// The first dictations without a Mac: it worked here; this is how to get it there.
    private var showNudge: Bool { !model.isPaired && model.latest?.delivery == .copiedOnPhone && !macNudgeDismissed }
}

/// A hairline between the panel's rows, inset like a grouped list's.
struct PanelDivider: View {
    var body: some View { Divider().overlay(Ink.line).padding(.leading, Space.inset) }
}

// MARK: Send to

/// "SEND TO", the picked place's name, and a row of buttons — one per place.
struct PlacesRow: View {
    @EnvironmentObject var model: AppModel
    /// The ⋯ menu's photo and file pickers.
    @State private var pickingPhoto = false
    @State private var pickingFile = false
    var current: TargetRef
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let places = model.placeOptions(current: current)
        let selected = places.first { $0.holds(current) }?.id
        let notOpen = model.isNotOpen(current)
        let answered = model.liveTarget(for: current).flatMap { model.needs($0) }
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            // The name beside Watch and ⋯ when it fits on one line; a longer one (a Terminal
            // window's title) takes the whole width under them instead of wrapping to six
            // lines beside them (Oct 18 2026).
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        // Whole, or this layout doesn't fit (it had wrapped to "SEND / TO" beside
                        // three buttons).
                        kicker.fixedSize()
                        title(current, notOpen: notOpen, answered: answered).fixedSize()
                    }
                    Spacer(minLength: 0)
                    buttons(current, notOpen: notOpen)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .center, spacing: 10) {
                        kicker
                        Spacer(minLength: 0)
                        buttons(current, notOpen: notOpen)
                    }
                    title(current, notOpen: notOpen, answered: answered)
                }
            }
            .padding(.horizontal, Space.inset)

            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(Array(places.enumerated()), id: \.element.id) { i, p in
                            // The apps with somewhere to type, then a line, then every other open app.
                            if p.kind == .app, !p.canType, i > 0, places[i - 1].canType {
                                OtherAppsRule(compact: compact)
                            }
                            PlaceButton(place: p, selected: p.id == selected, current: current, compact: compact,
                                        watchable: p.id == selected && current != .clipboard && model.isConnected && !notOpen,
                                        needs: model.isConnected ? model.needs(p) : nil,
                                        windowNeeds: { model.needs($0) != nil },
                                        onWatch: { watch(current) }) { pick($0) }
                                .id(p.id)
                        }
                        // Any app on the Mac, open or not (Open an app).
                        MoreAppsButton(compact: compact) { model.sheet = .openApp }
                    }
                    .padding(.horizontal, Space.inset)
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.hidden)
                // Only as far as it takes to bring the pick into view (Clipboard stays put when it's visible).
                .onAppear { if let selected { proxy.scrollTo(selected) } }
                .onChange(of: selected) { _, id in
                    guard let id else { return }
                    withAnimation(Motion.pick(.snappy(duration: 0.35), reduce: reduceMotion)) { proxy.scrollTo(id) }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Places on your Mac")
            .accessibilityIdentifier("places")
        }
        .padding(.top, compact ? 10 : 14)
        .padding(.bottom, compact ? 6 : 10)
        .opacity(model.isConnected ? 1 : 0.8)
    }


    /// The app's one kicker voice (mono, tracked) — the same as "TO CLAUDE · SENDS" over the
    /// transcript and the times in History.
    private var kicker: some View {
        Kicker("Send to").accessibilityHidden(true)
    }

    private func title(_ current: TargetRef, notOpen: Bool, answered: NeedsYou?) -> some View {
        (Text(current.displayName).foregroundColor(Ink.ink)
         + (notOpen ? Text("  Not open on your Mac").font(.subheadline).foregroundColor(Light.ochre) : Text(""))
         + (answered.map { Text($0.asking ? "  Asking you" : "  Answered you").font(.subheadline).foregroundColor(Light.ember) } ?? Text("")))
            .font(.headline)
            // A window name can run to 70 characters plus "Not open": as many lines as it
            // takes, never "…" (a limit of three cut a Terminal title mid-word).
            .fixedSize(horizontal: false, vertical: true)
            .contentTransition(.opacity)
            .animation(Motion.snap, value: current)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Send to: \(current.displayName)" + (notOpen ? ", not open on your Mac — it'll be copied instead" : "")
                                + (answered.map { $0.asking ? ", asking you something" : ", answered you" } ?? ""))
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("send-to")
    }

    @ViewBuilder private func buttons(_ current: TargetRef, notOpen: Bool) -> some View {
        // Watching is the eye on the picked icon, tapped again (Oct 19 2026, Sameer: "get rid of the
        // dedicated watch button and instead put the eye logo as an overlay of the selected app").
        // Volume, brightness and media keys, one tap: its own round button, the icon alone.
        if model.canMacControls {
            MacControlsButton(style: .round).transition(.opacity)
        }
        // ⋯: a photo, a file or the clipboard into the chat you send to, and a fresh look at the
        // open apps. Opening an app that isn't open is the + at the end of the row, and only there.
        Menu {
            if model.isConnected, model.watcher.canWatchDesktop {
                Section {
                    WholeScreenItems(watcher: model.watcher, verb: true)
                }
            }
            MacShareItems(pickingPhoto: $pickingPhoto, pickingFile: $pickingFile)
            Section {
                Button { model.refreshTargets(); Haptics.tick() } label: { Label("Refresh Open Apps", systemImage: "arrow.clockwise") }
            }
        } label: {
            Image(systemName: "ellipsis").font(.subheadline.weight(.bold)).frame(width: 20, height: 20)
        }
        .nativeGlassButton()
        .buttonBorderShape(.circle)
        .controlSize(.small)
        .accessibilityLabel("More")
        .accessibilityHint("Send a photo or file into \(Places.appName(current, in: model)), move the clipboard, or look again at the open apps.")
        .accessibilityIdentifier("send-to-more")
        .macSharePickers(photo: $pickingPhoto, file: $pickingFile, model: model)
    }

    /// The picked place tapped again: show its window (an app, or Where I'm typing, while connected).
    private func watch(_ t: TargetRef) {
        guard t != .clipboard, model.isConnected, !model.isNotOpen(t) else { return }
        Haptics.tick()
        model.watcher.open(t)
    }

    private func pick(_ t: TargetRef) {
        guard t != model.selection.target else { return }
        Haptics.tick()
        withAnimation(Motion.pick(Motion.snap, reduce: reduceMotion)) { model.pick(t) }
        if let live = model.liveTarget(for: t), !live.typeable {
            model.explain(Places.tapFirst(live.appName))
        } else {
            model.explain(Places.sentence(for: t, send: model.selection.send))
        }
    }
}

/// One place: its icon with its name under it, as a native button. The pick is the prominent
/// (tinted) one, so which is selected is the button itself.
private struct PlaceButton: View {
    var place: PlaceOption
    var selected: Bool
    var current: TargetRef
    var compact = false
    /// The pick, and its window can be shown: the eye on its icon says another tap watches it.
    var watchable = false
    /// One of its windows answered you: the mark on its icon.
    var needs: NeedsYou?
    var windowNeeds: (LiveTarget) -> Bool = { _ in false }
    /// The place already picked, tapped again: its window, live (Oct 18 2026, Sameer).
    var onWatch: () -> Void = {}
    var onPick: (TargetRef) -> Void

    var body: some View {
        Button {
            // An app already picked keeps its window; otherwise the one that answered you, else its newest.
            if let n = needs, let w = place.windows.first(where: n.concerns), !current.matches(w) { onPick(w.ref) }
            else if !place.holds(current) { onPick(place.target) }
            else { onWatch() }
        } label: {
            // Icons only (Oct 18 2026, Sameer: "remove the sub text entirely and just show the App
            // logos in the selector for a cleaner look"): the picked place's name is the line above,
            // every icon's name is its VoiceOver label, and a long press lists an app's windows.
            ZStack {
                TargetIcon(target: place.target, icon: place.icon, size: compact ? 32 : 36, onTint: selected)
                    .saturation(place.kind == .closed ? 0 : 1)
                    .overlay(alignment: .topTrailing) {
                        if needs != nil {
                            // Answered you: a mark like an app's badge, in the colour of your move.
                            Circle()
                                .fill(Light.ember)
                                .frame(width: 11, height: 11)
                                .overlay(Circle().stroke(Ink.ground, lineWidth: 2))
                                .offset(x: 4, y: -4)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .animation(Motion.snap, value: needs != nil)
                    .overlay(alignment: .bottomTrailing) {
                        if watchable {
                            // Tap again to watch: the eye, on a small glass disc at the icon's corner.
                            Image(systemName: "eye.fill")
                                .font(.system(size: compact ? 8 : 9, weight: .bold))
                                .foregroundStyle(Ink.ground)
                                .frame(width: compact ? 16 : 18, height: compact ? 16 : 18)
                                .background(Circle().fill(Ink.ink))
                                .overlay(Circle().stroke(Ink.ground, lineWidth: 1.5))
                                .offset(x: 5, y: 5)
                                .transition(.scale(scale: 0.5).combined(with: .opacity))
                                .accessibilityHidden(true)
                        }
                    }
                    .animation(Motion.snap, value: watchable)
                // On its way (just opened from Open an App): a turn over its icon.
                if place.kind == .opening { ProgressView().controlSize(.small).tint(Ink.ink) }
            }
            .frame(width: compact ? 40 : 44, height: compact ? 40 : 44)
        }
        .placeButtonStyle(selected: selected)
        .controlSize(.small)
        .opacity(place.kind == .closed && !selected ? 0.55 : 1)
        .contextMenu {
            if place.windows.count > 1 {
                Section("\(place.name) windows") {
                    ForEach(place.windows) { w in
                        Button { onPick(w.ref) } label: {
                            if current.matches(w) { Label(w.windowTitle ?? w.appName, systemImage: "checkmark") }
                            else if windowNeeds(w) { Label(w.windowTitle ?? w.appName, systemImage: "circlebadge.fill") }
                            else { Text(w.windowTitle ?? w.appName) }
                            if windowNeeds(w) { Text("Answered you") }
                        }
                    }
                }
            }
        }
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(watchable ? "Tap again to watch its window on your Mac." : selected ? "" : "Sends your dictations here.")
        .accessibilityAction(named: "Watch") { if watchable { onWatch() } }
    }

    private var label: String {
        var s = place.name
        if place.windows.count > 1 { s += ", \(place.windows.count) windows" }
        if place.kind == .closed { s += ", not open on your Mac" }
        if place.kind == .opening { s += ", opening on your Mac" }
        if let needs { s += needs.asking ? ", asking you something" : ", answered you" }
        return s
    }
}

/// The line in the Send to row between the apps with somewhere to type and every other open app
/// (Oct 18 2026). Those take the words in whatever text box you tap in them.
private struct OtherAppsRule: View {
    var compact = false

    var body: some View {
        Capsule()
            .fill(Ink.line)
            .frame(width: 1, height: compact ? 26 : 30)
            .padding(.horizontal, 4)
            .frame(height: compact ? 40 : 44)
            .accessibilityElement()
            .accessibilityLabel("Other open apps")
            .accessibilityHint("These take your words in the text box you tap in them.")
    }
}

/// The end of the Send to row: open any app on the Mac.
private struct MoreAppsButton: View {
    var compact = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: (compact ? 32 : 36) * 0.42, weight: .semibold))
                .foregroundStyle(Ink.secondary)
                .frame(width: compact ? 32 : 36, height: compact ? 32 : 36)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Ink.ink.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Ink.line, lineWidth: 1))
                .frame(width: compact ? 40 : 44, height: compact ? 40 : 44)
        }
        .placeButtonStyle(selected: false)
        .controlSize(.small)
        .accessibilityLabel("More apps")
        .accessibilityHint("Opens any app on your Mac, even one that isn't open, and sends there.")
        .accessibilityIdentifier("more-apps")
    }
}

private extension View {
    /// Native glass buttons on iOS 26+ (the pick `.glassProminent`, tinted cyan); bordered below.
    @ViewBuilder func placeButtonStyle(selected: Bool) -> some View {
        let shape = ButtonBorderShape.roundedRectangle(radius: 16)
        if #available(iOS 26.0, *) {
            if selected { buttonStyle(.glassProminent).buttonBorderShape(shape).tint(Light.cyan) }
            else { buttonStyle(.glass).buttonBorderShape(shape) }
        } else {
            if selected { buttonStyle(.borderedProminent).buttonBorderShape(shape).tint(Light.cyan) }
            else { buttonStyle(.bordered).buttonBorderShape(shape).tint(Ink.ink) }
        }
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
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Copies on this iPhone").font(.body.weight(.semibold)).foregroundStyle(Ink.ink)
                    Text("Pair your Mac to send to its apps").font(.footnote).foregroundStyle(Light.cyan)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(Ink.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Space.inset)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Send to: this iPhone's clipboard. Pair your Mac to choose where it goes.")
        .accessibilityHint("Pairs this iPhone with Macrophone on your Mac.")
        .accessibilityIdentifier("send-to")
    }
}

// MARK: Send after pasting

/// The native switch with its whole name (what it does for this place is the VoiceOver hint).
struct SendAfterPastingRow: View {
    @EnvironmentObject var model: AppModel
    var target: TargetRef
    var compact = false

    var body: some View {
        let enabled = target.canSend
        let on = enabled && model.sendSetting(for: target)
        let detail = Places.sendDetail(target, in: model)
        // One line only: a second line that changed with the place made the panel jump.
        Toggle(isOn: Binding(get: { on }, set: { set($0) })) {
            Text("Send after pasting")
                .font(.body)
                .foregroundStyle(enabled ? Ink.ink : Ink.tertiary)
        }
        .accessibilityHint(detail)
        .toggleStyle(.switch)
        .tint(Light.cyan)
        .disabled(!enabled)
        .padding(.horizontal, Space.inset)
        .padding(.vertical, compact ? 8 : 11)
        // VoiceOver reads the switch with both lines: what it is, and what it does here (or why not).
        .accessibilityIdentifier("send-toggle")
    }

    private func set(_ new: Bool) {
        Haptics.tick()
        withAnimation(Motion.snap) { model.setSend(new, for: target) }
        model.explain(Places.sentence(for: target, send: new))
    }
}

// MARK: Cleanup

/// The five levels as a native segmented control (by the mic and in Settings).
struct CleanupPicker: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var settings: Settings

    var body: some View {
        let available = CleanupWords.available(model, settings)
        Picker("Cleanup", selection: Binding(get: { available ? settings.cleanupLevel : .off }, set: { pick($0) })) {
            ForEach(CleanupLevel.allCases) { l in Text(l.title).tag(l) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .disabled(!available)
        .accessibilityIdentifier("cleanup-level")
    }

    private func pick(_ l: CleanupLevel) {
        guard l != settings.cleanupLevel else { return }
        Haptics.tick()
        model.setCleanupLevel(l)
        model.explain(CleanupWords.sentence(for: l, edited: model.customInstructionsEdited))
    }
}

/// "Cleanup", the five levels, and one line saying what the picked one does (with Edit
/// instructions beside it for Custom).
struct CleanupRow: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var settings: Settings
    var compact = false
    /// Opens the Custom instructions.
    var onEditCustom: () -> Void

    var body: some View {
        let available = CleanupWords.available(model, settings)
        let level = available ? settings.cleanupLevel : .off
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            // Edit instructions sits beside the kicker, as Watch sits beside Send to — so the
            // line under the picker keeps the whole width and never runs to a third line past
            // the panel's foot (it did on an SE, Oct 18 2026). The row keeps the button's
            // height whether or not it's there, so a level change can't make the panel jump.
            HStack(alignment: .center, spacing: 10) {
                Kicker("Cleanup")
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if available, level == .custom {
                    Button("Edit instructions", action: onEditCustom)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Ink.ink)
                        .controlSize(.small)
                        .nativeGlassButton()
                        .transition(.opacity)
                        .accessibilityIdentifier("edit-custom")
                }
            }
            .frame(minHeight: buttonRow)
            CleanupPicker(settings: settings)
            Text(available ? CleanupWords.line(level, edited: model.customInstructionsEdited)
                           : CleanupWords.unavailableReason(model, settings))
                .font(.footnote)
                .foregroundStyle(available ? Ink.secondary : Light.ochre)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentTransition(.opacity)
                // Room for two lines either way.
                .frame(minHeight: twoLines, alignment: .topLeading)
        }
        .animation(.easeInOut(duration: 0.2), value: level)
        .padding(.horizontal, Space.inset)
        .padding(.top, compact ? 10 : 12)
        .padding(.bottom, compact ? 6 : 8)
    }

    /// Two footnote lines (18pt each at the default size).
    @ScaledMetric(relativeTo: .footnote) private var twoLines: CGFloat = 36
    /// A small glass button's height — the kicker row's, with or without the button.
    @ScaledMetric(relativeTo: .footnote) private var buttonRow: CGFloat = 30
}

/// The words for cleanup.
enum CleanupWords {
    @MainActor static func available(_ model: AppModel, _ settings: Settings) -> Bool {
        model.cleanupAvailability.isAvailable && settings.isEnglish
    }

    /// "Medium — fixes grammar and false starts".
    static func line(_ l: CleanupLevel, edited: Bool) -> String {
        switch l {
        case .off: return "Off — sent exactly as heard"
        case .custom: return edited ? "Custom — follows your own instructions" : "Custom — Medium's instructions until you edit them"
        default:
            var s = l.summary
            if s.hasPrefix("Also ") { s.removeFirst(5) }
            if s.hasSuffix(".") { s.removeLast() }
            return "\(l.title) — \(s.prefix(1).lowercased() + s.dropFirst())"
        }
    }

    /// What the next dictation's cleanup will do, in a sentence (the status line).
    static func sentence(for l: CleanupLevel, edited: Bool) -> String {
        switch l {
        case .off: return "Cleanup off — sent exactly as heard"
        case .custom: return edited ? "Custom cleanup — your own instructions"
                                    : "Custom cleanup — Medium's instructions until you edit them"
        default: return "\(l.title) cleanup — \(l.summary.dropLast())"
        }
    }

    @MainActor static func unavailableReason(_ model: AppModel, _ settings: Settings) -> String {
        if !settings.isEnglish { return "Cleanup works in English only for now — your words are sent exactly as heard" }
        return model.cleanupAvailability.explanation + " Until then, your words are sent exactly as heard."
    }
}

// MARK: The panel's container

private struct ControlPanel: ViewModifier {
    var glow: Color
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        // A material plate, like a sheet's: the controls on it are the glass (glass on glass blurs
        // twice and merges the buttons into the panel). Its edge is lit from above and its foot
        // takes a breath of the Thread's light below it — cool at rest, ember while the mic is
        // open, mint when the words land — so the plate sits in the page's light, not on top of it.
        let shape = RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
        content
            .background {
                ZStack {
                    if reduceTransparency { shape.fill(Ink.raised) } else { shape.fill(.regularMaterial) }
                    shape.fill(RadialGradient(colors: [glow.opacity(0.14), .clear],
                                              center: UnitPoint(x: 0.5, y: 1.1), startRadius: 0, endRadius: 360))
                        .animation(.easeInOut(duration: 0.7), value: glow)
                }
            }
            .overlay(SpecularEdge(shape: shape))
    }
}

extension View {
    /// The controls' grouped panel: a regular-material plate with a lit edge, its foot in the
    /// Thread's light.
    func controlPanel(glow: Color = Light.cyan) -> some View { modifier(ControlPanel(glow: glow)) }
}
