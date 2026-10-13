#if DEBUG
import Foundation
import MacrophoneKit
import SwiftUI
import UIKit

/// Launch hooks for driving screens headlessly. DEBUG builds only. Pass them with
/// `SIMCTL_CHILD_<NAME>=… xcrun simctl launch <udid> com.sameer.macrophone`.
///
/// MACROPHONE_RESET=1                         clear settings, history, queue (not pairings)
/// MACROPHONE_SCREEN=onboarding|main|history|settings|pairing|dictionary|language|diagnostics|sendto
/// MACROPHONE_ONBOARDING_STEP=0…6             which setup step to open on
/// MACROPHONE_FAKE_TRANSCRIPT=<text>          a finished dictation, as if spoken (cleanup + delivery run)
/// MACROPHONE_FAKE_CAMERA=1                  the QR scanner sees a Mac's pairing window (store screenshots)
/// MACROPHONE_CLEANUP_BUDGET=<seconds>       cleanup's time budget (to see a partial cleanup)
/// MACROPHONE_FAKE_EARLY=1                    …marked "stopped early"
/// MACROPHONE_FAKE_RECORDING=<text>           the live recording screen, words appearing
/// MACROPHONE_FAKE_HISTORY=1                  four sample history items
/// MACROPHONE_FAKE_PAIRED=<Mac name>          looks paired + connected, with the sample open apps and automations below
/// MACROPHONE_FAKE_TARGETS=default|long|none  stand-in for the Mac's open apps (long: a very long window name)
/// MACROPHONE_FAKE_PROFILES=<spec>|default    stand-in for the Mac's automations, kept even when a real Mac connects:
///                                            "Quick note=note@light;Remind me=remind"  (name=prefix,prefix@cleanup)
/// MACROPHONE_SEND_TO=clipboard|front|<app or automation name>  the Send-to choice (as if picked)
/// MACROPHONE_SEND=1|0                        Paste & send on / off for it
/// MACROPHONE_CLEANUP=off|light|medium|heavy  the cleanup level
/// MACROPHONE_CLEANUP_AVAILABLE=1             treat on-device cleanup as available (the simulator may not have it)
/// MACROPHONE_ROUTE_PROBE=1                   a hidden "debug-route" element reads the last dictation's target/send/cleanup
/// MACROPHONE_INTENT_TARGET=clipboard|front|<name>  runs Start Dictation the way a Shortcut / control does, with that
///                                            target (needs MACROPHONE_SIM_RECORD; stops after 3 s)
/// MACROPHONE_STATUS=queued|delivered|failed|sending|copied
/// MACROPHONE_DICTIONARY=a,b,c                dictionary words
/// MACROPHONE_DEVICE_NAME=<name>             what this iPhone calls itself
/// MACROPHONE_LANGUAGE=<id>                   recognizer language
/// MACROPHONE_OPEN_URL=<url>                  handled exactly like onOpenURL (simctl openurl asks "Open in…?" first)
/// MACROPHONE_PAIR_CODE=<Mac name>            code pairing with the Mac of that name
/// MACROPHONE_UNPAIR=1                       forget the paired Mac (tells it, if reachable)
/// MACROPHONE_RESEND_LATEST=1                 resend the last dictation (same id) after a few seconds
/// MACROPHONE_RECORD=<seconds>                really record from the mic for that long, then stop
/// MACROPHONE_PAIRING=connecting|code|paired|failed|expired  the pairing panel in that phase
enum DebugHooks {
    static let env = ProcessInfo.processInfo.environment
    static var fakeCamera: Bool { env["MACROPHONE_FAKE_CAMERA"] == "1" }

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
        if let name = env["MACROPHONE_DEVICE_NAME"] { d.set(name, forKey: Settings.K.deviceName) }
    }

    static var settingsPath: [SettingsRoute] {
        switch env["MACROPHONE_SCREEN"] {
        case "dictionary": return [.dictionary]
        case "language": return [.language]
        case "diagnostics": return [.diagnostics]
        default: return []
        }
    }

    /// Automations a developer would set up on the Mac.
    static let sampleAutomations: [ProfileSummary] = parseTargets("Quick note=note@light;Remind me=remind;Ask Claude=ask claude")

    /// Apps a developer has open, newest first. Icons are drawn here (glyphs, not the apps' own).
    @MainActor static func sampleApps(long: Bool = false) -> [LiveTarget] {
        let now = Date()
        var list = [
            LiveTarget(bundleID: "com.anthropic.claudefordesktop", appName: "Claude", icon: icon("sparkle", 0.85, 0.47, 0.34), lastActive: now),
            LiveTarget(bundleID: "com.apple.MobileSMS", appName: "Messages", icon: icon("message.fill", 0.20, 0.78, 0.35), lastActive: now - 60),
            LiveTarget(bundleID: "com.apple.Terminal", appName: "Terminal", windowTitle: "claude", windowKey: "41", icon: icon("terminal.fill", 0.16, 0.17, 0.20), lastActive: now - 120),
            LiveTarget(bundleID: "com.apple.Notes", appName: "Notes", icon: icon("note.text", 0.96, 0.78, 0.25), lastActive: now - 600),
            LiveTarget(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", icon: icon("number", 0.29, 0.13, 0.33), lastActive: now - 3_600),
        ]
        if long {
            list.insert(LiveTarget(bundleID: "com.apple.Terminal", appName: "Terminal",
                                   windowTitle: "claude — ~/Projects/macrophone/Packages/MacrophoneKit — 120×40",
                                   windowKey: "77", icon: icon("terminal.fill", 0.16, 0.17, 0.20), lastActive: now + 1), at: 0)
        }
        return list
    }

    @MainActor private static func icon(_ symbol: String, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> Data? {
        let size = CGSize(width: 64, height: 64)
        let img = UIGraphicsImageRenderer(size: size).image { _ in
            UIColor(red: r, green: g, blue: b, alpha: 1).setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 14).fill()
            let cfg = UIImage.SymbolConfiguration(pointSize: 30, weight: .semibold)
            if let s = UIImage(systemName: symbol, withConfiguration: cfg)?.withTintColor(.white, renderingMode: .alwaysOriginal) {
                s.draw(in: CGRect(x: (64 - s.size.width) / 2, y: (64 - s.size.height) / 2, width: s.size.width, height: s.size.height))
            }
        }
        return img.pngData()
    }

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

    /// "clipboard", "front", or an open app's / automation's name → a target.
    @MainActor static func target(named to: String, in model: AppModel) -> TargetRef? {
        switch to {
        case "clipboard": return .clipboard
        case "front": return .frontApp
        default:
            if let t = model.liveTargets.first(where: { $0.title == to || $0.appName == to }) { return t.ref }
            if let p = model.profiles.first(where: { $0.name == to }) { return .automation(id: p.id, name: p.name) }
            return nil
        }
    }

    @MainActor static func apply(_ model: AppModel) {
        if let mac = env["MACROPHONE_FAKE_PAIRED"] {
            model.debugFakePairing(mac: mac)
            if env["MACROPHONE_FAKE_PROFILES"] == nil { model.debugFakeProfiles(sampleAutomations) }
            if env["MACROPHONE_FAKE_TARGETS"] == nil { model.debugFakeTargets(sampleApps()) }
        }
        if let spec = env["MACROPHONE_FAKE_PROFILES"] {
            model.debugFakeProfiles(spec == "default" ? sampleAutomations : parseTargets(spec))
        }
        switch env["MACROPHONE_FAKE_TARGETS"] {
        case "default"?: model.debugFakeTargets(sampleApps())
        case "long"?: model.debugFakeTargets(sampleApps(long: true))
        case "none"?: model.debugFakeTargets([])
        default: break
        }
        if let to = env["MACROPHONE_SEND_TO"], let t = target(named: to, in: model) { model.pick(t) }
        if let send = env["MACROPHONE_SEND"] { model.setSend(send == "1") }
        if let level = env["MACROPHONE_CLEANUP"].flatMap(CleanupLevel.init(rawValue:)) { model.setCleanupLevel(level) }
        if env["MACROPHONE_FAKE_HISTORY"] == "1" { model.debugSeedHistory() }
        if env["MACROPHONE_UNPAIR"] == "1" { Task { await model.unpair() } }
        if let to = env["MACROPHONE_INTENT_TARGET"] {
            let id: String? = {
                switch target(named: to, in: model) {
                case .clipboard?: return TargetEntity.clipboardID
                case .frontApp?: return TargetEntity.frontID
                case let .app(bid, key, _)?: return "app:\(bid)#\(key ?? "")"
                case let .automation(id, _)?: return "auto:\(id.uuidString)"
                case nil: return nil
                }
            }()
            Task {
                try? await Task.sleep(nanoseconds: UInt64((Double(env["MACROPHONE_FAKE_DELAY"] ?? "2.5") ?? 2.5) * 1e9))
                await IntentBridge.startRecording(targetID: id, name: to)
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
        if let phase = env["MACROPHONE_PAIRING"] {
            let mac = model.pairedMac?.name ?? "Sameer's MacBook Pro"
            switch phase {
            case "connecting": model.pairing = .connecting(mac)
            case "code": model.pairing = .showingCode("482913", mac)
            case "paired": model.pairing = .paired(mac)
            case "failed": model.pairing = .connecting(mac); model.debugFailPairing()
            case "expired": model.pairing = .failed("That QR code is out of date. Scan the one on your Mac now.")
            default: break
            }
            if model.sheet == nil, !model.showOnboarding { model.sheet = .pairing }
        }
        if let text = env["MACROPHONE_FAKE_RECORDING"] {
            model.debugSimulateRecording(text)
        }
        if let status = env["MACROPHONE_STATUS"] {
            let mac = model.pairedMac?.name ?? "Sameer's MacBook Pro"
            switch status {
            case "queued": model.debugSetStatus(.queued)
            case "delivered": model.debugSetStatus(.delivered(mac: mac, detail: "Pasted into Claude", late: false, to: nil))
            case "delivered-prefix": model.debugSetStatus(.delivered(mac: mac, detail: "Sent to Claude", late: false,
                                                                     to: RouteNote(name: "Claude", spoken: "Claude", send: true)))
            case "delivered-spoken": model.debugSetStatus(.delivered(mac: mac, detail: "Sent to Messages", late: false,
                                                                     to: RouteNote(name: "Messages", spoken: "Messages", send: true)))
            case "not-open": model.debugSetStatus(.delivered(mac: mac, detail: "Claude isn't open on your Mac — copied instead", late: false,
                                                             to: RouteNote(name: "Claude", spoken: nil)))
            case "problem": model.debugSetStatus(.problem("Microphone access is off for Macrophone.", openSettings: true))
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
