import Foundation

// The window's corner shape on the wire (Core/WindowMask.swift has the rule). Its own delegate
// protocol on the phone, like the cursor's (CursorLink.swift), so the big delegate stays as it is.
// The Mac app sends it when a watch's stream starts and whenever its picture size changes.

/// The phone's side: the watched window's corners, as the Mac read them.
@MainActor
public protocol LinkClientMaskDelegate: AnyObject {
    func linkClient(_ client: LinkClient, watchMask: WatchWindowMask)
}

extension LinkServer {
    /// The window's corners for this phone — only if its hello named the feature. False when it
    /// didn't, or isn't connected.
    @discardableResult
    public func sendMask(_ mask: WatchWindowMask, to peerID: UUID) async -> Bool {
        guard mask.isValid, phoneFeatures(peerID).contains(WatchWindowMask.feature) else { return false }
        return await send(.watchMask(mask), to: peerID)
    }
}

extension LinkClient {
    /// The connected Mac sends the window's corners (its welcome names it).
    public var macSendsMask: Bool { macFeatures.contains(WatchWindowMask.feature) }

    func deliverMask(_ m: WatchWindowMask) {
        guard m.isValid else { return }
        Task { @MainActor [weak self] in
            guard let self, let d = self.delegate as? LinkClientMaskDelegate else { return }
            d.linkClient(self, watchMask: m)
        }
    }
}
