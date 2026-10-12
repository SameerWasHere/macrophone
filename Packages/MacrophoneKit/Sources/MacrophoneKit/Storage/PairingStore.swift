import CryptoKit
import Foundation
import Security

/// Where each side keeps the devices it's paired with. The model allows any number of
/// peers on either side even though v1's screens show one.
public protocol PairingStore: AnyObject, Sendable {
    func peers() -> [PairedPeer]
    func key(for peerID: UUID) -> SymmetricKey?
    func save(_ peer: PairedPeer, key: SymmetricKey)
    func touch(_ peerID: UUID)
    func remove(_ peerID: UUID)
}

/// Peer list in a small JSON file; keys in the Keychain (never in the file).
public final class KeychainPairingStore: PairingStore, @unchecked Sendable {
    private let service: String
    private let listURL: URL
    private let lock = NSLock()

    /// - Parameter service: Keychain service name, e.g. "com.sameer.macrophone.pairing".
    public init(service: String, directory: URL) {
        self.service = service
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.listURL = directory.appendingPathComponent("paired-devices.json")
    }

    public func peers() -> [PairedPeer] {
        lock.lock(); defer { lock.unlock() }
        return readList()
    }

    private func readList() -> [PairedPeer] {
        guard let data = try? Data(contentsOf: listURL) else { return [] }
        return (try? WireCoding.decoder.decode([PairedPeer].self, from: data)) ?? []
    }

    private func writeList(_ list: [PairedPeer]) {
        if let data = try? WireCoding.encoder.encode(list) {
            try? data.write(to: listURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    public func key(for peerID: UUID) -> SymmetricKey? {
        var q = baseQuery(peerID)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return SymmetricKey(data: data)
    }

    public func save(_ peer: PairedPeer, key: SymmetricKey) {
        lock.lock(); defer { lock.unlock() }
        SecItemDelete(baseQuery(peer.id) as CFDictionary)
        var add = baseQuery(peer.id)
        add[kSecValueData as String] = key.rawData
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrLabel as String] = "\(Product.name) pairing — \(peer.name)"
        SecItemAdd(add as CFDictionary, nil)
        var list = readList().filter { $0.id != peer.id }
        list.append(peer)
        writeList(list)
    }

    public func touch(_ peerID: UUID) {
        lock.lock(); defer { lock.unlock() }
        var list = readList()
        guard let i = list.firstIndex(where: { $0.id == peerID }) else { return }
        list[i].lastSeen = Date()
        writeList(list)
    }

    public func remove(_ peerID: UUID) {
        lock.lock(); defer { lock.unlock() }
        SecItemDelete(baseQuery(peerID) as CFDictionary)
        writeList(readList().filter { $0.id != peerID })
    }

    private func baseQuery(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }
}

/// File-only store for the command-line test tool and tests. Keys sit in a 0600 file.
public final class FilePairingStore: PairingStore, @unchecked Sendable {
    private struct Entry: Codable { var peer: PairedPeer; var key: Data }
    private let url: URL
    private let lock = NSLock()

    public init(url: URL) {
        self.url = url
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    private func read() -> [Entry] {
        guard let d = try? Data(contentsOf: url) else { return [] }
        return (try? WireCoding.decoder.decode([Entry].self, from: d)) ?? []
    }

    private func write(_ e: [Entry]) {
        guard let d = try? WireCoding.encoder.encode(e) else { return }
        FileManager.default.createFile(atPath: url.path, contents: d, attributes: [.posixPermissions: 0o600])
    }

    public func peers() -> [PairedPeer] { lock.lock(); defer { lock.unlock() }; return read().map(\.peer) }
    public func key(for peerID: UUID) -> SymmetricKey? {
        lock.lock(); defer { lock.unlock() }
        return read().first { $0.peer.id == peerID }.map { SymmetricKey(data: $0.key) }
    }
    public func save(_ peer: PairedPeer, key: SymmetricKey) {
        lock.lock(); defer { lock.unlock() }
        write(read().filter { $0.peer.id != peer.id } + [Entry(peer: peer, key: key.rawData)])
    }
    public func touch(_ peerID: UUID) {
        lock.lock(); defer { lock.unlock() }
        var e = read()
        if let i = e.firstIndex(where: { $0.peer.id == peerID }) { e[i].peer.lastSeen = Date(); write(e) }
    }
    public func remove(_ peerID: UUID) {
        lock.lock(); defer { lock.unlock() }
        write(read().filter { $0.peer.id != peerID })
    }
}

/// This device's stable identity on the link.
public struct DeviceIdentity: Codable, Sendable {
    public var id: UUID
    public var name: String
    public init(id: UUID, name: String) { self.id = id; self.name = name }

    /// Loads (or creates once) the id from UserDefaults; the name is passed in fresh each time.
    public static func load(defaults: UserDefaults = .standard, name: String) -> DeviceIdentity {
        let key = "macrophone.deviceID"
        if let s = defaults.string(forKey: key), let id = UUID(uuidString: s) { return DeviceIdentity(id: id, name: name) }
        let id = UUID()
        defaults.set(id.uuidString, forKey: key)
        return DeviceIdentity(id: id, name: name)
    }
}
