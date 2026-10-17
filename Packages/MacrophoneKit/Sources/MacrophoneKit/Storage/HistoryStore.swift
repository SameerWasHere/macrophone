import Foundation

/// A rolling list of the last N items, newest first, kept only on this device.
/// With `isEnabled` off nothing is written to disk and the file is deleted, but the most
/// recent item is still held in memory (the Mac's pull API reads it).
public final class HistoryStore<Item: Codable & Identifiable & Sendable>: @unchecked Sendable where Item.ID: Sendable {
    public let capacity: Int
    private let url: URL
    private let lock = NSLock()
    private var items: [Item] = []
    private var memoryLatest: Item?
    private var enabled: Bool

    public init(url: URL, capacity: Int = 50, enabled: Bool) {
        self.url = url
        self.capacity = capacity
        self.enabled = enabled
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if enabled, let d = try? Data(contentsOf: url), let list = try? WireCoding.decoder.decode([Item].self, from: d) {
            items = Array(list.prefix(capacity))
        } else if !enabled {
            try? FileManager.default.removeItem(at: url)
        }
    }

    public var isEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return enabled }
        set {
            lock.lock()
            enabled = newValue
            if !newValue {
                memoryLatest = items.first ?? memoryLatest
                items.removeAll()
            }
            lock.unlock()
            if newValue { persist() } else { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// Newest first. Empty when history is off.
    public var all: [Item] { lock.lock(); defer { lock.unlock() }; return items }

    /// The newest item, from disk history or (history off) memory.
    public var latest: Item? { lock.lock(); defer { lock.unlock() }; return items.first ?? memoryLatest }

    public func add(_ item: Item) {
        lock.lock()
        memoryLatest = item
        guard enabled else { lock.unlock(); return }
        items.removeAll { $0.id == item.id }
        items.insert(item, at: 0)
        if items.count > capacity { items.removeLast(items.count - capacity) }
        lock.unlock()
        persist()
    }

    /// Replace an item in place (e.g. its delivery status changed).
    public func update(_ item: Item) {
        lock.lock()
        if (memoryLatest?.id).map({ $0 == item.id }) == true { memoryLatest = item }
        guard enabled, let i = items.firstIndex(where: { $0.id == item.id }) else { lock.unlock(); return }
        items[i] = item
        lock.unlock()
        persist()
    }

    public func remove(_ id: Item.ID) {
        lock.lock()
        items.removeAll { $0.id == id }
        if memoryLatest?.id == id { memoryLatest = nil }
        lock.unlock()
        persist()
    }

    public func clear() {
        lock.lock(); items.removeAll(); memoryLatest = nil; lock.unlock()
        try? FileManager.default.removeItem(at: url)
    }

    /// Writes happen here, in order, never on the caller's thread (a dictation lands on the main thread).
    private let writeQueue = DispatchQueue(label: "macrophone.history", qos: .utility)

    private func persist() {
        lock.lock()
        guard enabled else { lock.unlock(); return }
        let snapshot = items
        lock.unlock()
        let url = self.url
        writeQueue.async {
            if let d = try? WireCoding.encoder.encode(snapshot) {
                try? d.write(to: url, options: [.atomic])
            }
        }
    }
}
