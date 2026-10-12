import AppIntents
import SwiftUI
import WidgetKit

/// Control Center, the Lock Screen and the Action Button: one button that opens Macrophone
/// already recording. Each control can be set to a target ("Dictate to Claude") or left on
/// the app's own choice ("Dictate to Mac").
struct StartDictationControl: ControlWidget {
    static let kind = "com.sameer.macrophone.controls.start"

    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: Self.kind, intent: DictateControlConfiguration.self) { config in
            ControlWidgetButton(action: StartDictationIntent(profile: config.profile)) {
                Label(title(config.profile), systemImage: "mic.fill")
            }
        }
        .displayName("Dictate to Mac")
        .description("Opens Macrophone already listening. Choose a target to send straight to it.")
    }

    private func title(_ p: ProfileEntity?) -> String {
        guard let p else { return "Dictate to Mac" }
        return p.isAutomatic ? "Dictate · Automatic" : "Dictate to \(p.name)"
    }
}

@main
struct MacrophoneControlsBundle: WidgetBundle {
    var body: some Widget {
        StartDictationControl()
    }
}
