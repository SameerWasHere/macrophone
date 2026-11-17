import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import MacrophoneKit

/// The Whole Screen, fitted to the iPhone (Nov 16 2026). Sameer: "even in whole screen mode the Mac
/// screen is optimized for the space available on the phone in its various orientations", and
/// "it's okay if all the windows get moved to this new virtual display since the whole point of
/// this app is to use your Mac while you're away".
///
/// A phone asks for the whole screen at its view's shape (`FittedScreenRequest`); this makes a
/// display that shape (a virtual one: HiDPI, its own menu bar, Dock and wallpaper), makes it the
/// MAIN display, moves every app's windows onto it (each one's frame remembered first) and says so
/// — `MacDisplays.watched` then names it, so the Whole Screen's stream, clicks, pointer, scrolls
/// and typing all follow. A new shape (the phone turned, the Duo folded, full screen) re-shapes the
/// same display in place and fits the windows again. Off — the phone's Actual Size or Done, the
/// grace after its watch stops, another place watched, the phone gone, Quit — the main display
/// goes back, the display is removed and every window gets its remembered frame.
///
/// The display is made with CoreGraphics' own virtual-display classes (`CGVirtualDisplay…`), which
/// have no public header: they're looked up by name and every selector checked first, so a macOS
/// without them only means the feature isn't named to phones (today's Whole Screen). The display
/// lives in this process: a crash or a force-quit removes it and macOS moves the windows back to
/// the real screen by itself (at the sizes they had on the fitted one). Nothing is written to disk.
///
/// The log has sizes and counts only — never an app's name or a window's title.
@MainActor
final class VirtualScreen {
    static let shared = VirtualScreen()

    var log: (String) -> Void = { _ in }
    /// The fitted screen came, changed shape or went: the Whole Screen's watches look again now.
    var onChange: () -> Void = {}
    /// It went by itself (the grace): the phone that asked hears.
    var onEnded: (UUID) -> Void = { _ in }

    // MARK: What `MacDisplays` reads (from any thread)

    nonisolated private static let lock = NSLock()
    nonisolated(unsafe) private static var liveID: CGDirectDisplayID?
    nonisolated(unsafe) private static var realMain: CGDirectDisplayID?
    /// The fitted display while it's up (and ready to be shown).
    nonisolated static var currentID: CGDirectDisplayID? { lock.withLock { liveID } }
    /// The display that was main before the fitted one took over (nil while it isn't up).
    nonisolated static var mainBefore: CGDirectDisplayID? { lock.withLock { liveID == nil ? nil : realMain } }

    // MARK: State

    private var display: NSObject?
    private(set) var size: FittedScreenSize?
    private var owner: UUID?
    /// Where each display sat before the fitted one became main (global origins).
    private var arrangement: [(id: CGDirectDisplayID, origin: CGPoint)] = []
    private var madeMain = false
    private var moved: [Moved] = []
    private var grace: Task<Void, Never>?
    private var work: Task<FittedScreenState, Never>?
    /// Being made or reshaped right now (the Whole Screen's stream waits for it).
    private(set) var busy = false

    var isOn: Bool { display != nil && size != nil }

    /// A window this moved: where it was, to put it back.
    struct Moved: @unchecked Sendable {
        let element: AXUIElement
        let pid: pid_t
        let original: CGRect
    }

    // MARK: Asked by a phone

    /// One request at a time, in the order they came.
    func handle(_ request: FittedScreenRequest, from peer: UUID, watchingDesktop: Bool) async -> FittedScreenState {
        let before = work
        let task = Task { @MainActor [weak self] () -> FittedScreenState in
            _ = await before?.value
            guard let self else { return .off }
            return await self.apply(request, from: peer, watchingDesktop: watchingDesktop)
        }
        work = task
        return await task.value
    }

