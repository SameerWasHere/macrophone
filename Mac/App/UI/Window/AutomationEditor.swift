import AppKit
import MacrophoneKit
import SwiftUI

/// Create or edit an automation: where the words go, how they're shaped, and what else happens.
struct AutomationEditor: View {
    @State var profile: Profile
    let isNew: Bool
    @ObservedObject var store: AutomationStore
    @ObservedObject var settings: Settings
    @Environment(\.dismiss) private var dismiss

    enum Where: Int { case copy, focused, tmux, nowhere }
    @State private var whereTo: Where
    @State private var templateText: String
    @State private var scriptText: String
    @State private var webhookText: String
    @State private var tmuxTarget: String
    @State private var prefixes: [String]
    @State private var prefixDraft = ""
    @State private var actions: [ProfileAction]
    @State private var confirmDelete = false

    init(profile: Profile, isNew: Bool, store: AutomationStore, settings: Settings) {
        _profile = State(initialValue: profile)
        self.isNew = isNew
        self.store = store
        self.settings = settings
        let w: Where
        switch profile.destination {
        case .clipboard, .app: w = .copy
        case .focusedApp: w = .focused
        case .tmux: w = .tmux
        case .none: w = .nowhere
        }
        _whereTo = State(initialValue: w)
        _templateText = State(initialValue: profile.template ?? "")
        _scriptText = State(initialValue: profile.script ?? "")
        _webhookText = State(initialValue: profile.webhookURL?.absoluteString ?? "")
        if case .tmux(let t) = profile.destination { _tmuxTarget = State(initialValue: t) } else { _tmuxTarget = State(initialValue: "") }
        _prefixes = State(initialValue: profile.voicePrefixes ?? [])
        _actions = State(initialValue: profile.actions ?? [])
    }

    // MARK: Derived

