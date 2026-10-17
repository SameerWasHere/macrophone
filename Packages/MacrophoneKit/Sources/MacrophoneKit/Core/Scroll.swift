import CoreGraphics
import Foundation

// A swipe as a trackpad gesture (Oct 17 2026, after Sill). A swipe on the phone's picture used to
// reach the Mac as bare scroll-wheel ticks: the Mac's apps never saw a gesture, so nothing
// rubber-banded at an edge and a flick stopped dead when the finger lifted. Now the phone
// brackets its deltas with phases — the finger landed, lifted — and after a flick runs the coast
// itself, a delta per display frame (macOS adds momentum in its trackpad driver, below where a
// posted event enters, so the Mac won't make one), bracketed too. The Mac posts each delta as a
// continuous scroll event with the phase fields a trackpad sets, at the finger's spot.
//
// Gated by the welcome: a phone sends the phases only to a Mac that named "scroll" (an unknown
// message ends a session); to any other Mac a swipe is the deltas alone, as before. The deltas
// themselves are the `watchScroll` message every Mac understands.

public enum WatchScroll {
    /// The Mac takes a swipe's phases (`watchScrollPhase`) and posts it as a trackpad gesture.
    public static let feature = "scroll"
}

/// A swipe's input as the Mac's link hands it on, straight from its receive loop
/// (`LinkServer.watchInput`): a step, or a phase.
public enum WatchInput: Sendable, Equatable {
    /// Scroll at a point (fractions of the window) by a delta (fractions).
    case scroll(at: CGPoint, by: CGVector)
    case phase(WatchScrollPhase, at: CGPoint)
}

/// Where a swipe is: the finger landed, lifted; the coast after a flick began, ended.
public enum WatchScrollPhase: String, Codable, Sendable, CaseIterable {
    case began
    case ended
    case momentumBegan
    case momentumEnded
}

/// The Mac's side, pure: the phone's phases and deltas (in points of the window) become the scroll
/// events to post, each with the phase a trackpad would stamp on it. The wheel fields are whole
/// points, so the rounding remainder is carried into the next event — a slow drag, and the tail
/// of every coast, is made of sub-point steps that would otherwise scroll nothing.
///
///   began          → nothing yet; the first delta goes out as the gesture's `began`
///   deltas         → `changed`
///   ended          → one empty event, `ended`
///   momentumBegan  → nothing yet; the first delta is `momentumBegan`
///   deltas         → `momentumChanged`
///   momentumEnded  → one empty event, `momentumEnded`
///
/// A phase with no delta inside it (a swipe that never moved) posts nothing, so the Mac never
/// sees an end without its beginning. Outside any phase (a phone from before) a delta is the plain
/// wheel event it always was.
public struct ScrollEvents: Sendable, Equatable {
    public enum Phase: Equatable, Sendable {
        /// A bare wheel event (no gesture).
        case none
        case began, changed, ended
        case momentumBegan, momentumChanged, momentumEnded

        /// Opens a gesture or a coast: the event's deltas, if any, are the first of it.
        var opens: Bool { self == .began || self == .momentumBegan }
    }

    public struct Event: Equatable, Sendable {
        /// Up and down (positive moves the content down, like a finger dragging it), then sideways.
        public var wheel1: Int32
        public var wheel2: Int32
        public var phase: Phase
    }

    private enum State: Equatable { case idle, gesture(begun: Bool), momentum(begun: Bool) }
    private var state = State.idle
    private var remainder = CGPoint.zero

    public init() {}

    /// A swipe that goes quiet this long with no message is closed (`quiet`): fingers resting
    /// mid-swipe send nothing, so a gesture gets a generous wait; a coast steps sixty times a
    /// second, so half a second of silence means it died. Nil when nothing is open.
    public var idleTimeout: TimeInterval? {
        switch state {
        case .idle: return nil
        case .gesture: return 2
        case .momentum: return 0.5
        }
    }

    /// The phone said where its swipe is. The event to post, if any (an open phase's closing one).
    public mutating func phase(_ p: WatchScrollPhase) -> Event? {
        var closing: Event?
        switch p {
        case .began:
            closing = close()
            state = .gesture(begun: false)
            remainder = .zero
        case .ended:
            closing = close()
        case .momentumBegan:
            closing = close()
            state = .momentum(begun: false)
        case .momentumEnded:
            closing = close()
        }
        return closing
    }

