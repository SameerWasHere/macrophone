#if DEBUG
import Foundation
import MacrophoneKit
import SwiftUI

/// Launch hooks for driving screens headlessly. DEBUG builds only. Pass them with
/// `SIMCTL_CHILD_<NAME>=… xcrun simctl launch <udid> com.sameer.macrophone`.
///
/// MACROPHONE_RESET=1                         clear settings, history, queue (not pairings)
/// MACROPHONE_SCREEN=onboarding|main|history|settings|pairing|dictionary|language|diagnostics
/// MACROPHONE_ONBOARDING_STEP=0…6             which setup step to open on
/// MACROPHONE_FAKE_TRANSCRIPT=<text>          a finished dictation, as if spoken (cleanup + delivery run)
/// MACROPHONE_FAKE_EARLY=1                    …marked "stopped early"
/// MACROPHONE_FAKE_RECORDING=<text>           the live recording screen, words appearing
/// MACROPHONE_FAKE_HISTORY=1                  four sample history items
/// MACROPHONE_FAKE_PAIRED=<Mac name>          looks paired + connected with three profiles (screens only)
/// MACROPHONE_STATUS=queued|delivered|failed|sending|copied
/// MACROPHONE_DICTIONARY=a,b,c                dictionary words
/// MACROPHONE_LANGUAGE=<id>                   recognizer language
/// MACROPHONE_OPEN_URL=<url>                  handled exactly like onOpenURL (simctl openurl asks "Open in…?" first)
/// MACROPHONE_PAIR_CODE=1                     code pairing with the first Mac found
enum DebugHooks {
    static let env = ProcessInfo.processInfo.environment

    /// Runs before the model exists.
    static func early() {
        let d = UserDefaults.standard
        if env["MACROPHONE_RESET"] == "1" {
            for key in d.dictionaryRepresentation().keys where key.hasPrefix("settings.") || key.hasPrefix("onboarding.") || key.hasPrefix("link.") {
                d.removeObject(forKey: key)
            }
            try? FileManager.default.removeItem(at: AppFiles.history)
            try? FileManager.default.removeItem(at: AppFiles.queue)
            try? FileManager.default.removeItem(at: AppFiles.log)
        }
        if let screen = env["MACROPHONE_SCREEN"] {
            d.set(screen != "onboarding", forKey: "onboarding.done")
            if screen != "onboarding" { d.set(true, forKey: "link.networkExplained") }
        }
        if let s = env["MACROPHONE_ONBOARDING_STEP"].flatMap(Int.init) {
            d.set(s, forKey: "onboarding.step")
            d.set(false, forKey: "onboarding.done")
        }
        if let words = env["MACROPHONE_DICTIONARY"] {
            d.set(DictionaryPass.normalize(words.split(separator: ",").map(String.init)), forKey: Settings.K.dictionary)
        }
        if let lang = env["MACROPHONE_LANGUAGE"] { d.set(lang, forKey: Settings.K.language) }
    }

    static var settingsPath: [SettingsRoute] {
        switch env["MACROPHONE_SCREEN"] {
        case "dictionary": return [.dictionary]
        case "language": return [.language]
        case "diagnostics": return [.diagnostics]
        default: return []
        }
    }

    @MainActor static func apply(_ model: AppModel) {
        if env["MACROPHONE_FAKE_HISTORY"] == "1" { model.debugSeedHistory() }
        if let mac = env["MACROPHONE_FAKE_PAIRED"] {
            model.debugFakePairing(mac: mac, profiles: ["Default", "Claude prompt", "Slack message"])
        }
        switch env["MACROPHONE_SCREEN"] {
        case "history": model.sheet = .history
        case "settings", "dictionary", "language", "diagnostics": model.sheet = .settings
        case "pairing": model.sheet = .pairing
        default: break
        }
        if let s = env["MACROPHONE_OPEN_URL"], let url = URL(string: s) {
            model.handleURL(url)
        }
        if env["MACROPHONE_PAIR_CODE"] == "1" {
            model.sheet = .pairing
            Task {
                for _ in 0..<40 where model.discoveredMacs.isEmpty { try? await Task.sleep(nanoseconds: 250_000_000) }
                if let mac = model.discoveredMacs.first { await model.pairWithCode(mac) }
            }
        }
        if let text = env["MACROPHONE_FAKE_RECORDING"] {
            model.debugSimulateRecording(text)
        }
        if let status = env["MACROPHONE_STATUS"] {
            let mac = model.pairedMac?.name ?? "Sameer's MacBook Pro"
            switch status {
            case "queued": model.debugSetStatus(.queued)
            case "delivered": model.debugSetStatus(.delivered(mac: mac, detail: "Pasted into Claude", late: false))
            case "failed": model.debugSetStatus(.failed(mac: mac, detail: "Accessibility permission is off"))
            case "sending": model.debugSetStatus(.sending(mac: mac))
            case "copied": model.debugSetStatus(.copiedOnPhone)
            default: break
            }
        }
        if let text = env["MACROPHONE_FAKE_TRANSCRIPT"] {
            let early = env["MACROPHONE_FAKE_EARLY"] == "1"
            Task {
                // Give the link a moment to connect, as a real dictation would have.
                try? await Task.sleep(nanoseconds: UInt64((Double(env["MACROPHONE_FAKE_DELAY"] ?? "2.5") ?? 2.5) * 1e9))
                model.debugInject(text, stoppedEarly: early)
            }
        }
    }
}
#endif
