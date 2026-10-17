import AppKit
import ApplicationServices
import Foundation
import MacrophoneKit

/// Readable text (Oct 17 2026, "Aa"): the phone asks for the watched window narrower and taller —
/// about its own shape — so the window's text reads larger on the phone (the phone fits the
/// window's width across its screen). Done through Accessibility, the window itself resized; it
/// goes back to its own size and place when watching stops (Done, another window, the phone
/// gone, Quit) — unless someone moved or resized it on the Mac meanwhile, then it stays.
///
/// Frames are global points with a top-left origin, as Accessibility and the window server give them.
enum WindowFit {
    /// One window the phone has sized.
    struct Record {
        let element: AXUIElement
        /// Where it was before the first fit.
        let original: CGRect
        /// Where the last fit left it, as the app took it (an app keeps a minimum width).
        var applied: CGRect
        var fit: WatchFit
    }

    /// Accessibility and the window server round differently; an app lands a point off.
    static let tolerance: CGFloat = 4

    /// Sizes the window for `fit`. Nil when it can't (Accessibility off, the window gone or full
    /// screen, the app refusing a size) — and for `.normal`, after putting it back.
    static func apply(_ fit: WatchFit, pid: pid_t, windowID: CGWindowID, record: Record?) -> Record? {
        guard AXIsProcessTrusted() else { return nil }
        if fit == .normal {
            if let record { restore(record) }
            return nil
        }
        let ax = AX.app(pid)
        guard let win = record?.element ?? AX.window(in: ax, id: windowID), AX.isAlive(win),
              !AX.bool(win, "AXFullScreen"), AX.isSettable(win, kAXSizeAttribute) else { return nil }
        let now = AX.frame(win)
        guard now.width > 50, now.height > 50, let area = visibleArea(around: now),
              let target = fit.frame(for: now, in: area) else { return nil }
        guard set(win, frame: target) else { return nil }
        let applied = AX.frame(win)
        return Record(element: win, original: record?.original ?? now, applied: applied, fit: fit)
    }

    /// Puts the window back where it was — if it's still where the fit left it. Moved or resized
    /// on the Mac since, it stays.
    static func restore(_ r: Record) {
        guard AXIsProcessTrusted(), AX.isAlive(r.element), !AX.bool(r.element, "AXFullScreen") else { return }
        let now = AX.frame(r.element)
        guard same(now, r.applied) else { return }
        _ = set(r.element, frame: r.original)
    }

    static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    /// Position, then size, then position again: a window that grows toward an edge is kept on
    /// screen by the app, which moves it; the second write puts the corner where it was asked.
    private static func set(_ win: AXUIElement, frame: CGRect) -> Bool {
        var origin = frame.origin, size = frame.size
        guard let p = AXValueCreate(.cgPoint, &origin), let s = AXValueCreate(.cgSize, &size) else { return false }
        let moved = AX.set(win, kAXPositionAttribute, p)
        let sized = AX.set(win, kAXSizeAttribute, s)
        _ = AX.set(win, kAXPositionAttribute, p)
        return moved && sized
    }

    /// The visible frame (under the menu bar, above the Dock) of the display the window is on,
    /// top-left origin.
    static func visibleArea(around r: CGRect) -> CGRect? {
        guard let primary = NSScreen.screens.first else { return nil }
        let h = primary.frame.height
        func flipped(_ f: CGRect) -> CGRect { CGRect(x: f.minX, y: h - f.maxY, width: f.width, height: f.height) }
        let center = CGPoint(x: r.midX, y: r.midY)
        let screen = NSScreen.screens.first { flipped($0.frame).contains(center) } ?? NSScreen.main ?? primary
        return flipped(screen.visibleFrame)
    }
}
