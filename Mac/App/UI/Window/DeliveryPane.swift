import SwiftUI
import UserNotifications

struct DeliveryPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: Settings
    @ObservedObject var notifier: Notifier

    var body: some View {
        PanePage {
            PaneHeader(title: "Delivery", subtitle: "Where dictations go is one choice, shared with your iPhone. Every app open on this Mac with somewhere to type is on the list — nothing to set up.")

            SendToCard(model: model, settings: settings, automations: model.automations)

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Clipboard")
                Plate {
                    PlateRow(title: "Show a notification",
                             subtitle: settings.clipboardNotification
                                ? "When Send to is Clipboard, a popup shows what arrived — and Notification Center keeps it if you're away from your Mac."
                                : "Off: it's copied silently and the menu bar icon ticks.",
                             icon: "bell.badge", iconColor: Light.teal) {
                        Toggle("", isOn: $settings.clipboardNotification)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .accessibilityLabel("Show a notification")
                    }
                }
            }

            permissions

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Always on")
                Plate {
                    safety("timer", "A 2.5-second countdown before anything is pasted or sent", "Cancel it in the popup. Hovering pauses it.")
                    PlateDivider(inset: 50)
                    safety("paperplane", "It's only sent when you choose Paste & send", "Otherwise it's pasted and waits for you. Your choice on the iPhone (or here) is what says it may send.")
                    PlateDivider(inset: 50)
                    safety("lock.shield", "Never into a password field", "If a password field or Secure Keyboard Entry is active, it's copied instead.")
                    PlateDivider(inset: 50)
                    safety("clock.arrow.circlepath", "Delayed dictations are only copied", "Anything your iPhone queued while your Mac was away is never pasted or sent on its own.")
                    PlateDivider(inset: 50)
                    safety("arrow.uturn.backward", "Your clipboard comes back", "After a paste, whatever you had copied is put back. Clipboard managers skip the dictation.")
                    PlateDivider(inset: 50)
                    safety("questionmark.app.dashed", "If the app isn't there, it's copied", "An app that's quit or a window that's closed gets nothing typed into it — the popup says so and it's on your clipboard.")
                }
            }
        }
    }

    @ViewBuilder private var permissions: some View {
        let needsAX: Bool = {
            switch settings.selection.target {
            case .frontApp, .app: return true
            case .clipboard, .automation: return false
            }
        }()
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Permissions")
            Plate {
                PlateRow(title: "Accessibility",
                         subtitle: model.accessibilityGranted
                            ? "Allowed. Macrophone can see which apps have somewhere to type, paste, and press send for you."
                            : (needsAX ? "Needed to paste. Until it's on, dictations are copied and you'll see why in the popup."
                                       : "Needed to list the apps you can send to and to paste. Not needed for the clipboard."),
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
            return "Macrophone asks once your first dictation has arrived. Then anything that lands while your Mac is locked waits in Notification Center."
        }
    }

    private func safety(_ symbol: String, _ title: String, _ line: String) -> some View {
        PlateRow(title: title, subtitle: line, icon: symbol, iconColor: Light.teal)
    }
}
