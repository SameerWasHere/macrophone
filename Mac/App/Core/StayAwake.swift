import AppKit
import Foundation
import IOKit.pwr_mgt
import MacrophoneKit

/// Keeps the Mac reachable while the phone uses it, the way SameerOS keeps its runs awake (Oct 18
/// 2026, Sameer: "SameerOS has this built in and works well"):
///   - While a phone is connected, and for 15 minutes after the last one leaves, the Mac doesn't
///     idle-sleep — the display still may (a paste works with the screen dark; SameerOS learned
///     not to light a screen nobody asked to see).
///   - While a phone watches a window, the display stays on, so the picture is live; if it was
///     already dark when watching began, it's woken once — he asked to see it.
/// Both are plain power assertions, released on time (SameerOS's keep-alive once ran all night:
/// every hold here has an end).
@MainActor
final class StayAwake {
    private var system: IOPMAssertionID = 0
    private var display: IOPMAssertionID = 0
    private var release: DispatchWorkItem?
    private unowned let log: DiagnosticLog
    static let linger: TimeInterval = 15 * 60

    init(log: DiagnosticLog) { self.log = log }

    /// The screen is locked (or the login window is up): nothing may be typed or clicked.
    static var isLocked: Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if (d["CGSSessionScreenIsLocked"] as? Bool) == true || (d["CGSSessionScreenIsLocked"] as? Int) == 1 { return true }
        return (d["kCGSSessionOnConsoleKey"] as? Bool) == false
    }

    func update(phonesConnected: Bool, watching: Bool) {
        if phonesConnected {
            release?.cancel()
            release = nil
            if system == 0 { system = hold(kIOPMAssertPreventUserIdleSystemSleep, "Macrophone: your iPhone is connected") }
        } else if system != 0, release == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.drop(&self.system)
                self.release = nil
                self.log.add("stay awake: the Mac may sleep again")
            }
            release = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.linger, execute: work)
        }
        if watching {
            if display == 0 {
                if CGDisplayIsAsleep(CGMainDisplayID()) != 0 {
                    var id: IOPMAssertionID = 0
                    if IOPMAssertionDeclareUserActivity("Macrophone: your iPhone is watching" as CFString, kIOPMUserActiveLocal, &id) == kIOReturnSuccess {
                        IOPMAssertionRelease(id)
                    }
                    log.add("stay awake: woke the display to watch")
                }
                display = hold(kIOPMAssertPreventUserIdleDisplaySleep, "Macrophone: your iPhone is watching a window")
            }
        } else {
            drop(&display)
        }
    }

    private func hold(_ type: String, _ reason: String) -> IOPMAssertionID {
        var id: IOPMAssertionID = 0
        let ok = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id)
        return ok == kIOReturnSuccess ? id : 0
    }

    private func drop(_ id: inout IOPMAssertionID) {
        guard id != 0 else { return }
        IOPMAssertionRelease(id)
        id = 0
    }
}
