import Foundation

/// tmux pane targeting: types into a pane (`session:window.pane`) whatever app is in front.
enum Tmux {
    struct Pane: Identifiable, Hashable {
        /// "work:1.0"
        var target: String
        var command: String
        var path: String
        var id: String { target }

        /// "~/code/app"
        var shortPath: String {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        }
    }

    struct Failure: Error { var message: String }

    /// tmux in Homebrew's folders, else whatever a login shell finds.
    static var executable: String? {
        if let cached { return cached.isEmpty ? nil : cached }
        let fm = FileManager.default
        for p in ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"] where fm.isExecutableFile(atPath: p) {
            cached = p
            return p
        }
        let found = (try? shell(["/bin/zsh", "-lc", "command -v tmux"]))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        cached = fm.isExecutableFile(atPath: found) ? found : ""
        return cached!.isEmpty ? nil : cached
    }
    nonisolated(unsafe) private static var cached: String?
    static func forgetLocation() { cached = nil }

    @discardableResult
    private static func shell(_ argv: [String], stdin: String? = nil, timeout: TimeInterval = 5) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = stdin == nil ? FileHandle.nullDevice : inp
        try p.run()
        if let stdin {
            inp.fileHandleForWriting.write(Data(stdin.utf8))
            try? inp.fileHandleForWriting.close()
        }
        let deadline = Date().addingTimeInterval(timeout)
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        while p.isRunning && Date() < deadline { usleep(10_000) }
        if p.isRunning { p.terminate(); throw Failure(message: "tmux didn't answer") }
        if p.terminationStatus != 0 {
            let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .split(whereSeparator: \.isNewline).first.map(String.init) ?? "exit \(p.terminationStatus)"
            throw Failure(message: e)
        }
        return String(decoding: outData, as: UTF8.self)
    }

    private static func tmux(_ args: [String], stdin: String? = nil) throws -> String {
        guard let exe = executable else { throw Failure(message: "tmux isn't installed (brew install tmux)") }
        return try shell([exe] + args, stdin: stdin)
    }

    /// Every pane of every session. Empty when tmux isn't running.
    static func panes() -> [Pane] {
        guard let out = try? tmux(["list-panes", "-a", "-F", "#{session_name}:#{window_index}.#{pane_index}\t#{pane_current_command}\t#{pane_current_path}"]) else { return [] }
        return out.split(whereSeparator: \.isNewline).compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 3 else { return nil }
            return Pane(target: f[0], command: f[1], path: f[2])
        }
    }

    static func paneExists(_ target: String) -> Bool {
        (try? tmux(["display-message", "-p", "-t", target, "#{pane_id}"])) != nil
    }

    static func currentPath(_ target: String) -> String? {
        (try? tmux(["display-message", "-p", "-t", target, "#{pane_current_path}"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Types `text` into the pane, then Enter when `enter`. One line goes as literal keys;
    /// several lines go as a bracketed paste, so a line break never runs a half-typed command.
    static func send(_ text: String, to target: String, enter: Bool) async throws {
        try await Task.detached(priority: .userInitiated) {
            guard paneExists(target) else { throw Failure(message: "There's no tmux pane \(target) right now") }
            if text.contains("\n") {
                _ = try tmux(["load-buffer", "-b", "macrophone", "-"], stdin: text)
                _ = try tmux(["paste-buffer", "-p", "-d", "-b", "macrophone", "-t", target])
            } else {
                _ = try tmux(["send-keys", "-t", target, "-l", text])
            }
            if enter {
                usleep(120_000)
                _ = try tmux(["send-keys", "-t", target, "Enter"])
            }
        }.value
    }
}
