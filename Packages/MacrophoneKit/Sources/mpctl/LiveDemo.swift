import Foundation
import MacrophoneKit

// `mpctl serve` as a Mac that types live (Type as I speak, Core/LiveTyping.swift): it keeps what it
// "typed" per dictation as a stand-in text box, prints counts only (never the words), and at the end
// prints the plan the Mac would follow. `--no-live` is a Mac from before (the phone sends none).
//   LIVE piece 3: +12 −0 (typed 41)
//   LIVE end: 14 pieces, 212 characters typed, 3 taken back; plan: replace 41 characters with 44
//   LIVE cancel: took back 41 characters (6 pieces)
@MainActor
enum LiveDemo {
    static var typed: [UUID: String] = [:]
    static var counts: [UUID: LiveCounts] = [:]
    static var nextSeq: [UUID: Int] = [:]
    static var waiting: [UUID: [Int: LivePiece]] = [:]

    static func piece(_ p: LivePiece) {
        waiting[p.id, default: [:]][p.seq] = p
        while let q = waiting[p.id]?.removeValue(forKey: nextSeq[p.id] ?? 1) {
            nextSeq[p.id] = q.seq + 1
            apply(q)
        }
    }

    private static func apply(_ p: LivePiece) {
        var t = typed[p.id] ?? ""
        var c = counts[p.id] ?? LiveCounts()
        if p.isCancel {
            stdout("LIVE cancel: took back \(t.count) characters (\(c.pieces) pieces)")
            typed[p.id] = nil
            counts[p.id] = nil
            return
        }
        let d = min(p.delete, t.count)
        t = String(t.dropLast(d)) + p.text
        c.pieces += 1
        c.typed += p.text.count
        c.deleted += d
        typed[p.id] = t
        counts[p.id] = c
        stdout("LIVE piece \(p.seq): +\(p.text.count) −\(d) (typed \(t.count))")
    }

    static func waitAndFinish(_ d: Dictation) async {
        let end = Date().addingTimeInterval(LiveTyping.piecesWait)
        while Date() < end, (nextSeq[d.id] ?? 1) <= (d.livePieces ?? 0) {
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        finish(d)
    }

    /// The final dictation of a live one: what the Mac would do (a readable box holding exactly what
    /// it typed, the caret at its end, nothing touched).
    static func finish(_ d: Dictation) {
        guard let n = d.livePieces else { return }
        let t = typed.removeValue(forKey: d.id) ?? ""
        let c = counts.removeValue(forKey: d.id) ?? LiveCounts()
        let field = LiveReconcile.Field(value: t, caret: t.utf16.count)
        let plan = LiveReconcile.plan(typed: t, final: d.text, field: field, untouched: true)
        let words: String
        switch plan {
        case .nothing: words = "nothing to correct"
        case let .replace(_, length, text): words = "replace \(length) characters with \(text.count)"
        case let .backspace(delete, text): words = "\(delete) Deletes, then \(text.count) characters"
        case .deliverNormally: words = "the usual paste"
        }
        let missing = n - c.pieces
        stdout("LIVE end: \(c.line)\(missing > 0 ? " (\(missing) pieces never arrived)" : ""); plan: \(words)")
    }
}

extension ServeDelegate: LinkServerLiveDelegate {
    func linkServer(_ server: LinkServer, livePiece: LivePiece, from peerID: UUID) {
        LiveDemo.piece(livePiece)
    }
}
