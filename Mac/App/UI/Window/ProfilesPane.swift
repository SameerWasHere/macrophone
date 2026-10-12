import MacrophoneKit
import SwiftUI

struct ProfilesPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: ProfileStore
    @ObservedObject var settings: Settings
    @State private var editing: Profile?

    var body: some View {
        PanePage {
            HStack(alignment: .bottom) {
                PaneHeader(title: "Profiles", subtitle: "A profile decides where a dictation goes and what happens next. Pick one on your iPhone before you speak.")
                Button {
                    editing = Profile(name: "New profile")
                } label: {
                    Label("New Profile", systemImage: "plus")
                }
                .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: true))
                .padding(.bottom, 2)
            }

            VStack(spacing: 10) {
                ForEach(store.profiles) { p in
                    ProfileRow(profile: p, mode: settings.deliveryMode, edit: { editing = p })
                }
            }

            Text("Profiles sync to your iPhone whenever it's connected. A profile's cleanup level overrides the iPhone's setting.")
                .font(.system(size: 11.5)).foregroundStyle(Ink.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.environment["MACROPHONE_SHOW"] == "profile-editor", editing == nil {
                editing = store.profiles.first { $0.name == "Claude prompt" } ?? store.profiles.first
            }
            #endif
        }
        .sheet(item: $editing) { p in
            ProfileEditor(profile: p, isNew: !store.profiles.contains { $0.id == p.id }, store: store, settings: settings)
        }
    }
}

struct ProfileRow: View {
    let profile: Profile
    let mode: DeliveryMode
    var edit: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: edit) {
            HStack(alignment: .center, spacing: 14) {
                destinationIcon
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(profile.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.ink)
                        if profile.isDefault { Chip(text: "Default", color: Light.teal) }
                        if profile.sendsOffDevice { Chip(text: "Sends text off this Mac", color: Light.ochre, icon: "arrow.up.right") }
                    }
                    Text(profile.describe(mode: mode))
                        .font(.system(size: 12)).foregroundStyle(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Ink.tertiary)
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Ink.raised.opacity(hover ? 0.95 : 0.72)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Ink.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel("\(profile.name). \(profile.describe(mode: mode)). Edit")
    }

    @ViewBuilder private var destinationIcon: some View {
        switch profile.destination {
        case .app(let id, _):
            if let icon = InstalledApp.icon(for: id) {
                Image(nsImage: icon).resizable().frame(width: 32, height: 32)
            } else { symbol("app.dashed") }
        case .focusedApp: symbol("text.cursor")
        case .clipboard: symbol(mode == .autoPaste ? "text.cursor" : "doc.on.clipboard")
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Ink.secondary)
            .frame(width: 32, height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Ink.ink.opacity(0.06)))
    }
}

/// Create or edit a profile.
struct ProfileEditor: View {
    @State var profile: Profile
    let isNew: Bool
    @ObservedObject var store: ProfileStore
    @ObservedObject var settings: Settings
    @Environment(\.dismiss) private var dismiss
    @State private var destinationKind = 0
    @State private var templateText = ""
    @State private var scriptText = ""
    @State private var webhookText = ""
    @State private var pickingApp = false
    @State private var confirmDelete = false

    init(profile: Profile, isNew: Bool, store: ProfileStore, settings: Settings) {
        _profile = State(initialValue: profile)
        self.isNew = isNew
        self.store = store
        self.settings = settings
        switch profile.destination {
        case .clipboard: _destinationKind = State(initialValue: 0)
        case .focusedApp: _destinationKind = State(initialValue: 1)
        case .app: _destinationKind = State(initialValue: 2)
        }
        _templateText = State(initialValue: profile.template ?? "")
        _scriptText = State(initialValue: profile.script ?? "")
        _webhookText = State(initialValue: profile.webhookURL?.absoluteString ?? "")
    }

