import AppKit
import EventKit
import MacrophoneKit
import SwiftUI

/// The profile's extra actions: save to Obsidian, Apple Notes, Reminders; ask Claude.
struct ActionsEditor: View {
    @Binding var actions: [ProfileAction]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if actions.isEmpty {
                Text("Also save what you said somewhere, or ask Claude about it.")
                    .font(.system(size: 11.5)).foregroundStyle(Ink.tertiary)
            }
            ForEach($actions) { $a in
                ActionCard(action: $a, remove: { actions.removeAll { $0.id == a.id } })
            }
            Menu {
                Button("Save to Obsidian") { add(.obsidian(vaultPath: "", notePath: nil, dailyFolder: nil, heading: nil)) }
                Button("Save to Apple Notes") { add(.appleNote(folder: nil, appendTo: nil)) }
                Button("Add to Reminders") { add(.reminder(list: nil, detectDates: true)) }
                Divider()
                Button("Ask Claude") { add(.claude(model: ClaudeClient.defaultModel, systemPrompt: nil, deliverReply: true)) }
            } label: {
                Label("Add Action", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private func add(_ kind: ProfileAction.Kind) {
        actions.append(ProfileAction(kind: kind))
    }
}

private struct ActionCard: View {
    @Binding var action: ProfileAction
    var remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(tint).frame(width: 18)
                Text(action.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.ink)
                if action.sendsOffDevice { Chip(text: "Sends text to Anthropic", color: Light.ochre, icon: "arrow.up.right") }
                Spacer()
                Button(action: remove) {
                    Image(systemName: "minus.circle.fill").foregroundStyle(Ink.tertiary)
                }
                .buttonStyle(.plain)
                .help("Remove this action")
                .accessibilityLabel("Remove \(action.title)")
            }
            switch action.kind {
            case .obsidian: ObsidianFields(action: $action)
            case .appleNote: NotesFields(action: $action)
            case .reminder: ReminderFields(action: $action)
            case .claude: ClaudeFields(action: $action)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(action.sendsOffDevice ? Light.ochre.opacity(0.05) : Ink.raised.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(action.sendsOffDevice ? Light.ochre.opacity(0.25) : Ink.line, lineWidth: 1))
    }

    private var symbol: String {
        switch action.kind {
        case .obsidian: return "doc.text"
        case .appleNote: return "note.text"
        case .reminder: return "checklist"
        case .claude: return "sparkle"
        }
    }

    private var tint: Color {
        switch action.kind {
        case .obsidian: return Light.violet
        case .appleNote: return Light.gold
        case .reminder: return Light.cyan
        case .claude: return Light.ember
        }
    }
}

/// A labelled row inside an action card.
private func row<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text(label).font(.system(size: 12)).foregroundStyle(Ink.secondary).frame(width: 96, alignment: .trailing)
        content()
    }
}

private func note(_ s: String) -> some View {
    Text(s).font(.system(size: 11.5)).foregroundStyle(Ink.tertiary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 106)
}

private func optional(_ s: String) -> String? {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? nil : t
}

// MARK: Obsidian

private struct ObsidianFields: View {
    @Binding var action: ProfileAction

    private var parts: (vault: String, note: String, daily: String, heading: String) {
        if case let .obsidian(v, n, d, h) = action.kind { return (v, n ?? "", d ?? "", h ?? "") }
        return ("", "", "", "")
    }

