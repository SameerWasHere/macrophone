import Foundation
import Security

/// The person's own Anthropic API key, in the login keychain. Never written anywhere else,
/// never in diagnostics.
enum ClaudeKey {
    private static var service: String { (Bundle.main.bundleIdentifier ?? "com.sameer.macrophone.mac") + ".anthropic-api-key" }
    private static let account = "default"

    static func load() -> String? {
        #if DEBUG
        if let k = ProcessInfo.processInfo.environment["MACROPHONE_CLAUDE_KEY"], !k.isEmpty { return k }
        #endif
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        let s = String(decoding: d, as: UTF8.self)
        return s.isEmpty ? nil : s
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        delete()
        let attrs: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecValueData as String: Data(key.utf8),
                                    kSecAttrLabel as String: "Macrophone — Anthropic API key",
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }

    /// "sk-ant-api03-…AbCd" — enough to recognise, never the whole thing.
    static func masked(_ key: String) -> String {
        guard key.count > 16 else { return String(repeating: "•", count: key.count) }
        return String(key.prefix(10)) + String(repeating: "•", count: 12) + String(key.suffix(4))
    }
}

/// A direct call to the Claude API (Messages, streamed) with the person's own key. Raw HTTP:
/// there's no official Swift SDK.
struct ClaudeClient {
    static let models: [(id: String, name: String, line: String)] = [
        ("claude-sonnet-5-5", "Claude Sonnet 5.5", "Fast and capable — the default."),
        ("claude-opus-5-5", "Claude Opus 5.5", "The most capable. Slower, costs more."),
        ("claude-haiku-5-5", "Claude Haiku 5.5", "The quickest and cheapest."),
    ]
    static let defaultModel = "claude-sonnet-5-5"

    static func name(of model: String) -> String { models.first { $0.id == model }?.name ?? model }

    enum Failure: Error, Equatable {
        case noKey, badKey, rateLimited, overloaded, offline, refused, tooLong
        case other(String)

        var title: String {
            switch self {
            case .noKey: return "Add your Anthropic API key to ask Claude"
            case .badKey: return "Claude didn't accept your API key"
            case .rateLimited: return "Claude is rate-limiting your key"
            case .overloaded: return "Claude is busy right now"
            case .offline: return "Couldn't reach Claude"
            case .refused: return "Claude declined to answer this one"
            case .tooLong: return "Claude's reply hit the length limit"
            case .other(let s): return s
            }
        }

        var detail: String {
            switch self {
            case .noKey: return "Developer › Claude API key. Your dictation is on your clipboard."
            case .badKey: return "Check or replace the key in Developer › Claude API key."
            case .rateLimited: return "Wait a moment and try again."
            case .overloaded: return "Try again in a minute."
            case .offline: return "Check your internet connection and try again."
            case .refused: return "Nothing was sent on your behalf."
            case .tooLong: return "What arrived is kept."
            case .other: return "Try again."
            }
        }
    }

    var key: String
    var model: String
    var system: String?
    var session: URLSession = .shared
    var endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    /// The request body. Sonnet 5.5 and Opus 5.5 opt into the server-side fallback, so a
    /// classifier decline is answered by the recommended fallback model instead of nothing.
    func request(for text: String) -> URLRequest {
        var r = URLRequest(url: endpoint, timeoutInterval: 120)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        r.setValue(key, forHTTPHeaderField: "x-api-key")
        r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "stream": true,
            "messages": [["role": "user", "content": text]],
        ]
        if let system, !system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { body["system"] = system }
        if model == "claude-sonnet-5-5" || model == "claude-opus-5-5" {
            body["fallbacks"] = "default"
            r.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return r
    }

    /// Streams the reply: `onText` gets the whole reply so far after every piece.
    func stream(_ text: String, onText: @escaping @MainActor (String) -> Void) async throws -> String {
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: request(for: text))
        } catch {
            throw Failure.offline
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status != 200 {
            var body = Data()
            for try await b in bytes { body.append(b); if body.count > 8000 { break } }
            throw Self.failure(status: status, body: body)
        }
        var reply = ""
        var stopReason: String?
        do {
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
                      let type = obj["type"] as? String else { continue }
                switch type {
                case "content_block_start":
                    // A fallback boundary: the first model declined mid-answer and another
                    // continues — drop what the declined one wrote.
                    if let block = obj["content_block"] as? [String: Any], block["type"] as? String == "fallback" {
                        reply = ""
                        await onText(reply)
                    }
                case "content_block_delta":
                    if let delta = obj["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                       let piece = delta["text"] as? String {
                        reply += piece
                        await onText(reply)
                    }
                case "message_delta":
                    if let delta = obj["delta"] as? [String: Any], let s = delta["stop_reason"] as? String { stopReason = s }
                case "error":
                    let e = obj["error"] as? [String: Any]
                    switch e?["type"] as? String {
                    case "overloaded_error": throw Failure.overloaded
                    case "rate_limit_error": throw Failure.rateLimited
                    default: throw Failure.other("Claude stopped: \(e?["message"] as? String ?? "an error")")
                    }
                default: break
                }
            }
        } catch let f as Failure {
            throw f
        } catch {
            throw Failure.offline
        }
        if stopReason == "refusal" { throw Failure.refused }
        if stopReason == "max_tokens" && reply.isEmpty { throw Failure.tooLong }
        return reply
    }

    static func failure(status: Int, body: Data) -> Failure {
        let type = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any]).flatMap { ($0["error"] as? [String: Any])?["type"] as? String }
        switch (status, type) {
        case (401, _), (_, "authentication_error"): return .badKey
        case (403, _), (_, "permission_error"): return .other("Your API key isn't allowed to do this")
        case (429, _): return .rateLimited
        case (529, _), (503, _), (_, "overloaded_error"): return .overloaded
        case (402, _), (_, "billing_error"): return .other("Your Anthropic account needs credit")
        case (404, _), (_, "not_found_error"): return .other("Your key can't use that model")
        default: return .other("Claude answered \(status)")
        }
    }

    /// Checks a key without spending tokens: lists the models it can use.
    static func test(key: String, session: URLSession = .shared) async -> Result<Void, Failure> {
        var r = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=1")!, timeoutInterval: 15)
        r.setValue(key, forHTTPHeaderField: "x-api-key")
        r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        do {
            let (data, resp) = try await session.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            return code == 200 ? .success(()) : .failure(failure(status: code, body: data))
        } catch {
            return .failure(.offline)
        }
    }
}
