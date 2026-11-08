import MacrophoneKit
import SwiftUI

/// The small moments (Nov 8 2026, Sameer: "I just don't quite feel surprise and delight when
/// using this app … Do it."). One place that hears what happened to a dictation and lets the
/// screens make a moment of it — none of them in the way, none of them slower:
///
/// - **The words travel** (`WordFlightLayer`): as the words go out, they leave the transcript and
///   drop into the Dock icon they're going to; when the Mac says they landed, the icon catches
///   them with a small bounce (`DockCatch`) — or, if they didn't, it shakes its head.
/// - **Sounds** (`SoundCues`) at the catch: a tink, a breath of air for a send, falling for Undo.
/// - **Firsts and milestones** (`MilestoneBanner`): the first dictation that ever lands, and
///   1,000 / 10,000 / 100,000 words — counted here, on this iPhone, never sent anywhere; once each.
///
/// AppModel calls in at three moments (`wordsLeaving`, `landed` / `missed`, `undone`); nothing
/// here touches the link or the words' path, and nothing is logged but counts.
@MainActor
final class Delight: ObservableObject {
    static let shared = Delight()

    // MARK: The words travel

    /// Words on their way out: the flight layer takes them from the transcript to their place.
    struct Leaving: Equatable {
        let id = UUID()
        var words: String
        var target: TargetRef?
    }
    @Published private(set) var leaving: Leaving?
    /// Where the live words were last laid out (global), for the flight's start.
    var wordsFrame: CGRect = .zero

    private enum Flight { case none, flying, arrived }
    private var flight: Flight = .none
    /// A landing that came while the words were still in the air: the catch waits for them.
    private var pendingCatch: (ok: Bool, sent: Bool)?

    /// The words leave the phone (cleanup done, the send begins).
    func wordsLeaving(_ text: String, target: TargetRef?) {
        pendingCatch = nil
        let words = Self.firstWords(text)
        guard !words.isEmpty else { flight = .none; return }
        flight = .flying
        leaving = Leaving(words: words, target: target)
    }

    /// The flight layer couldn't fly them (no Dock on screen, Reduce Motion, another layout).
    func flightSkipped() { flightArrived() }

    /// The words reached their icon (or never flew): a landing already heard is caught now.
    func flightArrived() {
        flight = .arrived
        if let p = pendingCatch {
            pendingCatch = nil
            fireCatch(ok: p.ok, sent: p.sent)
        }
    }

