import Foundation
import MacrophoneKit
import SwiftUI

/// Everything the person sets, in UserDefaults. Published so screens follow along.
@MainActor
final class Settings: ObservableObject {
    private let d: UserDefaults

    @Published var cleanupLevel: CleanupLevel { didSet { d.set(cleanupLevel.rawValue, forKey: K.cleanup) } }
    @Published var dictionary: [String] { didSet { d.set(dictionary, forKey: K.dictionary) } }
    /// BCP-47 identifier of the recognizer locale.
    @Published var language: String { didSet { d.set(language, forKey: K.language) } }
    @Published var autoStop: Bool { didSet { d.set(autoStop, forKey: K.autoStop) } }
    /// Seconds of silence after speech before auto-stop, 2…8.
    @Published var autoStopDelay: Double { didSet { d.set(autoStopDelay, forKey: K.autoStopDelay) } }
    @Published var historyEnabled: Bool { didSet { d.set(historyEnabled, forKey: K.history) } }
    /// After a dictation is sent into an app, show that app's window (Watching, Oct 14 2026).
    @Published var watchAfterSending: Bool { didSet { d.set(watchAfterSending, forKey: K.watchAfterSending) } }
    /// The Custom cleanup level's instructions as the person wrote them. Empty = the default
    /// (exactly Medium's). Applied to the cleaner the moment it changes, and at launch.
    @Published var customInstructions: String {
        didSet {
            let t = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
            // Unedited or emptied: nothing stored, so it follows the default.
            if t.isEmpty || t == CleanupPrompts.defaultCustomInstructions { d.removeObject(forKey: K.customInstructions) }
            else { d.set(customInstructions, forKey: K.customInstructions) }
            CleanupPrompts.setCustomInstructions(t.isEmpty ? nil : customInstructions)
        }
    }
    /// What this iPhone calls itself to the Mac. iOS only gives apps "iPhone", so the person can rename it.
    @Published var deviceName: String { didSet { d.set(deviceName, forKey: K.deviceName) } }
    /// The one shared Send-to choice (synced with the Mac both ways; the phone's wins on connect).
    @Published var selection: SendSelection {
        didSet {
            if let data = try? JSONEncoder().encode(selection) { d.set(data, forKey: K.selection) }
            if selection.target.canSend { rememberSend(selection.send, for: selection.target) }
        }
    }

    init(defaults: UserDefaults = .standard) {
        d = defaults
        Self.migrate(defaults)
        cleanupLevel = defaults.string(forKey: K.cleanup).flatMap(CleanupLevel.init(rawValue:)) ?? .medium
        dictionary = defaults.stringArray(forKey: K.dictionary) ?? []
        language = defaults.string(forKey: K.language) ?? Languages.defaultIdentifier
        autoStop = defaults.object(forKey: K.autoStop) as? Bool ?? false
        autoStopDelay = defaults.object(forKey: K.autoStopDelay) as? Double ?? 3
        historyEnabled = defaults.object(forKey: K.history) as? Bool ?? true
        watchAfterSending = defaults.object(forKey: K.watchAfterSending) as? Bool ?? true
        let custom = defaults.string(forKey: K.customInstructions) ?? ""
        customInstructions = custom
        CleanupPrompts.setCustomInstructions(custom)
        deviceName = defaults.string(forKey: K.deviceName) ?? UIDevice.current.name
        selection = Self.storedSelection(defaults)
    }

    /// Read without the main actor: the link sends it to the Mac right after every welcome.
    nonisolated static func storedSelection(_ d: UserDefaults = .standard) -> SendSelection {
        if let data = d.data(forKey: K.selection), let s = try? JSONDecoder().decode(SendSelection.self, from: data) { return s }
        return .default   // a fresh install copies to the Mac's clipboard
    }

