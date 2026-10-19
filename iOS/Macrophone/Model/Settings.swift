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
    /// A notification when a window on the Mac asks something nobody is watching (Oct 16 2026).
    @Published var agentAlerts: Bool { didSet { d.set(agentAlerts, forKey: K.agentAlerts) } }
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
    /// The Send-to choice on the active Mac (synced with it both ways; the phone's wins on
    /// connect). Each Mac has its own (Oct 19 2026, `MacPreferences`): `useMac` brings a Mac's
    /// back when it becomes active.
    @Published var selection: SendSelection {
        didSet {
            prefs.setSelection(selection, for: macID)
            if selection.target.canSend { rememberSend(selection.send, for: selection.target) }
        }
    }
    /// The Mac these per-Mac settings are for (the active one); nil before any is paired.
    private(set) var macID: UUID?
    private let prefs: MacPreferences

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
        agentAlerts = defaults.object(forKey: K.agentAlerts) as? Bool ?? true
        let custom = defaults.string(forKey: K.customInstructions) ?? ""
        customInstructions = custom
        CleanupPrompts.setCustomInstructions(custom)
        deviceName = defaults.string(forKey: K.deviceName) ?? UIDevice.current.name
        prefs = MacPreferences(defaults: defaults)
        selection = Self.storedSelection(defaults, mac: nil)
    }

    /// Read without the main actor: the link sends it to the Mac right after every welcome.
    nonisolated static func storedSelection(_ d: UserDefaults = .standard, mac: UUID?) -> SendSelection {
        MacPreferences(defaults: d).selection(for: mac)
    }

    /// The active Mac changed (or the first one was paired, or the last forgotten): its own
    /// Send to pick and remembered send settings come back. A Mac from before several Macs
    /// takes the one set of keys the app kept until now, once.
    func useMac(_ id: UUID?) {
        if let id { prefs.adopt(legacyFor: id) }
        macID = id
        let s = prefs.selection(for: id)
        if s != selection { selection = s }
    }

    /// A Mac forgotten takes what was remembered for it with it.
    func forget(mac: UUID) {
        prefs.forget(mac: mac)
        if macID == mac { macID = nil }
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

    /// Paste or Paste & send, remembered for each place the person has used on the active Mac.
    func rememberedSend(for target: TargetRef) -> Bool { prefs.rememberedSend(for: target, mac: macID) }

    func rememberSend(_ on: Bool, for target: TargetRef) { prefs.rememberSend(on, for: target, mac: macID) }

    var isEnglish: Bool { language.lowercased().hasPrefix("en") }

    enum K {
        static let cleanup = "settings.cleanupLevel"
        static let dictionary = "settings.dictionary"
        static let language = "settings.language"
        static let autoStop = "settings.autoStop"
        static let autoStopDelay = "settings.autoStopDelay"
        static let history = "settings.historyEnabled"
        static let watchAfterSending = "settings.watchAfterSending"
        static let agentAlerts = "settings.agentAlerts"
        static let deviceName = "settings.deviceName"
        /// The one Mac's keys from before Oct 19 2026 (now per Mac: MacPreferences.key(_:mac:)).
        static let selection = MacPreferences.selectionKey
        static let sendByTarget = MacPreferences.sendByTargetKey
        static let customInstructions = "settings.customInstructions"
        // Gone (Oct 13 2026); removed on launch.
        static let oldSendTo = "settings.sendTo"
        static let oldHoldHint = "settings.showHoldHint"
        static let oldProfiles = "profiles.cache"
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
    /// The one Mac's open apps as last heard, before several Macs (read once, then moved).
    static var legacyTargets: URL { directory.appendingPathComponent("targets.json") }
    /// A Mac's open apps as last heard (names, ids and small icons — no text), one file per Mac.
    static func targets(for mac: UUID) -> URL { directory.appendingPathComponent("targets-\(mac.uuidString).json") }
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
