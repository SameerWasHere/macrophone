import Foundation

/// A plain-text log for "Share diagnostics". Records what happened — pairing steps,
/// connection errors, delivery results — and NEVER dictation text or key material.
/// Callers pass fixed phrases plus counts and error descriptions only.
public final class DiagnosticLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private let capacity: Int
    private let url: URL?
    /// Writes happen here, coalesced, never on the caller's thread.
    private let writeQueue = DispatchQueue(label: "macrophone.diagnostics", qos: .utility)
    private var writeScheduled = false
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public init(url: URL?, capacity: Int = 800) {
        self.url = url
        self.capacity = capacity
        if let url, let s = try? String(contentsOf: url, encoding: .utf8) {
            lines = s.split(separator: "\n").suffix(capacity).map(String.init)
        }
    }

    public func add(_ event: String) {
        let line = "\(formatter.string(from: Date()))  \(Self.scrub(event))"
        lock.lock()
        lines.append(line)
        if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
        let schedule = url != nil && !writeScheduled
        if schedule { writeScheduled = true }
        lock.unlock()
        #if DEBUG
        print("[macrophone] \(event)")
        #endif
        guard schedule, let url else { return }
        // One write per half second at most, off the caller's thread.
        writeQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let snapshot = self.lines
            self.writeScheduled = false
            self.lock.unlock()
            try? snapshot.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// The exported text: a header the caller provides (app version, OS, device model,
    /// settings that matter) and the event lines.
    public func export(header: [(String, String)]) -> String {
        lock.lock(); let snapshot = lines; lock.unlock()
        var out = "\(Product.name) diagnostics\n"
        out += "Generated \(formatter.string(from: Date()))\n"
        out += "This log never contains what you dictated or your pairing keys.\n\n"
        for (k, v) in header { out += "\(k): \(v)\n" }
        out += "\n--- events (\(snapshot.count)) ---\n"
        out += snapshot.joined(separator: "\n")
        out += "\n"
        return out
    }

    public func clear() {
        lock.lock(); lines.removeAll(); lock.unlock()
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    /// Belt and braces: strip anything that looks like a key, token or long base64 run.
    static func scrub(_ s: String) -> String {
        var out = s
        if let re = try? NSRegularExpression(pattern: "[A-Za-z0-9+/_=-]{32,}") {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "[redacted]")
        }
        return String(out.prefix(400))
    }
}
