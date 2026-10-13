import MacrophoneKit
import SwiftUI

struct ProfilesPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: ProfileStore
    @ObservedObject var settings: Settings
    @State private var editing: Profile?
    @State private var gallery = false
    @State private var addingRule = false

    var body: some View {
        PanePage {
            HStack(alignment: .bottom, spacing: 10) {
                PaneHeader(title: "Profiles", subtitle: "Where a dictation goes and what happens next. Pick one under Send to on your iPhone, or start a dictation with its voice prefix.")
                Button { editing = Profile(name: "New profile") } label: { Label("New Profile", systemImage: "plus") }
                    .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: false))
                    .padding(.bottom, 2)
                Button { gallery = true } label: { Label("Add a Target…", systemImage: "scope") }
                    .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: true))
                    .padding(.bottom, 2)
            }

            VStack(spacing: 10) {
                ForEach(store.profiles) { p in
                    ProfileRow(profile: p, mode: settings.deliveryMode, edit: { editing = p })
                }
            }

            Text("Profiles show up under Send to on your iPhone whenever it's connected. A profile's cleanup level overrides the iPhone's setting.")
                .font(.system(size: 11.5)).foregroundStyle(Ink.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            rules
        }
        .onAppear {
            #if DEBUG
            switch ProcessInfo.processInfo.environment["MACROPHONE_SHOW"] {
            case "profile-editor", "profile-editor-terminal", "profile-editor-actions", "profile-editor-tmux":
                if editing == nil { editing = DebugHooks.profileForEditor(store) }
            case "target-gallery": gallery = true
            default: break
            }
            #endif
        }
        .sheet(item: $editing) { p in
            ProfileEditor(profile: p, isNew: !store.profiles.contains { $0.id == p.id }, store: store, settings: settings)
        }
        .sheet(isPresented: $gallery) {
            TargetGallery(store: store) { new in
                gallery = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { editing = new }
            }
        }
        .sheet(isPresented: $addingRule) {
            AppPickerSheet(title: "When this app is in front…", exclude: Set(settings.appRules.map(\.bundleID))) { app in
                let pick = store.profiles.first { !$0.isDefault } ?? store.defaultProfile
                settings.appRules.append(AppRule(bundleID: app.bundleID, appName: app.name, profileID: pick.id))
            }
        }
    }

    // MARK: Per-app rules

    private var rules: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("When an app is in front")
            Plate {
                PlateRow(title: "Pick the profile by the app you're using",
                         subtitle: "For dictations your iPhone sends on Automatic. A voice prefix or a profile you pick on the iPhone still wins.",
                         icon: "macwindow.on.rectangle", iconColor: Light.cyan) { EmptyView() }
                if !settings.appRules.isEmpty { PlateDivider() }
                ForEach($settings.appRules) { $rule in
                    HStack(spacing: 10) {
                        if let icon = InstalledApp.icon(for: rule.bundleID) {
                            Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                        } else {
                            Image(systemName: "app.dashed").frame(width: 22, height: 22).foregroundStyle(Ink.tertiary)
                        }
                        Text("When \(rule.appName) is in front, use")
                            .font(.system(size: 13)).foregroundStyle(Ink.ink)
                        Picker("", selection: $rule.profileID) {
                            ForEach(store.profiles) { p in Text(p.name).tag(p.id) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        if !store.profiles.contains(where: { $0.id == rule.profileID }) {
                            Text("profile deleted — uses the default").font(.system(size: 11)).foregroundStyle(Light.ochre)
                        }
                        Spacer()
                        Button { settings.appRules.removeAll { $0.id == rule.id } } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(Ink.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove this rule")
                        .accessibilityLabel("Remove the rule for \(rule.appName)")
                    }
                    .padding(.horizontal, 16).padding(.vertical, 7)
                }
                PlateDivider()
                HStack {
                    Button { addingRule = true } label: { Label("Add Rule…", systemImage: "plus") }
                        .buttonStyle(.borderless)
                    Spacer()
                    Text("Otherwise: \(store.defaultProfile.name)")
                        .font(.system(size: 11.5)).foregroundStyle(Ink.tertiary)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
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
                        ForEach(profile.voicePrefixes ?? [], id: \.self) { p in
                            Chip(text: "“\(p)”", color: Light.cyan, icon: "waveform")
                        }
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
        case .tmux: symbol("terminal")
        case .none: symbol((profile.actions ?? []).isEmpty ? "tray" : "square.and.arrow.down")
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

extension View {
    /// Writing Tools would offer to rewrite a template — not what this field is for.
    @ViewBuilder func noWritingTools() -> some View {
        if #available(macOS 15.0, *) { self.writingToolsBehavior(.disabled) } else { self }
    }
}