    private var webhookValid: Bool {
        let t = webhookText.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return true }
        guard let u = URL(string: t), let s = u.scheme?.lowercased(), s == "https" || s == "http", u.host != nil else { return false }
        return true
    }

    private var pastes: Bool { destinationKind != 0 || settings.deliveryMode == .autoPaste }

    private var appName: String? {
        if case .app(_, let name) = profile.destination { return name }
        return nil
    }

    private var offDevice: Bool {
        !scriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !webhookText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(isNew ? "New Profile" : "Edit Profile").font(Typeface.serif(24)).foregroundStyle(Ink.ink)

                    field("Name") {
                        TextField("Profile name", text: $profile.name).textFieldStyle(.roundedBorder)
                    }

                    field("Cleanup", note: "Overrides the iPhone's own setting when this profile is chosen.") {
                        Picker("", selection: $profile.cleanupLevel) {
                            Text("Use the iPhone's setting").tag(CleanupLevel?.none)
                            ForEach(CleanupLevel.allCases) { l in Text(l.title).tag(CleanupLevel?.some(l)) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }

                    field("Where it goes") {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("", selection: $destinationKind) {
                                Text("As set in Delivery (\(settings.deliveryMode.title))").tag(0)
                                Text("Paste into the app you're using").tag(1)
                                Text("Paste into a specific app").tag(2)
                            }
                            .pickerStyle(.radioGroup)
                            .labelsHidden()
                            if destinationKind == 2 {
                                HStack(spacing: 10) {
                                    if case .app(let id, let name) = profile.destination {
                                        if let icon = InstalledApp.icon(for: id) { Image(nsImage: icon).resizable().frame(width: 22, height: 22) }
                                        Text(name).font(.system(size: 13, weight: .medium)).foregroundStyle(Ink.ink)
                                    } else {
                                        Text("No app chosen").font(.system(size: 13)).foregroundStyle(Ink.tertiary)
                                    }
                                    Button(appName == nil ? "Choose App…" : "Change…") { pickingApp = true }
                                }
                                .padding(.leading, 20)
                                Text("Macrophone brings it to the front, then pastes.")
                                    .font(.system(size: 11.5)).foregroundStyle(Ink.tertiary).padding(.leading, 20)
                            }
                        }
                    }

                    field("Then") {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("Press Return after pasting", isOn: $profile.pressEnter)
                                .disabled(!pastes)
                            Text(pastes
                                 ? "Only in apps on your Return list (Delivery). Never for delayed dictations. You always get a 2.5-second countdown to cancel."
                                 : "Available when this profile pastes.")
                                .font(.system(size: 11.5)).foregroundStyle(Ink.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    field("Template", note: "Wraps the dictation. {{text}} is replaced with what you said.") {
                        TextEditor(text: $templateText)
                            .font(Typeface.mono(12, .regular))
                            .noWritingTools()
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .frame(height: 70)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Ink.sunk))
                            .overlay(alignment: .topLeading) {
                                if templateText.isEmpty {
                                    Text("You are a careful code reviewer. {{text}}")
                                        .font(Typeface.mono(12, .regular)).foregroundStyle(Ink.tertiary.opacity(0.7))
                                        .padding(.horizontal, 11).padding(.vertical, 6)
                                        .allowsHitTesting(false)
                                }
                            }
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Ink.line, lineWidth: 1))
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 8) {
                            Kicker("Automations")
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

                    Toggle("Use this profile when the iPhone doesn't pick one", isOn: $profile.isDefault)
                        .disabled(profile.isDefault && !isNew && store.profiles.first(where: \.isDefault)?.id == profile.id)
                }
                .padding(24)
            }
            Rectangle().fill(Ink.line).frame(height: 1)
            HStack {
                if !isNew {
                    Button("Delete Profile…", role: .destructive) { confirmDelete = true }
                        .foregroundStyle(Light.rose)
                        .confirmationDialog("Delete \(profile.name)?", isPresented: $confirmDelete) {
                            Button("Delete", role: .destructive) { store.delete(profile.id); dismiss() }
                        }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add Profile" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!webhookValid || (destinationKind == 2 && appName == nil) || profile.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 520, height: 580)
        .background(Ink.ground)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $pickingApp) {
            AppPickerSheet(title: "Paste into…") { app in
                profile.destination = .app(bundleID: app.bundleID, name: app.name)
            }
        }
    }

    private func save() {
        switch destinationKind {
        case 0: profile.destination = .clipboard
        case 1: profile.destination = .focusedApp
        default: break
        }
        if !pastes { profile.pressEnter = false }
        let t = templateText.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.template = t.isEmpty ? nil : templateText
        let s = scriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.script = s.isEmpty ? nil : s
        let w = webhookText.trimmingCharacters(in: .whitespaces)
        profile.webhookURL = w.isEmpty ? nil : URL(string: w)
        store.upsert(profile)
        dismiss()
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

extension View {
    /// Writing Tools would offer to rewrite a template — not what this field is for.
    @ViewBuilder func noWritingTools() -> some View {
        if #available(macOS 15.0, *) { self.writingToolsBehavior(.disabled) } else { self }
    }
}
