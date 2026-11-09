import Foundation
import MacrophoneKit

// `mpctl serve` takes an answer from a notification's button as the Mac does, and presses
// nothing: "ALERT ANSWER 1 for <prompt id prefix>".
extension ServeDelegate: LinkServerAlertAnswerDelegate {
    func linkServer(_ server: LinkServer, answer: AlertAnswer, from peerID: UUID) async -> AlertAnswerResult {
        stdout("ALERT ANSWER \(answer.index + 1) for \(answer.promptID.prefix(8))")
        return AlertAnswerResult(ok: true, detail: "Answered")
    }
}
