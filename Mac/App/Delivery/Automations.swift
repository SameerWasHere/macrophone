import Foundation
import MacrophoneKit

/// A profile's post-actions that can send text off this Mac. Contract: docs/API.md
/// (Webhook body, Script).
enum Automations {
    struct Failure: Error, CustomStringConvertible {
        var message: String
        var description: String { message }
    }

    // MARK: Webhook

    struct WebhookBody: Encodable {
        var id: String
        var text: String
        var raw: String
        var cleaned: String?
        var profile: String
        var created_at: Date
        var language: String
        var source_device: String
        var delayed: Bool
    }

    static func body(for d: Dictation, text: String, profile: String, delayed: Bool) -> Data {
        let b = WebhookBody(id: d.id.uuidString, text: text, raw: d.raw, cleaned: d.cleaned, profile: profile,
                            created_at: d.createdAt, language: d.language, source_device: d.sourceDevice, delayed: delayed)
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // `cleaned` is always present in the body (null when there's no cleaned version).
        if var obj = (try? JSONSerialization.jsonObject(with: (try? e.encode(b)) ?? Data())) as? [String: Any] {
            if obj["cleaned"] == nil { obj["cleaned"] = NSNull() }
            return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        }
        return (try? e.encode(b)) ?? Data()
    }

    /// POST with a 10 s timeout and one retry after 3 s.
    static func postWebhook(_ url: URL, body: Data) async throws {
        var lastError = "no answer"
        for attempt in 0..<2 {
            if attempt == 1 { try await Task.sleep(nanoseconds: 3_000_000_000) }
            var req = URLRequest(url: url, timeoutInterval: 10)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("\(Product.name)/\(AppPaths.appVersion)", forHTTPHeaderField: "User-Agent")
            req.httpBody = body
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(code) { return }
                lastError = "the server answered \(code)"
            } catch {
                lastError = (error as? URLError)?.code == .timedOut ? "it timed out" : "couldn't connect"
            }
        }
        throw Failure(message: "Webhook failed — \(lastError)")
    }

    // MARK: Script

    /// `/bin/zsh -lc "<command>"`, the text on stdin, MACROPHONE_* in the environment,
    /// a 30 s limit. Non-zero exit → the first line of stderr.
    static func runScript(_ command: String, text: String, raw: String, profile: String, id: UUID) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/zsh")
                p.arguments = ["-lc", command]
                var env = ProcessInfo.processInfo.environment
                env["MACROPHONE_TEXT"] = text
                env["MACROPHONE_RAW"] = raw
                env["MACROPHONE_PROFILE"] = profile
                env["MACROPHONE_ID"] = id.uuidString
                p.environment = env
                p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
                let stdin = Pipe(), stderr = Pipe()
                p.standardInput = stdin
                p.standardOutput = FileHandle.nullDevice
                p.standardError = stderr
                do { try p.run() } catch {
                    c.resume(throwing: Failure(message: "Script couldn't start")); return
                }
                // Write stdin off this thread so a script that never reads can't block us.
                DispatchQueue.global().async {
                    stdin.fileHandleForWriting.write(Data(text.utf8))
                    try? stdin.fileHandleForWriting.close()
                }
                var errData = Data()
                let errReader = DispatchQueue(label: "macrophone.script.stderr")
                let group = DispatchGroup()
                group.enter()
                errReader.async {
                    errData = stderr.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let timedOut = DispatchSemaphore(value: 0)
                var killed = false
                DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
                    if p.isRunning { killed = true; p.terminate() }
                    timedOut.signal()
                }
                p.waitUntilExit()
                _ = group.wait(timeout: .now() + 2)
                if killed {
                    c.resume(throwing: Failure(message: "Script stopped after 30 seconds"))
                } else if p.terminationStatus != 0 {
                    let first = String(decoding: errData, as: UTF8.self)
                        .split(whereSeparator: \.isNewline).first.map(String.init)?
                        .trimmingCharacters(in: .whitespaces) ?? ""
                    c.resume(throwing: Failure(message: first.isEmpty ? "Script exited with code \(p.terminationStatus)"
                                                                       : "Script failed: \(first)"))
                } else {
                    c.resume()
                }
            }
        }
    }
}
