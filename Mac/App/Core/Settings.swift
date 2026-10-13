import AppKit
import Foundation
import MacrophoneKit
import SystemConfiguration

/// Where this build keeps its files. A debug build uses its own folder so it never touches a
/// release install's history or pairings (the API's `api.json` is shared on purpose — the
/// CLI reads one fixed path).
enum AppPaths {
    static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// DEBUG only: MACROPHONE_INSTANCE=<name> runs a debug copy with its own folder, settings,
    /// pairing keys and identity, so a test copy can't disturb another one (or a release install).
    static var instance: String? {
        #if DEBUG
        if let n = ProcessInfo.processInfo.environment["MACROPHONE_INSTANCE"], !n.isEmpty { return n }
        #endif
        return nil
    }

    /// Settings live here (the standard defaults, or the debug instance's own).
    static let defaults: UserDefaults = {
        if let instance, let d = UserDefaults(suiteName: "com.sameer.macrophone.mac.debug.\(instance)") { return d }
        return .standard
    }()

    static var supportDirectory: URL {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        var name = isDebugBuild ? "\(Product.name) Debug" : Product.name
        if let instance { name += " \(instance)" }
        let dir = base.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var history: URL { supportDirectory.appendingPathComponent("history.json") }
    static var seenIDs: URL { supportDirectory.appendingPathComponent("seen-ids.json") }
    /// Before live targets (Oct 2026): profiles. Read once to migrate, never written again.
    static var legacyProfiles: URL { supportDirectory.appendingPathComponent("profiles.json") }
    static var automations: URL { supportDirectory.appendingPathComponent("automations.json") }
    static var diagnostics: URL { supportDirectory.appendingPathComponent("diagnostics.log") }
    static var keychainService: String {
        (Bundle.main.bundleIdentifier ?? "com.sameer.macrophone.mac") + ".pairing" + (instance.map { ".\($0)" } ?? "")
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
    static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    /// "Sameer's MacBook Pro" — the name the phone shows.
    static var computerName: String {
        let name = SCComputerName.current.flatMap { $0.isEmpty ? nil : $0 } ?? Host.current().localizedName ?? "Mac"
        // A debug test instance says so, so a phone never mixes it up with the real app.
        if let instance { return "\(name) (\(instance))" }
        return name
    }
}

enum SCComputerName {
    static var current: String? { SCDynamicStoreCopyComputerName(nil, nil) as String? }
}

/// User settings, persisted in UserDefaults.
@MainActor
final class Settings: ObservableObject {
    private let d = AppPaths.defaults

    /// Where dictations go — the one choice the iPhone and this Mac share (Send to).
    @Published var selection: SendSelection {
        didSet { d.set(try? JSONEncoder().encode(selection), forKey: "sendSelection") }
    }
    /// With Send to › Clipboard: show what arrived (the popup, and Notification Center when
    /// the person is away). Off: the menu bar icon ticks, nothing else.
    @Published var clipboardNotification: Bool { didSet { d.set(clipboardNotification, forKey: "clipboardNotification") } }
    @Published var historyEnabled: Bool { didSet { d.set(historyEnabled, forKey: "historyEnabled") } }
    @Published var apiEnabled: Bool { didSet { d.set(apiEnabled, forKey: "apiEnabled") } }
    @Published var hasCompletedSetup: Bool { didSet { d.set(hasCompletedSetup, forKey: "hasCompletedSetup") } }
    @Published var askedForNotifications: Bool { didSet { d.set(askedForNotifications, forKey: "askedForNotifications") } }

    /// Say the trigger, get the expansion. Global — every dictation, wherever it goes.
    @Published var snippets: [Snippet] { didSet { d.set(try? JSONEncoder().encode(snippets), forKey: "snippets") } }
    /// The shortcut that opens Macrophone's window from anywhere (the menu bar icon can hide
    /// behind the notch).
    @Published var hotkey: Hotkey { didSet { d.set(try? JSONEncoder().encode(hotkey), forKey: "hotkey") } }
    /// Names the person gave their phones on this Mac (peer id → name). iOS can hide a phone's
    /// real name, so a phone may introduce itself as just "iPhone".
    @Published var deviceNames: [String: String] { didSet { d.set(deviceNames, forKey: "deviceNames") } }
    /// The one-time "your menu bar is hiding Macrophone's icon" notice has been seen.
    @Published var toldAboutHiddenIcon: Bool { didSet { d.set(toldAboutHiddenIcon, forKey: "toldAboutHiddenIcon") } }

    init() {
        // Before live targets there was a "delivery mode": it becomes the first Send to choice
        // (a phone that connects with its own choice wins anyway) and the notification option.
        let legacyMode = d.string(forKey: "deliveryMode")
        if let data = d.data(forKey: "sendSelection"), let sel = try? JSONDecoder().decode(SendSelection.self, from: data) {
            selection = sel
        } else {
            let migrated = legacyMode == "autoPaste" ? SendSelection(target: .frontApp) : .default
            selection = migrated
            d.set(try? JSONEncoder().encode(migrated), forKey: "sendSelection")
        }
        clipboardNotification = d.object(forKey: "clipboardNotification") as? Bool ?? (legacyMode != "clipboardOnly")
        historyEnabled = d.object(forKey: "historyEnabled") as? Bool ?? true
        apiEnabled = d.object(forKey: "apiEnabled") as? Bool ?? true
        snippets = (d.data(forKey: "snippets")).flatMap { try? JSONDecoder().decode([Snippet].self, from: $0) } ?? []
        var key = (d.data(forKey: "hotkey")).flatMap { try? JSONDecoder().decode(Hotkey.self, from: $0) } ?? .default
        // ⌥⌘M (the first default) is "Minimize All" in most apps: move a saved copy of it to
        // the new default once. A shortcut the person picked themselves stays.
        if d.integer(forKey: "hotkeyVersion") < 2 {
            if key.keyCode == Hotkey.legacyDefault.keyCode && key.modifiers == Hotkey.legacyDefault.modifiers {
                key = Hotkey(keyCode: Hotkey.default.keyCode, modifiers: Hotkey.default.modifiers, enabled: key.enabled)
                d.set(try? JSONEncoder().encode(key), forKey: "hotkey")
            }
            d.set(2, forKey: "hotkeyVersion")
        }
        hotkey = key
        deviceNames = d.dictionary(forKey: "deviceNames") as? [String: String] ?? [:]
        toldAboutHiddenIcon = d.bool(forKey: "toldAboutHiddenIcon")
        hasCompletedSetup = d.bool(forKey: "hasCompletedSetup")
        askedForNotifications = d.bool(forKey: "askedForNotifications")
        // Retired with live targets: the Return list and per-app rules (the phone's "Paste & send"
        // is the consent now; the app you pick is the rule).
        for k in ["enterAllowlist", "allowlistVersion", "appRules", "readyMadeVersion"] { d.removeObject(forKey: k) }
    }
}
