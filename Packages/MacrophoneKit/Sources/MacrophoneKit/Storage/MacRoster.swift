import Foundation

// Several Macs on one iPhone (Oct 19 2026). The phone keeps every pairing (`PairingStore` always
// could); one Mac is active at a time — the one the mic sends to, the window view shows and the
// pill at the top names. These are the pure rules: the order the Macs are shown in, which one is
// active, and what the phone remembers for each. The Mac side needs none of it: each Mac pairs
// with a phone on its own, as before.

public enum MacRoster {
    /// The order the pill rolls through and the lists show: the order they were paired. Stable —
    /// it never resorts as names change or Macs come and go.
    public static func ordered(_ peers: [PairedPeer]) -> [PairedPeer] {
        peers.sorted { ($0.pairedAt, $0.id.uuidString) < ($1.pairedAt, $1.id.uuidString) }
    }

    /// The active Mac: the chosen one while it's still paired; else — a phone from before several
    /// Macs, or the chosen one forgotten — the most recently paired. That was v1's one rule, so
    /// a phone with one Mac keeps it with nothing to migrate and nothing to re-pair.
    public static func active(in peers: [PairedPeer], chosen: UUID?) -> PairedPeer? {
        if let chosen, let p = peers.first(where: { $0.id == chosen }) { return p }
        return peers.max { ($0.pairedAt, $0.id.uuidString) < ($1.pairedAt, $1.id.uuidString) }
    }

    /// The Mac after (`step` 1, a swipe up) or before (−1, a swipe down) the active one, round
    /// the list. Nil with fewer than two Macs.
    public static func step(_ step: Int, from active: UUID?, in peers: [PairedPeer]) -> PairedPeer? {
        let list = ordered(peers)
        guard list.count > 1 else { return nil }
        guard let i = list.firstIndex(where: { $0.id == active }) else { return list.first }
        let n = list.count
        return list[((i + step) % n + n) % n]
    }
}

/// What the phone remembers for each Mac: its Send to choice and Paste / Paste & send for each
/// place used there (each Mac has its own apps, so the pick comes back when you switch). Before
/// several Macs these lived under one key each; `adopt` moves those to the first Mac the phone
/// knew, once, so nothing is re-picked after the update.
// UserDefaults is thread-safe; the struct only holds it.
public struct MacPreferences: @unchecked Sendable {
    public static let selectionKey = "settings.selection"
    public static let sendByTargetKey = "settings.sendByTarget"
    /// The Mac chosen as active (nil: MacRoster's fallback — the most recently paired).
    public static let chosenMacKey = "macrophone.activeMac"

    private let d: UserDefaults

    public init(defaults: UserDefaults = .standard) { d = defaults }

    /// "settings.selection.<id>" for a Mac; the plain key for none (a phone that isn't paired).
    public static func key(_ base: String, mac: UUID?) -> String {
        mac.map { "\(base).\($0.uuidString)" } ?? base
    }

    public var chosenMac: UUID? {
        get { d.string(forKey: Self.chosenMacKey).flatMap(UUID.init(uuidString:)) }
        nonmutating set {
            if let id = newValue { d.set(id.uuidString, forKey: Self.chosenMacKey) } else { d.removeObject(forKey: Self.chosenMacKey) }
        }
    }

    public func selection(for mac: UUID?) -> SendSelection {
        if let data = d.data(forKey: Self.key(Self.selectionKey, mac: mac)),
           let s = try? JSONDecoder().decode(SendSelection.self, from: data) { return s }
        return .default   // a Mac just paired copies to its clipboard
    }

    public func setSelection(_ s: SendSelection, for mac: UUID?) {
        if let data = try? JSONEncoder().encode(s) { d.set(data, forKey: Self.key(Self.selectionKey, mac: mac)) }
    }

    public func rememberedSend(for target: TargetRef, mac: UUID?) -> Bool {
        guard target.canSend else { return false }
        return (d.dictionary(forKey: Self.key(Self.sendByTargetKey, mac: mac)) as? [String: Bool])?[target.storageKey] ?? false
    }

    public func rememberSend(_ on: Bool, for target: TargetRef, mac: UUID?) {
        guard target.canSend else { return }
        let key = Self.key(Self.sendByTargetKey, mac: mac)
        var all = (d.dictionary(forKey: key) as? [String: Bool]) ?? [:]
        all[target.storageKey] = on
        d.set(all, forKey: key)
    }

    /// The one Mac's keys from before become this Mac's — only when it has none of its own yet
    /// and there's something to move. The old keys are removed. True when something moved.
    @discardableResult
    public func adopt(legacyFor mac: UUID) -> Bool {
        var moved = false
        if d.object(forKey: Self.key(Self.selectionKey, mac: mac)) == nil, let data = d.data(forKey: Self.selectionKey) {
            d.set(data, forKey: Self.key(Self.selectionKey, mac: mac))
            moved = true
        }
        if d.object(forKey: Self.key(Self.sendByTargetKey, mac: mac)) == nil, let by = d.dictionary(forKey: Self.sendByTargetKey) {
            d.set(by, forKey: Self.key(Self.sendByTargetKey, mac: mac))
            moved = true
        }
        if moved {
            d.removeObject(forKey: Self.selectionKey)
            d.removeObject(forKey: Self.sendByTargetKey)
        }
        return moved
    }

    /// A Mac forgotten takes what was remembered for it with it.
    public func forget(mac: UUID) {
        d.removeObject(forKey: Self.key(Self.selectionKey, mac: mac))
        d.removeObject(forKey: Self.key(Self.sendByTargetKey, mac: mac))
        if chosenMac == mac { chosenMac = nil }
    }
}

public extension TargetRef {
    /// A stable key for remembering things per place ("app:com.apple.MobileSMS#41").
    var storageKey: String {
        switch self {
        case .clipboard: return "clipboard"
        case .frontApp: return "front"
        case let .app(bid, key, _): return "app:\(bid)#\(key ?? "")"
        }
    }
}
