import Foundation

// The Mac's pointer shape on the wire (Core/MacCursor.swift has the rule). Its own delegate
// protocol on the phone, like the wallpaper's (WallpaperLink.swift), so the big delegate stays as
// it is. The Mac app sends it when its watch sees the shape change.

/// The phone's side: the pointer shape of the Mac it came from.
@MainActor
public protocol LinkClientCursorDelegate: AnyObject {
    func linkClient(_ client: LinkClient, macCursor: MacCursor)
}

extension LinkServer {
    /// The pointer's shape changed (or the phone's pointer just showed): send it to this phone —
    /// only if its hello named it. False when it didn't, or isn't connected.
    @discardableResult
    public func sendCursor(_ cursor: MacCursor, to peerID: UUID) async -> Bool {
        guard cursor.isValid, phoneFeatures(peerID).contains(MacCursor.feature) else { return false }
        return await send(.macCursor(cursor), to: peerID)
    }
}

extension LinkClient {
    /// The connected Mac sends its pointer's shape (its welcome names it).
    public var macSendsCursor: Bool { macFeatures.contains(MacCursor.feature) }

    func deliverCursor(_ c: MacCursor) {
        guard c.isValid else { return }
        Task { @MainActor [weak self] in
            guard let self, let d = self.delegate as? LinkClientCursorDelegate else { return }
            d.linkClient(self, macCursor: c)
        }
    }
}
