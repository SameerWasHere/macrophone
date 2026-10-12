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

    static var supportDirectory: URL {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent(isDebugBuild ? "\(Product.name) Debug" : Product.name)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var history: URL { supportDirectory.appendingPathComponent("history.json") }
    static var seenIDs: URL { supportDirectory.appendingPathComponent("seen-ids.json") }
    static var profiles: URL { supportDirectory.appendingPathComponent("profiles.json") }
    static var diagnostics: URL { supportDirectory.appendingPathComponent("diagnostics.log") }
    static var keychainService: String {
        (Bundle.main.bundleIdentifier ?? "com.sameer.macrophone.mac") + ".pairing"
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
    static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    /// "Sameer's MacBook Pro" — the name the phone shows.
    static var computerName: String {
        if let n = SCComputerName.current, !n.isEmpty { return n }
        return Host.current().localizedName ?? "Mac"
    }
}

enum SCComputerName {
    static var current: String? { SCDynamicStoreCopyComputerName(nil, nil) as String? }
}

/// How a dictation reaches you when its profile doesn't say otherwise.
enum DeliveryMode: String, CaseIterable, Identifiable, Codable {
    case clipboardNotify, clipboardOnly, autoPaste
    var id: String { rawValue }

    var title: String {
        switch self {
        case .clipboardNotify: return "Clipboard + notification"
        case .clipboardOnly: return "Clipboard only"
        case .autoPaste: return "Auto-paste"
        }
    }

    var summary: String {
        switch self {
        case .clipboardNotify: return "Copies it and shows what arrived. You paste with ⌘V."
        case .clipboardOnly: return "Copies it silently. The menu bar icon ticks, nothing else."
        case .autoPaste: return "Pastes into the app you're using after a short countdown you can cancel. Puts your clipboard back afterwards."
        }
    }

    var symbol: String {
        switch self {
        case .clipboardNotify: return "bell.badge"
        case .clipboardOnly: return "doc.on.clipboard"
        case .autoPaste: return "text.cursor"
        }
    }
}

struct AllowedApp: Codable, Hashable, Identifiable {
    var bundleID: String
    var name: String
    var id: String { bundleID }
}

/// User settings, persisted in UserDefaults.
@MainActor
final class Settings: ObservableObject {
    private let d = UserDefaults.standard

    @Published var deliveryMode: DeliveryMode { didSet { d.set(deliveryMode.rawValue, forKey: "deliveryMode") } }
    @Published var historyEnabled: Bool { didSet { d.set(historyEnabled, forKey: "historyEnabled") } }
    @Published var apiEnabled: Bool { didSet { d.set(apiEnabled, forKey: "apiEnabled") } }
    @Published var enterAllowlist: [AllowedApp] {
        didSet { d.set(try? JSONEncoder().encode(enterAllowlist), forKey: "enterAllowlist") }
    }
    @Published var hasCompletedSetup: Bool { didSet { d.set(hasCompletedSetup, forKey: "hasCompletedSetup") } }
    @Published var askedForNotifications: Bool { didSet { d.set(askedForNotifications, forKey: "askedForNotifications") } }

    static let defaultAllowlist: [AllowedApp] = [
        AllowedApp(bundleID: "com.anthropic.claudefordesktop", name: "Claude"),
        AllowedApp(bundleID: "com.apple.Terminal", name: "Terminal"),
        AllowedApp(bundleID: "com.googlecode.iterm2", name: "iTerm"),
        AllowedApp(bundleID: "com.mitchellh.ghostty", name: "Ghostty"),
        AllowedApp(bundleID: "dev.warp.Warp-Stable", name: "Warp"),
        AllowedApp(bundleID: "com.todesktop.230313mzl4w4u92", name: "Cursor"),
        AllowedApp(bundleID: "com.microsoft.VSCode", name: "Visual Studio Code"),
        AllowedApp(bundleID: "com.openai.chat", name: "ChatGPT"),
    ]

    init() {
        deliveryMode = DeliveryMode(rawValue: d.string(forKey: "deliveryMode") ?? "") ?? .clipboardNotify
        historyEnabled = d.object(forKey: "historyEnabled") as? Bool ?? true
        apiEnabled = d.object(forKey: "apiEnabled") as? Bool ?? true
        if let data = d.data(forKey: "enterAllowlist"), let list = try? JSONDecoder().decode([AllowedApp].self, from: data) {
            enterAllowlist = list
        } else {
            enterAllowlist = Self.defaultAllowlist
        }
        hasCompletedSetup = d.bool(forKey: "hasCompletedSetup")
        askedForNotifications = d.bool(forKey: "askedForNotifications")
    }

    func allowsEnter(in bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return enterAllowlist.contains { $0.bundleID == bundleID }
    }
}
