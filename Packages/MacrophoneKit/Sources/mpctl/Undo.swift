import Foundation
import MacrophoneKit

// `mpctl serve` answers an undo as the Mac does — for the last dictation it "pasted" (not sent),
// a moment ago — and presses nothing: "UNDO <id prefix> ok".
extension ServeDelegate: LinkServerUndoDelegate {
    func linkServer(_ server: LinkServer, undoPaste id: UUID, from peerID: UUID) async -> UndoResult {
        stdout("UNDO \(id.uuidString.prefix(8))")
        return UndoResult(id: id, ok: true, detail: "Undid the paste")
    }
}
