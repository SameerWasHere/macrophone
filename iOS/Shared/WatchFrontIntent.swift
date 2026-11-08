import AppIntents
import SwiftUI
import WidgetKit

/// What's in front on your Mac, one tap away (Nov 7 2026): opens Macrophone, waits for the Mac and
/// watches the window in front on it at that moment (Model/FrontWindowHere.swift). Siri and
/// Shortcuts run it, and so does the Control Center / Lock Screen control below. Compiled into
/// the control's extension too, where only the app does the watching.
struct WatchFrontIntent: AppIntent {
    // No "Mac" or the app's name in intent text: App Store processing rejects it (ITMS-90626).
    static var title: LocalizedStringResource { "Watch What's in Front" }
    static var description: IntentDescription? {
        IntentDescription("Opens the window that's in front on your computer right now, live — to look, click and type into it from here.",
                          categoryName: "Watching")
    }
    static var openAppWhenRun: Bool { true }
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.immediate) }

    init() {}

    func perform() async throws -> some IntentResult {
        #if MACROPHONE_APP
        await IntentBridge.watchFront()
        #endif
        return .result()
    }
}

/// Control Center, the Lock Screen and the Action Button: the window in front on the Mac, live.
@available(iOS 18.0, *)
struct WatchFrontControl: ControlWidget {
    static let kind = "com.sameer.macrophone.controls.front"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: WatchFrontIntent()) {
                Label("What's in Front", systemImage: "macwindow.on.rectangle")
            }
        }
        .displayName("Watch What's in Front")
        .description("Opens the window in front on your Mac, live.")
    }
}