    private func apply(_ request: FittedScreenRequest, from peer: UUID, watchingDesktop: Bool) async -> FittedScreenState {
        guard request.on else {
            if isOn, owner == nil || owner == peer { await off(why: "the phone asked") }
            return .off
        }
        guard let want = request.size else { return FittedScreenState(on: false, reason: "That isn't a screen's shape") }
        guard Self.available else { return FittedScreenState(on: false, reason: "This Mac can't make a screen that shape") }
        guard AXIsProcessTrusted() else {
            return FittedScreenState(on: false, reason: "Your Mac needs to allow Accessibility for Macrophone before it can fit its screen to your iPhone")
        }
        if StayAwake.isLocked { return FittedScreenState(on: false, reason: "Your Mac is locked") }
        owner = peer
        grace?.cancel(); grace = nil
        // Asked with no Whole Screen watch running (a toggle while paused): it never outlives the grace.
        if !watchingDesktop { armGrace(for: peer) }
        if let have = size, display != nil {
            if FittedScreen.differs(have, want) { await reshape(to: want) }
        } else {
            await make(want)
        }
        guard let now = size, let id = Self.currentID else {
            return FittedScreenState(on: false, reason: "This Mac couldn't make a screen that shape")
        }
        return FittedScreenState(on: true, key: MacDisplays.key(for: id), width: now.width, height: now.height)
    }

    // MARK: The watch that shows it

    /// The phone's watch changed: on the Whole Screen (again) the grace is off; anything else —
    /// stopped, paused, another window, the phone gone — starts it.
    func watchChanged(_ peer: UUID, desktop: Bool) {
        guard isOn, owner == peer else { return }
        if desktop { grace?.cancel(); grace = nil } else if grace == nil { armGrace(for: peer) }
    }

