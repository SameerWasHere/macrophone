import Foundation

// Undo the last paste on the wire (Core/UndoPaste.swift has the rule). Its own delegate
// protocols, like the wallpaper's (WallpaperLink.swift).

/// The Mac app's side: undo this dictation's paste, and say how it went.
@MainActor
public protocol LinkServerUndoDelegate: AnyObject {
    func linkServer(_ server: LinkServer, undoPaste id: UUID, from peerID: UUID) async -> UndoResult
}

/// The phone's side: what the Mac's undo did.
@MainActor
public protocol LinkClientUndoDelegate: AnyObject {
    func linkClient(_ client: LinkClient, undoDone: UndoResult)
}

extension LinkServer {
    func handleUndo(_ id: UUID, from peerID: UUID, on session: SecureSession) {
        Task { [weak self] in
            guard let self else { return }
            guard let result = await self.undoOnMain(id, from: peerID) else { return }
            try? await session.send(.undoDone(result))
        }
    }

    @MainActor private func undoOnMain(_ id: UUID, from peerID: UUID) async -> UndoResult? {
        guard let d = delegate as? LinkServerUndoDelegate else { return nil }
        return await d.linkServer(self, undoPaste: id, from: peerID)
    }
}

extension LinkClient {
    /// The connected Mac undoes its last paste when asked (its welcome names it).
    public var macCanUndo: Bool { macFeatures.contains(UndoPaste.feature) }

    /// Asks the Mac to undo this dictation's paste. False when it can't be asked.
    @discardableResult
    public func undoPaste(_ id: UUID) -> Bool {
        guard macCanUndo, let s = currentSession else { return false }
        s.post(.undoPaste(id: id))
        return true
    }

    func deliverUndo(_ r: UndoResult) {
        Task { @MainActor [weak self] in
            guard let self, let d = self.delegate as? LinkClientUndoDelegate else { return }
            d.linkClient(self, undoDone: r)
        }
    }
}
