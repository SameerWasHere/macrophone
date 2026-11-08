import AppKit
import CoreGraphics
import Foundation
import IOKit.pwr_mgt

/// Keep Awake's displays (Nov 7 2026, from On The Go): the built-in's brightness, external
/// displays turned off with BetterDisplay when it's installed (an optional extra), every display
/// asleep otherwise, and waking them. Writes only through `KeepAwakeMacSystem`, which a dry run
/// replaces with a log line.
enum DisplayControl {
    // MARK: Brightness (DisplayServices, a private framework — looked up at run time)

    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

    /// dlopen'd once: a macOS that drops or renames the framework (or an Intel Mac without the
    /// symbols) leaves brightness alone and Keep Awake carries on — the displays still sleep.
    private static let services: (get: GetFn, set: SetFn)? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let g = dlsym(h, "DisplayServicesGetBrightness"), let s = dlsym(h, "DisplayServicesSetBrightness") else { return nil }
        return (unsafeBitCast(g, to: GetFn.self), unsafeBitCast(s, to: SetFn.self))
    }()

    static var canDim: Bool { services != nil }

    static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    /// The built-in panel, if it's on — never an external (in clamshell the main display is an
    /// external, and On The Go dimmed whatever was main).
    static var builtIn: CGDirectDisplayID? { onlineDisplays().first { CGDisplayIsBuiltin($0) != 0 } }
    static var externals: [CGDirectDisplayID] { onlineDisplays().filter { CGDisplayIsBuiltin($0) == 0 } }

    static func brightness() -> Float? {
        guard let s = services, let d = builtIn else { return nil }
        var v: Float = 0
        return s.get(d, &v) == 0 ? v : nil
    }

    static func setBrightness(_ v: Float) {
        guard let s = services, let d = builtIn else { return }
        _ = s.set(d, min(1, max(0, v)))
    }

    // MARK: Sleep and wake

    /// `pmset displaysleepnow`: an explicit display sleep (assertions don't block it; the Mac
    /// stays up). Needs no administrator.
    static func sleepAll() { _ = Shell.run("/usr/bin/pmset", ["displaysleepnow"]) }

    /// What a key press does.
    static func wake() {
        var id: IOPMAssertionID = 0
        if IOPMAssertionDeclareUserActivity("Macrophone: Keep Awake, displays on" as CFString, kIOPMUserActiveLocal, &id) == kIOReturnSuccess {
            IOPMAssertionRelease(id)
        }
    }

    // MARK: BetterDisplay (optional)

    static let betterDisplayBinary = "/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay"
    static let betterDisplayID = "pro.betterdisplay.BetterDisplay"
    static var betterDisplayInstalled: Bool { FileManager.default.isExecutableFile(atPath: betterDisplayBinary) }
    private static let launchLock = NSLock()

    /// The CLI (the app's own binary); starts BetterDisplay in the background first when it isn't
    /// running — its CLI only talks to the running app, and timed out for 16 s when it had quit.
    static func betterDisplay(_ args: [String], retry: Bool = true) -> String {
        if retry, NSRunningApplication.runningApplications(withBundleIdentifier: betterDisplayID).isEmpty, ensureRunning() {
            return betterDisplay(args, retry: false)
        }
        let out = Shell.run(betterDisplayBinary, args).output.trimmingCharacters(in: .whitespacesAndNewlines)
        if retry, out.contains("Host app might not be running"), ensureRunning() { return betterDisplay(args, retry: false) }
        return out
    }

    private static func ensureRunning() -> Bool {
        launchLock.lock(); defer { launchLock.unlock() }
        if NSRunningApplication.runningApplications(withBundleIdentifier: betterDisplayID).isEmpty {
            _ = Shell.run("/usr/bin/open", ["-g", "-b", betterDisplayID])
        }
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 1.5)
            if !Shell.run(betterDisplayBinary, ["get", "-tagID=2", "-connected"]).output.contains("timed out") { return true }
        }
        return false
    }

    /// Every external display BetterDisplay knows (tag, connected).
    static func externalTags() -> [(tag: String, name: String)] {
        let json = betterDisplay(["get", "-identifiers", "-deviceType=Display"])
        // A comma-separated list of JSON objects, not an array.
        guard let data = ("[" + json + "]").data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let tag = item["tagID"] as? String else { return nil }
            let name = item["name"] as? String ?? "Display"
            let location = item["registryLocation"] as? String ?? ""
            let builtIn = name == "Built-in Display" || name == "Color LCD" || location.contains("disp0@")
            return builtIn ? nil : (tag, name)
        }
    }

    /// Unplugs every connected external (one process per display, at once). Off the main thread.
    static func unplugExternals() -> [String] {
        let tags = externalTags()
        var done = [String?](repeating: nil, count: tags.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: tags.count) { i in
            let t = tags[i].tag
            guard betterDisplay(["get", "-tagID=\(t)", "-connected"]) == "on" else { return }
            let r = betterDisplay(["set", "-tagID=\(t)", "-connected=off"])
            if r.isEmpty || r == "ok" { lock.lock(); done[i] = t; lock.unlock() }
        }
        return done.compactMap { $0 }
    }

    /// Plugs those back in; returns the tags that didn't come back. Off the main thread.
    static func plugIn(_ tags: [String]) -> [String] {
        var failed = [String?](repeating: nil, count: tags.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: tags.count) { i in
            let r = betterDisplay(["set", "-tagID=\(tags[i])", "-connected=on"])
            if !(r.isEmpty || r == "ok") { lock.lock(); failed[i] = tags[i]; lock.unlock() }
        }
        return failed.compactMap { $0 }
    }
}

/// A process, run and waited for.
enum Shell {
    @discardableResult
    static func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