    private func armGrace(for peer: UUID) {
        grace?.cancel()
        let seconds = WatchService.restoreGrace
        grace = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            guard !Task.isCancelled, let self, self.isOn else { return }
            self.grace = nil
            _ = await self.handleOff(why: "\(Int(seconds)) s after the watch stopped")
            self.onEnded(peer)
        }
    }

    private func handleOff(why: String) async -> FittedScreenState {
        let before = work
        let task = Task { @MainActor [weak self] () -> FittedScreenState in
            _ = await before?.value
            await self?.off(why: why)
            return .off
        }
        work = task
        return await task.value
    }

    // MARK: Making it

    private func make(_ want: FittedScreenSize) async {
        let began = Date()
        busy = true
        defer { busy = false }
        guard let made = CGVD.makeDisplay(), CGVD.apply(want, to: made), let id = CGVD.id(of: made), id != 0 else {
            log("fitted screen: the display couldn't be made")
            return
        }
        display = made
        guard await settle(id, want) else {
            log("fitted screen: the display never came up at \(want.width)×\(want.height) — removed")
            display = nil
            return
        }
        // What was where, before anything moves.
        let main = CGMainDisplayID()
        arrangement = MacDisplays.online().filter { $0 != id }.map { ($0, CGDisplayBounds($0).origin) }
        let wallpaper = Self.wallpaper(of: main)
        var mainNote = "not main"
        if Self.makesMain {
            madeMain = Self.makeMain(id)
            mainNote = madeMain ? "main" : "couldn't be made main"
        }
        Self.lock.withLock { Self.liveID = id; Self.realMain = main }
        size = want
        let visible = await visibleArea(of: id, want)
        // The real desktop's picture on it (the system's default would be a stranger's screen).
        if let wallpaper, let screen = Self.screen(id) { try? NSWorkspace.shared.setDesktopImageURL(wallpaper, for: screen, options: [:]) }
        let counts = await fitWindows(into: visible)
        onChange()
        log("fitted screen: made \(want.width)×\(want.height) (\(Self.pixels(id).width)×\(Self.pixels(id).height) px, \(mainNote)) in \(Int(Date().timeIntervalSince(began) * 1000)) ms · \(counts.windows) windows of \(counts.apps) apps moved onto it\(Self.onlyNote)")
    }

    private func reshape(to want: FittedScreenSize) async {
        guard let made = display, let id = CGVD.id(of: made) else { return }
        let began = Date()
        busy = true
        defer { busy = false }
        guard CGVD.apply(want, to: made), await settle(id, want) else {
            // The same display wouldn't take it: a new one.
            log("fitted screen: the display didn't take \(want.width)×\(want.height) live — made again")
            let kept = moved
            _ = teardown()
            await gone(id)
            moved = kept
            await make(want)
            return
        }
        size = want
        // (A mode change can hand the menu bar back to the real display.)
        if madeMain, CGMainDisplayID() != id { madeMain = Self.makeMain(id) }
        let visible = await visibleArea(of: id, want)
        let counts = await fitWindows(into: visible)
        onChange()
        log("fitted screen: reshaped to \(want.width)×\(want.height) in \(Int(Date().timeIntervalSince(began) * 1000)) ms · \(counts.windows) windows fitted again")
    }

    /// Waits for the display to be online at the size asked, at 2× (the system lists a 1× mode of
    /// twice the points beside it and sometimes picks that one).
    private func settle(_ id: CGDirectDisplayID, _ want: FittedScreenSize) async -> Bool {
        for _ in 0..<60 {
            if CGDisplayIsOnline(id) != 0 {
                let b = CGDisplayBounds(id)
                if Int(b.width) == want.width, Int(b.height) == want.height, Self.pixels(id).width == want.pixelsWide { return true }
                Self.pickMode(id, want)
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let b = CGDisplayBounds(id)
        return CGDisplayIsOnline(id) != 0 && Int(b.width) == want.width && Int(b.height) == want.height
    }

    /// The current mode's real pixels (`CGDisplayPixelsWide` gives points on a HiDPI mode).
    private static func pixels(_ id: CGDirectDisplayID) -> (width: Int, height: Int) {
        guard let m = CGDisplayCopyDisplayMode(id) else { return (0, 0) }
        return (m.pixelWidth, m.pixelHeight)
    }

    private static func pickMode(_ id: CGDirectDisplayID, _ want: FittedScreenSize) {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] else { return }
        guard let mode = modes.first(where: { $0.width == want.width && $0.height == want.height && $0.pixelWidth == want.pixelsWide })
                ?? modes.first(where: { $0.width == want.width && $0.height == want.height }) else { return }
        if let now = CGDisplayCopyDisplayMode(id), now.width == mode.width, now.height == mode.height, now.pixelWidth == mode.pixelWidth { return }
        CGDisplaySetDisplayMode(id, mode, nil)
    }

    /// The fitted display at 0,0 — the menu bar and the Dock go to it — every other display kept
    /// where it was relative to it. For this login session only (nothing is saved).
    private static func makeMain(_ id: CGDirectDisplayID) -> Bool {
        let base = CGDisplayBounds(id).origin
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        for d in MacDisplays.online() {
            let o = CGDisplayBounds(d).origin
            CGConfigureDisplayOrigin(config, d, Int32(o.x - base.x), Int32(o.y - base.y))
        }
        return CGCompleteDisplayConfiguration(config, .forSession) == .success
    }

    /// Under the menu bar, above the Dock, on the fitted display — top-left origin, global. AppKit
    /// hears of a new display a moment after CoreGraphics does.
    private func visibleArea(of id: CGDirectDisplayID, _ want: FittedScreenSize) async -> CGRect {
        for _ in 0..<30 {
            if let s = Self.screen(id), Int(s.frame.width) == want.width, Int(s.frame.height) == want.height, let primary = NSScreen.screens.first {
                // The menu bar's height is known at once; the Dock takes a moment to arrive.
                let h = primary.frame.height, v = s.visibleFrame
                let area = CGRect(x: v.minX, y: h - v.maxY, width: v.width, height: v.height)
                if area.width > 200, area.height > 200 { return area }
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let b = CGDisplayBounds(id)
        return CGRect(x: b.minX, y: b.minY + 25, width: b.width, height: b.height - 25)
    }

    private static func screen(_ id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
    }

    private static func wallpaper(of id: CGDirectDisplayID) -> URL? {
        screen(id).flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
    }

    // MARK: The windows

    /// Every app's windows onto the fitted screen: a standard window that can be resized fills it
    /// (under the menu bar, above the Dock — an app on a phone-shaped screen is as big as the
    /// screen); anything else (a panel, a fixed-size window) is centred on it, no bigger than it.
    /// Each one's frame is remembered the first time it's moved.
    private func fitWindows(into visible: CGRect) async -> (windows: Int, apps: Int) {
        guard AXIsProcessTrusted() else { return (0, 0) }
        let me = ProcessInfo.processInfo.processIdentifier
        let pids = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != me && Self.mayMove($0.bundleIdentifier) }
            .map(\.processIdentifier)
        let known = moved
        let result = await Task.detached(priority: .userInitiated) { Self.fit(pids: pids, into: visible, known: known) }.value
        moved = result.moved
        return (result.count, result.apps)
    }

    nonisolated private static func fit(pids: [pid_t], into visible: CGRect, known: [Moved]) -> (moved: [Moved], count: Int, apps: Int) {
        var all = known.filter { AX.isAlive($0.element) }
        var count = 0, apps = 0
        var again: [(AXUIElement, CGRect)] = []
        for pid in pids {
            var any = false
            for win in AX.windows(AX.app(pid)) {
                guard !AX.bool(win, "AXFullScreen"), !AX.bool(win, kAXMinimizedAttribute), AX.isSettable(win, kAXPositionAttribute) else { continue }
                let now = AX.frame(win)
                guard now.width > 40, now.height > 40 else { continue }
                let resizable = AX.isSettable(win, kAXSizeAttribute)
                let target: CGRect
                if resizable, AX.subrole(win) == "AXStandardWindow" {
                    target = visible
                } else {
                    let w = resizable ? min(now.width, visible.width) : now.width, h = resizable ? min(now.height, visible.height) : now.height
                    target = CGRect(x: visible.minX + max(0, (visible.width - w) / 2).rounded(), y: visible.minY + max(0, (visible.height - h) / 2).rounded(), width: w, height: h)
                }
                if !all.contains(where: { CFEqual($0.element, win) }) { all.append(Moved(element: win, pid: pid, original: now)) }
                if resizable {
                    _ = WindowFit.set(win, frame: target)
                    again.append((win, target))
                } else {
                    var origin = target.origin
                    if let p = AXValueCreate(.cgPoint, &origin) { _ = AX.set(win, kAXPositionAttribute, p) }
                }
                count += 1
                any = true
            }
            if any { apps += 1 }
        }
        // A window grown while still on the screen it came from is kept to that screen's height by
        // its app: a moment after the move, the size is asked again of any that fell short.
        for pass in 0..<2 {
            let short = again.filter { !WindowFit.same(AX.frame($0.0), $0.1) }
            guard !short.isEmpty else { break }
            usleep(pass == 0 ? 200_000 : 400_000)
            for (win, target) in short { _ = WindowFit.set(win, frame: target) }
        }
        return (all, count, apps)
    }

    nonisolated private static func putBack(_ moved: [Moved]) -> Int {
        guard AXIsProcessTrusted() else { return 0 }
        var n = 0
        for m in moved where AX.isAlive(m.element) && !AX.bool(m.element, "AXFullScreen") {
            _ = WindowFit.set(m.element, frame: m.original)
            let now = AX.frame(m.element)
            if abs(now.minX - m.original.minX) <= WindowFit.tolerance, abs(now.minY - m.original.minY) <= WindowFit.tolerance { n += 1 }
        }
        return n
    }

    // MARK: Putting it all back

    /// The main display back and the fitted one removed, now. Returns the windows to put back
    /// (once the display is gone: a frame set while the screens rearrange is clamped).
    private func teardown() -> [Moved] {
        grace?.cancel(); grace = nil
        let id = Self.currentID
        if madeMain, !arrangement.isEmpty {
            var config: CGDisplayConfigRef?
            if CGBeginDisplayConfiguration(&config) == .success, let config {
                for (d, origin) in arrangement where CGDisplayIsOnline(d) != 0 {
                    CGConfigureDisplayOrigin(config, d, Int32(origin.x), Int32(origin.y))
                }
                // The fitted one off to the left of everything for its last moment.
                if let id, let size {
                    let left = arrangement.map(\.origin.x).min() ?? 0
                    CGConfigureDisplayOrigin(config, id, Int32(left) - Int32(size.width), 0)
                }
                CGCompleteDisplayConfiguration(config, .forSession)
            }
        }
        Self.lock.withLock { Self.liveID = nil; Self.realMain = nil }
        display = nil
        size = nil
        owner = nil
        madeMain = false
        arrangement = []
        let windows = moved
        moved = []
        return windows
    }

    private func gone(_ id: CGDirectDisplayID?) async {
        guard let id else { return }
        for _ in 0..<40 where CGDisplayIsOnline(id) != 0 { try? await Task.sleep(nanoseconds: 50_000_000) }
        try? await Task.sleep(nanoseconds: 350_000_000)
    }

    private func off(why: String) async {
        guard display != nil else { return }
        let id = Self.currentID
        let windows = teardown()
        onChange()
        await gone(id)
        let back = await Task.detached(priority: .userInitiated) { Self.putBack(windows) }.value
        onChange()
        log("fitted screen: off (\(why)) · \(back) of \(windows.count) windows put back where they were")
    }

    /// Quitting: everything back before the process (and the display with it) goes.
    func quit() {
        guard display != nil else { return }
        let id = Self.currentID
        let windows = teardown()
        if let id { for _ in 0..<30 where CGDisplayIsOnline(id) != 0 { usleep(50_000) } }
        usleep(300_000)
        let back = Self.putBack(windows)
        log("fitted screen: off (quitting) · \(back) of \(windows.count) windows put back where they were")
    }

    // MARK: Whether this Mac can

    /// The classes and every selector used are there, and it isn't switched off
    /// (`defaults write com.sameer.macrophone.mac watch.screenFit -bool NO`).
    static var available: Bool {
        CGVD.available && (AppPaths.defaults.object(forKey: "watch.screenFit") as? Bool ?? true)
    }

    // MARK: Debug: only an app of mine, never his windows

    #if DEBUG
    /// A Debug build moves NO windows unless told which app's: MACROPHONE_FIT_ONLY=<bundle id>
    /// (that app's only) or `*` (every app's, as a release build does). MACROPHONE_FIT_NO_MAIN=1
    /// leaves the menu bar and the Dock on the real display.
    nonisolated private static let only = ProcessInfo.processInfo.environment["MACROPHONE_FIT_ONLY"]
    nonisolated private static func mayMove(_ bundleID: String?) -> Bool {
        guard let only else { return false }
        return only == "*" || only == bundleID
    }
    private static var makesMain: Bool { ProcessInfo.processInfo.environment["MACROPHONE_FIT_NO_MAIN"] != "1" }
    private static var onlyNote: String { only == "*" ? "" : only == nil ? " (a Debug build: no windows moved without MACROPHONE_FIT_ONLY)" : " (only the app named by MACROPHONE_FIT_ONLY)" }

    /// MACROPHONE_FIT_TEST=1004x1426@3,1426x1004@2: the fitted screen at each size for that many
    /// seconds, then off — printed, for a proof without a phone. Then the app quits.
    func debugTestIfAsked() {
        guard let spec = ProcessInfo.processInfo.environment["MACROPHONE_FIT_TEST"] else { return }
        let steps: [(FittedScreenSize, Double)] = spec.split(separator: ",").compactMap { part in
            let a = part.split(separator: "@"), d = a.first?.split(separator: "x").compactMap { Int($0) } ?? []
            guard d.count == 2 else { return nil }
            return (FittedScreenSize(width: d[0], height: d[1]), a.count > 1 ? Double(a[1]) ?? 2 : 2)
        }
        let say = log
        log = { line in say(line); print("FIT " + line); fflush(stdout) }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            print("FIT available \(Self.available), accessibility \(AXIsProcessTrusted()), displays \(MacDisplays.online().count), main \(CGMainDisplayID())"); fflush(stdout)
            for (size, hold) in steps {
                if self.display == nil { await self.make(size) } else { await self.reshape(to: size) }
                if let id = Self.currentID {
                    let b = CGDisplayBounds(id)
                    print("FIT display \(id) bounds \(Int(b.minX)),\(Int(b.minY)) \(Int(b.width))×\(Int(b.height)) · \(Self.pixels(id).width)×\(Self.pixels(id).height) px · main \(CGMainDisplayID() == id) · watched \(MacDisplays.watched == id) · listed to phones \(MacDisplays.current().count)")
                    for m in self.moved { let f = AX.frame(m.element); print("FIT window was \(Int(m.original.minX)),\(Int(m.original.minY)) \(Int(m.original.width))×\(Int(m.original.height)) now \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))×\(Int(f.height))") }
                    fflush(stdout)
                }
                try? await Task.sleep(nanoseconds: UInt64(hold * 1e9))
            }
            let windows = self.moved
            await self.off(why: "the test's end")
            for m in windows { let f = AX.frame(m.element); print("FIT window back at \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))×\(Int(f.height)) (was \(Int(m.original.minX)),\(Int(m.original.minY)) \(Int(m.original.width))×\(Int(m.original.height)))") }
            print("FIT done · displays \(MacDisplays.online().count), main \(CGMainDisplayID())"); fflush(stdout)
            NSApp.terminate(nil)
        }
    }
    #else
    nonisolated private static func mayMove(_ bundleID: String?) -> Bool { true }
    private static var makesMain: Bool { true }
    private static var onlyNote: String { "" }
    #endif
}

