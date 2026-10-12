import SwiftUI
import UserNotifications

struct DeliveryPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: Settings
    @ObservedObject var notifier: Notifier
    @State private var addingApp = false

    var body: some View {
        PanePage {
            PaneHeader(title: "Delivery", subtitle: "What happens when a dictation arrives. A profile can send it somewhere specific instead.")

            VStack(spacing: 10) {
                ForEach(DeliveryMode.allCases) { m in
                    ModeCard(mode: m, selected: settings.deliveryMode == m) { choose(m) }
                }
            }

            permissions

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Return list")
                Plate {
                    PlateRow(title: "Apps where Return can be pressed",
                             subtitle: "A profile set to press Return only does it in these apps. Everywhere else it pastes and stops.") {
                        EmptyView()
                    }
                    PlateDivider()
                    if settings.enterAllowlist.isEmpty {
                        Text("No apps — Return is never pressed.")
                            .font(.system(size: 12)).foregroundStyle(Ink.tertiary)
                            .padding(.horizontal, 16).padding(.vertical, 12)
                    }
                    ForEach(settings.enterAllowlist) { app in
                        HStack(spacing: 10) {
                            if let icon = InstalledApp.icon(for: app.bundleID) {
                                Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                            } else {
                                Image(systemName: "app.dashed").frame(width: 20, height: 20).foregroundStyle(Ink.tertiary)
                            }
                            Text(app.name).font(.system(size: 13)).foregroundStyle(Ink.ink)
                            if InstalledApp.icon(for: app.bundleID) == nil {
                                Text("not installed").font(.system(size: 11)).foregroundStyle(Ink.tertiary)
                            }
                            Spacer()
                            Button {
                                settings.enterAllowlist.removeAll { $0.bundleID == app.bundleID }
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(Ink.tertiary)
                            }
                            .buttonStyle(.plain)
                            .help("Remove \(app.name)")
                            .accessibilityLabel("Remove \(app.name)")
                        }
                        .padding(.horizontal, 16).padding(.vertical, 7)
                    }
                    PlateDivider()
                    HStack {
                        Button { addingApp = true } label: { Label("Add App…", systemImage: "plus") }
                            .buttonStyle(.borderless)
                        Spacer()
                        Button("Restore Defaults") { settings.enterAllowlist = Settings.defaultAllowlist }
                            .buttonStyle(.borderless)
                            .foregroundStyle(Ink.secondary)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Always on")
                Plate {
                    safety("timer", "A 2.5-second countdown before anything is pasted", "Cancel it in the popup. Hovering pauses it.")
                    PlateDivider(inset: 50)
                    safety("lock.shield", "Never into a password field", "If a password field or Secure Keyboard Entry is active, it's copied instead.")
                    PlateDivider(inset: 50)
                    safety("clock.arrow.circlepath", "Delayed dictations are only copied", "Anything your iPhone queued while your Mac was away is never pasted or sent on its own.")
                    PlateDivider(inset: 50)
                    safety("arrow.uturn.backward", "Your clipboard comes back", "After a paste, whatever you had copied is put back. Clipboard managers skip the dictation.")
                }
            }
        }
        .sheet(isPresented: $addingApp) {
            AppPickerSheet(title: "Allow Return in…", exclude: Set(settings.enterAllowlist.map(\.bundleID))) { app in
                settings.enterAllowlist.append(AllowedApp(bundleID: app.bundleID, name: app.name))
            }
        }
    }

    private func choose(_ m: DeliveryMode) {
        if m == .autoPaste && !Paster.isTrusted { Paster.requestTrust() }
        settings.deliveryMode = m
    }

    @ViewBuilder private var permissions: some View {
        let needsAX = settings.deliveryMode == .autoPaste || model.profiles.profiles.contains { $0.pastes(mode: settings.deliveryMode) }
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Permissions")
            Plate {
                PlateRow(title: "Accessibility",
                         subtitle: model.accessibilityGranted
                            ? "Allowed. Macrophone can paste and press Return for you."
                            : (needsAX ? "Needed to paste. Until it's on, dictations are copied and you'll see why in the popup."
                                       : "Only needed for pasting. Not needed for the clipboard modes."),
                         subtitleColor: !model.accessibilityGranted && needsAX ? Light.ochre : Ink.tertiary,
                         icon: model.accessibilityGranted ? "checkmark.circle.fill" : "hand.raised",
                         iconColor: model.accessibilityGranted ? Light.mint : (needsAX ? Light.ochre : Ink.tertiary)) {
                    if !model.accessibilityGranted {
                        Button("Open System Settings") {
                            Paster.requestTrust()
                            NSWorkspace.shared.open(Paster.accessibilitySettingsURL)
                        }
                        .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: needsAX))
                    }
                }
                PlateDivider(inset: 50)
                PlateRow(title: "Notifications",
                         subtitle: notificationLine,
                         icon: notifier.status == .authorized || notifier.status == .provisional ? "checkmark.circle.fill" : "bell",
                         iconColor: notifier.status == .authorized || notifier.status == .provisional ? Light.mint : Ink.tertiary) {
                    if notifier.status == .denied {
                        Button("Open System Settings") { NSWorkspace.shared.open(Paster.notificationSettingsURL) }
                            .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: false))
                    } else if notifier.status == .notDetermined {
                        Button("Allow…") { notifier.requestIfNeeded() }
                            .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: false))
                    }
                }
            }
        }
    }

    private var notificationLine: String {
        switch notifier.status {
        case .authorized, .provisional, .ephemeral:
            return "On. If your Mac is locked when something arrives, it's waiting in Notification Center."
        case .denied:
            return "Off in System Settings. The popup still shows while you're at your Mac."
        default:
            return "Asked the first time something arrives — for dictations that land while your Mac is locked."
        }
    }

    private func safety(_ symbol: String, _ title: String, _ line: String) -> some View {
        PlateRow(title: title, subtitle: line, icon: symbol, iconColor: Light.teal)
    }
}

struct ModeCard: View {
    let mode: DeliveryMode
    let selected: Bool
    var choose: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: choose) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle().strokeBorder(selected ? Light.teal : Ink.lineHeavy, lineWidth: selected ? 5 : 1.2)
                        .frame(width: 18, height: 18)
                }
                .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(mode.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.ink)
                        if mode == .clipboardNotify { Chip(text: "Default", color: Ink.tertiary) }
                        if mode == .autoPaste { Chip(text: "Needs Accessibility", color: Ink.tertiary) }
                    }
                    Text(mode.summary).font(.system(size: 12.5)).foregroundStyle(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: mode.symbol)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(selected ? Light.teal : Ink.tertiary)
                    .frame(width: 28)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(selected ? Light.teal.opacity(0.08) : Ink.raised.opacity(hover ? 0.95 : 0.72)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? Light.teal.opacity(0.45) : Ink.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
