import MacrophoneKit
import SwiftUI

// "Send to": where on the Mac the next dictation goes. One chip by the mic, one tap to a
// picker of the Mac's targets, Automatic first. A spoken lead-in ("Claude, …") overrides it
// for one dictation, and the chip shows that live.

enum TargetGlyph {
    static let automatic = "wand.and.sparkles"

    /// The glyph from what the Mac says the target is; older Macs send only a name.
    static func symbol(for p: ProfileSummary) -> String {
        switch p.targetKind {
        case .clipboard?: return "doc.on.clipboard"
        case .focusedApp?: return "cursorarrow.rays"
        case .tmux?: return "terminal"
        case .app?:
            let bid = (p.targetBundleID ?? "").lowercased()
            if ["com.apple.terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.warp-stable"].contains(bid) { return "terminal" }
            return symbol(for: p.targetApp ?? p.name)
        case .none?:
            return symbol(for: p.name)
        case nil:
            return symbol(for: p.name)
        }
    }

    /// A plain glyph from a name.
    static func symbol(for name: String) -> String {
        let n = name.lowercased()
        if n.contains("terminal") || n.contains("claude code") || n.contains("tmux") || n.contains("shell") { return "terminal" }
        if n.contains("clipboard") || n.contains("copy") { return "doc.on.clipboard" }
        if n.contains("note") || n.contains("obsidian") { return "note.text" }
        if n.contains("remind") { return "checklist" }
        if n.contains("slack") || n.contains("message") || n.contains("mail") { return "bubble.left" }
        if n.contains("cursor") || n.contains("code") || n.contains("xcode") { return "chevron.left.forwardslash.chevron.right" }
        return "arrow.up.forward.app"
    }
}

extension ProfileSummary {
    /// "Say “Claude, …”" — the first lead-in, as a hint.
    var prefixHint: String? {
        guard let p = voicePrefixes?.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
        return "Say “\(spokenForm(p, name: name)), …”"
    }
}

/// The chip by the mic: "SEND TO  → Claude ⌄".
struct SendToChip: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var recorder: Recorder
    var recording: Bool

    var body: some View {
        let live: (ProfileSummary?, Bool) = recording ? model.liveRoute(recorder.transcript) : (model.selectedProfile, false)
        let name = live.0?.name ?? "Automatic"
        let symbol = live.0.map { TargetGlyph.symbol(for: $0) } ?? TargetGlyph.automatic
        Button { model.sheet = .sendTo } label: {
            HStack(spacing: 8) {
                Kicker(live.1 ? "Said" : "Send to", color: live.1 ? Light.ember : Ink.tertiary)
                Image(systemName: symbol)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(live.0 == nil ? Light.violet : Light.cyan)
                    .contentTransition(.symbolEffect(.replace))
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Ink.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    .contentTransition(.opacity)
                if !recording {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Ink.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(minHeight: 38)
            .background(Capsule().fill(Ink.ink.opacity(live.1 ? 0.09 : 0.05)))
            .overlay(Capsule().strokeBorder(live.1 ? Light.ember.opacity(0.5) : Ink.line, lineWidth: 1))
            .contentShape(Capsule())
            .animation(Motion.snap, value: name)
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .allowsHitTesting(!recording)
        .accessibilityLabel(live.1 ? "Sending this one to \(name), because you said it" : "Send to: \(name)")
        .accessibilityHint(recording ? "" : "Choose where on your Mac your dictations go.")
        .accessibilityIdentifier("send-to")
    }
}

/// The picker: Automatic, then each of the Mac's targets with the words that pick it by voice.
struct SendToSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(symbol: TargetGlyph.automatic, tint: Light.violet, title: "Automatic",
                        subtitle: "Your Mac picks by the app in front", selected: model.settings.sendTo == .automatic) {
                        pick(.automatic)
                    }
                }
                .listRowBackground(Ink.raised)

                Section {
                    ForEach(model.profiles) { p in
                        row(symbol: TargetGlyph.symbol(for: p), tint: Light.cyan, title: p.name,
                            subtitle: subtitle(p), selected: model.settings.sendTo == .profile(p.id)) {
                            pick(.profile(p.id))
                        }
                    }
                } header: {
                    Text("On \(model.macName)")
                } footer: {
                    Text(footer)
                        .padding(.top, 4)
                }
                .listRowBackground(Ink.raised)
            }
            .scrollContentBackground(.hidden)
            .background(Ink.ground.ignoresSafeArea())
            .navigationTitle("Send To")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.fontWeight(.semibold) }
            }
        }
        .tint(Light.cyan)
    }

    private var footer: String {
        let anyPrefix = model.profiles.contains { $0.prefixHint != nil }
        var s = anyPrefix ? "Start with a target's name to send just that dictation there — “Claude, refactor this…”. " : ""
        s += "Targets are set up in Macrophone on your Mac."
        if !model.isConnected { s += " Your Mac isn't connected, so this is the list it last sent." }
        return s
    }

    private func subtitle(_ p: ProfileSummary) -> String? {
        var parts: [String] = []
        if let hint = p.prefixHint { parts.append(hint) }
        if let level = p.cleanupLevel { parts.append("\(level.title) cleanup") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func pick(_ t: SendTarget) {
        model.setSendTo(t)
        dismiss()
    }

    private func row(symbol: String, tint: Color, title: String, subtitle: String?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.14)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.25), lineWidth: 1))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.semibold)).foregroundStyle(Ink.ink)
                    if let subtitle {
                        Text(subtitle).font(.footnote).foregroundStyle(Ink.tertiary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Light.cyan)
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