/// CoreGraphics' virtual display, reached by name (it has no public header). Every class and
/// selector is checked before use: a macOS without one leaves `available` false and nothing here
/// is ever called.
private enum CGVD {
    private static let displayClass: AnyClass? = NSClassFromString("CGVirtualDisplay")
    private static let descriptorClass: AnyClass? = NSClassFromString("CGVirtualDisplayDescriptor")
    private static let settingsClass: AnyClass? = NSClassFromString("CGVirtualDisplaySettings")
    private static let modeClass: AnyClass? = NSClassFromString("CGVirtualDisplayMode")
    private static let initDisplay = NSSelectorFromString("initWithDescriptor:")
    private static let initMode = NSSelectorFromString("initWithWidth:height:refreshRate:")
    private static let applySettings = NSSelectorFromString("applySettings:")

    static let available: Bool = {
        guard let displayClass, let descriptorClass, let settingsClass, let modeClass,
              descriptorClass is NSObject.Type, settingsClass is NSObject.Type else { return false }
        func has(_ c: AnyClass, _ names: [String]) -> Bool { names.allSatisfy { class_respondsToSelector(c, NSSelectorFromString($0)) } }
        return has(displayClass, ["initWithDescriptor:", "applySettings:", "displayID"])
            && has(descriptorClass, ["setQueue:", "setName:", "setMaxPixelsWide:", "setMaxPixelsHigh:", "setSizeInMillimeters:", "setProductID:", "setVendorID:", "setSerialNum:"])
            && has(settingsClass, ["setHiDPI:", "setModes:"])
            && has(modeClass, ["initWithWidth:height:refreshRate:"])
    }()

