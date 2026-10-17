import AppKit
import CoreGraphics
import Foundation
import MacrophoneKit

/// A phone's swipes onto the Mac, off the main thread (Oct 17 2026): each step and phase comes
/// straight from the link's receive loop (`LinkServer.watchInput`) and is posted from this
/// poster's own serial queue — sixty a second during a swipe, and the main actor sees none of
/// them. The window's frame is looked up at a swipe's start and again when a second old; the
/// phase bookkeeping is `ScrollEvents`; a swipe gone quiet is closed by a timer here; the pointer,
/// which a scroll event posted at a spot moves there, is put back once the swipe is over.
/// `WatchService` tells it which window, and hears about a swipe's start (to bring the window
/// forward if another covers the spot — the steps don't wait for that).
final class ScrollPoster: @unchecked Sendable {
    private let queue = DispatchQueue(label: "macrophone.watch-scroll", qos: .userInteractive)
    private var events = ScrollEvents()
    private var bounds: CGRect?
    private var boundsAt = Date.distantPast
    private var point = CGPoint.zero
    private var cursorBefore: CGPoint?
    private var watchdog: DispatchWorkItem?
    private var timing = false
    private var actionAt = Date.distantPast
    private let lock = NSLock()
    private var windowID: CGWindowID?
    private(set) var steps = 0
    private(set) var gestures = 0

    /// Called on `queue` when a swipe lands, with its spot on screen: the main-actor side checks
    /// whether another window covers it there and brings the watched one forward if so.
    var onBegan: (@Sendable (CGPoint) -> Void)?
    /// Called on `queue` with every step and phase: the video pipe sends any change at the
    /// stream's rate while a swipe is under way.
    var onInput: (@Sendable () -> Void)?

    init(timing: Bool) { self.timing = timing }

    /// The window the swipes go to (nil while it isn't found).
    var window: CGWindowID? {
        get { lock.lock(); defer { lock.unlock() }; return windowID }
        set { lock.lock(); windowID = newValue; lock.unlock(); queue.async { self.bounds = nil } }
    }

    /// A step: scroll at `p` (fractions of the window) by `d` (fractions).
    func scroll(at p: CGPoint, by d: CGVector) {
        queue.async {
            self.steps += 1
            self.onInput?()
            guard let b = self.frame(at: p) else { return }
            guard let e = self.events.delta(dx: d.dx * b.width, dy: d.dy * b.height) else { return }
            self.post(e)
            if self.timing, e.phase == .began || e.phase == .momentumBegan { print("[watch] scroll \(e.phase) posted \(Int(Date().timeIntervalSince(self.actionAt) * 1000)) ms after the action"); fflush(stdout) }
            self.rearm()
        }
    }

    /// Where the swipe is: landed, lifted, coasting.
    func phase(_ phase: WatchScrollPhase, at p: CGPoint) {
        queue.async {
            if phase == .began {
                self.gestures += 1
                self.actionAt = Date()
                self.boundsAt = .distantPast
            }
            self.onInput?()
            guard self.frame(at: p) != nil else { return }
            if phase == .began { self.onBegan?(self.point) }
            if let e = self.events.phase(phase) { self.post(e) }
            self.rearm()
        }
    }

    /// The swipe ended for good (the watch stopped): the pointer goes back.
    func stop() {
        queue.async {
            self.watchdog?.cancel()
            if let c = self.cursorBefore { CGWarpMouseCursorPosition(c); self.cursorBefore = nil }
        }
    }

    /// queue: the window's frame, looked up at most once a second, and the swipe's spot in it.
    private func frame(at p: CGPoint) -> CGRect? {
        guard let wid = window else { return nil }
        if bounds == nil || Date().timeIntervalSince(boundsAt) > 1 {
            bounds = WindowServer.bounds(of: wid)
            boundsAt = Date()
        }
        guard let b = bounds else { return nil }
        point = CGPoint(x: b.minX + p.x * b.width, y: b.minY + p.y * b.height)
        if cursorBefore == nil { cursorBefore = CGEvent(source: nil)?.location }
        return b
    }

    /// queue: closes a swipe gone quiet, or puts the pointer back once it's over.
    private func rearm() {
        watchdog?.cancel()
        let item: DispatchWorkItem
        let delay: TimeInterval
        if let timeout = events.idleTimeout {
            delay = timeout
            item = DispatchWorkItem { [weak self] in
                guard let self, let e = self.events.quiet() else { return }
                self.post(e)
                self.rearm()
            }
        } else {
            delay = 0.6
            item = DispatchWorkItem { [weak self] in
                guard let self, let c = self.cursorBefore else { return }
                self.cursorBefore = nil
                CGWarpMouseCursorPosition(c)
            }
        }
        watchdog = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// One scroll event, at the spot (the event carries its own place, which routes it to the
    /// window under it, in front or not). Inside a gesture it is a continuous (trackpad) scroll
    /// with point deltas and the phase fields set — what makes an app rubber-band and coast;
    /// outside one the plain pixel wheel event a phone from before always got. Content follows the
    /// finger: dragging down shows what's above (a positive wheel).
    private func post(_ e: ScrollEvents.Event) {
        guard let ev = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: e.wheel1, wheel2: e.wheel2, wheel3: 0) else { return }
        ev.location = point
        if e.phase != .none {
            ev.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            ev.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(e.wheel1))
            ev.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(e.wheel2))
            // Exactly one of the two is set: a coast's events carry no scroll phase.
            let scroll: CGScrollPhase? = switch e.phase { case .began: .began; case .changed: .changed; case .ended: .ended; default: nil }
            let momentum: CGMomentumScrollPhase? = switch e.phase { case .momentumBegan: .begin; case .momentumChanged: .continuous; case .momentumEnded: .end; default: nil }
            ev.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(scroll?.rawValue ?? 0))
            ev.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum?.rawValue ?? 0))
        }
        ev.post(tap: .cghidEventTap)
    }
}
