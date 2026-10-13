import MacrophoneKit
import SwiftUI
import UIKit

// The quick controls by the mic: where it goes (the Mac's open apps), Paste or Paste & send, and
// how much cleanup — each one tap, applied to the next dictation (or the one being recorded) and
// synced to the Mac at once. Saying an app's name first ("Messages, …") overrides the choice for
// one dictation, and the chip shows that live.

enum TargetGlyph {
    static func symbol(for t: TargetRef) -> String {
        switch t {
        case .clipboard: return "doc.on.clipboard"
        case .frontApp: return "cursorarrow.rays"
        case let .app(bid, _, name): return appSymbol(bundleID: bid, name: name)
        case let .automation(_, name): return automationSymbol(name)
        }
    }

    static func appSymbol(bundleID: String, name: String) -> String {
        let b = bundleID.lowercased(), n = name.lowercased()
        if ["com.apple.terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.warp-stable"].contains(b) || n.contains("terminal") { return "terminal" }
        if n.contains("message") || n.contains("slack") || n.contains("mail") { return "bubble.left" }
        if n.contains("note") { return "note.text" }
        if n.contains("cursor") || n.contains("code") || n.contains("xcode") { return "chevron.left.forwardslash.chevron.right" }
        return "macwindow"
    }

    /// A plain glyph for an automation, from its name.
    static func automationSymbol(_ name: String) -> String {
        let n = name.lowercased()
        if n.contains("tmux") || n.contains("terminal") || n.contains("shell") { return "terminal" }
        if n.contains("note") || n.contains("obsidian") { return "note.text" }
        if n.contains("remind") || n.contains("todo") { return "checklist" }
        if n.contains("claude") || n.contains("ask") { return "sparkles" }
        if n.contains("script") || n.contains("webhook") { return "curlybraces" }
        return "gearshape.2"
    }
}

/// App icons the Mac sends (small PNGs), decoded once.
@MainActor
enum IconCache {
    private static var images: [Data: UIImage] = [:]
    static func image(_ data: Data?) -> UIImage? {
        guard let data else { return nil }
        if let i = images[data] { return i }
        let i = UIImage(data: data)
        images[data] = i
        return i
    }
}

/// The app's own icon when the Mac sent one, else a glyph on a tinted plate.
struct TargetIcon: View {
    var target: TargetRef
    var icon: Data?
    var size: CGFloat = 20

    var body: some View {
        if let img = IconCache.image(icon) {
            Image(uiImage: img).resizable().interpolation(.high).scaledToFit()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            let tint = Self.tint(target)
            Image(systemName: TargetGlyph.symbol(for: target))
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).fill(tint.opacity(0.16)))
                .overlay(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).strokeBorder(tint.opacity(0.3), lineWidth: 1))
                .accessibilityHidden(true)
        }
    }

    static func tint(_ t: TargetRef) -> Color {
        switch t {
        case .clipboard: return Light.teal
        case .frontApp: return Light.violet
        case .app: return Light.cyan
        case .automation: return Light.gold
        }
    }
}

extension ProfileSummary {
    /// "Say “Note” first" — the first lead-in, as a hint.
    var prefixHint: String? {
        guard let p = voicePrefixes?.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
        return "Say “\(spokenForm(p, name: name))” first"
    }
}

// MARK: The quick controls

/// Two lines over the mic: where it goes; then Paste / Paste & send and the cleanup level.
/// Lives in a fixed slot (see MainView), so nothing here can move the mic.
struct QuickControls: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var settings: Settings
    @ObservedObject var recorder: Recorder
    var recording: Bool
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage("onboarding.macNudgeDismissed") private var macNudgeDismissed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 6) {
            if showNudge {
                MacAppNudge { withAnimation(Motion.pick(Motion.depart, reduce: reduceMotion)) { macNudgeDismissed = true } }
                    .transition(.opacity)
            } else {
                WhereChip(recorder: recorder, recording: recording)
            }
            secondLine
        }
        .padding(.horizontal, 16)
        // Quiet while recording, but still live: a change applies to the words being spoken.
        .opacity(recording ? 0.6 : 1)
        .animation(.easeInOut(duration: 0.25), value: recording)
    }

    /// The first dictations without a Mac: it worked here; this is how to get it there.
    private var showNudge: Bool { !model.isPaired && model.latest?.delivery == .copiedOnPhone && !macNudgeDismissed }

    /// While recording, an app said first is where this one goes — the toggle follows it.
    private var target: TargetRef { recording ? model.liveRoute(recorder.transcript).target : model.selection.target }

    @ViewBuilder private var secondLine: some View {
        let t = target
        if typeSize.isAccessibilitySize {
            VStack(spacing: 6) { SendToggle(settings: settings, target: t); CleanupChip(settings: settings, short: false) }
        } else {
            // Wider words first; narrower ones on a small phone. The height never changes.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { SendToggle(settings: settings, target: t); CleanupChip(settings: settings, short: false) }
                HStack(spacing: 8) { SendToggle(settings: settings, target: t); CleanupChip(settings: settings, short: true) }
                HStack(spacing: 6) { SendToggle(settings: settings, target: t, short: true); CleanupChip(settings: settings, short: true) }
            }
        }
    }
}

