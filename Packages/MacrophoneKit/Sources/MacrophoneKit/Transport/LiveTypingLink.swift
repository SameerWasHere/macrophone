import Foundation

// Type as I speak on the wire (Core/LiveTyping.swift has the rules). Its own delegate protocol,
// like the undo's (UndoLink.swift).

/// The Mac app's side: a piece of a dictation typed live (or its cancel). Pieces are numbered; the
/// Mac puts them in order itself (`LivePiece.seq`).
@MainActor
public protocol LinkServerLiveDelegate: AnyObject {
    func linkServer(_ server: LinkServer, livePiece: LivePiece, from peerID: UUID)
}

extension LinkServer {
    func handleLivePiece(_ piece: LivePiece, from peerID: UUID) {
        // A piece this Mac can't take (too big, a number out of range) is dropped, never a session's end.
        guard piece.isValid else { return }
        Task { @MainActor [weak self] in
            guard let self, let d = self.delegate as? LinkServerLiveDelegate else { return }
            d.linkServer(self, livePiece: piece, from: peerID)
        }
    }
}

extension LinkClient {
    /// The connected Mac types a dictation as it's spoken (its welcome names it).
    public var macTypesLive: Bool { macFeatures.contains(LiveTyping.feature) }

    /// Sends one piece, in order behind the ones before it. False when it can't (no session, or a
    /// Mac from before): the dictation then goes the usual way at the end.
    @discardableResult
    public func sendLivePiece(_ piece: LivePiece) -> Bool {
        guard macTypesLive, let s = currentSession else { return false }
        s.post(.livePiece(piece))
        return true
    }
}
