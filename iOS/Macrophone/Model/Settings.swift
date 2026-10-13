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
    @Published var showHoldHint: Bool { didSet { d.set(showHoldHint, forKey: K.holdHint) } }
    /// What this iPhone calls itself to the Mac. iOS only gives apps "iPhone", so the person can rename it.
    @Published var deviceName: String { didSet { d.set(deviceName, forKey: K.deviceName) } }
    /// Where dictations go: Automatic (the Mac picks by the app in front) or one of its targets.
    @Published var sendTo: SendTarget { didSet { d.set(sendTo.stored, forKey: K.sendTo) } }

    init(defaults: UserDefaults = .standard) {
        d = defaults
        cleanupLevel = defaults.string(forKey: K.cleanup).flatMap(CleanupLevel.init(rawValue:)) ?? .medium
        dictionary = defaults.stringArray(forKey: K.dictionary) ?? []
        language = defaults.string(forKey: K.language) ?? Languages.defaultIdentifier
        autoStop = defaults.object(forKey: K.autoStop) as? Bool ?? false
        autoStopDelay = defaults.object(forKey: K.autoStopDelay) as? Double ?? 3
        historyEnabled = defaults.object(forKey: K.history) as? Bool ?? true
        showHoldHint = defaults.object(forKey: K.holdHint) as? Bool ?? true
        deviceName = defaults.string(forKey: K.deviceName) ?? UIDevice.current.name
        if let s = defaults.string(forKey: K.sendTo) {
            sendTo = SendTarget(stored: s)
        } else if let id = defaults.string(forKey: K.profile).flatMap(UUID.init(uuidString:)) {
            sendTo = .profile(id)   // v1 picked a profile in the old chip: keep it
        } else {
            sendTo = .automatic     // a fresh install sends on Automatic
        }
    }

    var isEnglish: Bool { language.lowercased().hasPrefix("en") }

    enum K {
        static let cleanup = "settings.cleanupLevel"
        static let dictionary = "settings.dictionary"
        static let language = "settings.language"
        static let autoStop = "settings.autoStop"
        static let autoStopDelay = "settings.autoStopDelay"
        static let history = "settings.historyEnabled"
        static let holdHint = "settings.showHoldHint"
        static let deviceName = "settings.deviceName"
        static let profile = "settings.profileID"   // v1, read once for migration
        static let sendTo = "settings.sendTo"
    }
}

/// The Send-to choice on the main screen.
enum SendTarget: Equatable, Hashable {
    case automatic
    case profile(UUID)

    init(stored: String) {
        if let id = UUID(uuidString: stored) { self = .profile(id) } else { self = .automatic }
    }
    var stored: String {
        switch self {
        case .automatic: return "automatic"
        case .profile(let id): return id.uuidString
        }
    }
    var profileID: UUID? { if case .profile(let id) = self { return id }; return nil }
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