/// The shape every quick control wears.
private struct QuickPlate: ViewModifier {
    var highlighted = false
    var tint: Color = Ink.line
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 19, style: .continuous)
        content
            .padding(.horizontal, 14)
            .frame(minHeight: 38)
            .background(shape.fill(Ink.ink.opacity(highlighted ? 0.09 : 0.05)))
            .overlay(shape.strokeBorder(contrast == .increased ? Ink.ink.opacity(0.45) : tint, lineWidth: 1))
            .padding(.vertical, 3)
            .contentShape(Rectangle())
    }
}

/// "SEND TO  [icon] Messages ⌄" — one tap opens the picker.
struct WhereChip: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var recorder: Recorder
    var recording: Bool

    var body: some View {
        let paired = model.isPaired
        let live: (target: TargetRef, send: Bool, byVoice: Bool) = recording ? model.liveRoute(recorder.transcript) : (model.selection.target, model.selection.send, false)
        let target = live.target
        let name = paired ? target.displayName : "This iPhone's clipboard"
        let said = live.byVoice
        let notOpen = paired && model.isNotOpen(target)
        let icon = model.liveTarget(for: target)?.icon
        Button { model.sheet = paired ? .sendTo : .pairing } label: {
            // Ladder: kicker + name; name alone; smaller; two lines. Never "…".
            ViewThatFits(in: .horizontal) {
                row(kicker: true, name: name, font: .subheadline, said: said, notOpen: notOpen, target: target, icon: icon, paired: paired)
                row(kicker: false, name: name, font: .subheadline, said: said, notOpen: notOpen, target: target, icon: icon, paired: paired)
                row(kicker: false, name: name, font: .footnote, said: said, notOpen: notOpen, target: target, icon: icon, paired: paired)
                row(kicker: false, name: name, font: .caption, said: said, notOpen: notOpen, target: target, icon: icon, paired: paired, wrap: true)
            }
            .modifier(QuickPlate(highlighted: said, tint: said ? Light.ember.opacity(0.5) : (notOpen ? Light.ochre.opacity(0.45) : Ink.line)))
            .animation(Motion.snap, value: name)
        }
        .buttonStyle(.plain)
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
        .accessibilityLabel(accessibility(name: name, said: said, notOpen: notOpen, paired: paired))
        .accessibilityHint(paired ? "Choose where on your Mac your dictations go." : "Pairs this iPhone with Macrophone on your Mac.")
        .accessibilityIdentifier("send-to")
    }

    private func row(kicker: Bool, name: String, font: Font, said: Bool, notOpen: Bool, target: TargetRef, icon: Data?, paired: Bool, wrap: Bool = false) -> some View {
        HStack(spacing: 8) {
            if kicker { Kicker(said ? "Said" : "Send to", color: said ? Light.ember : Ink.tertiary).fixedSize() }
            if paired { TargetIcon(target: target, icon: icon, size: 20) } else {
                Image(systemName: "iphone").font(.footnote.weight(.semibold)).foregroundStyle(Ink.tertiary).accessibilityHidden(true)
            }
            Text(name)
                .font(font.weight(.semibold))
                .foregroundStyle(notOpen ? Ink.secondary : Ink.ink)
                .lineLimit(wrap ? 2 : 1)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: !wrap, vertical: true)
                .contentTransition(.opacity)
            if notOpen {
                Image(systemName: "moon.zzz").font(.caption.weight(.semibold)).foregroundStyle(Light.ochre).accessibilityHidden(true)
            }
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2.weight(.bold))
                .foregroundStyle(Ink.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 6)
    }

    private func accessibility(name: String, said: Bool, notOpen: Bool, paired: Bool) -> String {
        if !paired { return "Send to: this iPhone's clipboard. Pair your Mac to choose where it goes." }
        if said { return "Sending this one to \(name), because you said it" }
        return "Send to: \(name)" + (notOpen ? ", not open on your Mac — it'll be copied instead" : "")
    }
}

