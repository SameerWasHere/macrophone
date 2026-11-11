import Foundation

// The latency pass (Nov 10 2026, Sameer: watching a Mac window from the phone should feel real
// time). Two rules the Mac's video pipe runs by, pure so they're tested here.

/// While he's touching it: for `window` seconds after any input from the phone for this watch — a
/// click, a pointer move, a key, typing, a held key, a scroll step, an answer chosen — every frame
/// that changed at all goes at the stream's own rate, a caret's worth included (a character typed
/// in a 2560-pixel window is a sliver, which the idle pace sends at fifteen a second). The change
/// is also measured on a finer grid then, so a glyph or a thin caret isn't missed by the idle
/// grid. A still window still sends nothing, and with no input the idle pace is unchanged.
public enum WatchTouchPace {
    /// How long after an input the window counts as being touched.
    public static let window: TimeInterval = 2
    /// The brightness plane's sample step while touched (the idle step is 8: a 2560-pixel window is
    /// 64 000 samples; 4 is 256 000, ~0.3 ms, only for these seconds).
    public static let fineStep = 4
    public static let idleStep = 8

    /// Touched: an input within `window` seconds (`sinceInput` is seconds since the last one; never
    /// touched is `.infinity`).
    public static func touched(sinceInput: TimeInterval) -> Bool { sinceInput >= 0 && sinceInput < window }

    /// The least time since the last frame before this one goes (`changed`: the share of the window
    /// changed since the last frame sent). Touched video: any change at all at the stream's rate —
    /// half its period, so a frame arriving a little early on the stream's clock never waits for
    /// the next. Otherwise `WatchPacing.minimumInterval` as before.
    public static func minimumInterval(changed: Double, sinceInput: TimeInterval, rate: Int, live: Bool = true, quick: Bool = true) -> TimeInterval {
        if changed <= 0 { return .infinity }
        if live, touched(sinceInput: sinceInput) { return 0.5 / Double(max(1, rate)) }
        return WatchPacing.minimumInterval(changed: changed, quick: quick, rate: rate, live: live)
    }

    /// The sample step for the brightness plane (video frames); pictures (BGRA) keep their 4.
    public static func sampleStep(planar: Bool, sinceInput: TimeInterval) -> Int {
        guard planar else { return 4 }
        return touched(sinceInput: sinceInput) ? fineStep : idleStep
    }
}

/// The picture's width follows the wire (Nov 10 2026): when frames back up on the way to the phone
/// (a slow Wi-Fi, a cellular link over Tailscale), the stream steps down a width — fewer bytes a
/// frame, so the wire catches up — and steps back up only after a sustained stretch of fast sends.
/// Hysteresis both ways (a step down needs several slow sends in a short run, a step up a long run
/// of fast ones, and no step within `settle` of the last), so it never flaps. The phone keeps its
/// view when the same window comes in at another resolution (`WatchReconnect.sameShape`).
public struct WatchWireSizer: Sendable, Equatable {
    /// The widths it steps through, widest first (pixels). The top is the watch's own ceiling
    /// (2560 at home, 1600 away); a ceiling below a step skips it.
    public static let steps: [Int] = [2560, 1600, 1000]
    /// A send this slow (seconds — a frame from handing to the sender to on the wire) is slow.
    public static let slowSend = 0.08
    /// One this quick is fast.
    public static let fastSend = 0.025
    /// Of the last `recent` sends, this many slow (or `heldLimit` frames held for the wire among
    /// them) steps down.
    public static let recent = 10
    public static let slowToStepDown = 6
    /// Fast sends in a row to step up.
    public static let fastToStepUp = 90
    /// And this long since the last step, either way.
    public static let settleDown: TimeInterval = 2
    public static let settleUp: TimeInterval = 8

    public let ceiling: Int
    /// The width now (the stream's maximum).
    public private(set) var width: Int
    /// The width the frames really have (a window narrower than `width` streams at its own): a step
    /// down goes below this, never to a step that changes nothing.
    public var showing: Int?
    private var lastSends: [Double] = []
    private var fastRun = 0
    private var held = 0
    private var steppedAt: TimeInterval = -.infinity
    private var upAt: TimeInterval = -.infinity
    /// Doubles each time a step up is undone within `relapse` (at most 8): a link that can't hold
    /// the wider picture isn't offered it again every few seconds.
    public private(set) var upBackoff = 1
    /// A step down this soon after a step up undoes it.
    public static let relapse: TimeInterval = 30

    /// `ceiling`: the widest this watch sends (the stream's own maximum width).
    /// `width`: where it starts (a watch already stepped down keeps its step across a new stream) —
    /// the widest step at or under it.
    public init(ceiling: Int, width: Int? = nil) {
        self.ceiling = ceiling
        let ladder = [ceiling] + Self.steps.filter { $0 < ceiling }
        self.width = ladder.first { $0 <= (width ?? ceiling) } ?? ladder.last ?? ceiling
    }

    /// The widths below the ceiling, widest first, the ceiling itself on top.
    public var ladder: [Int] { [ceiling] + Self.steps.filter { $0 < ceiling } }

    /// A step: the new width, and the median of the recent sends that made it.
    public struct Step: Sendable, Equatable {
        public var width: Int
        public var down: Bool
        public var sendMs: Int
        /// Frames held back for the wire since the last quick send (what stepped it, when the
        /// sends themselves still returned quickly — the backlog in the socket's own buffer).
        public var held: Int = 0
    }

    /// A frame went onto the wire after `seconds`, at `now` (any clock, seconds). Returns a step
    /// when the width should change.
    public mutating func sent(seconds: Double, at now: TimeInterval) -> Step? {
        lastSends.append(seconds)
        if lastSends.count > Self.recent { lastSends.removeFirst() }
        fastRun = seconds <= Self.fastSend ? fastRun + 1 : 0
        // Frames held for the wire count only while no send has been quick since.
        if seconds < Self.slowSend { held = 0 }
        return decide(at: now)
    }

    /// A frame was held back because the wire was behind (two handed in, not yet sent).
    public mutating func heldForWire(at now: TimeInterval) -> Step? {
        held += 1
        fastRun = 0
        return decide(at: now)
    }

    private mutating func decide(at now: TimeInterval) -> Step? {
        let ladder = self.ladder
        guard let i = ladder.firstIndex(of: width) else { width = ceiling; return nil }
        let slow = lastSends.filter { $0 >= Self.slowSend }.count
        let below = ladder.dropFirst(i + 1).first { $0 < min(width, showing ?? width) }
        if let below, now - steppedAt >= Self.settleDown,
           (lastSends.count >= Self.recent && slow >= Self.slowToStepDown) || held >= Self.recent {
            return step(to: below, down: true, at: now)
        }
        if i > 0, fastRun >= Self.fastToStepUp * upBackoff, now - steppedAt >= Self.settleUp {
            return step(to: ladder[i - 1], down: false, at: now)
        }
        return nil
    }

    private mutating func step(to w: Int, down: Bool, at now: TimeInterval) -> Step {
        if down { upBackoff = now - upAt < Self.relapse ? min(8, upBackoff * 2) : 1 } else { upAt = now }
        let sorted = lastSends.sorted()
        let median = sorted.isEmpty ? 0 : Int(sorted[sorted.count / 2] * 1000)
        let heldNow = held
        width = w
        steppedAt = now
        lastSends = []
        fastRun = 0
        held = 0
        return Step(width: w, down: down, sendMs: median, held: heldNow)
    }
}
