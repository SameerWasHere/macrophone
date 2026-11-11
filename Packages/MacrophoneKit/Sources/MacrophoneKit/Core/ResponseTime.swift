import CoreGraphics
import Foundation

// How long the Mac takes to answer a finger (Nov 10 2026, Sameer: watching should feel real
// time). The phone times each input it sends — a tap or click, a key or a typed character, a
// scroll's first step, a trackpad click — to the next video frame put on screen after it. It is
// the whole loop as he feels it: the wire there, the Mac posting the event and the app redrawing,
// the capture, the encode, the wire back, the decode and the display.
//
// Only one input is timed at a time (the earliest still unanswered): inputs while one waits add
// nothing, so a burst of typing is timed by its first key, not counted twelve times against one
// frame. A frame that was already on its way when the input went counts too — the time is never
// more than the truth, and a busy window (a spinner) can make it read low; a still window that
// doesn't change for the input sends nothing, and the wait is dropped after `giveUpAfter`.

/// The input-to-picture time, pure (the phone's `Watcher` feeds it real times).
public struct ResponseClock: Sendable, Equatable {
    /// An input with no frame after it this long is forgotten (the window didn't change for it).
    public static let giveUpAfter: TimeInterval = 2
    /// How many recent times the median and p90 are taken over.
    public static let window = 200

    /// When the input being timed went (seconds, the caller's clock); nil when none waits.
    public private(set) var waitingSince: TimeInterval?
    /// The recent times, milliseconds, oldest first.
    public private(set) var samples: [Double] = []
    /// Every time measured since the last reset (the log's "over K inputs").
    public private(set) var count = 0
    /// Every time since the reset, for the closing line (kept short: whole milliseconds).
    private var all: [Int] = []

    public init() {}

    /// The newest time, ms.
    public var last: Double? { samples.last }
    /// The median of the recent times, ms.
    public var median: Double? { Self.quantile(samples, 0.5) }
    public var p90: Double? { Self.quantile(samples, 0.9) }

    /// An input went at `t`. Starts the timing unless one is already waiting (and still fresh).
    public mutating func input(at t: TimeInterval) {
        if let since = waitingSince, t - since < Self.giveUpAfter { return }
        waitingSince = t
    }

    /// A frame went on screen at `t`: the time it answered the waiting input, ms, if any.
    @discardableResult
    public mutating func frameShown(at t: TimeInterval) -> Double? {
        guard let since = waitingSince else { return nil }
        waitingSince = nil
        let ms = (t - since) * 1000
        guard ms >= 0, t - since < Self.giveUpAfter else { return nil }
        samples.append(ms)
        if samples.count > Self.window { samples.removeFirst(samples.count - Self.window) }
        count += 1
        if all.count < 20_000 { all.append(Int(ms.rounded())) }
        return ms
    }

    /// The window changed (another one, a pause): a wait in flight is dropped, the times kept.
    public mutating func dropWaiting() { waitingSince = nil }

    /// A new watch: everything starts over.
    public mutating func reset() { self = ResponseClock() }

    /// The closing line, numbers only: nil with nothing measured.
    public var summary: String? {
        guard count > 0 else { return nil }
        let a = all.map(Double.init)
        let med = Int((Self.quantile(a, 0.5) ?? 0).rounded())
        let p90 = Int((Self.quantile(a, 0.9) ?? 0).rounded())
        return "watching: response median \(med) ms, p90 \(p90) ms over \(count) input\(count == 1 ? "" : "s")"
    }

    /// The `q` quantile (nearest rank) of `xs`; nil when empty.
    public static func quantile(_ xs: [Double], _ q: Double) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        let i = min(s.count - 1, max(0, Int((Double(s.count) * q).rounded(.up)) - 1))
        return s[i]
    }
}

/// Scrolling that answers the finger before the Mac does (Nov 10 2026), pure. The phone sends a
/// swipe's deltas and the picture only moves when the Mac's frame for them comes back, a response
/// time later. This keeps the deltas sent within that time — the ones the picture can't show yet —
/// and gives the shift that would put the picture where the finger is: their sum, capped, settling
/// to nothing as they age past the response time (by then the Mac's frame shows them). Points of
/// the view, the direction the finger moved (the Mac moves its content the way the finger drags).
public struct ScrollPrediction: Sendable, Equatable {
    /// The most the picture is ever shifted, points.
    public static let cap: CGFloat = 120
    /// A response time past this isn't predicted over (a stalled link: the picture would slide off
    /// with nothing behind it).
    public static let longestLag: TimeInterval = 0.6

    private var sent: [(t: TimeInterval, d: CGVector)] = []

    public init() {}

    public static func == (a: ScrollPrediction, b: ScrollPrediction) -> Bool {
        a.sent.count == b.sent.count && zip(a.sent, b.sent).allSatisfy { $0.t == $1.t && $0.d == $1.d }
    }

    /// A delta went to the Mac at `t`.
    public mutating func sent(_ d: CGVector, at t: TimeInterval) {
        guard d.dx.isFinite, d.dy.isFinite else { return }
        sent.append((t, d))
    }

    /// The shift at `t` for a response time of `lag` seconds: what was sent in the last `lag`.
    public mutating func offset(at t: TimeInterval, lag: TimeInterval) -> CGVector {
        guard lag > 0, lag <= Self.longestLag else { sent.removeAll(); return .zero }
        sent.removeAll { t - $0.t >= lag }
        var dx: CGFloat = 0, dy: CGFloat = 0
        for s in sent { dx += s.d.dx; dy += s.d.dy }
        let length = hypot(dx, dy)
        if length > Self.cap { dx *= Self.cap / length; dy *= Self.cap / length }
        return CGVector(dx: dx, dy: dy)
    }

    /// Nothing left to show (every delta older than the lag).
    public var isEmpty: Bool { sent.isEmpty }

    public mutating func clear() { sent.removeAll() }
}
