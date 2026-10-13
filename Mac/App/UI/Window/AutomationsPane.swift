import MacrophoneKit
import SwiftUI

/// Automations: the deeper things a dictation can do, listed on the iPhone under Send to ›
/// Automations — save to Obsidian, Apple Notes or Reminders, type into a tmux pane, ask Claude,
/// run a script, post to a webhook.
struct AutomationsPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: AutomationStore
    @ObservedObject var settings: Settings
    @State private var editing: Profile?

    var body: some View {
        PanePage {
            HStack(alignment: .bottom, spacing: 10) {
                PaneHeader(title: "Automations", subtitle: "More than pasting: save what you said, type it into a tmux pane, ask Claude about it, or hand it to a script. Pick one on your iPhone under Send to › Automations.")
                Menu {
                    ForEach(AutomationTemplate.all) { t in
                        Button { editing = t.make() } label: { Label(t.title, systemImage: t.symbol) }
                    }
                } label: {
                    Label("New Automation", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(.bottom, 4)
            }

            if store.automations.isEmpty {
                empty
            } else {
                VStack(spacing: 10) {
                    ForEach(store.automations) { a in
                        AutomationRow(automation: a, selected: isSelected(a), edit: { editing = a })
                    }
                }
            }

            Text("Apps don't need an automation — every app open on this Mac with somewhere to type is already under Send to. Start a dictation with an automation's voice prefix (“note, …”) to use it for that one.")
                .font(.system(size: 11.5)).foregroundStyle(Ink.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            #if DEBUG
            switch ProcessInfo.processInfo.environment["MACROPHONE_SHOW"] {
            case "automation-editor", "automation-editor-actions", "automation-editor-tmux":
                if editing == nil { editing = DebugHooks.automationForEditor(store) }
            default: break
            }
            #endif
        }
        .sheet(item: $editing) { a in
            AutomationEditor(profile: a, isNew: !store.automations.contains { $0.id == a.id }, store: store, settings: settings)
        }
    }

    private func isSelected(_ a: Profile) -> Bool {
        if case .automation(let id, _) = settings.selection.target { return id == a.id }
        return false
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No automations yet").font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.ink)
            Text("Choose New Automation to save dictations to Obsidian, Apple Notes or Reminders, type them into a tmux pane, ask Claude, or run a script or webhook.")
                .font(.system(size: 12.5)).foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Ink.raised.opacity(0.72)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Ink.line, lineWidth: 1))
    }
}

/// The starting points in New Automation.
struct AutomationTemplate: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let make: () -> Profile

    static let all: [AutomationTemplate] = [
        .init(id: "obsidian", title: "Save to Obsidian", symbol: "doc.text") {
            Profile(name: "Obsidian", destination: .none, voicePrefixes: ["log"],
                    actions: [ProfileAction(kind: .obsidian(vaultPath: "", notePath: nil, dailyFolder: nil, heading: nil))])
        },
        .init(id: "notes", title: "Save to Apple Notes", symbol: "note.text") {
            Profile(name: "Apple Notes", destination: .none, voicePrefixes: ["note"],
                    actions: [ProfileAction(kind: .appleNote(folder: nil, appendTo: nil))])
        },
        .init(id: "reminders", title: "Add to Reminders", symbol: "checklist") {
            Profile(name: "Reminders", destination: .none, voicePrefixes: ["remind me"],
                    actions: [ProfileAction(kind: .reminder(list: nil, detectDates: true))])
        },
        .init(id: "tmux", title: "Type into a tmux pane", symbol: "terminal") {
            Profile(name: "tmux", destination: .tmux(target: ""), pressEnter: true, outputFormat: .singleLine)
        },
        .init(id: "claude", title: "Ask Claude", symbol: "sparkle") {
            Profile(name: "Ask Claude", destination: .none, voicePrefixes: ["ask Claude"],
                    actions: [ProfileAction(kind: .claude(model: ClaudeClient.defaultModel, systemPrompt: nil, deliverReply: true))])
        },
        .init(id: "script", title: "Run a script", symbol: "chevron.left.forwardslash.chevron.right") {
            var p = Profile(name: "Script", destination: .none)
            p.script = ""
            return p
        },
        .init(id: "webhook", title: "Send to a webhook", symbol: "arrow.up.right.square") {
            Profile(name: "Webhook", destination: .none)
        },
        .init(id: "blank", title: "Copy with a template", symbol: "text.badge.plus") {
            Profile(name: "New automation", destination: .clipboard, template: "{{text}}")
        },
    ]
}

struct AutomationRow: View {
    let automation: Profile
    let selected: Bool
    var edit: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: edit) {
            HStack(alignment: .center, spacing: 14) {
                icon.frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(automation.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.ink)
                        if selected { Chip(text: "Send to", color: Light.cyan, icon: "checkmark") }
                        ForEach(automation.voicePrefixes ?? [], id: \.self) { p in
                            Chip(text: "“\(p)”", color: Light.cyan, icon: "waveform")
                        }
                        if automation.sendsOffDevice { Chip(text: "Sends text off this Mac", color: Light.ochre, icon: "arrow.up.right") }
                    }
                    Text(automation.describe)
                        .font(.system(size: 12)).foregroundStyle(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Ink.tertiary)
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Ink.raised.opacity(hover ? 0.95 : 0.72)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(selected ? Light.cyan.opacity(0.4) : Ink.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel("\(automation.name). \(automation.describe). Edit")
    }

    private var symbolName: String {
        if let a = automation.actions?.first {
            switch a.kind {
            case .obsidian: return "doc.text"
            case .appleNote: return "note.text"
            case .reminder: return "checklist"
            case .claude: return "sparkle"
            }
        }
        switch automation.destination {
        case .tmux: return "terminal"
        case .focusedApp: return "text.cursor"
        case .clipboard: return "doc.on.clipboard"
        case .app: return "app"
        case .none: return automation.webhookURL != nil ? "arrow.up.right.square" : "chevron.left.forwardslash.chevron.right"
        }
    }

    private var icon: some View {
        Image(systemName: symbolName)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Ink.secondary)
            .frame(width: 32, height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Ink.ink.opacity(0.06)))
    }
}

extension View {
    /// Writing Tools would offer to rewrite a template — not what this field is for.
    @ViewBuilder func noWritingTools() -> some View {
        if #available(macOS 15.0, *) { self.writingToolsBehavior(.disabled) } else { self }
    }
}
