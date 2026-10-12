import AppIntents
import SwiftUI
import WidgetKit

/// Control Center and Lock Screen: one button that opens Macrophone already recording.
struct StartDictationControl: ControlWidget {
    static let kind = "com.sameer.macrophone.controls.start"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: StartDictationIntent()) {
                Label("Dictate to Mac", systemImage: "mic.fill")
            }
        }
        .displayName("Dictate to Mac")
        .description("Opens Macrophone already listening.")
    }
}

@main
struct MacrophoneControlsBundle: WidgetBundle {
    var body: some Widget {
        StartDictationControl()
    }
}
