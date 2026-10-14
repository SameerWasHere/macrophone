import Foundation
import MacrophoneKit
import Network

/// The local pull API (docs/API.md). HTTP/1.1 on 127.0.0.1 only, one request per connection
/// (`Connection: close`), Bearer token, browsers locked out (any Origin / Sec-Fetch-Site →
/// 403, Host must be 127.0.0.1:<port> or localhost:<port>, no CORS, OPTIONS → 403).
final class LocalAPIServer: @unchecked Sendable {
    struct PhoneStatus: Encodable {
        var name: String
        var connected: Bool
        var last_seen: Date?
        enum CodingKeys: String, CodingKey { case name, connected, last_seen }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            try c.encode(connected, forKey: .connected)
            if let last_seen { try c.encode(last_seen, forKey: .last_seen) } else { try c.encodeNil(forKey: .last_seen) }
        }
    }

    struct Status: Encodable {
        var app_version: String
        var api_version = 1
        var history_enabled: Bool
        var phones: [PhoneStatus]
    }

    enum State: Equatable {
        case off
        case starting
        case listening(port: UInt16)
        case failed(String)
    }

    static let ports: ClosedRange<UInt16> = Product.apiPort...(Product.apiPort + 9)
    static let maxHeaderBytes = 16 * 1024

    /// Readers — thread-safe (the history store locks).
    var latest: () -> PulledDictation? = { nil }
    var history: (Int) -> [PulledDictation] = { _ in [] }
    var log: DiagnosticLog?
    /// Called on the main queue.
    var onStateChange: (State) -> Void = { _ in }

    private let queue = DispatchQueue(label: "macrophone.api")
    private let lock = NSLock()
    private var listener: NWListener?
    private var token: String
    private var status: Status
    private var port: UInt16 = 0
    private var waiters: [ObjectIdentifier: Waiter] = [:]
    private var generation = 0

    private final class Waiter {
        let connection: NWConnection
        var timeout: DispatchWorkItem?
        init(connection: NWConnection) { self.connection = connection }
    }

    init(token: String, status: Status) {
        self.token = token
        self.status = status
    }

    func setToken(_ t: String) { lock.lock(); token = t; lock.unlock() }
    func setStatus(_ s: Status) { lock.lock(); status = s; lock.unlock() }
    var currentPort: UInt16 { lock.lock(); defer { lock.unlock() }; return port }

    // MARK: Listener

    func start() {
        queue.async {
            self.stopLocked()
            self.generation += 1
            self.emit(.starting)
            self.tryPort(Self.ports.lowerBound, generation: self.generation)
        }
    }

    func stop() {
        queue.async {
            self.generation += 1
            self.stopLocked()
            self.emit(.off)
        }
    }

    private func stopLocked() {
        listener?.cancel()
        listener = nil
        lock.lock(); port = 0; lock.unlock()
        for w in waiters.values { w.timeout?.cancel(); w.connection.cancel() }
        waiters.removeAll()
    }

    private func tryPort(_ p: UInt16, generation g: Int) {
        guard g == generation else { return }
        guard p <= Self.ports.upperBound else {
            log?.add("API: no free port in \(Self.ports.lowerBound)–\(Self.ports.upperBound)")
            emit(.failed("Ports \(Self.ports.lowerBound)–\(Self.ports.upperBound) are all in use."))
            return
        }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: p)!)
        params.allowLocalEndpointReuse = false
        params.includePeerToPeer = false
        let l: NWListener
        do { l = try NWListener(using: params) } catch {
            tryPort(p + 1, generation: g); return
        }
        var settled = false
        l.stateUpdateHandler = { [weak self, weak l] state in
            guard let self, let l, g == self.generation else { l?.cancel(); return }
            switch state {
            case .ready:
                settled = true
                self.lock.lock(); self.port = p; self.lock.unlock()
                self.log?.add("API listening on 127.0.0.1:\(p)")
                self.emit(.listening(port: p))
            case .failed, .waiting:
                if !settled {
                    settled = true
                    l.cancel()
                    if self.listener === l { self.listener = nil }
                    self.tryPort(p + 1, generation: g)
                } else if case .failed(let e) = state {
                    self.log?.add("API listener failed: \(e)")
                    self.emit(.failed("The API stopped: \(e.localizedDescription)"))
                }
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        listener = l
        l.start(queue: queue)
    }

    private func emit(_ s: State) {
        DispatchQueue.main.async { self.onStateChange(s) }
    }

    // MARK: Requests

    private struct Request {
        var method: String
        var path: String
        var query: [String: String]
        var headers: [String: String]
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        // A client gets 10 s to send its headers.
        let deadline = DispatchWorkItem { [weak c] in c?.cancel() }
        queue.asyncAfter(deadline: .now() + 10, execute: deadline)
        readHeaders(c, buffer: Data(), deadline: deadline)
    }

    private func readHeaders(_ c: NWConnection, buffer: Data, deadline: DispatchWorkItem) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                deadline.cancel()
                let head = buf[buf.startIndex..<end.lowerBound]
                guard let req = Self.parse(head) else {
                    self.respond(c, 400, ["error": "Bad request."]); return
                }
                self.route(req, on: c)
                return
            }
            if buf.count > Self.maxHeaderBytes {
                deadline.cancel()
                self.respond(c, 431, ["error": "Request headers too large."]); return
            }
            if error != nil || complete { deadline.cancel(); c.cancel(); return }
            self.readHeaders(c, buffer: buf, deadline: deadline)
        }
    }

    private static func parse(_ head: Data) -> Request? {
        guard let text = String(data: head, encoding: .utf8) ?? String(data: head, encoding: .isoLatin1) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let first = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard first.count == 3, first[2].hasPrefix("HTTP/1.") else { return nil }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let k = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[k] = headers[k].map { $0 + ", " + v } ?? v
        }
        let target = String(first[1])
        let comps = URLComponents(string: target)
        var query: [String: String] = [:]
        for q in comps?.queryItems ?? [] { query[q.name] = q.value ?? "" }
        return Request(method: String(first[0]), path: comps?.path ?? target, query: query, headers: headers)
    }

    private func route(_ r: Request, on c: NWConnection) {
        // 1. Browsers: never.
        if r.headers["origin"] != nil || r.headers["sec-fetch-site"] != nil || r.headers["sec-fetch-mode"] != nil {
            log?.add("API refused a browser request")
            return respond(c, 403, ["error": "Browser requests aren't allowed."])
        }
        // 2. DNS rebinding: the Host must be this address.
        let p = currentPort
        let host = (r.headers["host"] ?? "").lowercased()
        guard host == "127.0.0.1:\(p)" || host == "localhost:\(p)" else {
            return respond(c, 403, ["error": "Wrong Host header."])
        }
        if r.method == "OPTIONS" { return respond(c, 403, ["error": "Browser requests aren't allowed."]) }
        // 3. The token.
        lock.lock(); let expected = "Bearer " + token; lock.unlock()
        guard let auth = r.headers["authorization"], Self.constantTimeEqual(auth, expected) else {
            return respond(c, 401, ["error": "Missing or wrong token. Find it in Macrophone › Developer."])
        }
        let known = ["/v1/latest", "/v1/history", "/v1/next", "/v1/status"]
        guard known.contains(r.path) else { return respond(c, 404, ["error": "Not found."]) }
        guard r.method == "GET" else { return respond(c, 405, ["error": "Use GET."], extra: ["Allow": "GET"]) }

        switch r.path {
        case "/v1/latest":
            if let item = latest() { respondItem(c, item) } else { respondEmpty(c) }
        case "/v1/history":
            var n = Int(r.query["limit"] ?? "") ?? 10
            n = min(50, max(1, n))
            let items = Array(history(50).prefix(n)).map(Item.init)
            respondJSON(c, 200, Self.encode(HistoryBody(items: items)))
        case "/v1/next":
            var t = Double(r.query["timeout"] ?? "") ?? 60
            t = min(300, max(1, t))
            wait(c, timeout: t)
        case "/v1/status":
            lock.lock(); let s = status; lock.unlock()
            respondJSON(c, 200, Self.encode(s))
        default:
            respond(c, 404, ["error": "Not found."])
        }
    }

    private struct HistoryBody: Encodable { var items: [Item] }

    /// One item on the wire (the same shape as `PulledDictation`), every key
    /// always present (null when absent) so the shape never changes between items.
    struct Item: Encodable {
        let d: PulledDictation
        init(_ d: PulledDictation) { self.d = d }
        enum K: String, CodingKey {
            case id, text, raw, cleaned, language, profile, delayed
            case cleanupLevel = "cleanup_level", createdAt = "created_at", receivedAt = "received_at"
            case stoppedEarly = "stopped_early", sourceDevice = "source_device"
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: K.self)
            try c.encode(d.id, forKey: .id)
            try c.encode(d.text, forKey: .text)
            try c.encode(d.raw, forKey: .raw)
            try c.encode(d.cleaned, forKey: .cleaned)
            try c.encode(d.cleanupLevel, forKey: .cleanupLevel)
            try c.encode(d.language, forKey: .language)
            try c.encode(d.profile, forKey: .profile)
            try c.encode(d.createdAt, forKey: .createdAt)
            try c.encode(d.receivedAt, forKey: .receivedAt)
            try c.encode(d.delayed, forKey: .delayed)
            try c.encode(d.stoppedEarly, forKey: .stoppedEarly)
            try c.encode(d.sourceDevice, forKey: .sourceDevice)
        }
    }

    // MARK: Long-poll

    private func wait(_ c: NWConnection, timeout: Double) {
        let w = Waiter(connection: c)
        let key = ObjectIdentifier(c)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.waiters.removeValue(forKey: key) != nil else { return }
            self.respondEmpty(c)
        }
        w.timeout = work
        waiters[key] = w
        queue.asyncAfter(deadline: .now() + timeout, execute: work)
        watchForHangup(c) { [weak self] in
            guard let self, let w = self.waiters.removeValue(forKey: key) else { return }
            w.timeout?.cancel()
        }
    }

    private func watchForHangup(_ c: NWConnection, _ onHangup: @escaping () -> Void) {
        c.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: onHangup()
            default: break
            }
        }
        func drain() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, complete, error in
                if complete || error != nil { c.cancel(); return }
                if data != nil { drain() }
            }
        }
        drain()
    }

    /// A new dictation arrived (call from anywhere).
    func publish(_ item: PulledDictation) {
        queue.async {
            for (key, w) in self.waiters {
                w.timeout?.cancel()
                self.waiters.removeValue(forKey: key)
                self.respondItem(w.connection, item)
            }
        }
    }

    // MARK: Responses

    private func respondItem(_ c: NWConnection, _ item: PulledDictation) {
        respondJSON(c, 200, Self.encode(Item(item)))
    }

    private func respondEmpty(_ c: NWConnection) {
        send(c, status: 204, headers: [:], body: Data())
    }

    private func respond(_ c: NWConnection, _ code: Int, _ body: [String: String], extra: [String: String] = [:]) {
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
        var headers = extra
        headers["Content-Type"] = "application/json; charset=utf-8"
        send(c, status: code, headers: headers, body: data + Data("\n".utf8))
    }

    private func respondJSON(_ c: NWConnection, _ code: Int, _ body: Data) {
        send(c, status: code, headers: ["Content-Type": "application/json; charset=utf-8"], body: body + Data("\n".utf8))
    }

    private func send(_ c: NWConnection, status: Int, headers: [String: String], body: Data) {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        var h = headers
        h["Connection"] = "close"
        h["Cache-Control"] = "no-store"
        h["X-Content-Type-Options"] = "nosniff"
        if status != 204 { h["Content-Length"] = String(body.count) }
        for (k, v) in h.sorted(by: { $0.key < $1.key }) { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        c.send(content: Data(head.utf8) + (status == 204 ? Data() : body), contentContext: .finalMessage, isComplete: true,
               completion: .contentProcessed { _ in c.cancel() })
    }

    private static func reason(_ s: Int) -> String {
        switch s {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 431: return "Request Header Fields Too Large"
        default: return "Error"
        }
    }

    private static let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    static func encode<T: Encodable>(_ v: T) -> Data { (try? jsonEncoder.encode(v)) ?? Data("{}".utf8) }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var d: UInt8 = 0
        for i in 0..<x.count { d |= x[i] ^ y[i] }
        return d == 0
    }
}
