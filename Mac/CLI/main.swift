import Foundation
import MacrophoneKit

// macrophone (alias mp) — read what you dictated on your iPhone, from the terminal.
// Contract: docs/API.md › CLI. Exit codes: 0 ok, 1 nothing/timeout, 2 usage,
// 3 Mac app not running or API off, 4 auth failed.

let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"

let usage = """
macrophone — read what you dictate on your iPhone (alias: mp)

Usage:
  mp                                same as `mp latest`
  mp latest [--raw] [--json]        print the latest dictation (--raw: the raw transcript)
  mp list [-n 10] [--json]          recent dictations, newest first (1–50)
  mp wait [--timeout 60] [--json]   wait for the next dictation and print it (exit 1 on timeout)
  mp watch [--json]                 print every new dictation as it arrives
  mp status                         is Macrophone running, which iPhones are connected
  mp mcp                            run the MCP server on stdio (for Claude and other agents)
  mp --version | --help

Exit codes: 0 ok · 1 nothing yet / timed out · 2 usage · 3 Macrophone not running or API off · 4 token rejected
"""

func out(_ s: String) {
    FileHandle.standardOutput.write(Data((s.hasSuffix("\n") ? s : s + "\n").utf8))
}

func err(_ s: String) {
    FileHandle.standardError.write(Data((s.hasSuffix("\n") ? s : s + "\n").utf8))
}

struct Options {
    var command = "latest"
    var json = false
    var raw = false
    var count = 10
    var timeout = 60
}

func parse(_ argv: [String]) -> Options? {
    var o = Options()
    var args = argv[...]
    if let first = args.first, !first.hasPrefix("-") {
        o.command = first
        args = args.dropFirst()
    }
    while let a = args.popFirst() {
        switch a {
        case "--json": o.json = true
        case "--raw": o.raw = true
        case "-n", "--count", "--limit":
            guard let v = args.popFirst(), let n = Int(v), (1...50).contains(n) else { err("-n takes a number from 1 to 50"); return nil }
            o.count = n
        case "--timeout", "-t":
            guard let v = args.popFirst(), let n = Int(v), (1...300).contains(n) else { err("--timeout takes seconds from 1 to 300"); return nil }
            o.timeout = n
        case "--help", "-h": o.command = "help"
        case "--version", "-v", "-V": o.command = "version"
        default:
            if a.hasPrefix("-n"), let n = Int(a.dropFirst(2)), (1...50).contains(n) { o.count = n; continue }
            err("Unknown option \(a). Try `mp --help`.")
            return nil
        }
    }
    return o
}

func decodeItem(_ d: Data) -> PulledDictation? { try? PulledDictation.decoder.decode(PulledDictation.self, from: d) }

func compactJSON(_ item: PulledDictation) -> String {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: (try? e.encode(item)) ?? Data(), as: UTF8.self)
}

func prettyJSON(_ item: PulledDictation) -> String {
    String(decoding: (try? PulledDictation.encoder.encode(item)) ?? Data(), as: UTF8.self)
}

func timeLabel(_ d: Date) -> String {
    let f = DateFormatter()
    if Calendar.current.isDateInToday(d) { f.timeStyle = .short; f.dateStyle = .none } else { f.setLocalizedDateFormatFromTemplate("MMM d j:mm") }
    return f.string(from: d)
}

func run() async -> Int32 {
    guard let o = parse(Array(CommandLine.arguments.dropFirst())) else { return 2 }
    switch o.command {
    case "help": out(usage); return 0
    case "version": out("macrophone \(version)"); return 0
    case "mcp": return await MCPServer().run()
    case "latest", "list", "wait", "watch", "status": break
    default:
        err("Unknown command \(o.command). Try `mp --help`.")
        return 2
    }

    do {
        let api = try APIClient.make()
        switch o.command {
        case "latest":
            let (code, data) = try await api.get("/v1/latest")
            guard code == 200, let item = decodeItem(data) else { err("Nothing dictated yet."); return 1 }
            out(o.json ? prettyJSON(item) : (o.raw ? item.raw : item.text))

        case "list":
            let (_, data) = try await api.get("/v1/history?limit=\(o.count)")
            if o.json { out(String(decoding: data, as: UTF8.self)); return 0 }
            struct Body: Decodable { var items: [PulledDictation] }
            let items = (try? PulledDictation.decoder.decode(Body.self, from: data))?.items ?? []
            if items.isEmpty { err("Nothing dictated yet."); return 1 }
            for item in items {
                let text = (o.raw ? item.raw : item.text).replacingOccurrences(of: "\n", with: "\n      ")
                out("\(timeLabel(item.receivedAt))  \(text)")
            }

        case "wait":
            let (code, data) = try await api.get("/v1/next?timeout=\(o.timeout)", timeout: TimeInterval(o.timeout + 15))
            guard code == 200, let item = decodeItem(data) else { err("No dictation arrived in \(o.timeout) second\(o.timeout == 1 ? "" : "s")."); return 1 }
            out(o.json ? compactJSON(item) : (o.raw ? item.raw : item.text))

        case "watch":
            try await api.stream { data in
                guard let item = decodeItem(data) else { return }
                out(o.json ? compactJSON(item) : (o.raw ? item.raw : item.text))
            }

        case "status":
            let (_, data) = try await api.get("/v1/status")
            if o.json { out(String(decoding: data, as: UTF8.self)); return 0 }
            let s = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            out("Macrophone \(s["app_version"] as? String ?? "?") is running · API v\(s["api_version"] as? Int ?? 1) on 127.0.0.1:\(api.config.port)")
            out("History: \((s["history_enabled"] as? Bool ?? true) ? "on" : "off (only the latest is kept, in memory)")")
            let phones = s["phones"] as? [[String: Any]] ?? []
            if phones.isEmpty { out("iPhones: none paired") }
            for p in phones {
                let name = p["name"] as? String ?? "iPhone"
                if p["connected"] as? Bool == true {
                    out("iPhone: \(name) — connected")
                } else if let seen = p["last_seen"] as? String, let d = ISO8601DateFormatter().date(from: seen) {
                    out("iPhone: \(name) — last seen \(timeLabel(d))")
                } else {
                    out("iPhone: \(name) — not connected")
                }
            }
        default: break
        }
        return 0
    } catch let e as ClientError {
        err(e.message)
        return e.exitCode
    } catch {
        err("\(error)")
        return 1
    }
}

setvbuf(stdout, nil, _IOLBF, 0)
exit(await run())
