#if DEBUG
import Foundation
import MacrophoneKit
import SwiftUI

/// Launch hooks for driving screens headlessly. DEBUG builds only. Pass them with
/// `SIMCTL_CHILD_<NAME>=… xcrun simctl launch <udid> com.sameer.macrophone`.
///
/// MACROPHONE_RESET=1                         clear settings, history, queue (not pairings)
/// MACROPHONE_SCREEN=onboarding|main|history|settings|pairing|dictionary|language|diagnostics|sendto
/// MACROPHONE_ONBOARDING_STEP=0…6             which setup step to open on
/// MACROPHONE_FAKE_TRANSCRIPT=<text>          a finished dictation, as if spoken (cleanup + delivery run)
/// MACROPHONE_CLEANUP_BUDGET=<seconds>       cleanup's time budget (to see a partial cleanup)
/// MACROPHONE_FAKE_EARLY=1                    …marked "stopped early"
/// MACROPHONE_FAKE_RECORDING=<text>           the live recording screen, words appearing
/// MACROPHONE_FAKE_HISTORY=1                  four sample history items
/// MACROPHONE_FAKE_PAIRED=<Mac name>          looks paired + connected, with the sample targets below (screens only)
/// MACROPHONE_FAKE_PROFILES=<spec>|default    stand-in for the Mac's targets, kept even when a real Mac connects:
///                                            "Claude=claude;Claude Code (Terminal)=claude code,terminal@heavy;Clipboard"
///                                            (name=prefix,prefix@cleanup; the first is the Mac's default)
/// MACROPHONE_SEND_TO=automatic|<target name> the Send-to choice
/// MACROPHONE_INTENT_TARGET=automatic|<name>  runs Start Dictation the way a Shortcut / control does, with that
///                                            target (needs MACROPHONE_SIM_RECORD; stops after 3 s)
/// MACROPHONE_STATUS=queued|delivered|failed|sending|copied
/// MACROPHONE_DICTIONARY=a,b,c                dictionary words
/// MACROPHONE_LANGUAGE=<id>                   recognizer language
/// MACROPHONE_OPEN_URL=<url>                  handled exactly like onOpenURL (simctl openurl asks "Open in…?" first)
/// MACROPHONE_PAIR_CODE=<Mac name>            code pairing with the Mac of that name
/// MACROPHONE_UNPAIR=1                       forget the paired Mac (tells it, if reachable)
/// MACROPHONE_RESEND_LATEST=1                 resend the last dictation (same id) after a few seconds
/// MACROPHONE_RECORD=<seconds>                really record from the mic for that long, then stop
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

    /// The targets a developer would set up on the Mac.
    static let sampleTargets: [ProfileSummary] = parseTargets(
        "Clipboard;Claude=claude;Claude Code (Terminal)=claude code,terminal;ChatGPT=chatgpt,chat gpt;Cursor=cursor;Quick note=note@light")

    static func parseTargets(_ spec: String) -> [ProfileSummary] {
        spec.split(separator: ";").enumerated().map { i, part in
            var s = String(part)
            var level: CleanupLevel?
            if let at = s.lastIndex(of: "@") { level = CleanupLevel(rawValue: String(s[s.index(after: at)...])); s = String(s[..<at]) }
            let bits = s.split(separator: "=", maxSplits: 1).map(String.init)
            let prefixes = bits.count > 1 ? bits[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } : nil
            return ProfileSummary(id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012X", i + 1))!, name: bits[0].trimmingCharacters(in: .whitespaces),
                                  cleanupLevel: level, isDefault: i == 0, voicePrefixes: prefixes)
        }
    }

    @MainActor static func apply(_ model: AppModel) {
        if let mac = env["MACROPHONE_FAKE_PAIRED"] {
            model.debugFakePairing(mac: mac)
            if env["MACROPHONE_FAKE_PROFILES"] == nil { model.debugFakeProfiles(sampleTargets) }
        }
        if let spec = env["MACROPHONE_FAKE_PROFILES"] {
            model.debugFakeProfiles(spec == "default" ? sampleTargets : parseTargets(spec))
        }
        if let to = env["MACROPHONE_SEND_TO"] {
            if to == "automatic" { model.setSendTo(.automatic) }
            else if let p = model.profiles.first(where: { $0.name == to }) { model.setSendTo(.profile(p.id)) }
        }
        if env["MACROPHONE_FAKE_HISTORY"] == "1" { model.debugSeedHistory() }
        if env["MACROPHONE_UNPAIR"] == "1" { Task { await model.unpair() } }
        if let to = env["MACROPHONE_INTENT_TARGET"] {
            let id = to == "automatic" ? ProfileEntity.automaticID : model.profiles.first { $0.name == to }?.id
            Task {
                try? await Task.sleep(nanoseconds: UInt64((Double(env["MACROPHONE_FAKE_DELAY"] ?? "2.5") ?? 2.5) * 1e9))
                await IntentBridge.startRecording(profileID: id)
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                model.stopRecording()
            }
        }
        switch env["MACROPHONE_SCREEN"] {
        case "history": model.sheet = .history
        case "settings", "dictionary", "language", "diagnostics": model.sheet = .settings
        case "pairing": model.sheet = .pairing
        case "sendto": model.sheet = .sendTo
        default: break
        }
        if let s = env["MACROPHONE_OPEN_URL"], let url = URL(string: s) {
            model.handleURL(url)
        }
        if let name = env["MACROPHONE_PAIR_CODE"] {
            model.sheet = .pairing
            model.startLink()
            Task {
                for _ in 0..<40 where !model.discoveredMacs.contains(where: { $0.name == name }) { try? await Task.sleep(nanoseconds: 250_000_000) }
                if let mac = model.discoveredMacs.first(where: { $0.name == name }) { await model.pairWithCode(mac) }
            }
        }
        if env["MACROPHONE_RESEND_LATEST"] == "1" {
            Task {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if let item = model.latest { model.resend(item) }
            }
        }
        if let secs = env["MACROPHONE_RECORD"].flatMap(Double.init) {
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await model.startRecording()
                try? await Task.sleep(nanoseconds: UInt64(secs * 1e9))
                model.stopRecording()
            }
        }
        if let text = env["MACROPHONE_FAKE_RECORDING"] {
            model.debugSimulateRecording(text)
        }
        if let status = env["MACROPHONE_STATUS"] {
            let mac = model.pairedMac?.name ?? "Sameer's MacBook Pro"
            switch status {
            case "queued": model.debugSetStatus(.queued)
            case "delivered": model.debugSetStatus(.delivered(mac: mac, detail: "Pasted into Claude", late: false, to: nil))
            case "delivered-prefix": model.debugSetStatus(.delivered(mac: mac, detail: "Pasted into Claude · Sent", late: false,
                                                                     to: RouteNote(name: "Claude", spoken: "Claude")))
            case "failed": model.debugSetStatus(.failed(mac: mac, detail: "Accessibility permission is off"))
            case "sending": model.debugSetStatus(.sending(mac: mac, to: nil))
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
