import Foundation
import MacrophoneKit

/// Dictations waiting for the Mac, in the order they were spoken. Text only, on disk, so a
/// queued item survives the app being closed. Each keeps its id, so a retry is never a duplicate.
@MainActor
final class DeliveryQueue: ObservableObject {
    struct Entry: Codable, Identifiable, Hashable {
        var dictation: Dictation
        /// It missed the Mac at least once — the Mac shows it as delayed and never auto-sends it.
        var delayed: Bool
        var attempts: Int
        var id: UUID { dictation.id }
    }

    @Published private(set) var entries: [Entry] = []
    private let url: URL

    init(url: URL) {
        self.url = url
        if let d = try? Data(contentsOf: url), let list = try? Self.decoder.decode([Entry].self, from: d) {
            entries = list
        }
    }

    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }
    func contains(_ id: UUID) -> Bool { entries.contains { $0.id == id } }

    func append(_ d: Dictation, delayed: Bool) {
        if let i = entries.firstIndex(where: { $0.id == d.id }) {
            entries[i].dictation = d
            entries[i].delayed = entries[i].delayed || delayed
        } else {
            entries.append(Entry(dictation: d, delayed: delayed, attempts: 0))
        }
        persist()
    }

    func markAttempt(_ id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].attempts += 1
        entries[i].delayed = true
        persist()
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        persist()
    }

    func removeAll() {
        entries.removeAll()
        persist()
    }

    private func persist() {
        if entries.isEmpty { try? FileManager.default.removeItem(at: url); return }
        if let d = try? Self.encoder.encode(entries) {
            try? d.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}
