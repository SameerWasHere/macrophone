import Foundation

// MacrophoneHelper — Keep Awake's root daemon (Nov 7 2026). It does one job: run the `pmset`
// changes the allowlist (PowerChange, shared with MacrophoneKit) lets through, for Macrophone
// only (a code-signing requirement on every connection). Started by launchd on demand; quits
// itself after ten quiet minutes and launchd starts it again when it's next called.

final class HelperService: NSObject, MacrophonePowerHelperProtocol, NSXPCListenerDelegate {
    private var lastCall = Date()
    private let lock = NSLock()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(PowerHelperIdentity.clientRequirement)
        connection.exportedInterface = NSXPCInterface(with: MacrophonePowerHelperProtocol.self)
        connection.exportedObject = self
        connection.resume()
        touch()
        return true
    }

    private func touch() { lock.lock(); lastCall = Date(); lock.unlock() }
    var quietFor: TimeInterval { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(lastCall) }

    func version(reply: @escaping (Int) -> Void) {
        touch()
        reply(PowerHelperVersion.current)
    }

    func apply(_ changes: [String], reply: @escaping (Bool, String) -> Void) {
        touch()
        guard !changes.isEmpty, changes.count <= 16 else { reply(false, "no changes"); return }
        var parsed: [PowerChange] = []
        for c in changes {
            guard let p = PowerChange(wire: c) else { reply(false, "refused \(c.prefix(40))"); return }
            parsed.append(p)
        }
        for p in parsed {
            let (status, out) = run("/usr/bin/pmset", p.arguments)
            guard status == 0 else { reply(false, "pmset \(p.wire) exited \(status): \(out.prefix(200))"); return }
        }
        reply(true, "applied \(parsed.count)")
    }

    func restartCoreAudio(reply: @escaping (Bool, String) -> Void) {
        touch()
        let (status, out) = run("/bin/launchctl", ["kickstart", "-k", "system/com.apple.audio.coreaudiod"])
        reply(status == 0, String(out.prefix(200)))
    }

    func stepDown(reply: @escaping () -> Void) {
        reply()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
    }

    private func run(_ path: String, _ args: [String]) -> (Int32, String) {
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

let service = HelperService()
let listener = NSXPCListener(machServiceName: PowerHelperIdentity.label)
listener.delegate = service
listener.resume()
// Ten quiet minutes, then out of the way.
let idle = Timer(timeInterval: 60, repeats: true) { _ in if service.quietFor > 600 { exit(0) } }
RunLoop.main.add(idle, forMode: .default)
RunLoop.main.run()
