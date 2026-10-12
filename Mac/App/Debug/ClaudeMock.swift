#if DEBUG
import Foundation

/// A mocked Claude transport for headless checks (MACROPHONE_CLAUDE_MOCK) — no network,
/// no tokens. Each mode answers the way the real API does.
final class ClaudeMock: URLProtocol {
    nonisolated(unsafe) static var mode = "ok"
    nonisolated(unsafe) static var lastBody: [String: Any]?
    nonisolated(unsafe) static var lastHeaders: [String: String] = [:]

    static func session(_ mode: String) -> URLSession {
        self.mode = mode
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [ClaudeMock.self]
        return URLSession(configuration: cfg)
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "api.anthropic.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
            stream.close()
            Self.lastBody = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        } else if let b = request.httpBody {
            Self.lastBody = (try? JSONSerialization.jsonObject(with: b)) as? [String: Any]
        }
        Self.lastHeaders = request.allHTTPHeaderFields ?? [:]
        print("claude mock: model=\(Self.lastBody?["model"] ?? "?") stream=\(Self.lastBody?["stream"] ?? "?") fallbacks=\(Self.lastBody?["fallbacks"] ?? "none") beta=\(Self.lastHeaders["anthropic-beta"] ?? "none") system=\(Self.lastBody?["system"] != nil)")
        fflush(stdout)
        switch Self.mode {
        case "offline":
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        case "badkey":
            respond(401, "{\"type\":\"error\",\"error\":{\"type\":\"authentication_error\",\"message\":\"invalid x-api-key\"}}")
            return
        case "ratelimit":
            respond(429, "{\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\",\"message\":\"rate limited\"}}")
            return
        default: break
        }
        if request.url?.path == "/v1/models" { respond(200, "{\"data\":[{\"id\":\"claude-sonnet-5-5\"}]}"); return }
        let words = ["OK", " — this", " reply", " came", " from", " the", " mocked", " transport."]
        var events = ["event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_mock\",\"model\":\"claude-sonnet-5-5\"}}\n\n",
                      "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n"]
        for w in words {
            let esc = w.replacingOccurrences(of: "\"", with: "\\\"")
            events.append("event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"\(esc)\"}}\n\n")
        }
        let stop = Self.mode == "refusal" ? "refusal" : "end_turn"
        events.append("event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"\(stop)\"}}\n\n")
        events.append("event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n")
        let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["content-type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        for e in events {
            client?.urlProtocol(self, didLoad: Data(e.utf8))
            usleep(90_000)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    private func respond(_ code: Int, _ body: String) {
        let resp = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: ["content-type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
#endif