/// Paste | Paste & send — one tap, no sheet. Disabled with its reason where sending can't apply.
struct SendToggle: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var settings: Settings
    /// The place it applies to: the choice, or an app said first while recording.
    var target: TargetRef
    var short = false

    var body: some View {
        if let reason = disabledReason(target) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.down.left").font(.caption.weight(.semibold)).accessibilityHidden(true)
                Text(reason).font(.footnote.weight(.medium)).lineLimit(1).fixedSize()
            }
            .foregroundStyle(Ink.tertiary)
            .modifier(QuickPlate(tint: Ink.faint))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Paste and send: unavailable. \(reason).")
            .accessibilityIdentifier("send-toggle")
        } else {
            let on = model.sendSetting(for: target)
            HStack(spacing: 2) {
                option("Paste", on: !on, hint: "Pastes the text and leaves it for you to send.") { model.setSend(false, for: target) }
                option(short ? "Send" : "Paste & send", on: on, hint: "Pastes, then presses send after a short countdown on your Mac.") { model.setSend(true, for: target) }
            }
            .padding(3)
            .background(Capsule().fill(Ink.ink.opacity(0.06)).padding(.vertical, 3))
            .overlay(Capsule().strokeBorder(Ink.line, lineWidth: 1).padding(.vertical, 3))
            .frame(minHeight: 44)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("After pasting into \(target.displayName)")
            .accessibilityIdentifier("send-toggle")
        }
    }

    private func disabledReason(_ t: TargetRef) -> String? {
        if !model.isPaired { return "Pair your Mac to send" }
        switch t {
        case .clipboard: return "Clipboard can't send"
        case .automation: return "Automations can't send"
        case .frontApp, .app: return nil
        }
    }

    private func option(_ title: String, on: Bool, hint: String, action: @escaping () -> Void) -> some View {
        Button { withAnimation(Motion.snap) { action() } } label: {
            Text(title)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 12)
                .frame(minHeight: 32)
                .foregroundStyle(on ? Ink.ground : Ink.secondary)
                .background(Capsule().fill(on ? Ink.ink : .clear))
                .contentShape(Capsule().inset(by: -6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title == "Send" ? "Paste & send" : title)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityHint(hint)
    }
}

/// The cleanup level as a menu: the four levels with their one-line summaries, the current one
/// ticked. A menu (not tap-to-cycle) because each level says what it does before you pick it,
/// and any level is one tap away instead of up to three.
struct CleanupChip: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var settings: Settings
    var short: Bool

    var body: some View {
        let available = model.cleanupAvailability.isAvailable && settings.isEnglish
        let profileLevel = model.selectedProfile?.cleanupLevel
        let level = available ? (profileLevel ?? settings.cleanupLevel) : .off
        Menu {
            if available {
                Section {
                    ForEach(CleanupLevel.allCases) { l in
                        Button { model.setCleanupLevel(l) } label: {
                            if l == settings.cleanupLevel { Label(l.title, systemImage: "checkmark") } else { Text(l.title) }
                            Text(l.summary)
                        }
                    }
                } header: {
                    Text("Cleanup on this iPhone")
                }
                if let p = model.selectedProfile, let pl = p.cleanupLevel {
                    Section { Text("“\(p.name)” uses \(pl.title) on your Mac — it wins while it's picked.") }
                }
            } else {
                Section { Text(unavailableReason) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: level == .off ? "wand.and.rays.inverse" : "wand.and.stars")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(level == .off ? Ink.tertiary : Light.teal)
                    .accessibilityHidden(true)
                Text(label(level, available: available))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(available ? Ink.ink : Ink.secondary)
                    .lineLimit(1)
                    .fixedSize()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Ink.tertiary)
                    .accessibilityHidden(true)
            }
            .modifier(QuickPlate())
        }
        .buttonStyle(.plain)
        .menuOrder(.fixed)
        .accessibilityLabel(available ? "Cleanup: \(level.title)" : "Cleanup off")
        .accessibilityValue(available ? level.summary : unavailableReason)
        .accessibilityHint(available ? "Choose how much the words are tidied before they're sent." : "")
        .accessibilityIdentifier("cleanup-level")
    }

    private func label(_ level: CleanupLevel, available: Bool) -> String {
        if !available || level == .off { return "Cleanup off" }
        return short ? level.title : "\(level.title) cleanup"
    }

    private var unavailableReason: String {
        if !settings.isEnglish { return "Cleanup works in English only for now. Your words are sent exactly as heard." }
        return model.cleanupAvailability.explanation + " Until then, your words are sent exactly as heard."
    }
}