    private func set(vault: String? = nil, note: String? = nil, daily: String? = nil, heading: String? = nil) {
        let p = parts
        action.kind = .obsidian(vaultPath: vault ?? p.vault, notePath: optional(note ?? p.note),
                                dailyFolder: optional(daily ?? p.daily), heading: optional(heading ?? p.heading))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("Vault") {
                Text(parts.vault.isEmpty ? "No vault chosen" : (parts.vault as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 12, weight: parts.vault.isEmpty ? .regular : .medium))
                    .foregroundStyle(parts.vault.isEmpty ? Light.ochre : Ink.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Button(parts.vault.isEmpty ? "Choose Vault…" : "Change…") { choose() }
            }
            row("Note") {
                TextField("Today's daily note", text: Binding(get: { parts.note }, set: { set(note: $0) }))
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
            }
            if parts.note.isEmpty {
                row("Daily folder") {
                    TextField(dailyPlaceholder, text: Binding(get: { parts.daily }, set: { set(daily: $0) }))
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                }
            }
            row("Under heading") {
                TextField("Optional, e.g. Inbox", text: Binding(get: { parts.heading }, set: { set(heading: $0) }))
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
            }
            note("Adds “- \(TemplateRenderer.clockContext()["time"] ?? "14:05") what you said” to \(destinationLine). A plain file write — Obsidian doesn't need to be open.")
        }
    }

    private var dailyPlaceholder: String {
        guard !parts.vault.isEmpty else { return "Vault root" }
        let cfg = URL(fileURLWithPath: parts.vault).appendingPathComponent(".obsidian/daily-notes.json")
        if let d = try? Data(contentsOf: cfg), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let f = o["folder"] as? String, !f.isEmpty { return "\(f) (from Obsidian)" }
        return "Vault root"
    }

    private var destinationLine: String {
        let vault = parts.vault.isEmpty ? URL(fileURLWithPath: "/") : URL(fileURLWithPath: parts.vault)
        let path = NoteActions.noteRelativePath(vault: vault, notePath: optional(parts.note), dailyFolder: optional(parts.daily), now: Date())
        let h = parts.heading.trimmingCharacters(in: .whitespaces)
        return h.isEmpty ? path : "\(path), under “\(h)”"
    }

    private func choose() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.prompt = "Use This Vault"
        p.message = "Choose your Obsidian vault — the folder that holds your notes."
        if p.runModal() == .OK, let url = p.url { set(vault: url.path) }
    }
}

// MARK: Apple Notes

private struct NotesFields: View {
    @Binding var action: ProfileAction
    @State private var mode = 0

    private var parts: (folder: String, append: String) {
        if case let .appleNote(f, a) = action.kind { return (f ?? "", a ?? "") }
        return ("", "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("Each dictation") {
                Picker("", selection: Binding(get: { parts.append.isEmpty && mode == 0 ? 0 : 1 }, set: { m in
                    mode = m
                    action.kind = m == 0 ? .appleNote(folder: optional(parts.folder), appendTo: nil)
                                         : .appleNote(folder: optional(parts.folder), appendTo: optional(parts.append) ?? "Dictations")
                })) {
                    Text("Makes a new note").tag(0)
                    Text("Adds to one note").tag(1)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            if !parts.append.isEmpty || mode == 1 {
                row("Note title") {
                    TextField("e.g. Dictations", text: Binding(get: { parts.append }, set: {
                        action.kind = .appleNote(folder: optional(parts.folder), appendTo: $0)
                    }))
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                }
            }
            row("Folder") {
                TextField("Notes' default folder", text: Binding(get: { parts.folder }, set: {
                    action.kind = .appleNote(folder: optional($0), appendTo: optional(parts.append))
                }))
                .textFieldStyle(.roundedBorder).frame(maxWidth: 240)
            }
            note("Syncs through iCloud if you use iCloud Notes. The first time, macOS asks to let Macrophone use Notes.")
            AutomationPermissionRow(bundleID: NoteActions.notesBundleID, appName: "Notes",
                                    why: "Macrophone writes the note through Notes itself.")
                .padding(.leading, 106)
        }
    }
}

// MARK: Reminders

private struct ReminderFields: View {
    @Binding var action: ProfileAction
    @State private var lists: [String] = []
    @State private var allowed = NoteActions.remindersAllowed
    @State private var denied = false

