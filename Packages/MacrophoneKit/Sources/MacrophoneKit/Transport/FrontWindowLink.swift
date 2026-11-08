import Foundation

// What's in front on the Mac, on the wire (Core/FrontWindow.swift has the rule). Its own delegate
// protocols, like the volume's (VolumeLink.swift), so the two big delegates stay as they are.

/// The Mac app's side: the window in front, when a phone that shows it connects.
@MainActor
public protocol LinkServerFrontWindowDelegate: AnyObject {
    /// The window in front now, for this phone (nil: nothing safe to offer).
    func frontWindow(_ server: LinkServer, for peerID: UUID) -> FrontWindow?
}

/// The phone's side: the window in front on the Mac it came from.
@MainActor
public protocol LinkClientFrontWindowDelegate: AnyObject {
    func linkClient(_ client: LinkClient, frontWindow: FrontWindow?, macID: UUID)
}

extension LinkServer {
    /// Right after the welcome, to a phone that named it.
    func sendFrontWindowAfterWelcome(to peerID: UUID, on session: SecureSession) {
        Task { [weak self] in
            guard let self, let d = await self.frontWindowDelegateOnMain() else { return }
            let w = await d.frontWindow(self, for: peerID)
            try? await session.send(.frontWindow(w))
        }
    }

    @MainActor func frontWindowDelegateOnMain() -> LinkServerFrontWindowDelegate? {
        delegate as? LinkServerFrontWindowDelegate
    }

    /// The window in front changed: send it to this phone — only if its hello named it (an older
    /// phone never gets a message it can't read). False when it didn't, or isn't connected.
    @discardableResult
    public func sendFrontWindow(_ window: FrontWindow?, to peerID: UUID) async -> Bool {
        guard phoneFeatures(peerID).contains(FrontWindow.feature) else { return false }
        return await send(.frontWindow(window), to: peerID)
    }

    /// The window in front changed: tell every phone that shows it.
    public func broadcastFrontWindow(_ window: FrontWindow?) {
        for id in phones(with: FrontWindow.feature) { Task { await self.sendFrontWindow(window, to: id) } }
    }
}

extension LinkClient {
    /// The connected Mac says what's in front (its welcome names it).
    public var macSendsFrontWindow: Bool { macFeatures.contains(FrontWindow.feature) }

    func deliverFrontWindow(_ w: FrontWindow?, macID: UUID) {
        Task { @MainActor [weak self] in
            guard let self, let d = self.delegate as? LinkClientFrontWindowDelegate else { return }
            d.linkClient(self, frontWindow: w, macID: macID)
        }
    }
}