    /// A delta, in points: the event to post, with the phase the swipe is in.
    public mutating func delta(dx: Double, dy: Double) -> Event? {
        // Int32(Double) traps on NaN and anything past its range: a bad delta is dropped, a huge
        // one clamped before converting.
        guard dx.isFinite, dy.isFinite else { return nil }
        let limit = Double(Int32.max)
        let exact = CGPoint(x: dx + remainder.x, y: dy + remainder.y)
        let w1 = min(max(exact.y.rounded(), -limit), limit)
        let w2 = min(max(exact.x.rounded(), -limit), limit)
        remainder = CGPoint(x: exact.x - w2, y: exact.y - w1)
        if abs(remainder.x) >= 1 || abs(remainder.y) >= 1 { remainder = .zero }
        let phase: Phase
        switch state {
        case .idle: phase = .none
        case .gesture(let begun): phase = begun ? .changed : .began; state = .gesture(begun: true)
        case .momentum(let begun): phase = begun ? .momentumChanged : .momentumBegan; state = .momentum(begun: true)
        }
        return Event(wheel1: Int32(w1), wheel2: Int32(w2), phase: phase)
    }

    /// The swipe went quiet (`idleTimeout` passed with no message): the open phase is closed on the
    /// Mac, but the swipe keeps its shape, un-begun — if the phone was only resting and its deltas
    /// resume, they start a fresh gesture rather than continue one the Mac saw end.
    public mutating func quiet() -> Event? {
        let was = state
        let closing = close()
        switch was {
        case .gesture: state = .gesture(begun: false)
        case .momentum: state = .momentum(begun: false)
        case .idle: break
        }
        return closing
    }

    /// The closing event for whatever is open, then idle.
    private mutating func close() -> Event? {
        defer { state = .idle }
        switch state {
        case .gesture(begun: true): return Event(wheel1: 0, wheel2: 0, phase: .ended)
        case .momentum(begun: true): return Event(wheel1: 0, wheel2: 0, phase: .momentumEnded)
        default: return nil
        }
    }
}

/// The phone's side, pure: the coast after a flick. Starts at the lift-off speed and decays a
/// little every sixtieth of a second until a step would move less than a third of a point; the
/// owner steps it on a display link and sends each step as a delta, bracketed by the momentum
/// phases. A lift under `minimumSpeed` is a placement, not a flick: no coast.
public struct ScrollMomentum: Sendable, Equatable {
    /// Points a second, below which a swipe just stops.
    public static let minimumSpeed = 150.0
    /// The rate the decay is defined at — a 120 Hz display sends no more than sixty a second.
    public static let tickRate = 60.0
    /// Velocity kept per tick: a flick of 1000–3000 points a second coasts for about 1.6–2.1 s,
    /// inside the tail of a Mac trackpad's.
    public static let decayPerTick = 0.96
    /// A tick that would move less than this many points ends the coast.
    public static let stopBelow = 0.3

    /// Points a second, decaying.
    public private(set) var velocity: CGVector

    /// Nil unless the lift was a flick.
    public init?(velocity: CGVector) {
        guard velocity.dx.isFinite, velocity.dy.isFinite, hypot(velocity.dx, velocity.dy) > Self.minimumSpeed else { return nil }
        self.velocity = velocity
    }

    /// The next step, in points, after `dt` seconds — nil when the coast is over. Real time, so a
    /// skipped frame doesn't slow it; clamped, so a long stall can't become one big jump.
    public mutating func step(dt: TimeInterval) -> CGVector? {
        let dt = min(max(dt, 0), 0.1)
        let decay = pow(Self.decayPerTick, dt * Self.tickRate)
        velocity = CGVector(dx: velocity.dx * decay, dy: velocity.dy * decay)
        guard hypot(velocity.dx, velocity.dy) / Self.tickRate >= Self.stopBelow else { return nil }
        return CGVector(dx: velocity.dx * dt, dy: velocity.dy * dt)
    }
}
