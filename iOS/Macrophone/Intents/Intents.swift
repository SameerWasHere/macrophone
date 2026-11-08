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

/// Pastes text into a place on the Mac — an open app, Where I'm typing or the clipboard — and
/// presses send after pasting when asked. Runs without opening the app (Siri: "Send to Claude
/// with Macrophone" asks what to send); the text goes the way a dictation does, to the active
/// Mac, and waits in the queue when it can't be reached.
struct SendTextIntent: AppIntent {
    static var title: LocalizedStringResource { "Send Text" }
    static var description: IntentDescription? {
        // No "Mac" or the app's name in intent text (ITMS-90626).
        IntentDescription("Pastes the text into the place you pick — an open app on your computer, where you're typing, or its clipboard — and presses send if you ask. If your computer can't be reached it waits and goes later.",
                          categoryName: "Sending")
    }
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true),
               requestValueDialog: "What should I send?")
    var text: String

    @Parameter(title: "Send To", description: "Clipboard, Where I'm typing, or an open app on your computer. Leave empty for the one picked in the app.",
               requestValueDialog: "Where should it go?")
    var target: TargetEntity?

    @Parameter(title: "Send After Pasting", description: "Press the app's send key after pasting. Leave empty for what's set for that place in the app.")
    var sendAfterPasting: Bool?

    init() {}
    init(text: String, target: TargetEntity?, sendAfterPasting: Bool? = nil) {
        self.text = text
        self.target = target
        self.sendAfterPasting = sendAfterPasting
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Send \(\.$text) to \(\.$target)") { \.$sendAfterPasting }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let words = await IntentBridge.sendText(text, targetID: target?.id, name: target?.name, send: sendAfterPasting)
        return .result(dialog: IntentDialog(stringLiteral: words))
    }
}

/// Opens the app on a window of the Mac, live — an open app's, or the whole screen.
struct WatchPlaceIntent: AppIntent {
    static var title: LocalizedStringResource { "Watch" }
    static var description: IntentDescription? {
        IntentDescription("Opens the window you pick live — an open app on your computer, or its whole screen — and sends there.",
                          categoryName: "Watching")
    }
    static var openAppWhenRun: Bool { true }
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @Parameter(title: "Window", description: "An open app on your computer, or its whole screen. Leave empty for the one picked in the app.",
               optionsProvider: WatchPlaceOptions())
    var target: TargetEntity?

    init() {}
    init(target: TargetEntity?) { self.target = target }

    static var parameterSummary: some ParameterSummary {
        Summary("Watch \(\.$target)")
    }

    func perform() async throws -> some IntentResult {
        await IntentBridge.watch(targetID: target?.id, name: target?.name)
        return .result()
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
                        "Dictate to \(.applicationName)",
                        "Dictate to \(\.$target) with \(.applicationName)",
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
        // "Hey Siri, send to Claude with Macrophone": Siri asks what to send, and it goes.
        AppShortcut(intent: SendTextIntent(),
                    phrases: [
                        "Send to \(\.$target) with \(.applicationName)",
                        "Tell \(\.$target) with \(.applicationName)",
                        "Send text to \(\.$target) with \(.applicationName)",
                        "Send text with \(.applicationName)",
                    ],
                    shortTitle: "Send Text",
                    systemImageName: "paperplane")
        AppShortcut(intent: WatchPlaceIntent(),
                    phrases: [
                        "Watch \(\.$target) with \(.applicationName)",
                        "Show \(\.$target) with \(.applicationName)",
                        "Watch my Mac with \(.applicationName)",
                    ],
                    shortTitle: "Watch",
                    systemImageName: "eye")
        // What's in front on the Mac, live (Nov 7 2026, Shared/WatchFrontIntent.swift).
        AppShortcut(intent: WatchFrontIntent(),
                    phrases: [
                        "Watch what's in front with \(.applicationName)",
                        "Watch what's in front on my Mac with \(.applicationName)",
                        "Show what's on my Mac with \(.applicationName)",
                        "Pick up where my Mac is with \(.applicationName)",
                    ],
                    shortTitle: "What's in Front",
                    systemImageName: "macwindow.on.rectangle")
    }
}