    /// Quietly drops what the simplification (Oct 13 2026) took out: automations, the hint toggle,
    /// the pre-live-targets choice. A picked automation becomes Clipboard.
    private static func migrate(_ d: UserDefaults) {
        if d.string(forKey: K.oldSendTo) == "automatic", d.data(forKey: K.selection) == nil,
           let data = try? JSONEncoder().encode(SendSelection(target: .frontApp)) {
            d.set(data, forKey: K.selection)
        }
        // A stored automation (before Oct 13 2026) no longer decodes: storedSelection falls back to Clipboard.
        if var bySend = d.dictionary(forKey: K.sendByTarget) as? [String: Bool], bySend.keys.contains(where: { $0.hasPrefix("auto:") }) {
            bySend = bySend.filter { !$0.key.hasPrefix("auto:") }
            d.set(bySend, forKey: K.sendByTarget)
        }
        // The automations list was mirrored into the shared keychain item for the control.
        if d.object(forKey: K.oldProfiles) != nil { SharedStore.delete(account: K.oldProfiles) }
        for key in [K.oldSendTo, K.oldHoldHint, K.oldProfiles] where d.object(forKey: key) != nil { d.removeObject(forKey: key) }
    }

    /// Paste or Paste & send, remembered for each target the person has used.
    func rememberedSend(for target: TargetRef) -> Bool {
        guard target.canSend else { return false }
        return (d.dictionary(forKey: K.sendByTarget) as? [String: Bool])?[target.storageKey] ?? false
    }

    func rememberSend(_ on: Bool, for target: TargetRef) {
        guard target.canSend else { return }
        var all = (d.dictionary(forKey: K.sendByTarget) as? [String: Bool]) ?? [:]
        all[target.storageKey] = on
        d.set(all, forKey: K.sendByTarget)
    }

    var isEnglish: Bool { language.lowercased().hasPrefix("en") }

    enum K {
        static let cleanup = "settings.cleanupLevel"
        static let dictionary = "settings.dictionary"
        static let language = "settings.language"
        static let autoStop = "settings.autoStop"
        static let autoStopDelay = "settings.autoStopDelay"
        static let history = "settings.historyEnabled"
        static let watchAfterSending = "settings.watchAfterSending"
        static let deviceName = "settings.deviceName"
        static let selection = "settings.selection"
        static let sendByTarget = "settings.sendByTarget"
        static let customInstructions = "settings.customInstructions"
        // Gone (Oct 13 2026); removed on launch.
        static let oldSendTo = "settings.sendTo"
        static let oldHoldHint = "settings.showHoldHint"
        static let oldProfiles = "profiles.cache"
    }
}

extension TargetRef {
    /// A stable key for remembering things per target ("app:com.apple.MobileSMS#41").
    var storageKey: String {
        switch self {
        case .clipboard: return "clipboard"
        case .frontApp: return "front"
        case let .app(bid, key, _): return "app:\(bid)#\(key ?? "")"
        }
    }
}

/// Where the app keeps its files: Application Support/Macrophone.
enum AppFiles {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Macrophone", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    static var history: URL { directory.appendingPathComponent("history.json") }
    static var queue: URL { directory.appendingPathComponent("queue.json") }
    static var log: URL { directory.appendingPathComponent("diagnostics.log") }
    /// The Mac's open apps as last heard (names, ids and small icons — no text).
    static var targets: URL { directory.appendingPathComponent("targets.json") }
}

extension Bundle {
    var shortVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0" }
    var buildNumber: String { infoDictionary?["CFBundleVersion"] as? String ?? "1" }
}

/// iOS tells apps only "iPhone". The Mac's own name usually says whose it is — "Sameer's MacBook Pro" —
/// so that's the one honest guess: "Sameer's iPhone".
enum DeviceNameSuggestion {
    static func from(macName: String?) -> String? {
        guard let mac = macName?.trimmingCharacters(in: .whitespaces) else { return nil }
        for apostrophe in ["’s ", "'s "] {
            if let r = mac.range(of: apostrophe), r.lowerBound > mac.startIndex {
                let owner = mac[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
                let rest = mac[r.upperBound...].lowercased()
                guard !owner.isEmpty, owner.count <= 30, rest.contains("mac") || rest.contains("imac") else { continue }
                return owner + apostrophe.trimmingCharacters(in: .whitespaces) + " iPhone"
            }
        }
        return nil
    }
}