    private var parts: (list: String?, detect: Bool) {
        if case let .reminder(l, d) = action.kind { return (l, d) }
        return (nil, true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("List") {
                if allowed {
                    Picker("", selection: Binding(get: { parts.list ?? "" }, set: {
                        action.kind = .reminder(list: $0.isEmpty ? nil : $0, detectDates: parts.detect)
                    })) {
                        Text("Your default list").tag("")
                        ForEach(lists, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                } else {
                    Text(denied ? "Not allowed — turn on Macrophone in System Settings › Privacy & Security › Reminders." : "Macrophone needs to see your lists.")
                        .font(.system(size: 12)).foregroundStyle(denied ? Light.ochre : Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(denied ? "Open System Settings" : "Allow…") {
                        if denied { NSWorkspace.shared.open(NoteActions.remindersSettingsURL); return }
                        Task {
                            allowed = await NoteActions.requestReminders()
                            denied = !allowed
                            lists = NoteActions.reminderLists()
                        }
                    }
                }
            }
            row("Dates") {
                Toggle("Turn “tomorrow at 5pm” into a due date", isOn: Binding(get: { parts.detect }, set: {
                    action.kind = .reminder(list: parts.list, detectDates: $0)
                }))
            }
            note(example)
        }
        .onAppear {
            allowed = NoteActions.remindersAllowed
            let st = NoteActions.remindersStatus
            denied = st == .denied || st == .restricted
            lists = NoteActions.reminderLists()
        }
    }

    private var example: String {
        guard parts.detect else { return "The whole dictation becomes the reminder's title." }
        let r = ReminderParsing.parse("Call the dentist tomorrow at 5pm")
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .medium
        f.timeStyle = .short
        var when = r.due.map { f.string(from: $0) } ?? "tomorrow"
        if when.hasPrefix("Tomorrow") || when.hasPrefix("Today") { when = when.prefix(1).lowercased() + when.dropFirst() }
        return "“Call the dentist tomorrow at 5pm” becomes “\(r.title)”, due \(when)."
    }
}

// MARK: Claude

private struct ClaudeFields: View {
    @Binding var action: ProfileAction
    @State private var hasKey = ClaudeKey.load() != nil

    private var parts: (model: String, system: String, deliver: Bool) {
        if case let .claude(m, s, d) = action.kind { return (m, s ?? "", d) }
        return (ClaudeClient.defaultModel, "", true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("Model") {
                Picker("", selection: Binding(get: { parts.model }, set: {
                    action.kind = .claude(model: $0, systemPrompt: optional(parts.system), deliverReply: parts.deliver)
                })) {
                    ForEach(ClaudeClient.models, id: \.id) { m in Text(m.name).tag(m.id) }
                }
                .labelsHidden().fixedSize()
                Text(ClaudeClient.models.first { $0.id == parts.model }?.line ?? "")
                    .font(.system(size: 11.5)).foregroundStyle(Ink.tertiary)
            }
            row("Instructions") {
                TextField("Optional — e.g. Answer in two sentences.", text: Binding(get: { parts.system }, set: {
                    action.kind = .claude(model: parts.model, systemPrompt: $0.isEmpty ? nil : $0, deliverReply: parts.deliver)
                }), axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
            }
            row("Reply") {
                Toggle("Copy Claude's reply to the clipboard", isOn: Binding(get: { parts.deliver }, set: {
                    action.kind = .claude(model: parts.model, systemPrompt: optional(parts.system), deliverReply: $0)
                }))
            }
            note("Sends what you dictated to Anthropic with your own API key. The reply streams into the popup and is kept in History next to the dictation.")
            HStack(spacing: 8) {
                Image(systemName: hasKey ? "key.fill" : "key")
                    .foregroundStyle(hasKey ? Light.mint : Light.ochre)
                Text(hasKey ? "Your API key is set." : "No API key yet — add one in Developer › Claude API key.")
                    .font(.system(size: 11.5)).foregroundStyle(hasKey ? Ink.tertiary : Light.ochre)
                if !hasKey {
                    Button("Open Developer") { AppDelegate.shared?.openMainWindow(pane: .developer) }
                        .buttonStyle(.borderless)
                }
            }
            .padding(.leading, 106)
        }
        .onAppear { hasKey = ClaudeKey.load() != nil }
    }
}
