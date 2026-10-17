#if DEBUG
import Foundation
import MacrophoneKit
import SwiftUI
import UIKit

/// Launch hooks for driving screens headlessly. DEBUG builds only. Pass them with
/// `SIMCTL_CHILD_<NAME>=… xcrun simctl launch <udid> com.sameer.macrophone`.
///
/// MACROPHONE_RESET=1                         clear settings, history, queue (not pairings)
/// MACROPHONE_SCREEN=onboarding|main|history|settings|pairing|dictionary|language|diagnostics|sendto|custom|settings-custom|openapp
/// MACROPHONE_OPEN_APP=<name>                 with SCREEN=openapp: then open that app from the list
///                                            (custom: the Custom cleanup editor from the mic screen; settings-custom: from Settings)
/// MACROPHONE_ONBOARDING_STEP=0…6             which setup step to open on
/// MACROPHONE_FAKE_TRANSCRIPT=<text>          a finished dictation, as if spoken (cleanup + delivery run)
/// MACROPHONE_FAKE_CAMERA=1                  the QR scanner sees a Mac's pairing window (store screenshots)
/// MACROPHONE_CLEANUP_BUDGET=<seconds>       cleanup's time budget (to see a partial cleanup)
/// MACROPHONE_FAKE_EARLY=1                    …marked "stopped early"
/// MACROPHONE_FAKE_RECORDING=<text>           the live recording screen, words appearing
/// MACROPHONE_FAKE_HISTORY=1                  four sample history items
/// MACROPHONE_FAKE_PAIRED=<Mac name>          looks paired + connected, with the sample open apps below
/// MACROPHONE_FAKE_TARGETS=default|long|none|many  stand-in for the Mac's open apps (long: a very long window name; many: 15)
/// MACROPHONE_SEND_TO=clipboard|front|<app name>  the Send-to choice (as if picked)
/// MACROPHONE_SEND=1|0                        Paste & send on / off for it
/// MACROPHONE_CLEANUP=off|light|medium|heavy|custom  the cleanup level
/// MACROPHONE_CUSTOM_INSTRUCTIONS=<text>      the Custom level's instructions ("default" = back to Medium's)
/// MACROPHONE_CLEANUP_AVAILABLE=1             treat on-device cleanup as available (the simulator may not have it)
/// MACROPHONE_FAKE_CLEANUP=1                  a stand-in cleaner: the words come back as spoken, marked cleaned at the
///                                            level, so the route (and the Mac) see the level the real model would run
/// MACROPHONE_ROUTE_PROBE=1                   a hidden "debug-route" element reads the last dictation's target/send/cleanup
///                                            (and, at Custom, the instructions the cleaner was given)
/// MACROPHONE_INTENT_TARGET=clipboard|front|<name>  runs Start Dictation the way a Shortcut / control does, with that
///                                            target (needs MACROPHONE_SIM_RECORD; stops after 3 s)
/// MACROPHONE_LANDINGS=ignore|ignore-old  drop the Mac's landing reports (a Mac that never confirms / an older one)
/// MACROPHONE_STATUS=queued|delivered|failed|sending|copied|landing|landed-sent|landed-sent-spoken|landed-pasted|landed-clipboard|landed-failed|landed-copied|landed-cancelled|unconfirmed
/// MACROPHONE_EXPLAIN=<sentence>             the status line's control explanation, held (layout checks)
/// MACROPHONE_MIC_ONLY=1                      simulator: the real mic without the recognizer (Filament proof)
/// MACROPHONE_MIC_WORDS=<text>                …with these words appearing as the voice comes in
/// MACROPHONE_DICTIONARY=a,b,c                dictionary words
/// MACROPHONE_DEVICE_NAME=<name>             what this iPhone calls itself
/// MACROPHONE_LANGUAGE=<id>                   recognizer language
/// MACROPHONE_OPEN_URL=<url>                  handled exactly like onOpenURL (simctl openurl asks "Open in…?" first)
/// MACROPHONE_PAIR_CODE=<Mac name>            code pairing with the Mac of that name
/// MACROPHONE_UNPAIR=1                       forget the paired Mac (tells it, if reachable)
/// MACROPHONE_RESEND_LATEST=1                 resend the last dictation (same id) after a few seconds
/// MACROPHONE_RECORD=<seconds>                really record from the mic for that long, then stop
/// MACROPHONE_AUDIO_FILE=<path>               record that audio file instead of the mic (real speed), then stop
/// MACROPHONE_PAIRING=connecting|code|paired|failed|expired  the pairing panel in that phase
/// MACROPHONE_WATCH=1                         open Watching on the Send-to choice once the Mac is connected
/// MACROPHONE_WATCH_ACTIONS=a,b,c             …then do these 2 s apart: escape, arrowUp, arrowDown, returnKey,
///                                            tap@0.2@0.5 (a click there), pan / scroll (what one finger does),
///                                            answer@1 (the window's question, second answer), keys,
///                                            next / prev (the next or previous window), attend@<bundle>@<window>
///                                            (what tapping an alert does)
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
        if let text = env["MACROPHONE_CUSTOM_INSTRUCTIONS"] {
            if text == "default" { d.removeObject(forKey: Settings.K.customInstructions) } else { d.set(text, forKey: Settings.K.customInstructions) }
        }
    }

    /// The stand-in cleaner (`MACROPHONE_FAKE_CLEANUP`): what the real one would be told, without the model.
    static func fakeClean(_ raw: String, level: CleanupLevel, dictionary: [String]) -> CleanupResult {
        _ = CleanupPrompts.instructions(level: level, dictionary: dictionary)
        return CleanupResult(cleaned: raw)
    }

    static var settingsPath: [SettingsRoute] {
        switch env["MACROPHONE_SCREEN"] {
        case "dictionary": return [.dictionary]
        case "language": return [.language]
        case "diagnostics": return [.diagnostics]
        case "settings-custom": return [.customCleanup]
        default: return []
        }
    }

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

    /// "clipboard", "front", or an open app's name → a target.
    @MainActor static func target(named to: String, in model: AppModel) -> TargetRef? {
        switch to {
        case "clipboard": return .clipboard
        case "front": return .frontApp
        default:
            if let t = model.liveTargets.first(where: { $0.title == to || $0.appName == to }) { return t.ref }
            // A sample app that isn't open now (MACROPHONE_FAKE_TARGETS=none): picked anyway, so it shows as closed.
            if let t = sampleApps(long: true).first(where: { $0.title == to || $0.appName == to }) { return t.ref }
            return nil
        }
    }

    @MainActor static func apply(_ model: AppModel) {
        if let mac = env["MACROPHONE_FAKE_PAIRED"] {
            model.debugFakePairing(mac: mac)
            if env["MACROPHONE_FAKE_TARGETS"] == nil { model.debugFakeTargets(sampleApps()) }
        }
        switch env["MACROPHONE_FAKE_TARGETS"] {
        case "default"?: model.debugFakeTargets(sampleApps())
        case "long"?: model.debugFakeTargets(sampleApps(long: true))
        case "none"?: model.debugFakeTargets([])
        case "many"?:
            // Fifteen apps: the dock scrolls, the pick kept in view.
            let more: [(String, String, CGFloat, CGFloat, CGFloat)] = [("Mail", "envelope.fill", 0.2, 0.5, 0.95), ("Xcode", "hammer.fill", 0.15, 0.45, 0.9),
                        ("Cursor", "cursorarrow", 0.1, 0.1, 0.12), ("ChatGPT", "bubble.left.fill", 0.1, 0.6, 0.5),
                        ("Linear", "line.3.horizontal", 0.35, 0.35, 0.8), ("Ghostty", "terminal", 0.2, 0.2, 0.3),
                        ("Safari", "safari.fill", 0.2, 0.55, 0.95), ("Obsidian", "diamond.fill", 0.45, 0.3, 0.75),
                        ("Discord", "gamecontroller.fill", 0.35, 0.4, 0.9), ("Things", "checkmark.square.fill", 0.25, 0.5, 0.95)]
            model.debugFakeTargets(sampleApps() + more.enumerated().map { i, a in
                LiveTarget(bundleID: "debug.\(a.0.lowercased())", appName: a.0, icon: icon(a.1, a.2, a.3, a.4),
                           lastActive: Date() - Double(4_000 + i * 60))
            })
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
        case "settings", "dictionary", "language", "diagnostics", "settings-custom": model.sheet = .settings
        case "custom": model.sheet = .customCleanup
        case "openapp":
            // After the Mac connects, so the list is real (mpctl serve sends a sample list).
            Task {
                for _ in 0..<40 where !model.isConnected { try? await Task.sleep(nanoseconds: 250_000_000) }
                model.sheet = .openApp
                if let name = env["MACROPHONE_OPEN_APP"] {
                    for _ in 0..<40 where model.macApps.isEmpty { try? await Task.sleep(nanoseconds: 250_000_000) }
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    if let app = model.macApps.first(where: { $0.name == name }) { model.sheet = nil; model.openOnMac(app) }
                }
            }
        case "pairing": model.sheet = .pairing
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
        if env["MACROPHONE_WATCH"] == "1" {
            Task {
                for _ in 0..<60 where !model.isConnected { try? await Task.sleep(nanoseconds: 250_000_000) }
                try? await Task.sleep(nanoseconds: 500_000_000)
                model.watcher.open(model.selection.target)
                for a in (env["MACROPHONE_WATCH_ACTIONS"] ?? "").split(separator: ",").map(String.init) {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if a.hasPrefix("scroll@") {
                        // scroll@0.5@0.4@0.2: at (0.5, 0.4), content dragged down by 20% of the window.
                        let v = a.split(separator: "@").dropFirst().compactMap { Double($0) }
                        if v.count == 3 { model.watcher.scroll(at: CGPoint(x: v[0], y: v[1]), by: CGVector(dx: 0, dy: v[2])) }
                    } else if a.hasPrefix("answer@"), let i = Int(a.dropFirst(7)) {
                        model.watcher.choose(i)
                    } else if a.hasPrefix("attend@") {
                        // What a tapped alert does: attend@com.apple.Terminal@42
                        let v = a.split(separator: "@").dropFirst().map(String.init)
                        if v.count == 2 { model.openAttention(.app(bundleID: v[0], windowKey: v[1], name: "Terminal — codex ~/api")) }
                    } else if a == "next" || a == "prev" {
                        model.watchStep(a == "next" ? 1 : -1)
                    } else if a == "keys" {
                        model.watcher.showKeys()
                    } else if a == "pan" || a == "scroll" {
                        model.watcher.setDrag(a == "pan" ? .pan : .scroll)
                    } else if a.hasPrefix("tap@") {
                        let xy = a.split(separator: "@").dropFirst().compactMap { Double($0) }
                        if xy.count == 2 { model.watcher.click(CGPoint(x: xy[0], y: xy[1])) }
                    } else if let action = WatchAction(rawValue: a) {
                        model.watcher.perform(action)
                    }
                }
            }
        }
        if env["MACROPHONE_CLOUD_SCHEMA"] == "1" {
            // Makes the iCloud record type alerts use (in the container's Development schema).
            Task { await AgentAlerts.shared.debugCreateSchema() }
        }
        if env["MACROPHONE_RESEND_LATEST"] == "1" {
            Task {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if let item = model.latest { model.resend(item) }
            }
        }
        if env["MACROPHONE_AUDIO_FILE"] != nil {
            // The file stands in for the mic (Recorder.audioFile); the recording stops after it.
            Task {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                await model.startRecording()
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
            case "landing": model.debugSetStatus(.landing(mac: mac, to: RouteNote(name: "Claude", spoken: nil, send: true)))
            case "landed-sent": model.debugSetStatus(.landed(Landing(result: .sent, detail: "Sent to Claude", target: TargetRef.app(bundleID: "com.anthropic.claudefordesktop", windowKey: nil, name: "Claude"), to: RouteNote(name: "Claude", spoken: nil, send: true))))
            case "landed-sent-spoken": model.debugSetStatus(.landed(Landing(result: .sent, detail: "Sent to Claude", target: TargetRef.app(bundleID: "com.anthropic.claudefordesktop", windowKey: nil, name: "Claude"), to: RouteNote(name: "Claude", spoken: "Claude", send: true))))
            case "landed-pasted": model.debugSetStatus(.landed(Landing(result: .pasted, detail: "Pasted into Claude", target: TargetRef.app(bundleID: "com.anthropic.claudefordesktop", windowKey: nil, name: "Claude"), to: RouteNote(name: "Claude", spoken: nil, send: true))))
            case "landed-clipboard": model.debugSetStatus(.landed(Landing(result: .copied, detail: "Copied to clipboard", target: .clipboard, to: RouteNote(name: "Clipboard"))))
            case "landed-failed": model.debugSetStatus(.landed(Landing(result: .failed, detail: "The message box in Claude wasn't found", target: TargetRef.app(bundleID: "com.anthropic.claudefordesktop", windowKey: nil, name: "Claude"), to: RouteNote(name: "Claude", spoken: nil, send: true))))
            case "landed-copied": model.debugSetStatus(.landed(Landing(result: .copied, detail: "Claude isn't open — copied instead", target: TargetRef.app(bundleID: "com.anthropic.claudefordesktop", windowKey: nil, name: "Claude"), to: RouteNote(name: "Claude", spoken: nil, send: true))))
            case "landed-cancelled": model.debugSetStatus(.landed(Landing(result: .cancelled, detail: "Paste cancelled", target: TargetRef.app(bundleID: "com.anthropic.claudefordesktop", windowKey: nil, name: "Claude"), to: RouteNote(name: "Claude", spoken: nil, send: true))))
            case "unconfirmed": model.debugSetStatus(.unconfirmed(mac: mac))
            default: break
            }
        }
        if let s = env["MACROPHONE_EXPLAIN"] { model.explain(s, for: 3600) }
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
