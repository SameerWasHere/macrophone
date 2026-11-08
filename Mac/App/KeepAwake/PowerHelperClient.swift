import AppKit
import Foundation
import MacrophoneKit
import ServiceManagement

/// The app's side of Keep Awake's root helper (Nov 7 2026). Registering it is a guided one-time
/// step — macOS asks the person once in System Settings › General › Login Items & Extensions —
/// and after that every sleep-settings change is an XPC call: no password, ever.
///
/// The version handshake: the helper answers `PowerHelperVersion.current`; one that answers an
/// older number (Macrophone was updated, the old daemon still runs) is asked to step down, and
/// launchd starts the copy inside this app on the next call.
@MainActor
final class PowerHelperClient {
    static let shared = PowerHelperClient()

    private var connection: NSXPCConnection?
    private var service: SMAppService { SMAppService.daemon(plistName: PowerHelperIdentity.plistName) }
    /// The version the running daemon last answered (nil: not asked yet, or no answer).
    private(set) var runningVersion: Int?

    var status: SMAppService.Status { service.status }

    var state: KeepAwakeHelperState {
        switch status {
        case .enabled:
            if let v = runningVersion, v < PowerHelperVersion.current { return .outdated }
            return .ready
        case .requiresApproval: return .needsApproval
        case .notRegistered, .notFound: return .notInstalled
        @unknown default: return .notInstalled
        }
    }

    /// Registers the daemon; macOS then waits for the person's approval (opened for them).
    /// Returns words for an error, or nil.
    func register() -> String? {
        do {
            try service.register()
        } catch {
            if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems(); return nil }
            if service.status == .enabled { return nil }
            let ns = error as NSError
            return "macOS didn't let Macrophone add it (\(ns.code)). Make sure Macrophone is in your Applications folder, then try again."
        }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        return nil
    }

    func unregister() -> Bool {
        connection?.invalidate()
        connection = nil
        runningVersion = nil
        do { try service.unregister(); return true } catch { return service.status == .notRegistered || service.status == .notFound }
    }

    private func proxy(onError: @escaping (Error) -> Void) -> MacrophonePowerHelperProtocol? {
        if connection == nil {
            let c = NSXPCConnection(machServiceName: PowerHelperIdentity.label, options: .privileged)
            c.remoteObjectInterface = NSXPCInterface(with: MacrophonePowerHelperProtocol.self)
            // Only our own daemon (a different binary registered under the label is refused).
            c.setCodeSigningRequirement(PowerHelperIdentity.helperRequirement)
            c.invalidationHandler = { [weak self] in Task { @MainActor in self?.connection = nil } }
            c.interruptionHandler = { [weak self] in Task { @MainActor in self?.connection = nil } }
            c.resume()
            connection = c
        }
        return connection?.remoteObjectProxyWithErrorHandler(onError) as? MacrophonePowerHelperProtocol
    }

    /// Asks the running daemon its version (8 s at most).
    func checkVersion() async -> Int? {
        guard status == .enabled else { runningVersion = nil; return nil }
        let v: Int? = await withTimeout(8) { done in
            guard let p = self.proxy(onError: { _ in done(nil) }) else { done(nil); return }
            p.version { done($0) }
        }
        runningVersion = v
        return v
    }

    /// Applies the changes. Before the first call of a run (and after an update) the version is
    /// checked; an old daemon steps down and the new one answers.
    func apply(_ changes: [PowerChange]) async -> (ok: Bool, detail: String) {
        guard status == .enabled else { return (false, "helper \(state.rawValue)") }
        if runningVersion == nil || runningVersion! < PowerHelperVersion.current {
            let v = await checkVersion()
            if let v, v < PowerHelperVersion.current {
                await stepDown()
                let again = await checkVersion()
                if again.map({ $0 < PowerHelperVersion.current }) ?? true { return (false, "helper outdated") }
            }
        }
        let wire = changes.map(\.wire)
        let r: (Bool, String)? = await withTimeout(8) { done in
            guard let p = self.proxy(onError: { e in done((false, "xpc: \((e as NSError).code)")) }) else { done((false, "no proxy")); return }
            p.apply(wire) { ok, msg in done((ok, msg)) }
        }
        return r.map { ($0.0, $0.1) } ?? (false, "helper timed out")
    }

    func restartCoreAudio() async -> Bool {
        guard status == .enabled else { return false }
        let r: Bool? = await withTimeout(8) { done in
            guard let p = self.proxy(onError: { _ in done(false) }) else { done(false); return }
            p.restartCoreAudio { ok, _ in done(ok) }
        }
        return r ?? false
    }

    private func stepDown() async {
        let _: Bool? = await withTimeout(3) { done in
            guard let p = self.proxy(onError: { _ in done(true) }) else { done(true); return }
            p.stepDown { done(true) }
        }
        connection?.invalidate()
        connection = nil
        try? await Task.sleep(nanoseconds: 600_000_000)
    }

    /// Runs `body` and hands back the first answer it gives, or nil after `seconds`.
    private func withTimeout<T>(_ seconds: Double, _ body: @escaping (@escaping (T?) -> Void) -> Void) async -> T? {
        await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
            let lock = NSLock()
            var finished = false
            let finish: (T?) -> Void = { v in
                lock.lock(); defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                cont.resume(returning: v)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { finish(nil) }
            body(finish)
        }
    }
}