    private var pastes: Bool {
        switch whereTo {
        case .focused, .tmux: return true
        case .copy, .nowhere: return false
        }
    }
    private var webhookValid: Bool {
        let t = webhookText.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return true }
        guard let u = URL(string: t), let s = u.scheme?.lowercased(), s == "https" || s == "http", u.host != nil else { return false }
        return true
    }
    private var offDevice: Bool {
        !scriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !webhookText.trimmingCharacters(in: .whitespaces).isEmpty
    }
    private var canSave: Bool {
        webhookValid && !profile.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !(whereTo == .tmux && tmuxTarget.trimmingCharacters(in: .whitespaces).isEmpty)
            && actionsValid
    }
    private var actionsValid: Bool {
        actions.allSatisfy { a in
            if case .obsidian(let vault, _, _, _) = a.kind { return !vault.isEmpty }
            return true
        }
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(isNew ? "New Automation" : "Edit Automation").font(Typeface.serif(24)).foregroundStyle(Ink.ink)

                    field("Name") {
                        TextField("Automation name", text: $profile.name).textFieldStyle(.roundedBorder)
                    }

                    field("Voice prefix", note: "Start a dictation with one of these and a pause — “\(prefixes.first ?? "note"), call the dentist tomorrow” — to use this automation for that one. Your iPhone takes the words off.") {
                        ChipField(items: $prefixes, draft: $prefixDraft, placeholder: "Type a word, press Return")
                    }

                    field("Cleanup", note: "Overrides the iPhone's own setting when this automation is used.") {
                        Picker("", selection: $profile.cleanupLevel) {
                            Text("Use the iPhone's setting").tag(CleanupLevel?.none)
                            ForEach(CleanupLevel.allCases) { l in Text(l.title).tag(CleanupLevel?.some(l)) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }

                    section("Where it goes") { destination }.id("where")
                    if pastes { section("Then") { thenSection }.id("then") }
                    section("Shape the text") { shapeSection }.id("shape")
                    section("Also") { ActionsEditor(actions: $actions) }.id("also")
                    automations.id("automations")
                }
                .padding(24)
            }
            .onAppear {
                #if DEBUG
                // Screenshots: MACROPHONE_EDITOR_SCROLL=where|then|shape|also|automations
                if let id = ProcessInfo.processInfo.environment["MACROPHONE_EDITOR_SCROLL"] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { proxy.scrollTo(id, anchor: .top) }
                }
                #endif
            }
            }
            Rectangle().fill(Ink.line).frame(height: 1)
            HStack {
                if !isNew {
                    Button("Delete Automation…", role: .destructive) { confirmDelete = true }
                        .buttonStyle(PillButtonStyle(tint: Light.rose, filled: false))
                        .confirmationDialog("Delete \(profile.name)?", isPresented: $confirmDelete) {
                            Button("Delete", role: .destructive) { store.delete(profile.id); dismiss() }
                        }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add Automation" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(16)
        }
        .frame(width: 600, height: 640)
        .background(Ink.ground)
        .preferredColorScheme(.dark)
    }

    // MARK: Where it goes

    @ViewBuilder private var destination: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $whereTo) {
                Text("Copy it to the clipboard").tag(Where.copy)
                Text("Paste it where I'm typing").tag(Where.focused)
                Text("Type it into a tmux pane").tag(Where.tmux)
                Text("Nowhere — only do what's under “Also”").tag(Where.nowhere)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            switch whereTo {
            case .tmux: TmuxPanePicker(target: $tmuxTarget).padding(.leading, 20)
            case .nowhere:
                Text("Nothing is pasted or copied. Add a note, reminder or Claude below.")
                    .font(.system(size: 11.5)).foregroundStyle(Ink.tertiary).padding(.leading, 20)
            default: EmptyView()
            }
        }
    }

    // MARK: Then

    @ViewBuilder private var thenSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(whereTo == .tmux ? "Press Return after typing" : "Send it — press the app's send key after pasting", isOn: $profile.pressEnter)
            Text("You get a 2.5-second countdown to cancel. Never into a password field, never for delayed dictations.")
                .font(.system(size: 11.5)).foregroundStyle(Ink.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Shape

    @ViewBuilder private var shapeSection: some View {
        let format = profile.outputFormat ?? .plain
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text("Format").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.secondary)
                    Picker("", selection: Binding(get: { format }, set: { profile.outputFormat = $0 == .plain ? nil : $0 })) {
                        ForEach(OutputFormat.allCases) { f in Text(f.title).tag(f) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Text(format.summary).font(.system(size: 11.5)).foregroundStyle(Ink.tertiary)
                if format != .plain {
                    Text(format.apply("Fix the login bug.\nThen add a test for it."))
                        .font(Typeface.mono(11.5, .regular))
                        .foregroundStyle(Ink.secondary)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Ink.ink.opacity(0.035)))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Ink.line, lineWidth: 1))
                        .accessibilityLabel("Preview of the \(format.title) format")
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Template").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.secondary)
                Text("Wraps what you said. {{text}} is your dictation; the other variables fill in when it arrives.")
                    .font(.system(size: 11.5)).foregroundStyle(Ink.tertiary)
                TemplateEditor(text: $templateText, placeholder: "You are a careful code reviewer. {{text}}",
                               sampleText: format.apply(ContextGatherer.samples["text"]!))
            }
            if !settings.snippets.isEmpty {
                Text(settings.snippets.count == 1 ? "Your snippet expands first, then the format, then the template."
                     : "Your \(settings.snippets.count) snippets expand first, then the format, then the template.")
                    .font(.system(size: 11.5)).foregroundStyle(Ink.tertiary)
            }
        }
    }

    // MARK: Script and webhook

    private var automations: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Kicker("Script and webhook")
                if offDevice { Chip(text: "Sends text off this Mac", color: Light.ochre, icon: "arrow.up.right") }
            }
            Text("These can send what you dictate beyond this Mac. Only add ones you trust.")
                .font(.system(size: 11.5)).foregroundStyle(Ink.tertiary)
            field("Run a script", note: "Runs with zsh. The text arrives on stdin and in $MACROPHONE_TEXT. 30-second limit.") {
                TextField("e.g. tee -a ~/notes.md", text: $scriptText)
                    .font(Typeface.mono(12, .regular))
                    .textFieldStyle(.roundedBorder)
            }
            field("Webhook", note: webhookValid ? "Each dictation is POSTed as JSON to this URL." : "Enter a full http:// or https:// address.") {
                TextField("https://hooks.example.com/…", text: $webhookText)
                    .font(Typeface.mono(12, .regular))
                    .textFieldStyle(.roundedBorder)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Light.ochre.opacity(offDevice ? 0.06 : 0.0)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(offDevice ? Light.ochre.opacity(0.25) : Ink.line, lineWidth: 1))
    }

    // MARK: Save

    private func save() {
        switch whereTo {
        case .copy: profile.destination = .clipboard
        case .focused: profile.destination = .focusedApp
        case .tmux: profile.destination = .tmux(target: tmuxTarget.trimmingCharacters(in: .whitespaces))
        case .nowhere: profile.destination = .none
        }
        if !pastes { profile.pressEnter = false }
        let t = templateText.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.template = t.isEmpty ? nil : templateText
        let s = scriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.script = s.isEmpty ? nil : s
        let w = webhookText.trimmingCharacters(in: .whitespaces)
        profile.webhookURL = w.isEmpty ? nil : URL(string: w)
        profile.windowMatch = nil
        var ps = prefixes
        let d = prefixDraft.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if !d.isEmpty, !ps.contains(where: { $0.lowercased() == d.lowercased() }) { ps.append(d) }
        profile.voicePrefixes = ps.isEmpty ? nil : ps
        profile.actions = actions.isEmpty ? nil : actions
        store.upsert(profile)
        dismiss()
    }

    // MARK: Layout helpers

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Kicker(title)
            content()
        }
    }

    private func field<C: View>(_ title: String, note: String? = nil, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.secondary)
            content()
            if let note {
                Text(note).font(.system(size: 11.5)).foregroundStyle(Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// "Allow Macrophone to control Terminal" — asked only from here, never by surprise.
struct AutomationPermissionRow: View {
    let bundleID: String
    let appName: String
    let why: String
    @State private var state: Scripting.Permission?
    @State private var asking = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: state == .granted ? "checkmark.circle.fill" : "lock")
                .foregroundStyle(state == .granted ? Light.mint : (state == .denied ? Light.ochre : Ink.tertiary))
                .font(.system(size: 13))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(state == .granted ? "Allowed to control \(appName)" : "Automation for \(appName)")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Ink.ink)
                Text(state == .denied ? "Turned off in System Settings › Privacy & Security › Automation. Titles still work." : why)
                    .font(.system(size: 11.5)).foregroundStyle(Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if state == .denied {
                Button("Open System Settings") { NSWorkspace.shared.open(Scripting.automationSettingsURL) }
                    .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: false))
            } else if state != .granted {
                Button(asking ? "Asking…" : "Allow…") {
                    asking = true
                    Task { state = await Scripting.requestPermission(bundleID); asking = false }
                }
                .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: false))
                .disabled(asking)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Ink.ink.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Ink.line, lineWidth: 1))
        .task(id: bundleID) { state = await Scripting.permissionAsync(bundleID, ask: false) }
    }
}

