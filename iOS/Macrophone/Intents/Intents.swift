import AppIntents
import Foundation

/// Opens Macrophone, records until you stop, and hands the text back to your shortcut.
struct DictateTextIntent: AppIntent {
    static var title: LocalizedStringResource { "Dictate Text" }
    static var description: IntentDescription? {
        IntentDescription("Listens, and when you tap stop passes the text — cleaned up if cleanup is on — to the next action. It's also sent on to your computer as usual.",
                          categoryName: "Dictation")
    }
    static var openAppWhenRun: Bool { true }
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.immediate) }

    init() {}

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let text = await IntentBridge.dictate(), !text.isEmpty else {
            throw DictationIntentError.nothingHeard
        }
        return .result(value: text)
    }
}

enum DictationIntentError: Error, CustomLocalizedStringResourceConvertible {
    case nothingHeard

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .nothingHeard: return "Macrophone didn't hear anything. Check that the microphone is allowed, then try again."
        }
    }
}

struct MacrophoneShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor { .navy }

    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartDictationIntent(),
                    phrases: [
                        "Dictate with \(.applicationName)",
                        "Start \(.applicationName)",
                        "Start dictating in \(.applicationName)",
                        "Talk to my Mac with \(.applicationName)",
                        "Dictate to \(\.$target) with \(.applicationName)",
                        "Send to \(\.$target) with \(.applicationName)",
                        "Dictate into \(\.$target) with \(.applicationName)",
                    ],
                    shortTitle: "Start Dictation",
                    systemImageName: "mic.fill")
        AppShortcut(intent: DictateTextIntent(),
                    phrases: [
                        "Get text from \(.applicationName)",
                        "Transcribe with \(.applicationName)",
                    ],
                    shortTitle: "Dictate Text",
                    systemImageName: "text.bubble")
    }
}
