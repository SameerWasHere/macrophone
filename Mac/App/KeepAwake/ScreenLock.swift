import AppKit
import OpenDirectory
import Security

/// The screen lock, for Keep Awake's opt-in "Don't lock the screen" (Nov 7 2026, from On The Go).
///
/// macOS reads the lock from the user's keybag, reachable only through `sysadminctl -screenLock
/// <off|immediate|seconds> -password <pw>` (the old `askForPassword` default is written and
/// ignored). It runs as the user, never as root (root is refused: "MKBDeviceSetGracePeriod error
/// -17"), so it needs the login password — kept in this Mac's login Keychain, checked against the
/// local directory before it's kept, used for nothing else, never logged or sent anywhere.
/// A known macOS quirk: a keybag out of step with the login password refuses even a correct
/// password with "error -14"; changing the password once in System Settings fixes it.
enum ScreenLock {
    private static var service: String {
        (Bundle.main.bundleIdentifier ?? "com.sameer.macrophone.mac") + ".screenlock" + (AppPaths.instance.map { ".\($0)" } ?? "")
    }
    private static let account = "login-password"

    /// "off", "immediate", "300" — the argument that puts it back; nil when unreadable.
    static func current() -> String? {
        let out = Shell.run("/usr/sbin/sysadminctl", ["-screenLock", "status"]).output.lowercased()
        if out.contains(" is off") { return "off" }
        if out.contains("immediate") { return "immediate" }
        if let r = out.range(of: #"(\d+) second"#, options: .regularExpression), let n = Int(out[r].split(separator: " ")[0]) { return String(n) }
        return nil
    }

    /// nil on success, else what sysadminctl said (never including the password).
    static func set(_ argument: String, password: String) -> String? {
        let out = Shell.run("/usr/sbin/sysadminctl", ["-screenLock", argument, "-password", password]).output
        let now = current()
        if argument == "off" ? now == "off" : now != "off" { return nil }
        return out.contains("-14") ? "error -14" : "refused"
    }

    static func verify(_ password: String) -> Bool {
        do {
            let node = try ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeLocalNodes))
            let record = try node.record(withRecordType: kODRecordTypeUsers, name: NSUserName(), attributes: nil)
            try record.verifyPassword(password)
            return true
        } catch { return false }
    }

    // MARK: Keychain

    static var storedPassword: String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let d = item as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// Whether one is kept, without reading it.
    static var hasStoredPassword: Bool {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess
    }

    static func store(_ password: String) {
        forget()
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                  kSecAttrAccount as String: account, kSecAttrLabel as String: "Macrophone — Keep Awake screen lock",
                                  kSecValueData as String: Data(password.utf8)]
        SecItemAdd(add as CFDictionary, nil)
    }

    static func forget() {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }

    // MARK: Asking

    /// The login password, checked, asked again after a typo; nil when he chooses Not Now.
    @MainActor
    static func ask() -> String? {
        var wrong = false
        while true {
            let alert = NSAlert()
            alert.messageText = wrong ? "That password didn't match" : "Turn off the screen lock while Keep Awake is on?"
            alert.informativeText = """
            macOS only lets an app change the screen lock with your login password. Macrophone keeps it in your Keychain on this Mac, uses it only to turn the lock off while Keep Awake is on and back on afterwards, and never sends it anywhere.

            While the lock is off, anyone at this Mac can use it without a password.
            """
            alert.addButton(withTitle: "Turn Off Screen Lock")
            alert.addButton(withTitle: "Not Now")
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            field.placeholderString = "Login password"
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            let pw = field.stringValue
            if !pw.isEmpty, verify(pw) { return pw }
            wrong = true
        }
    }
}