/// Picks a tmux pane from the running server, or takes one typed by hand.
struct TmuxPanePicker: View {
    @Binding var target: String
    @State private var panes: [Tmux.Pane] = []
    @State private var installed = true
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !installed {
                Label("tmux isn't installed. Install it with Homebrew: brew install tmux", systemImage: "exclamationmark.circle")
                    .font(.system(size: 11.5)).foregroundStyle(Light.ochre)
            } else if panes.isEmpty && !loading {
                Text("No tmux sessions are running. Start one, then Refresh — or type a pane below.")
                    .font(.system(size: 11.5)).foregroundStyle(Ink.tertiary)
            }
            if !panes.isEmpty {
                VStack(spacing: 0) {
                    ForEach(panes) { p in
                        Button { target = p.target } label: {
                            HStack(spacing: 10) {
                                Image(systemName: target == p.target ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(target == p.target ? Light.teal : Ink.tertiary)
                                Text(p.target).font(Typeface.mono(12, .semibold)).foregroundStyle(Ink.ink)
                                Text(p.command).font(.system(size: 12)).foregroundStyle(Ink.secondary)
                                Text(p.shortPath).font(.system(size: 11.5)).foregroundStyle(Ink.tertiary)
                                Spacer()
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Ink.sunk))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Ink.line, lineWidth: 1))
            }
            HStack(spacing: 8) {
                TextField("session:window.pane, e.g. work:1.0", text: $target)
                    .font(Typeface.mono(12, .regular))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Button("Refresh") { load() }
            }
            Text("Types into the pane whatever app is in front — even with the terminal hidden. Several lines go in as one paste.")
                .font(.system(size: 11.5)).foregroundStyle(Ink.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear(perform: load)
    }

    private func load() {
        loading = true
        Task {
            let (exe, list) = await Task.detached { () -> (String?, [Tmux.Pane]) in
                Tmux.forgetLocation()
                return (Tmux.executable, Tmux.panes())
            }.value
            installed = exe != nil
            panes = list
            loading = false
        }
    }
}
