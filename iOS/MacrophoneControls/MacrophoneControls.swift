import AppIntents
import SwiftUI
import WidgetKit

/// Control Center, the Lock Screen and the Action Button: one button that opens Macrophone
/// already recording. Each control can be set to a place — Clipboard, Where I'm typing, an app
/// open on the Mac ("Dictate to Messages") or an automation — or left on the app's own choice.
struct StartDictationControl: ControlWidget {
    static let kind = "com.sameer.macrophone.controls.start"

    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: Self.kind, intent: DictateControlConfiguration.self) { config in
            ControlWidgetButton(action: StartDictationIntent(target: config.target)) {
                Label(title(config.target), systemImage: "mic.fill")
            }
        }
        .displayName("Dictate to Mac")
        .description("Opens Macrophone already listening. Choose where it goes to send straight there.")
    }

    private func title(_ t: TargetEntity?) -> String {
        guard let t else { return "Dictate to Mac" }
        switch t.id {
        case TargetEntity.clipboardID: return "Dictate to Clipboard"
        case TargetEntity.frontID: return "Dictate where I'm typing"
        default: return "Dictate to \(t.name)"
        }
    }
}

@main
struct MacrophoneControlsBundle: WidgetBundle {
    var body: some Widget {
        StartDictationControl()
    }
}