    private static func alloc(_ c: AnyClass) -> AnyObject? {
        (c as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue()
    }

    /// A display big enough for any shape the rule gives (the mode picks the shape).
    static func makeDisplay() -> NSObject? {
        guard available, let displayClass, let descriptor = (descriptorClass as? NSObject.Type)?.init() else { return nil }
        let side = Int(FittedScreen.maxLong) * FittedScreen.pixelScale
        descriptor.setValue(DispatchQueue.main, forKey: "queue")
        descriptor.setValue("Macrophone", forKey: "name")
        descriptor.setValue(side, forKey: "maxPixelsWide")
        descriptor.setValue(side, forKey: "maxPixelsHigh")
        descriptor.setValue(NSValue(size: NSSize(width: 300, height: 300)), forKey: "sizeInMillimeters")
        // Always the same "monitor": the system keeps what it knows of it (its wallpaper) between uses.
        descriptor.setValue(0x4D50, forKey: "productID")
        descriptor.setValue(0x5342, forKey: "vendorID")
        descriptor.setValue(1, forKey: "serialNum")
        guard let raw = alloc(displayClass) else { return nil }
        return raw.perform(initDisplay, with: descriptor)?.takeRetainedValue() as? NSObject
    }

    static func apply(_ size: FittedScreenSize, to display: NSObject) -> Bool {
        guard available, let modeClass, let settings = (settingsClass as? NSObject.Type)?.init(), let raw = alloc(modeClass),
              let make = class_getMethodImplementation(modeClass, initMode), let apply = class_getMethodImplementation(type(of: display), applySettings) else { return false }
        typealias MakeMode = @convention(c) (AnyObject, Selector, UInt, UInt, Double) -> Unmanaged<AnyObject>?
        typealias Apply = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        guard let mode = unsafeBitCast(make, to: MakeMode.self)(raw, initMode, UInt(size.width), UInt(size.height), 60)?.takeRetainedValue() else { return false }
        settings.setValue(1, forKey: "hiDPI")
        settings.setValue([mode], forKey: "modes")
        return unsafeBitCast(apply, to: Apply.self)(display, applySettings, settings)
    }

    static func id(of display: NSObject) -> CGDirectDisplayID? {
        (display.value(forKey: "displayID") as? NSNumber)?.uint32Value
    }
}
