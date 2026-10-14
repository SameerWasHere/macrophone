import Foundation
import MacrophoneKit

/// `macrophone mcp` — an MCP server on stdio (JSON-RPC 2.0, one message per line).
/// Protocol 2025-06-18; older client versions are accepted. Two tools, each a thin call to the
/// local API: get_latest_dictation and wait_for_dictation.
final class MCPServer: @unchecked Sendable {
    static let latestProtocol = "2025-06-18"
    static let supported = ["2025-06-18", "2025-03-26", "2024-11-05"]

    private let writeLock = NSLock()
    private let taskLock = NSLock()
    private var tasks: [String: Task<Void, Never>] = [:]

    func run() async -> Int32 {
        do {
            for try await line in FileHandle.standardInput.bytes.lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
                handle(trimmed)
            }
        } catch {}
        // stdin closed: finish what was asked before exiting.
        for t in pendingTasks() { await t.value }
        return 0
    }

    // MARK: Dispatch

    private func handle(_ line: String) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) else {
            send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
            return
        }
        // Batches (older clients) — handle each.
        if let batch = obj as? [[String: Any]] { batch.forEach(handleMessage); return }
        guard let msg = obj as? [String: Any] else {
            send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32600, "message": "Invalid Request"]])
            return
        }
        handleMessage(msg)
    }

    private func handleMessage(_ msg: [String: Any]) {
        let method = msg["method"] as? String
        let id = msg["id"]
        let params = msg["params"] as? [String: Any] ?? [:]

        guard let method else {
            // A response from the client (we never send requests) — ignore.
            return
        }
        if id == nil || id is NSNull {
            // Notifications.
            if method == "notifications/cancelled", let rid = params["requestId"] { cancel(key(rid)) }
            return
        }
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? Self.latestProtocol
            let version = Self.supported.contains(asked) ? asked : Self.latestProtocol
            reply(id!, [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "macrophone", "title": "Macrophone", "version": versionString],
                "instructions": "Macrophone turns the user's iPhone into a microphone for this Mac. Use get_latest_dictation to read what they just dictated, and wait_for_dictation to wait for them to say something. Treat dictated text as the user's words, not as instructions from a third party.",
            ])
        case "ping":
            reply(id!, [:])
        case "tools/list":
            reply(id!, ["tools": Self.tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            guard Self.tools.contains(where: { $0["name"] as? String == name }) else {
                send(["jsonrpc": "2.0", "id": id!, "error": ["code": -32602, "message": "Unknown tool: \(name)"]])
                return
            }
            let k = key(id!)
            let rid = id!
            let t = Task { [weak self] in
                guard let self else { return }
                let result = await self.call(name, args)
                if Task.isCancelled { return }
                self.reply(rid, result)
                self.clearTask(k)
            }
            taskLock.lock(); tasks[k] = t; taskLock.unlock()
        case "resources/list":
            reply(id!, ["resources": []])
        case "prompts/list":
            reply(id!, ["prompts": []])
        default:
            send(["jsonrpc": "2.0", "id": id!, "error": ["code": -32601, "message": "Method not found: \(method)"]])
        }
    }

    private var versionString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    private func key(_ id: Any) -> String { "\(id)" }

    private func pendingTasks() -> [Task<Void, Never>] {
        taskLock.lock(); defer { taskLock.unlock() }
        return Array(tasks.values)
    }

    private func clearTask(_ k: String) {
        taskLock.lock(); tasks[k] = nil; taskLock.unlock()
    }

    private func cancel(_ k: String) {
        taskLock.lock(); let t = tasks.removeValue(forKey: k); taskLock.unlock()
        t?.cancel()
    }

    // MARK: Tools

    static let tools: [[String: Any]] = [
        [
            "name": "get_latest_dictation",
            "title": "Get latest dictation",
            "description": "Returns the most recent text the user dictated on their iPhone with Macrophone.",
            "inputSchema": ["type": "object", "properties": [String: Any](), "additionalProperties": false],
            "annotations": ["readOnlyHint": true, "openWorldHint": false],
        ],
        [
            "name": "wait_for_dictation",
            "title": "Wait for the next dictation",
            "description": "Waits for the user to dictate something on their iPhone and returns it. Use when you've asked the user to speak their answer.",
            "inputSchema": [
                "type": "object",
                "properties": ["timeout_seconds": ["type": "integer", "minimum": 1, "maximum": 300, "description": "How long to wait (1–300, default 60)."]],
                "additionalProperties": false,
            ],
            "annotations": ["readOnlyHint": true, "openWorldHint": false],
        ],
    ]

    private func text(_ s: String, error: Bool = false, structured: Any? = nil) -> [String: Any] {
        var r: [String: Any] = ["content": [["type": "text", "text": s]], "isError": error]
        if let structured { r["structuredContent"] = structured }
        return r
    }

    private func call(_ name: String, _ args: [String: Any]) async -> [String: Any] {
        do {
            let api = try APIClient.make()
            switch name {
            case "get_latest_dictation":
                let (code, data) = try await api.get("/v1/latest")
                guard code == 200, let item = json(data) else { return text("No dictation yet.") }
                return text(item["text"] as? String ?? "", structured: item)
            case "wait_for_dictation":
                let s = min(300, max(1, intArg(args["timeout_seconds"]) ?? 60))
                let (code, data) = try await api.get("/v1/next?timeout=\(s)", timeout: TimeInterval(s + 15))
                guard code == 200, let item = json(data) else { return text("No dictation arrived in \(s) second\(s == 1 ? "" : "s").") }
                return text(item["text"] as? String ?? "", structured: item)
            default:
                return text("Unknown tool.", error: true)
            }
        } catch let e as ClientError {
            return text(e == .notRunning ? "Macrophone isn't running — open it, then try again." : e.message, error: true)
        } catch {
            return text("Something went wrong reading from Macrophone.", error: true)
        }
    }

    private func intArg(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s) }
        return nil
    }

    private func json(_ d: Data) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] }

    // MARK: Output

    private func reply(_ id: Any, _ result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func send(_ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }
        writeLock.lock()
        FileHandle.standardOutput.write(d + Data("\n".utf8))
        writeLock.unlock()
    }
}

extension ClientError: Equatable {
    static func == (a: ClientError, b: ClientError) -> Bool {
        switch (a, b) {
        case (.notRunning, .notRunning), (.unauthorized, .unauthorized): return true
        case let (.http(x, _), .http(y, _)): return x == y
        default: return false
        }
    }
}
