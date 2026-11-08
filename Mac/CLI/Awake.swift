import Foundation

/// `mp awake on | off | status | displays on | off` — Keep Awake from the terminal (Nov 7 2026),
/// through the local API (`/v1/awake`). `--json` prints the API's answer on one line.
enum Awake {
    static let usage = "usage: mp awake on | off | status | displays on | off  [--json]"

    static func run(_ args: [String]) async -> Int32 {
        let json = args.contains("--json")
        let words = args.filter { $0 != "--json" }
        let action: String?
        switch words {
        case [], ["status"]: action = nil
        case ["on"]: action = "on"
        case ["off"]: action = "off"
        case ["displays", "on"]: action = "displays_on"
        case ["displays", "off"]: action = "displays_off"
        default: err(usage); return 2
        }
        do {
            let api = try APIClient.make()
            let code: Int, data: Data
            if let action { (code, data) = try await api.post("/v1/awake", json: ["action": action]) }
            else { (code, data) = try await api.get("/v1/awake") }
            guard code == 200 else { err("Macrophone answered \(code)."); return 1 }
            if json { out(oneLine(data)); return 0 }
            let s = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            out("Keep Awake: \(s["line"] as? String ?? "?")")
            if let b = s["battery"] as? Int { out("Battery: \(b)%\(s["charging"] as? Bool == true ? " (charging)" : "")") }
            for key in ["blocked", "problem", "warning"] { if let t = s[key] as? String { out(t) } }
            if s["sleep_still_off"] as? Bool == true { out("Your Mac is set never to sleep — open Macrophone › Keep Awake and choose Restore Normal Sleep.") }
            if s["dry_run"] as? Bool == true { out("(A dry run: this Macrophone only logs what it would change.)") }
            // A turn-on that didn't happen exits 1, so a script can tell.
            if action == "on", s["on"] as? Bool != true { return 1 }
            return 0
        } catch let e as ClientError {
            err(e.message)
            return e.exitCode
        } catch {
            err("\(error)")
            return 1
        }
    }
}