    private func fireCatch(ok: Bool, sent: Bool) {
        DockCatches.shared.fire(ok: ok)
        if ok { SoundCues.play(sent ? .sent : .landed) }
        if ok, let m = queuedMilestone {
            queuedMilestone = nil
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 650_000_000)
                self.milestone = m
            }
        }
    }

    /// The first few words, as the flight carries them.
    static func firstWords(_ text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return "" }
        var out = ""
        for w in words {
            if out.count + w.count > 26 { return out.isEmpty ? String(w.prefix(24)) + "…" : out + "…" }
            out += out.isEmpty ? String(w) : " " + w
        }
        return out
    }

    // MARK: Landings

    /// A dictation landed (`AppModel.showLanding`).
    func landed(id: UUID, text: String, sent: Bool, history: [HistoryItem]) {
        countWords(id: id, text: text, history: history)
        if flight == .flying { pendingCatch = (true, sent) } else { fireCatch(ok: true, sent: sent) }
        flight = .none
    }

    /// It didn't land where it was going.
    func missed() {
        if flight == .flying { pendingCatch = (false, false) } else { fireCatch(ok: false, sent: false) }
        flight = .none
    }

    /// The Mac took a paste back: the falling tinks, and its words come off the count.
    func undone(id: UUID) {
        SoundCues.play(.undo)
        if let n = counted.removeValue(forKey: id) { words = max(0, words - n) }
    }

    // MARK: Firsts and milestones

    struct Milestone: Equatable, Identifiable {
        let id = UUID()
        var symbol: String
        var title: String
        var detail: String
    }
    @Published var milestone: Milestone?
    private var queuedMilestone: Milestone?

    static let marks = [1_000, 10_000, 100_000]
    private let d = UserDefaults.standard
    private enum K {
        static let words = "delight.words"
        static let seeded = "delight.seeded"
        static let first = "delight.firstLanded"
        static let shown = "delight.milestonesShown"
    }
    private var words: Int {
        get { d.integer(forKey: K.words) }
        set { d.set(newValue, forKey: K.words) }
    }
    /// The last few dictations counted, so an Undo can take its words back off.
    private var counted: [UUID: Int] = [:]

    private func countWords(id: UUID, text: String, history: [HistoryItem]) {
        seedIfNeeded(excluding: id, history: history)
        let n = text.split(whereSeparator: \.isWhitespace).count
        guard n > 0 else { return }
        let before = words
        words = before + n
        if counted.count > 8 { counted.removeAll() }
        counted[id] = n
        if !d.bool(forKey: K.first) {
            d.set(true, forKey: K.first)
            queuedMilestone = Milestone(symbol: "sparkles", title: "Your first dictation landed",
                                        detail: "Hold the mic for a long prompt, tap it for a quick one.")
            return
        }
        var shown = Set(d.array(forKey: K.shown) as? [Int] ?? [])
        if let mark = Self.marks.last(where: { before < $0 && words >= $0 }), !shown.contains(mark) {
            shown.insert(mark)
            d.set(Array(shown), forKey: K.shown)
            queuedMilestone = Self.milestone(for: mark)
        }
    }

    /// The first time this runs, the count starts from what History already holds — someone with
    /// months of dictations doesn't get "your first" or "1,000 words" the day this arrives.
    private func seedIfNeeded(excluding id: UUID, history: [HistoryItem]) {
        guard !d.bool(forKey: K.seeded) else { return }
        d.set(true, forKey: K.seeded)
        let earlier = history.filter { $0.id != id && ($0.delivery == .delivered || $0.delivery == .duplicate) }
        let total = earlier.reduce(0) { $0 + $1.dictation.text.split(whereSeparator: \.isWhitespace).count }
        words = total
        if !earlier.isEmpty { d.set(true, forKey: K.first) }
        d.set(Self.marks.filter { $0 <= total }, forKey: K.shown)
    }

    static func milestone(for mark: Int) -> Milestone {
        // Typing at 40 words a minute, speaking at 150: what saying them saved.
        let minutes = Double(mark) / 40 - Double(mark) / 150
        let saved = minutes < 90 ? "About \(Int(minutes.rounded())) minutes of typing saved."
            : "About \(Int((minutes / 60).rounded())) hours of typing saved."
        let count = mark.formatted(.number)
        switch mark {
        case 100_000: return Milestone(symbol: "books.vertical.fill", title: "\(count) words — a novel’s worth", detail: saved)
        default: return Milestone(symbol: "text.bubble.fill", title: "\(count) words, said not typed", detail: saved)
        }
    }

    #if DEBUG
    static let debugPluck = Notification.Name("macrophone.debug.pluck")

    /// `MACROPHONE_DELIGHT` (a recording): `first`, `milestone@1000`, `pluck@0.3`, `flight@<words>`,
    /// `catch`, `miss`, `undo` — each a second or so apart, in order, after `MACROPHONE_DELIGHT_AFTER` (3 s).
    func runDebugHooks() {
        guard let spec = DebugHooks.env["MACROPHONE_DELIGHT"] else { return }
        let start = Double(DebugHooks.env["MACROPHONE_DELIGHT_AFTER"] ?? "") ?? 3
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(start * 1e9))
            for step in spec.split(separator: ",").map(String.init) {
                let parts = step.split(separator: "@", maxSplits: 1).map(String.init)
                let arg = parts.count > 1 ? parts[1] : nil
                switch parts[0] {
                case "first":
                    milestone = Milestone(symbol: "sparkles", title: "Your first dictation landed",
                                          detail: "Hold the mic for a long prompt, tap it for a quick one.")
                case "milestone": milestone = Self.milestone(for: Int(arg ?? "") ?? 1_000)
                case "pluck": NotificationCenter.default.post(name: Self.debugPluck, object: Double(arg ?? "") ?? 0.5)
                case "flight": wordsLeaving(arg ?? "Refactor the auth view so the login form", target: nil)
                case "catch": landed(id: UUID(), text: "", sent: false, history: [])
                case "miss": missed()
                case "undo": SoundCues.play(.undo)
                case "wait": try? await Task.sleep(nanoseconds: UInt64((Double(arg ?? "") ?? 1) * 1e9)); continue
                default: break
                }
                try? await Task.sleep(nanoseconds: 1_400_000_000)
            }
        }
    }
    #endif
}

/// The Dock's catches: one event at a time, heard by the pick's icon (`DockCatch`). Its own
/// object, so a flight or a milestone never re-draws the Dock.
@MainActor
final class DockCatches: ObservableObject {
    static let shared = DockCatches()
    struct Event: Equatable { var seq: Int; var ok: Bool }
    @Published private(set) var event: Event?
    private var seq = 0

    func fire(ok: Bool) {
        seq += 1
        event = Event(seq: seq, ok: ok)
    }
}
