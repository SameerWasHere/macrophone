import Foundation

// Keep Awake's one privileged act (Nov 7 2026): a `pmset` change. This file is compiled twice —
// into MacrophoneKit (the app, the tests) and, verbatim, into the root helper daemon
// (Mac/Helper), which runs only changes that pass `PowerChange(wire:)`. So it imports nothing
// but Foundation and holds nothing but the rule.
//
// The allowlist: four keys, each with the values that make sense, on one power source at a
// time (-a all, -b battery, -c charger, -u UPS). Anything else — another key, a number out of
// range, a second word — is refused before a process is started.

public struct PowerChange: Codable, Equatable, Hashable, Sendable {
    public enum Source: String, Codable, Sendable, CaseIterable {
        case all = "a", battery = "b", charger = "c", ups = "u"
    }

    public var source: Source
    public var key: String
    public var value: Int

    public init(_ source: Source, _ key: String, _ value: Int) {
        self.source = source
        self.key = key
        self.value = value
    }

    /// The keys a change may touch, with the values each may take.
    public static let allowed: [String: Set<Int>] = [
        "sleep": Set(0...1440),
        "displaysleep": Set(0...1440),
        // 0 off, 3 safe sleep (laptops), 25 hibernate only — the values pmset documents.
        "hibernatemode": [0, 3, 25],
        "disablesleep": [0, 1],
    ]

    /// Inside the allowlist. `disablesleep` is system-wide, so only with -a.
    public var isAllowed: Bool {
        guard let values = Self.allowed[key], values.contains(value) else { return false }
        if key == "disablesleep" { return source == .all }
        return true
    }

    /// `pmset` arguments: ["-a", "sleep", "0"].
    public var arguments: [String] { ["-\(source.rawValue)", key, String(value)] }

    /// "a sleep 0" — how a change crosses to the helper (a string survives NSXPC's secure
    /// coding with no class list to keep in step).
    public var wire: String { "\(source.rawValue) \(key) \(value)" }

    /// Parses `wire` back, strictly: three words, a known source, an allowed key and value.
    public init?(wire: String) {
        let parts = wire.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let s = Source(rawValue: parts[0]),
              parts[2].allSatisfy(\.isNumber), parts[2].count <= 4, let v = Int(parts[2]) else { return nil }
        self.init(s, parts[1], v)
        guard isAllowed else { return nil }
    }
}

/// The helper's protocol version, for the handshake: the app expects this one, and a helper
/// that answers an older number is asked to step down so launchd starts the new one.
public enum PowerHelperVersion {
    public static let current = 1
}