// MARK: The picker

/// Clipboard, Where I'm typing, the Mac's open apps (newest first), then its automations.
struct SendToList: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var settings: Settings
    var onPick: () -> Void = {}

    var body: some View {
        List {
            if settings.selection.target.canSend {
                Section {
                    Picker("After pasting", selection: Binding(get: { settings.selection.send }, set: { model.setSend($0) })) {
                        Text("Paste").tag(false)
                        Text("Paste & send").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("picker-send")
                } header: {
                    Text("For \(settings.selection.target.displayName)")
                } footer: {
                    Text("Paste & send presses the app's send key after a short countdown on your Mac. Remembered for each place.")
                }
                .listRowBackground(Ink.raised)
            }

            Section {
                row(.clipboard, icon: nil, subtitle: "Copies it on your Mac, to paste yourself")
                row(.frontApp, icon: nil, subtitle: "Pastes into whatever app is in front on your Mac")
            }
            .listRowBackground(Ink.raised)

            Section {
                if let missing = missingPick {
                    row(missing, icon: nil, subtitle: "Not open on your Mac — it'll be copied instead", dim: true)
                }
                if model.liveTargets.isEmpty {
                    Text(model.isConnected
                         ? "Nothing with a place to type is open on \(model.macName) right now."
                         : "Open apps show here when \(model.macName) is connected.")
                        .font(.subheadline)
                        .foregroundStyle(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 6)
                }
                ForEach(model.liveTargets) { t in
                    row(t.ref, icon: t.icon, subtitle: t.windowTitle == nil ? sendNote(t.ref) : "A window of \(t.appName)" + (sendNote(t.ref).map { " · \($0)" } ?? ""))
                }
            } header: {
                Text("Open on \(model.macName)")
            } footer: {
                Text(openFooter).padding(.top, 4)
            }
            .listRowBackground(Ink.raised)

            if !model.profiles.isEmpty {
                Section {
                    ForEach(model.profiles) { p in
                        row(.automation(id: p.id, name: p.name), icon: nil, subtitle: automationSubtitle(p))
                    }
                } header: {
                    Text("Automations")
                } footer: {
                    Text("Notes, reminders, scripts and the like, set up in Macrophone on your Mac. Start with an automation's name to use it once: “Note, call the bank.”")
                        .padding(.top, 4)
                }
                .listRowBackground(Ink.raised)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Ink.ground.ignoresSafeArea())
        .tint(Light.cyan)
        .onAppear { model.refreshTargets() }
    }

    /// The picked app, when it's no longer open on the Mac — shown rather than vanishing.
    private var missingPick: TargetRef? {
        let t = settings.selection.target
        guard case .app = t, model.liveTarget(for: t) == nil else { return nil }
        return t
    }

    private func sendNote(_ t: TargetRef) -> String? { settings.rememberedSend(for: t) ? "Paste & send" : nil }

    private var openFooter: String {
        var s = "Apps and windows on your Mac with somewhere to type, most recent first. Say an app's name first to send just that one there: “Messages, tell Sam I'm late.”"
        if model.isPaired, !model.isConnected { s += " \(model.macName) isn't connected right now, so this is the list it sent last." }
        return s
    }

    private func automationSubtitle(_ p: ProfileSummary) -> String? {
        var parts: [String] = []
        if let hint = p.prefixHint { parts.append(hint) }
        if let level = p.cleanupLevel { parts.append("\(level.title) cleanup") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func row(_ target: TargetRef, icon: Data?, subtitle: String?, dim: Bool = false) -> some View {
        let selected = settings.selection.target == target
        return Button {
            model.pick(target)
            onPick()
        } label: {
            HStack(spacing: 14) {
                TargetIcon(target: target, icon: icon, size: 34)
                    .opacity(dim ? 0.55 : 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.displayName).font(.body.weight(.semibold)).foregroundStyle(dim ? Ink.secondary : Ink.ink)
                    if let subtitle {
                        Text(subtitle).font(.footnote).foregroundStyle(dim ? Light.ochre : Ink.tertiary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Light.cyan)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The picker as a sheet from the chip.
struct SendToSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SendToList(settings: model.settings) { dismiss() }
                .navigationTitle("Send To")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.fontWeight(.semibold) }
                }
        }
        .tint(Light.cyan)
    }
}
